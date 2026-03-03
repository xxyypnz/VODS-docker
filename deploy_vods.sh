#!/bin/bash

# ============================================================================
# VODS - Video Object Detection Service 一键部署脚本
# 视频目标识别服务 - Docker 自动部署
# 日期：2026-02-23
# ============================================================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 配置
DEPLOY_ROOT="/home/pgh/work/docker_vds"
OUTPUT_DIR="${DEPLOY_ROOT}/output"
LOGS_DIR="${DEPLOY_ROOT}/logs"

echo ""
echo "============================================================================"
echo "  VODS - Video Object Detection Service 一键部署脚本"
echo "  视频目标识别服务 - Docker 自动部署"
echo "============================================================================"
echo ""

# 检查是否以正确用户运行
echo -n "检查运行用户... "
CURRENT_USER=$(whoami)
echo -e "${GREEN}${CURRENT_USER}${NC}"

# 检查 Docker 是否安装
echo -n "检查 Docker 安装... "
if command -v docker &> /dev/null; then
    DOCKER_VERSION=$(docker --version | cut -d' ' -f3)
    echo -e "${GREEN}已安装 (版本：${DOCKER_VERSION})${NC}"
else
    echo -e "${RED}未安装${NC}"
    echo -e "${YELLOW}请先安装 Docker: https://docs.docker.com/get-docker/${NC}"
    exit 1
fi

# 创建目录结构
echo ""
echo "创建目录结构..."
mkdir -p "${DEPLOY_ROOT}/src/services"
mkdir -p "${DEPLOY_ROOT}/src/models"
mkdir -p "${DEPLOY_ROOT}/src/utils"
mkdir -p "${DEPLOY_ROOT}/docker"
mkdir -p "${OUTPUT_DIR}"
mkdir -p "${LOGS_DIR}"
echo -e "${GREEN}✓ 目录结构创建完成${NC}"
echo "  ${DEPLOY_ROOT}/"
echo "  ├── src/"
echo "  │   ├── main.py"
echo "  │   ├── config.py"
echo "  │   ├── services/"
echo "  │   ├── models/"
echo "  │   └── utils/"
echo "  ├── docker/"
echo "  │   ├── Dockerfile"
echo "  │   └── docker-compose.yml"
echo "  ├── output/          # 帧图像保存目录"
echo "  └── logs/            # 日志目录"

# ============================================================================
# 生成 requirements.txt
# ============================================================================
echo ""
echo "生成 requirements.txt..."
cat > "${DEPLOY_ROOT}/requirements.txt" << 'EOF'
fastapi>=0.115.0
uvicorn[standard]>=0.30.0
opencv-python-headless>=4.9.0
numpy>=1.26.0
pydantic>=2.7.0
pydantic-settings>=2.5.0
python-multipart>=0.0.9
aiohttp>=3.9.0
requests>=2.32.0
EOF
echo -e "${GREEN}✓ requirements.txt 生成完成${NC}"

# ============================================================================
# 生成 .env 文件
# ============================================================================
echo "生成 .env 配置文件..."
cat > "${DEPLOY_ROOT}/.env" << 'EOF'
# 服务配置
SERVICE_HOST=0.0.0.0
SERVICE_PORT=8000

# 输出配置
OUTPUT_PATH=/app/output
FRAME_FORMAT=jpg
FRAME_QUALITY=85

# 视频处理配置
DEFAULT_SKIP_FRAMES=20
MIN_SKIP_FRAMES=1
MAX_SKIP_FRAMES=100
DEFAULT_DURATION_SECONDS=60
MAX_DURATION_SECONDS=300

# 并发配置
MAX_CONCURRENT_TASKS=4

# 日志配置
LOG_LEVEL=INFO
LOG_PATH=/app/logs

# 目标码定义
TARGET_CODES=1001,1002,1003,1004
TARGET_NAMES=锥形桶，告警标志，人员，锈蚀
EOF
echo -e "${GREEN}✓ .env 生成完成${NC}"

# ============================================================================
# 生成 src/config.py
# ============================================================================
echo "生成 src/config.py..."
cat > "${DEPLOY_ROOT}/src/config.py" << 'EOF'
from pydantic_settings import BaseSettings
from functools import lru_cache
from typing import List


class Settings(BaseSettings):
    """服务配置"""
    
    # 服务配置
    SERVICE_HOST: str = "0.0.0.0"
    SERVICE_PORT: int = 8000
    
    # 输出配置
    OUTPUT_PATH: str = "/app/output"
    FRAME_FORMAT: str = "jpg"
    FRAME_QUALITY: int = 85
    
    # 视频处理配置
    DEFAULT_SKIP_FRAMES: int = 20
    MIN_SKIP_FRAMES: int = 1
    MAX_SKIP_FRAMES: int = 100
    DEFAULT_DURATION_SECONDS: int = 60
    MAX_DURATION_SECONDS: int = 300
    
    # 并发配置
    MAX_CONCURRENT_TASKS: int = 4
    
    # 日志配置
    LOG_LEVEL: str = "INFO"
    LOG_PATH: str = "/app/logs"
    
    # 目标码定义
    TARGET_CODES: str = "1001,1002,1003,1004"
    TARGET_NAMES: str = "锥形桶，告警标志，人员，锈蚀"
    
    model_config = {
        "env_file": ".env",
        "env_file_encoding": "utf-8"
    }
    
    def get_target_codes(self) -> List[str]:
        """获取目标码列表"""
        return [code.strip() for code in self.TARGET_CODES.split(",")]
    
    def get_target_names(self) -> List[str]:
        """获取目标名称列表"""
        return [name.strip() for name in self.TARGET_NAMES.split(",")]
    
    def get_target_mapping(self) -> dict:
        """获取目标码 - 名称映射"""
        codes = self.get_target_codes()
        names = self.get_target_names()
        return {code: name for code, name in zip(codes, names)}


@lru_cache()
def get_settings() -> Settings:
    return Settings()


settings = get_settings()
EOF
echo -e "${GREEN}✓ src/config.py 生成完成${NC}"

# ============================================================================
# 生成 src/models/request.py
# ============================================================================
echo "生成 src/models/request.py..."
cat > "${DEPLOY_ROOT}/src/models/request.py" << 'EOF'
from pydantic import BaseModel, Field, field_validator
from typing import Optional, List, Literal
from pathlib import Path


class VideoRecognitionRequest(BaseModel):
    """视频识别请求"""
    
    # 视频源（RTSP 地址或视频文件路径）
    video_source: str = Field(..., description="RTSP 地址或视频文件路径")
    source_type: Literal["rtsp", "file"] = Field(..., description="视频源类型")
    
    # 识别目标码列表
    target_codes: List[str] = Field(default=["1001", "1002", "1003", "1004"], 
                                    description="识别目标码列表")
    
    # 跳帧参数
    skip_frames: int = Field(20, description="跳帧间隔，每隔 n 帧解码一帧", ge=1, le=100)
    
    # 处理时长
    duration_seconds: int = Field(60, description="处理持续时间 (秒)", ge=1, le=300)
    
    @field_validator('video_source')
    @classmethod
    def validate_video_source(cls, v: str) -> str:
        if not v or len(v.strip()) == 0:
            raise ValueError('视频源不能为空')
        return v.strip()
    
    @field_validator('source_type')
    @classmethod
    def validate_source_type(cls, v: str) -> str:
        if v not in ['rtsp', 'file']:
            raise ValueError('视频源类型必须是 rtsp 或 file')
        return v


class FrameResult(BaseModel):
    """单帧识别结果"""
    frame_index: int = Field(..., description="帧索引")
    original_file: str = Field(..., description="原始图像文件名")
    renamed_file: str = Field(..., description="重命名后图像文件名")
    file_path: str = Field(..., description="图像完整路径")
    target_codes: List[str] = Field(default_factory=list, description="识别到的目标码")
    target_names: List[str] = Field(default_factory=list, description="识别到的目标名称")
    has_target: bool = Field(..., description="是否识别到目标")


class VideoRecognitionResponse(BaseModel):
    """视频识别响应"""
    status: Literal["success", "failed", "processing"] = Field(..., description="状态")
    message: str = Field(..., description="消息")
    task_id: str = Field(..., description="任务 ID")
    
    # 原视频信息
    video_source: str = Field(..., description="原视频源 (RTSP 地址或文件路径)")
    source_type: str = Field(..., description="视频源类型")
    
    # 处理统计
    total_frames_decoded: int = Field(0, description="总解码帧数")
    total_frames_saved: int = Field(0, description="总保存帧数")
    frames_with_target: int = Field(0, description="识别到目标的帧数")
    frames_without_target: int = Field(0, description="未识别到目标的帧数")
    
    # 帧结果列表
    frames: List[FrameResult] = Field(default_factory=list, description="帧识别结果列表")
    
    # 时间信息
    start_time: str = Field(..., description="开始时间")
    end_time: Optional[str] = Field(None, description="结束时间")
    duration_seconds: float = Field(0, description="处理耗时 (秒)")
EOF
echo -e "${GREEN}✓ src/models/request.py 生成完成${NC}"

# ============================================================================
# 生成 src/models/__init__.py
# ============================================================================
echo "生成 src/models/__init__.py..."
cat > "${DEPLOY_ROOT}/src/models/__init__.py" << 'EOF'
from .request import VideoRecognitionRequest, VideoRecognitionResponse, FrameResult

__all__ = ["VideoRecognitionRequest", "VideoRecognitionResponse", "FrameResult"]
EOF
echo -e "${GREEN}✓ src/models/__init__.py 生成完成${NC}"

# ============================================================================
# 生成 src/utils/logger.py
# ============================================================================
echo "生成 src/utils/logger.py..."
cat > "${DEPLOY_ROOT}/src/utils/logger.py" << 'EOF'
import logging
import sys
from pathlib import Path
from datetime import datetime


def setup_logger(name: str, log_path: str = "/app/logs", level: str = "INFO") -> logging.Logger:
    """配置日志"""
    logger = logging.getLogger(name)
    
    # 如果已有处理器，不重复添加
    if logger.handlers:
        return logger
    
    logger.setLevel(getattr(logging, level.upper()))
    
    # 控制台处理器
    console_handler = logging.StreamHandler(sys.stdout)
    console_handler.setLevel(logging.DEBUG)
    console_format = logging.Formatter(
        '%(asctime)s | %(name)s | %(levelname)s | %(message)s',
        datefmt='%Y-%m-%d %H:%M:%S'
    )
    console_handler.setFormatter(console_format)
    logger.addHandler(console_handler)
    
    # 文件处理器
    try:
        Path(log_path).mkdir(parents=True, exist_ok=True)
        log_file = Path(log_path) / f"{name}_{datetime.now().strftime('%Y%m%d')}.log"
        file_handler = logging.FileHandler(log_file, encoding='utf-8')
        file_handler.setLevel(logging.INFO)
        file_format = logging.Formatter(
            '%(asctime)s | %(name)s | %(levelname)s | %(message)s',
            datefmt='%Y-%m-%d %H:%M:%S'
        )
        file_handler.setFormatter(file_format)
        logger.addHandler(file_handler)
    except Exception as e:
        logger.warning(f"文件日志配置失败：{e}")
    
    return logger
EOF
echo -e "${GREEN}✓ src/utils/logger.py 生成完成${NC}"

# ============================================================================
# 生成 src/utils/__init__.py
# ============================================================================
echo "生成 src/utils/__init__.py..."
cat > "${DEPLOY_ROOT}/src/utils/__init__.py" << 'EOF'
from .logger import setup_logger

__all__ = ["setup_logger"]
EOF
echo -e "${GREEN}✓ src/utils/__init__.py 生成完成${NC}"

# ============================================================================
# 生成 src/services/video_processor.py
# ============================================================================
echo "生成 src/services/video_processor.py..."
cat > "${DEPLOY_ROOT}/src/services/video_processor.py" << 'EOF'
import cv2
import logging
import os
import shutil
from pathlib import Path
from typing import Optional, Tuple, List, Dict, Any
import uuid

logger = logging.getLogger(__name__)


class VideoProcessor:
    """视频处理器 - 支持 RTSP 流和本地文件"""
    
    def __init__(self, video_source: str, source_type: str, output_path: str):
        self.video_source = video_source
        self.source_type = source_type
        self.output_path = Path(output_path)
        
        # 创建任务输出目录
        self.task_id = str(uuid.uuid4())[:12]
        self.task_output_dir = self.output_path / self.task_id
        self.task_output_dir.mkdir(parents=True, exist_ok=True)
        
        self.cap: Optional[cv2.VideoCapture] = None
        self.is_opened = False
        
        # 统计信息
        self.stats = {
            "total_frames_read": 0,
            "total_frames_saved": 0,
            "frames_with_target": 0,
            "frames_without_target": 0
        }
        
        # 视频信息
        self.fps = 0.0
        self.width = 0
        self.height = 0
    
    def open(self) -> bool:
        """打开视频源"""
        try:
            if self.source_type == "rtsp":
                # 打开 RTSP 流
                self.cap = cv2.VideoCapture(self.video_source, cv2.CAP_FFMPEG)
                self.cap.set(cv2.CAP_PROP_BUFFERSIZE, 3)
                self.cap.set(cv2.CAP_PROP_OPEN_TIMEOUT_MSEC, 10000)
                self.cap.set(cv2.CAP_PROP_READ_TIMEOUT_MSEC, 10000)
            else:
                # 打开本地视频文件
                if not os.path.exists(self.video_source):
                    logger.error(f"视频文件不存在：{self.video_source}")
                    return False
                self.cap = cv2.VideoCapture(self.video_source)
            
            if not self.cap or not self.cap.isOpened():
                logger.error(f"无法打开视频源：{self.video_source}")
                return False
            
            # 获取视频信息
            self.fps = self.cap.get(cv2.CAP_PROP_FPS) or 25.0
            self.width = int(self.cap.get(cv2.CAP_PROP_FRAME_WIDTH))
            self.height = int(self.cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
            
            self.is_opened = True
            logger.info(f"视频源打开成功：类型={self.source_type}, FPS={self.fps}, "
                       f"分辨率={self.width}x{self.height}")
            return True
            
        except Exception as e:
            logger.error(f"打开视频源异常：{e}")
            return False
    
    def read_frame(self) -> Tuple[bool, Optional[Any]]:
        """读取一帧"""
        if not self.is_opened or self.cap is None:
            return False, None
        
        try:
            ret, frame = self.cap.read()
            if not ret or frame is None:
                return False, None
            
            self.stats["total_frames_read"] += 1
            return True, frame
            
        except Exception as e:
            logger.error(f"读取帧异常：{e}")
            return False, None
    
    def save_frame(self, frame, frame_index: int) -> Optional[str]:
        """保存帧到文件"""
        try:
            file_name = f"{frame_index}.jpg"
            file_path = self.task_output_dir / file_name
            
            cv2.imwrite(str(file_path), frame, [cv2.IMWRITE_JPEG_QUALITY, 85])
            
            self.stats["total_frames_saved"] += 1
            logger.debug(f"保存帧：{frame_index} -> {file_path}")
            
            return str(file_path)
            
        except Exception as e:
            logger.error(f"保存帧异常：{e}")
            return None
    
    def rename_frame(self, old_path: str, frame_index: int, target_code: str) -> Optional[str]:
        """重命名帧文件"""
        try:
            old_file = Path(old_path)
            
            if target_code == "0000":
                # 未识别到目标
                new_name = f"{frame_index}_0000.jpg"
            else:
                # 识别到目标
                new_name = f"{frame_index}_{target_code}.jpg"
            
            new_path = old_file.parent / new_name
            
            # 重命名文件
            shutil.move(str(old_file), str(new_path))
            
            logger.debug(f"重命名帧：{old_path} -> {new_path}")
            
            return str(new_path)
            
        except Exception as e:
            logger.error(f"重命名帧异常：{e}")
            return old_path
    
    def close(self):
        """关闭视频源"""
        if self.cap:
            self.cap.release()
            self.cap = None
        self.is_opened = False
        logger.info(f"视频源已关闭：总读取={self.stats['total_frames_read']}, "
                   f"总保存={self.stats['total_frames_saved']}")
    
    def get_task_info(self) -> Dict[str, Any]:
        """获取任务信息"""
        return {
            "task_id": self.task_id,
            "video_source": self.video_source,
            "source_type": self.source_type,
            "output_dir": str(self.task_output_dir),
            "fps": self.fps,
            "width": self.width,
            "height": self.height
        }
EOF
echo -e "${GREEN}✓ src/services/video_processor.py 生成完成${NC}"

# ============================================================================
# 生成 src/services/frame_recognizer.py
# ============================================================================
echo "生成 src/services/frame_recognizer.py..."
cat > "${DEPLOY_ROOT}/src/services/frame_recognizer.py" << 'EOF'
import logging
from typing import List, Dict, Any
from pathlib import Path

logger = logging.getLogger(__name__)


class FrameRecognizer:
    """帧识别器 - 假识别实现"""
    
    # 目标码循环模式：1001->1002->1003->1004->0000->循环
    RECOGNITION_PATTERN = ["1001", "1002", "1003", "1004", "0000"]
    
    # 目标码 - 名称映射
    TARGET_MAPPING = {
        "1001": "锥形桶",
        "1002": "告警标志",
        "1003": "人员",
        "1004": "锈蚀",
        "0000": "无目标"
    }
    
    def __init__(self):
        self.frame_count = 0  # 已识别帧计数（用于循环模式）
    
    def recognize(self, frame_index: int) -> Dict[str, Any]:
        """
        识别单帧图像（假识别）
        
        识别模式：
        - 第 1 张：1001 锥形桶
        - 第 2 张：1002 告警标志
        - 第 3 张：1003 人员
        - 第 4 张：1004 锈蚀
        - 第 5 张：0000 无目标
        - 第 6 张起：循环上述模式
        """
        # 计算当前帧在循环中的位置
        pattern_index = self.frame_count % len(self.RECOGNITION_PATTERN)
        target_code = self.RECOGNITION_PATTERN[pattern_index]
        
        # 判断是否识别到目标
        has_target = target_code != "0000"
        
        # 获取目标名称
        target_names = []
        if has_target:
            target_names = [self.TARGET_MAPPING.get(target_code, "未知目标")]
        
        # 构建结果
        result = {
            "frame_index": frame_index,
            "target_codes": [target_code] if has_target else [],
            "target_names": target_names,
            "has_target": has_target,
            "pattern_index": pattern_index
        }
        
        self.frame_count += 1
        
        logger.debug(f"帧识别：frame_index={frame_index}, target_code={target_code}, "
                    f"has_target={has_target}")
        
        return result
    
    def reset(self):
        """重置识别计数器"""
        self.frame_count = 0
        logger.info("识别器已重置")
    
    def get_target_mapping(self) -> Dict[str, str]:
        """获取目标码 - 名称映射"""
        return self.TARGET_MAPPING.copy()
EOF
echo -e "${GREEN}✓ src/services/frame_recognizer.py 生成完成${NC}"

# ============================================================================
# 生成 src/services/__init__.py
# ============================================================================
echo "生成 src/services/__init__.py..."
cat > "${DEPLOY_ROOT}/src/services/__init__.py" << 'EOF'
from .video_processor import VideoProcessor
from .frame_recognizer import FrameRecognizer

__all__ = ["VideoProcessor", "FrameRecognizer"]
EOF
echo -e "${GREEN}✓ src/services/__init__.py 生成完成${NC}"

# ============================================================================
# 生成 src/main.py
# ============================================================================
echo "生成 src/main.py..."
cat > "${DEPLOY_ROOT}/src/main.py" << 'EOF'
from fastapi import FastAPI, HTTPException, BackgroundTasks
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
import logging
import asyncio
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional
import uuid

from .config import settings
from .models.request import VideoRecognitionRequest, VideoRecognitionResponse, FrameResult
from .services.video_processor import VideoProcessor
from .services.frame_recognizer import FrameRecognizer
from .utils.logger import setup_logger

# 配置日志
logger = setup_logger("vods", settings.LOG_PATH, settings.LOG_LEVEL)

# 创建 FastAPI 应用
app = FastAPI(
    title="VODS - Video Object Detection Service",
    description="视频目标识别服务 - 从视频流中提取帧并进行目标识别",
    version="1.0.0"
)

# CORS 配置
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# 任务管理
active_tasks: Dict[str, asyncio.Task] = {}
task_results: Dict[str, Dict] = {}


@app.on_event("startup")
async def startup_event():
    """服务启动"""
    logger.info("=" * 60)
    logger.info("VODS - Video Object Detection Service 启动中...")
    logger.info(f"监听地址：{settings.SERVICE_HOST}:{settings.SERVICE_PORT}")
    logger.info(f"输出目录：{settings.OUTPUT_PATH}")
    logger.info(f"最大并发任务数：{settings.MAX_CONCURRENT_TASKS}")
    logger.info(f"目标码定义：{settings.get_target_codes()}")
    logger.info(f"目标名称：{settings.get_target_names()}")
    logger.info("=" * 60)
    
    # 确保输出目录存在
    Path(settings.OUTPUT_PATH).mkdir(parents=True, exist_ok=True)


@app.on_event("shutdown")
async def shutdown_event():
    """服务关闭"""
    logger.info("VODS 服务关闭中...")
    for task_id, task in active_tasks.items():
        if not task.done():
            task.cancel()
            logger.info(f"取消任务：{task_id}")


@app.post("/api/v1/video/recognize", response_model=VideoRecognitionResponse)
async def video_recognize(request: VideoRecognitionRequest):
    """
    视频目标识别接口
    
    - **video_source**: RTSP 地址或视频文件路径
    - **source_type**: 视频源类型 (rtsp 或 file)
    - **target_codes**: 识别目标码列表 (默认 ["1001","1002","1003","1004"])
    - **skip_frames**: 跳帧间隔，每隔 n 帧解码一帧 (默认 20)
    - **duration_seconds**: 处理持续时间 (秒，默认 60)
    """
    # 检查并发数
    if len(active_tasks) >= settings.MAX_CONCURRENT_TASKS:
        raise HTTPException(
            status_code=429,
            detail=f"超过最大并发任务数限制：{settings.MAX_CONCURRENT_TASKS}"
        )
    
    # 生成任务 ID
    task_id = str(uuid.uuid4())[:12]
    
    logger.info(f"收到视频识别请求：task_id={task_id}, "
               f"video_source={request.video_source[:50]}..., "
               f"source_type={request.source_type}")
    
    # 启动后台任务
    async def run_recognition():
        try:
            result = await process_video(request, task_id)
            task_results[task_id] = result
            logger.info(f"任务完成：{task_id}, 状态={result['status']}")
        except Exception as e:
            logger.error(f"任务失败：{task_id}, 错误={e}")
            task_results[task_id] = {
                "status": "failed",
                "message": str(e),
                "task_id": task_id
            }
        finally:
            active_tasks.pop(task_id, None)
    
    # 创建并存储任务
    task = asyncio.create_task(run_recognition())
    active_tasks[task_id] = task
    
    # 立即返回任务信息（异步处理）
    return VideoRecognitionResponse(
        status="processing",
        message="视频识别任务已启动，请稍后查询结果",
        task_id=task_id,
        video_source=request.video_source,
        source_type=request.source_type,
        total_frames_decoded=0,
        total_frames_saved=0,
        frames_with_target=0,
        frames_without_target=0,
        frames=[],
        start_time=datetime.now().isoformat(),
        duration_seconds=0
    )


async def process_video(request: VideoRecognitionRequest, task_id: str) -> Dict:
    """处理视频识别任务"""
    start_time = datetime.now()
    frames_result: List[FrameResult] = []
    
    # 创建处理器和识别器
    processor = VideoProcessor(
        video_source=request.video_source,
        source_type=request.source_type,
        output_path=settings.OUTPUT_PATH
    )
    recognizer = FrameRecognizer()
    
    try:
        # 打开视频源
        if not processor.open():
            return {
                "status": "failed",
                "message": "无法打开视频源",
                "task_id": task_id,
                "video_source": request.video_source,
                "source_type": request.source_type,
                "total_frames_decoded": 0,
                "total_frames_saved": 0,
                "frames_with_target": 0,
                "frames_without_target": 0,
                "frames": [],
                "start_time": start_time.isoformat(),
                "end_time": datetime.now().isoformat(),
                "duration_seconds": 0
            }
        
        frame_count = 0
        saved_count = 0
        
        while processor.is_opened:
            # 读取帧
            ret, frame = processor.read_frame()
            if not ret:
                logger.info(f"视频流结束或读取失败：task_id={task_id}")
                break
            
            frame_count += 1
            
            # 跳帧判断
            if frame_count % request.skip_frames != 1:
                continue
            
            # 检查持续时间
            current_time = (datetime.now() - start_time).total_seconds()
            if current_time > request.duration_seconds:
                logger.info(f"达到指定持续时间：{request.duration_seconds}s")
                break
            
            # 保存帧
            frame_index = saved_count + 1
            file_path = processor.save_frame(frame, frame_index)
            
            if not file_path:
                logger.warning(f"保存帧失败：frame_index={frame_index}")
                continue
            
            saved_count += 1
            
            # 识别帧
            recognition_result = recognizer.recognize(frame_index)
            
            # 重命名文件
            target_code = recognition_result["target_codes"][0] if recognition_result["has_target"] else "0000"
            new_file_path = processor.rename_frame(file_path, frame_index, target_code)
            
            # 构建帧结果
            frame_result = FrameResult(
                frame_index=frame_index,
                original_file=f"{frame_index}.jpg",
                renamed_file=Path(new_file_path).name if new_file_path else "",
                file_path=new_file_path or "",
                target_codes=recognition_result["target_codes"],
                target_names=recognition_result["target_names"],
                has_target=recognition_result["has_target"]
            )
            frames_result.append(frame_result)
            
            # 更新统计
            if recognition_result["has_target"]:
                processor.stats["frames_with_target"] += 1
            else:
                processor.stats["frames_without_target"] += 1
            
            logger.debug(f"帧处理完成：{frame_index}, has_target={recognition_result['has_target']}")
            
            # 非阻塞等待
            await asyncio.sleep(0.001)
        
        end_time = datetime.now()
        duration = (end_time - start_time).total_seconds()
        
        logger.info(f"任务完成：task_id={task_id}, 解码={frame_count}, "
                   f"保存={saved_count}, 有目标={processor.stats['frames_with_target']}, "
                   f"无目标={processor.stats['frames_without_target']}, 耗时={duration:.2f}s")
        
        return {
            "status": "success",
            "message": "视频识别完成",
            "task_id": task_id,
            "video_source": request.video_source,
            "source_type": request.source_type,
            "total_frames_decoded": frame_count,
            "total_frames_saved": saved_count,
            "frames_with_target": processor.stats["frames_with_target"],
            "frames_without_target": processor.stats["frames_without_target"],
            "frames": [f.model_dump() for f in frames_result],
            "start_time": start_time.isoformat(),
            "end_time": end_time.isoformat(),
            "duration_seconds": round(duration, 2)
        }
        
    except Exception as e:
        logger.error(f"任务异常：task_id={task_id}, 错误={e}")
        return {
            "status": "failed",
            "message": str(e),
            "task_id": task_id,
            "video_source": request.video_source,
            "source_type": request.source_type,
            "total_frames_decoded": 0,
            "total_frames_saved": 0,
            "frames_with_target": 0,
            "frames_without_target": 0,
            "frames": [],
            "start_time": start_time.isoformat(),
            "end_time": datetime.now().isoformat(),
            "duration_seconds": 0
        }
    
    finally:
        processor.close()


@app.get("/api/v1/tasks/{task_id}")
async def get_task_status(task_id: str):
    """查询任务状态"""
    if task_id in task_results:
        result = task_results[task_id]
        return JSONResponse(content=result)
    
    if task_id in active_tasks:
        return JSONResponse(content={
            "status": "processing",
            "message": "任务正在处理中",
            "task_id": task_id
        })
    
    raise HTTPException(status_code=404, detail=f"任务不存在：{task_id}")


@app.get("/api/v1/tasks/{task_id}/frames")
async def get_task_frames(task_id: str):
    """获取任务的所有帧结果"""
    if task_id not in task_results:
        raise HTTPException(status_code=404, detail=f"任务不存在：{task_id}")
    
    result = task_results[task_id]
    return JSONResponse(content={
        "task_id": task_id,
        "total_frames": len(result.get("frames", [])),
        "frames": result.get("frames", [])
    })


@app.get("/health")
async def health_check():
    """健康检查"""
    return {
        "status": "healthy",
        "service": "VODS",
        "version": "1.0.0",
        "active_tasks": len(active_tasks),
        "completed_tasks": len(task_results)
    }


@app.get("/api/v1/stats")
async def get_stats():
    """获取服务统计"""
    return {
        "active_tasks": len(active_tasks),
        "completed_tasks": len(task_results),
        "max_concurrent_tasks": settings.MAX_CONCURRENT_TASKS,
        "output_path": settings.OUTPUT_PATH,
        "target_codes": settings.get_target_codes(),
        "target_names": settings.get_target_names()
    }


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(
        "src.main:app",
        host=settings.SERVICE_HOST,
        port=settings.SERVICE_PORT,
        reload=False
    )
EOF
echo -e "${GREEN}✓ src/main.py 生成完成${NC}"

# ============================================================================
# 生成 src/__init__.py
# ============================================================================
echo "生成 src/__init__.py..."
cat > "${DEPLOY_ROOT}/src/__init__.py" << 'EOF'
# VODS - Video Object Detection Service
EOF
echo -e "${GREEN}✓ src/__init__.py 生成完成${NC}"

# ============================================================================
# 生成 docker/Dockerfile
# ============================================================================
echo "生成 docker/Dockerfile..."
cat > "${DEPLOY_ROOT}/docker/Dockerfile" << 'EOF'
# VODS - Video Object Detection Service Dockerfile
FROM python:3.12-slim

# 设置工作目录
WORKDIR /app

# 设置环境变量
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple

# 安装系统依赖
RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    libgl1-mesa-glx \
    libglib2.0-0 \
    libsm6 \
    libxext6 \
    libxrender-dev \
    libgomp1 \
    && rm -rf /var/lib/apt/lists/*

# 复制依赖文件
COPY requirements.txt .

# 安装 Python 依赖
RUN pip install --no-cache-dir -r requirements.txt

# 复制源代码
COPY src/ ./src/
COPY .env ./.env

# 创建目录
RUN mkdir -p /app/output /app/logs

# 暴露端口
EXPOSE 8000

# 健康检查
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD python -c "import requests; requests.get('http://localhost:8000/health', timeout=5)" || exit 1

# 启动命令
CMD ["python", "-m", "uvicorn", "src.main:app", "--host", "0.0.0.0", "--port", "8000"]
EOF
echo -e "${GREEN}✓ docker/Dockerfile 生成完成${NC}"

# ============================================================================
# 生成 docker/docker-compose.yml
# ============================================================================
echo "生成 docker/docker-compose.yml..."
cat > "${DEPLOY_ROOT}/docker/docker-compose.yml" << 'EOF'
version: '3.8'

services:
  vods:
    build:
      context: ..
      dockerfile: docker/Dockerfile
    container_name: vods-server
    ports:
      - "8000:8000"
    environment:
      - SERVICE_HOST=0.0.0.0
      - SERVICE_PORT=8000
      - OUTPUT_PATH=/app/output
      - DEFAULT_SKIP_FRAMES=20
      - MAX_CONCURRENT_TASKS=4
      - LOG_LEVEL=INFO
    volumes:
      # 挂载输出目录到宿主机
      - /home/pgh/work/docker_vds/output:/app/output
      - /home/pgh/work/docker_vds/logs:/app/logs
      # 如果需要访问本地视频文件，挂载视频目录
      - /home/pgh/work/docker_vds/videos:/app/videos:ro
    restart: unless-stopped
    networks:
      - vods-network

networks:
  vods-network:
    driver: bridge
EOF
echo -e "${GREEN}✓ docker/docker-compose.yml 生成完成${NC}"

# ============================================================================
# 生成 README.md
# ============================================================================
echo "生成 README.md..."
cat > "${DEPLOY_ROOT}/README.md" << 'EOF'
# VODS - Video Object Detection Service

视频目标识别服务 - 从视频流中提取帧并进行目标识别

## 目录结构
