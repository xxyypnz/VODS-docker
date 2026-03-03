import cv2
import os
import logging
import threading
import time
from pathlib import Path as FilePath
from typing import Optional, List, Callable
from queue import Queue

logger = logging.getLogger("vods")

class VideoProcessor:
    def __init__(self, video_source: str, source_type: str, output_path: str, task_id: str):
        if not task_id:
            raise ValueError("CRITICAL ERROR: task_id is required.")
            
        self.video_source = video_source
        self.source_type = source_type
        self.output_path = output_path
        self.task_id = task_id
        
        self.cap: Optional[cv2.VideoCapture] = None
        self.is_opened = False
        self.should_stop = False
        
        # 统计信息
        self.stats = {
            "frames_decoded": 0,
            "frames_saved": 0,
            "frames_processed": 0
        }
        
        # 任务专属目录
        self.task_dir = FilePath(output_path) / task_id
        self.frames_dir = self.task_dir / "frames"
        
        # [新增] 线程安全队列，用于传递待处理的帧信息 (frame_index, file_path)
        # 使用队列代替直接扫目录，效率更高且线程安全
        self.pending_frames_queue = Queue(maxsize=50) 

    def open(self) -> bool:
        try:
            self.frames_dir.mkdir(parents=True, exist_ok=True)
            logger.info(f"📁 任务目录已准备：{self.frames_dir}")

            source_url = f"{self.video_source},rtsp_transport=tcp" if self.source_type == "rtsp" else self.video_source
            logger.info(f"🔗 连接 RTSP 流 (TCP): {source_url}")

            self.cap = cv2.VideoCapture(source_url, cv2.CAP_FFMPEG)
            if not self.cap.isOpened():
                # 回退尝试
                self.cap = cv2.VideoCapture(self.video_source, cv2.CAP_FFMPEG)
                if not self.cap.isOpened():
                    return False

            self.cap.set(cv2.CAP_PROP_BUFFERSIZE, 3)
            self.cap.set(cv2.CAP_PROP_OPEN_TIMEOUT_MSEC, 10000)
            self.is_opened = True
            logger.info(f"✅ 视频流已打开。")
            return True
        except Exception as e:
            logger.error(f"❌ 打开视频源异常：{e}", exc_info=True)
            return False

    def start_decoding_thread(self, skip_frames: int, duration_seconds: int):
        """
        [核心] 启动独立的解码线程
        """
        def decoder_loop():
            frame_counter = 0
            saved_count = 0
            start_time = time.time()
            
            logger.info(f"🧵 [Decoder Thread] 开始解码。Skip={skip_frames}, Duration={duration_seconds}s")
            
            while not self.should_stop and self.cap and self.cap.isOpened():
                # 检查时长
                if (time.time() - start_time) > duration_seconds:
                    logger.info(f"🧵 [Decoder Thread] 达到时长限制，停止解码。")
                    break
                
                ret, frame = self.cap.read()
                frame_counter += 1
                
                if not ret:
                    # 偶尔读取失败，短暂休眠后重试，避免死循环
                    time.sleep(0.01)
                    continue

                # 跳帧逻辑
                if frame_counter % skip_frames != 1:
                    continue
                
                # 保存帧
                saved_count += 1
                file_path = self.frames_dir / f"{saved_count}.jpg"
                
                try:
                    cv2.imwrite(str(file_path), frame, [int(cv2.IMWRITE_JPEG_QUALITY), 85])
                    self.stats["frames_decoded"] += 1
                    self.stats["frames_saved"] += 1
                    
                    # [关键] 将任务放入队列，通知识别线程
                    # 如果队列满了（识别太慢），这里会阻塞，起到背压作用，防止内存爆炸
                    # 但为了不让解码线程卡死太久，我们可以选择丢弃旧帧或简单阻塞
                    self.pending_frames_queue.put((saved_count, str(file_path)), block=True, timeout=5)
                    
                except Exception as e:
                    logger.error(f"🧵 [Decoder Thread] 保存帧失败：{e}")

            logger.info(f"🧵 [Decoder Thread] 退出。总解码：{self.stats['frames_decoded']}, 总保存：{self.stats['frames_saved']}")
            self.is_opened = False

        # 启动线程
        thread = threading.Thread(target=decoder_loop, daemon=True)
        thread.start()
        return thread

    def get_next_frame_for_recognition(self, timeout: float = 1.0) -> Optional[tuple]:
        """
        [核心] 识别线程调用此方法获取下一帧
        返回: (frame_index, file_path) 或 None (超时)
        """
        try:
            return self.pending_frames_queue.get(timeout=timeout)
        except:
            return None

    def close(self):
        self.should_stop = True
        if self.cap:
            self.cap.release()
            self.cap = None
        self.is_opened = False
        logger.info(f"🏁 视频处理器已关闭。统计：{self.stats}")
