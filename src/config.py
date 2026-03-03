from pydantic_settings import BaseSettings
from functools import lru_cache
from typing import List
import os


class Settings(BaseSettings):
    """Service configuration"""
    
    SERVICE_HOST: str = "192.168.0.52"
    SERVICE_PORT: int = 8000
    OUTPUT_PATH: str = "/app/output"
    FRAME_FORMAT: str = "jpg"
    FRAME_QUALITY: int = 85
    DEFAULT_SKIP_FRAMES: int = 20
    MIN_SKIP_FRAMES: int = 1
    MAX_SKIP_FRAMES: int = 100
    DEFAULT_DURATION_SECONDS: int = 60
    MAX_DURATION_SECONDS: int = 300
    MAX_CONCURRENT_TASKS: int = 4
    LOG_LEVEL: str = "INFO"
    LOG_PATH: str = "/app/logs"
    TARGET_CODES: str = "1001,1002,1003,1004"
    TARGET_NAMES: str = "Traffic Cone,Warning Sign,Person,Rust"
    
    # Suggestions file path
    SUGGESTIONS_FILE: str = "/app/suggestions.yaml"
    
    model_config = {
        "env_file": ".env",
        "env_file_encoding": "utf-8"
    }
    
    def get_target_codes(self) -> List[str]:
        return [code.strip() for code in self.TARGET_CODES.split(",")]
    
    def get_target_names(self) -> List[str]:
        return [name.strip() for name in self.TARGET_NAMES.split(",")]
    
    def get_suggestions_path(self) -> str:
        """Get suggestions file path"""
        if os.path.exists(self.SUGGESTIONS_FILE):
            return self.SUGGESTIONS_FILE
        return "/app/suggestions.yaml"


@lru_cache()
def get_settings() -> Settings:
    return Settings()


settings = get_settings()
