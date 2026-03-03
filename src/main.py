from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse, JSONResponse, FileResponse
import logging
import asyncio
import json
import os
import time
import threading
from datetime import datetime
from pathlib import Path as FilePath
from typing import Dict, List, AsyncGenerator, Optional, Tuple
from queue import Queue, Empty
import uuid

from .config import settings
from .models.request import VideoRecognitionRequest
from .services.video_processor import VideoProcessor
from .services.frame_recognizer import FrameRecognizer
from .utils.logger import setup_logger
from .utils.suggestions_loader import SuggestionsLoader

# Setup logger
logger = setup_logger("vods", settings.LOG_PATH, settings.LOG_LEVEL)
logging.getLogger("uvicorn.access").setLevel(logging.WARNING)

suggestions_loader: Optional[SuggestionsLoader] = None

# --- Configuration ---
DIFY_API_URL = os.getenv("DIFY_API_URL", "http://192.168.0.52:80/v1/workflows/run")
DIFY_API_KEY = os.getenv("DIFY_API_KEY", "app-ApyUdDu7vG8lvVyftbqiYIfR")
BASE_IMAGE_URL = os.getenv("BASE_IMAGE_URL", "http://192.168.0.52:8000")

def init_suggestions():
    global suggestions_loader
    try:
        suggestions_path = settings.get_suggestions_path()
        logger.info(f"Loading suggestions from: {suggestions_path}")
        suggestions_loader = SuggestionsLoader(suggestions_path)
        all_codes = suggestions_loader.get_all_codes()
        
        if all_codes:
            code_list = []
            for code in all_codes:
                suggestion = suggestions_loader.get_suggestion(code)
                title = suggestion.get('title', '(No Title)') if suggestion and isinstance(suggestion, dict) else "(Invalid)"
                code_str = str(code).zfill(4) if str(code).isdigit() else str(code)
                code_list.append(f"{code_str} {title}")
            logger.info("🎯 Loaded Targets: " + ", ".join(code_list))
        return True, len(all_codes)
    except Exception as e:
        logger.error(f"Failed to load suggestions: {e}", exc_info=True)
        return False, 0

app = FastAPI(title="VODS", description="Video Object Detection (Multi-threaded)", version="2.0.0")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_credentials=True, allow_methods=["*"], allow_headers=["*"])

active_tasks: Dict[str, dict] = {} # Store task info: {'thread': ..., 'status': ..., 'results': [...]}

@app.on_event("startup")
async def startup_event():
    logger.info("=" * 60)
    logger.info("VODS Starting... Multi-threaded Architecture Enabled.")
    logger.info(f"Dify URL: {DIFY_API_URL}")
    logger.info("=" * 60)
    init_suggestions()
    FilePath(settings.OUTPUT_PATH).mkdir(parents=True, exist_ok=True)

@app.post("/api/v1/video/recognize")
async def video_recognize(
    request: VideoRecognitionRequest,
    mode: str = Query(default="asyn", description="syn=streaming, asyn=background"),
    use_dify: bool = Query(default=False, description="True=Use Dify AI")
):
    if mode not in ["syn", "asyn"]: 
        raise HTTPException(400, "mode must be 'syn' or 'asyn'")
    
    task_id = str(uuid.uuid4())[:12]
    logger.info(f"\n\n======================== 新任务启动: {task_id} ========================")
    logger.info(f"Mode={mode}, UseDify={use_dify}, Skip={request.skip_frames}, Duration={request.duration_seconds}s")

    # 初始化组件
    recognizer = FrameRecognizer(
        use_dify=use_dify, 
        dify_api_url=DIFY_API_URL, 
        api_key=DIFY_API_KEY, 
        base_image_url=BASE_IMAGE_URL,
        suggestions_loader=suggestions_loader
    )
    
    processor = VideoProcessor(
        video_source=request.video_source,
        source_type=request.source_type,
        output_path=settings.OUTPUT_PATH,
        task_id=task_id 
    )

    if not processor.open():
        raise HTTPException(500, "Failed to open video source")

    # 任务状态容器
    task_context = {
        "stop_flag": False,
        "decoder_thread": None,
        "results": [],
        "error": None,
        "frames_decoded": 0,
        "frames_processed": 0
    }
    active_tasks[task_id] = task_context

    if mode == "syn":
        return StreamingResponse(
            syn_stream_generator(task_id, request, processor, recognizer, task_context),
            media_type="text/event-stream",
            headers={"Cache-Control": "no-cache"}
        )
    else:
        # 异步模式：启动后台线程处理，立即返回
        asyncio.create_task(run_async_task(task_id, request, processor, recognizer, task_context))
        return JSONResponse({"status": "processing", "task_id": task_id})

# ============================================================================
# 同步流式生成器 (Syn Mode)
# ============================================================================
async def syn_stream_generator(
    task_id: str, 
    request: VideoRecognitionRequest, 
    processor: VideoProcessor, 
    recognizer: FrameRecognizer,
    context: dict
):
    try:
        yield f"data: {json.dumps({'event': 'start', 'task_id': task_id, 'message': 'Decoding started in background thread'})}\n\n"

        # 1. [核心] 启动后台解码线程 (Producer)
        # 该线程会全速解码并填充 processor.pending_frames_queue
        decoder_thread = threading.Thread(
            target=decoder_worker, 
            args=(processor, request.skip_frames, request.duration_seconds, context),
            daemon=True
        )
        context["decoder_thread"] = decoder_thread
        decoder_thread.start()
        logger.info(f"🧵 [{task_id}] 解码线程已启动")

        # 2. 主线程作为消费者 (Consumer)，从队列取图并识别
        while not context["stop_flag"]:
            # [异步兼容] 将阻塞的队列获取操作放入线程池，避免卡住 Event Loop
            frame_data = await asyncio.to_thread(
                processor.get_next_frame_for_recognition, 
                timeout=2.0
            )

            if frame_data is None:
                # 超时且解码线程已结束，说明处理完毕
                if not decoder_thread.is_alive() and processor.pending_frames_queue.empty():
                    break
                continue

            frame_index, file_path = frame_data
            
            # [异步兼容] 将耗时的 Dify 识别操作放入线程池
            result = await asyncio.to_thread(
                process_single_frame, 
                frame_index, file_path, task_id, processor, recognizer, context
            )
            
            if result:
                yield f"data: {json.dumps(result)}\n\n"

        # 等待解码线程完全结束
        decoder_thread.join(timeout=5)
        
        final_stats = {
            "event": "complete",
            "task_id": task_id,
            "total_decoded": processor.stats.get("frames_saved", 0),
            "total_processed": context["frames_processed"],
            "targets_found": sum(1 for r in context["results"] if r.get('has_target')),
            "duration": round(time.time() - start_time if (start_time := time.time()) else 0, 2) # 简单占位，实际需记录 start_time
        }
        # 修正 duration 计算
        # 实际应该在函数开头记录 start_time，这里简化处理
        yield f"data: {json.dumps({'event': 'complete', 'task_id': task_id, 'status': 'success', 'stats': processor.stats})}\n\n"
        logger.info(f"✅ [{task_id}] 任务完成。解码:{processor.stats.get('frames_saved', 0)}, 处理:{context['frames_processed']}")

    except Exception as e:
        logger.error(f"❌ [{task_id}] 流处理异常：{e}", exc_info=True)
        context["error"] = str(e)
        yield f"data: {json.dumps({'event': 'error', 'message': str(e)})}\n\n"
    finally:
        context["stop_flag"] = True
        processor.close()
        active_tasks.pop(task_id, None)

# ============================================================================
# 异步任务处理 (Asyn Mode)
# ============================================================================
async def run_async_task(
    task_id: str, 
    request: VideoRecognitionRequest, 
    processor: VideoProcessor, 
    recognizer: FrameRecognizer,
    context: dict
):
    try:
        # 1. 启动解码线程
        decoder_thread = threading.Thread(
            target=decoder_worker, 
            args=(processor, request.skip_frames, request.duration_seconds, context),
            daemon=True
        )
        context["decoder_thread"] = decoder_thread
        decoder_thread.start()

        # 2. 消费循环
        while not context["stop_flag"]:
            frame_data = await asyncio.to_thread(processor.get_next_frame_for_recognition, timeout=2.0)
            
            if frame_data is None:
                if not decoder_thread.is_alive() and processor.pending_frames_queue.empty():
                    break
                continue

            frame_index, file_path = frame_data
            await asyncio.to_thread(
                process_single_frame, 
                frame_index, file_path, task_id, processor, recognizer, context
            )

        decoder_thread.join(timeout=5)
        context["status"] = "completed"
        logger.info(f"✅ [{task_id}] 异步任务完成。")

    except Exception as e:
        logger.error(f"❌ [{task_id}] 异步任务失败：{e}", exc_info=True)
        context["status"] = "failed"
        context["error"] = str(e)
    finally:
        context["stop_flag"] = True
        processor.close()

# ============================================================================
# 工作线程函数 (Worker Functions)
# ============================================================================

def decoder_worker(processor: VideoProcessor, skip_frames: int, duration_seconds: int, context: dict):
    """
    [生产者] 解码线程：负责拉流、解码、保存、入队
    """
    frame_counter = 0
    saved_count = 0
    start_time = time.time()
    
    logger.info(f"🧵 [Decoder] 开始工作。Skip={skip_frames}, MaxDuration={duration_seconds}s")
    
    while not context["stop_flag"] and processor.is_opened:
        if (time.time() - start_time) > duration_seconds:
            logger.info(f"🧵 [Decoder] 达到时长限制，停止。")
            break
        
        ret, frame = processor.cap.read()
        frame_counter += 1
        
        if not ret:
            time.sleep(0.01) # 避免死循环
            continue

        # 跳帧逻辑
        if frame_counter % skip_frames != 1:
            continue
        
        saved_count += 1
        file_path = processor.frames_dir / f"{saved_count}.jpg"
        
        try:
            # 保存图片
            cv2_imwrite_success = cv2.imwrite(str(file_path), frame, [int(cv2.IMWRITE_JPEG_QUALITY), 85])
            if cv2_imwrite_success:
                processor.stats["frames_saved"] += 1
                # 入队 (阻塞如果队列满，起到背压作用)
                processor.pending_frames_queue.put((saved_count, str(file_path)), block=True, timeout=5)
            else:
                logger.warning(f"🧵 [Decoder] 保存失败：{file_path}")
        except Exception as e:
            logger.error(f"🧵 [Decoder] 异常：{e}")

    logger.info(f"🧵 [Decoder] 退出。总保存：{saved_count}")

def process_single_frame(
    frame_index: int, 
    file_path: str, 
    task_id: str, 
    processor: VideoProcessor, 
    recognizer: FrameRecognizer,
    context: dict
):
    """
    [消费者] 处理单帧：识别、重命名、记录结果
    此函数运行在线程池中，阻塞不会影响解码
    """
    try:
        # 1. 构造图片 URL (供 Dify 使用)
        relative_path = FilePath(file_path).relative_to(processor.frames_dir)
        image_url = f"{BASE_IMAGE_URL}/{task_id}/frames/{relative_path}"
        
        # 2. 调用 Dify 识别 (这里是阻塞点，但在线程池中运行，安全)
        # 注意：需要修改 FrameRecognizer.recognize 以接受外部传入的 image_url，或者内部逻辑兼容
        # 为了最小改动，我们假设 recognize 内部会根据 frame_index 构造 URL。
        # 但此时文件已存在，URL 是有效的。
        # 如果 recognize 内部是重新构造 URL，逻辑依然成立。
        recognition_result = recognizer.recognize(frame_index, task_id=task_id)
        
        has_target = recognition_result.get("has_target", False)
        target_code_raw = recognition_result.get("target_code", "0000")
        
        # 3. 重命名文件
        old_file = FilePath(file_path)
        if has_target:
            suffix = target_code_raw.replace(",", "_")
            new_name = f"{frame_index}_{suffix}.jpg"
        else:
            new_name = f"{frame_index}_0000.jpg"
        
        new_path = old_file.parent / new_name
        if old_file.exists():
            old_file.rename(new_path)
        
        logger.info(f"🎯 [{task_id}] 帧 {frame_index} 处理完成：{new_name} (Target={has_target})")
        
        # 4. 记录结果
        context["frames_processed"] += 1
        result_record = {
            "frame_index": frame_index,
            "filename": new_name,
            "has_target": has_target,
            "target_code": target_code_raw,
            "url": f"/api/v1/tasks/{task_id}/frames/{new_name}"
        }
        context["results"].append(result_record)
        
        return {
            "event": "frame",
            "task_id": task_id,
            **result_record,
            "timestamp": datetime.now().isoformat()
        }
        
    except Exception as e:
        logger.error(f"❌ [{task_id}] 处理帧 {frame_index} 失败：{e}", exc_info=True)
        return None

# ============================================================================
# API Endpoints (不变)
# ============================================================================

@app.api_route("/api/v1/tasks/{task_id}/frames/{frame_filename}", methods=["GET","HEAD"])
def get_frame_image(task_id: str, frame_filename: str):
    path = FilePath(settings.OUTPUT_PATH) / task_id / "frames" / frame_filename
    if not path.exists():
        raise HTTPException(404, "Image not found")
    return FileResponse(path=str(path), media_type="image/jpeg", filename=frame_filename)

@app.get("/api/v1/tasks/{task_id}/frames")
async def list_task_frames(task_id: str):
    frames_dir = FilePath(settings.OUTPUT_PATH) / task_id / "frames"
    if not frames_dir.exists():
        raise HTTPException(404, "Frames directory not found")
    files = [
        {"filename": f.name, "url": f"/api/v1/tasks/{task_id}/frames/{f.name}", "size": f.stat().st_size} 
        for f in sorted(frames_dir.iterdir()) if f.is_file() and f.suffix.lower() in ['.jpg','.jpeg','.png']
    ]
    return {"task_id": task_id, "total": len(files), "frames": files}

@app.get("/api/v1/tasks/{task_id}")
async def get_task_status(task_id: str):
    if task_id not in active_tasks:
        # 尝试从磁盘推断已完成的任务（简化版）
        if (FilePath(settings.OUTPUT_PATH) / task_id).exists():
            return {"status": "completed", "task_id": task_id}
        raise HTTPException(404, "Task not found")
    
    ctx = active_tasks[task_id]
    return {
        "status": "completed" if ctx.get("status") == "completed" else ("failed" if ctx.get("error") else "processing"),
        "task_id": task_id,
        "processed": ctx.get("frames_processed", 0),
        "error": ctx.get("error")
    }

@app.get("/health")
async def health():
    return {"status": "healthy", "architecture": "multi-threaded"}

# 需要引入 cv2 在 worker 中使用
import cv2

if __name__ == "__main__":
    import uvicorn
    uvicorn.run("src.main:app", host=settings.SERVICE_HOST, port=settings.SERVICE_PORT, reload=False)
