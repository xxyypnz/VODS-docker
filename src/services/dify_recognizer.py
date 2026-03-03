import os
import logging
import requests
import json
from typing import Dict, Any

# [关键修复] 直接使用 "vods" 作为 logger 名称
# 这样能确保复用 main.py 中 setup_logger("vods", ...) 配置的 Handler 和 Format
logger = logging.getLogger("vods")

class DifyRecognizer:
    def __init__(self, api_url: str, api_key: str, prompt: str):
        self.api_url = api_url
        self.api_key = api_key
        self.prompt = prompt
        # 初始化日志已在 main.py 中统一打印

    def recognize(self, image_url: str, task_id: str, frame_index: int) -> Dict[str, Any]:
        """
        调用 Dify API 进行识别。
        :raises: RuntimeError 如果请求失败或返回非 200。
        """
        
        # 【第 1 步】
        logger.info(f"【第 1 步】视频解码第{frame_index}帧图像,image_url:{image_url}")

        payload = {
            "inputs": {
                "image_input": {
                    "type": "image",
                    "transfer_method": "remote_url",
                    "url": image_url
                },
                "query": self.prompt,
                "resolution": "1024x768"
            },
            "response_mode": "blocking",
            "user": f"vods-{task_id}"
        }

        headers = {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json"
        }

        # 【第 2 步】
        logger.info(f"【第 2 步】第 {frame_index} 帧图像，发送到 Dify 进行识别")

        try:
            response = requests.post(self.api_url, json=payload, headers=headers, timeout=30)
            
            # 【第 3 步】
            logger.info("【第 3 步】接收到 Dify HTTP 回复消息")

            if response.status_code != 200:
                error_msg = f"Dify API 返回错误状态码：{response.status_code}. Response: {response.text[:200]}"
                logger.error(f"❌ {error_msg}")
                raise RuntimeError(error_msg)

            result = response.json()
            outputs = result.get("data", {}).get("outputs", {})
            text_content = outputs.get("text", "")
            
            if not text_content:
                text_content = outputs.get("result", "") or result.get("outputs", {}).get("text", "")

            response_data = {"text": text_content}

            # 【第 4 步】
            formatted_json = json.dumps(response_data, indent=2, ensure_ascii=False)
            logger.info(f"【第 4 步】Dify HTTP 回复消息解析结果\n{formatted_json}")

            return response_data

        except requests.exceptions.Timeout:
            logger.error("❌ Dify API 请求超时 (30s)")
            raise RuntimeError("Dify API 请求超时")
        except requests.exceptions.RequestException as e:
            logger.error(f"❌ Dify API 网络请求异常：{e}")
            raise RuntimeError(f"Dify API 网络错误：{str(e)}")
        except Exception as e:
            logger.error(f"❌ Dify API 响应解析失败：{e}")
            raise RuntimeError(f"Dify API 处理异常：{str(e)}")
