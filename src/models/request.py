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
    duration_seconds: int = Field(60, description="处理持续时间 (秒)", ge=1, le=333600)
    
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
