import os
import logging
import json
import re
from typing import Dict, Any, List, Optional
from .dify_recognizer import DifyRecognizer

logger = logging.getLogger("vods")

class FrameRecognizer:
    def __init__(self, 
                 use_dify: bool = False, 
                 dify_api_url: str = "", 
                 api_key: str = "", 
                 base_image_url: str = "",
                 suggestions_loader: Optional[Any] = None):
        
        self.use_dify = use_dify
        self.dify_api_url = dify_api_url if dify_api_url else os.getenv("DIFY_API_URL", "")
        self.api_key = api_key if api_key else os.getenv("DIFY_API_KEY", "")
        self.base_image_url = (base_image_url if base_image_url else os.getenv("BASE_IMAGE_URL", "http://localhost:8000")).rstrip('/')
        
        self.dify_recognizer = None
        self.target_mapping: Dict[str, str] = {}  # { "Title": "Code" }
        self.target_titles_list: List[str] = []   # ["人形 + 绝缘手套", "人形 + 抽烟", ...]
        self.dify_query_prompt: str = ""          # 最终生成的 query 字符串

        # 从 Loader 构建映射表和目标列表
        if suggestions_loader:
            self._build_name_to_code_map(suggestions_loader)
        else:
            logger.warning("⚠️ SuggestionsLoader is None. Target mapping will be empty.")

        if self.use_dify:
            if not self.dify_api_url or not self.api_key:
                raise RuntimeError("Dify mode enabled but missing URL or Key.")
            
            # [改进 3] 构建最终的 Query 字符串
            # 格式：识别图片中的目标：目标1，目标2，目标3。
            titles_str = ", ".join(self.target_titles_list)
            if not titles_str:
                titles_str = "常见物体" # 兜底
            
            self.dify_query_prompt = f"识别图片中的目标：{titles_str}。"
            
            # 初始化 Dify Recognizer，传入完整的 prompt (这里只传基础指令，query 在每次调用时动态构造或在此处固定)
            # 为了灵活性，我们将完整的指令作为默认 prompt 传入，但 recognize 方法中会覆盖 inputs.query
            base_instruction = "请分析图片，严格只返回 JSON 格式数组，每个元素包含 T(目标名称) 和 N(数量)。"
            full_prompt = f"{self.dify_query_prompt} {base_instruction}"
            
            self.dify_recognizer = DifyRecognizer(self.dify_api_url, self.api_key, full_prompt)
            logger.info(f"✅ Dify Recognizer initialized. URL: {self.dify_api_url}")

    def _build_name_to_code_map(self, loader: Any):
        """
        遍历 suggestions.yaml，构建映射表和带编码的目标列表
        """
        try:
            codes = loader.get_all_codes()
            count = 0
            display_list = [] # 用于日志显示的列表 ["1001 标题", "1002 标题"...]
            
            for code in codes:
                # 跳过 0000
                if str(code) == "0000" or str(code) == "0":
                    continue
                
                suggestion = loader.get_suggestion(code)
                if suggestion and "title" in suggestion:
                    title = suggestion["title"]
                    code_str = str(code)
                    
                    # 构建映射
                    self.target_mapping[title] = code_str
                    
                    # 构建纯标题列表 (用于生成 Prompt)
                    self.target_titles_list.append(title)
                    
                    # 构建带编码的显示列表 (用于日志)
                    display_list.append(f"{code_str} {title}")
                    
                    count += 1
            
            # [改进 1] 打印带编码的目标列表，去掉 "(用于 Prompt)"
            if display_list:
                logger.info(f"📋 加载目标配置：{', '.join(display_list)}")
            else:
                logger.warning("⚠️ suggestions.yaml 中未找到有效目标 (除 0000 外)。")
                
            logger.info(f"✅ 成功加载 {count} 个目标映射关系。")
                
        except Exception as e:
            logger.error(f"❌ 构建目标映射表失败：{e}", exc_info=True)

    def recognize(self, frame_index: int, task_id: str) -> Dict[str, Any]:
        if not self.use_dify or not self.dify_recognizer:
            return {"has_target": False, "target_code": "0000", "target_name": "NoTarget"}

        image_url = f"{self.base_image_url}/{task_id}/frames/{frame_index}.jpg"
        
        # [改进 3] 动态构造 payload 中的 query
        # 虽然 __init__ 中构建了 prompt，但这里我们确保发送给 Dify 的 inputs.query 是最新的动态字符串
        current_query = self.dify_query_prompt

        # 调用 DifyRecognizer，这里我们需要稍微调整一下调用方式，让 recognize 能使用动态 query
        # 由于 DifyRecognizer 的 recognize 方法目前只接收 image_url，我们需要修改它的内部逻辑或者在这里构造 payload
        # 为了最小改动，我们直接调用 recognizer，但需要在 recognizer 内部支持动态 query，
        # 或者我们在 FrameRecognizer 这里直接发请求？
        # 方案：修改 DifyRecognizer 的 recognize 方法，允许传入自定义 query，或者利用 self.prompt
        # 当前 DifyRecognizer 的 __init__ 接收了 prompt，并在 recognize 中使用 self.prompt 构造 payload。
        # 所以只要 self.dify_recognizer.prompt 是正确的即可。
        # 但我们的 self.dify_query_prompt 是动态的（虽然启动时确定了，但为了严谨）。
        # 实际上，只要启动时 suggestions 加载了，self.dify_query_prompt 就不会变。
        # 所以直接使用 self.dify_recognizer.recognize 即可，因为它初始化时已经用了 self.dify_query_prompt + 指令。
        
        # 但是！如果 DifyRecognizer 内部写死了用 self.prompt 构造 payload，那我们需要确保它用的是我们想要的。
        # 让我们检查 DifyRecognizer 的代码逻辑：它用 self.prompt 构造 payload.inputs.query。
        # 我们在 __init__ 中已经设置了 full_prompt = f"{self.dify_query_prompt} {base_instruction}"。
        # 所以直接调用即可。
        
        outputs = self.dify_recognizer.recognize(image_url, task_id, frame_index)
        
        outputs_text = outputs.get("text", "[]")
        detected_codes: List[str] = []
        detected_names: List[str] = []

        try:
            clean_text = re.sub(r'```json|```', '', outputs_text).strip()
            data_list = json.loads(clean_text)
            
            if not isinstance(data_list, list):
                data_list = [data_list]

            for item in data_list:
                name = item.get("T", "")
                count = item.get("N", 0)
                
                if count > 0 and name:
                    code = self.target_mapping.get(name)
                    
                    if code:
                        detected_codes.append(code)
                        detected_names.append(name)
                    else:
                        logger.warning(f"⚠️ 未知目标 '{name}'，使用默认代码 9999")
                        detected_codes.append("9999")
                        detected_names.append(name)

        except Exception as e:
            logger.warning(f"JSON 解析失败：{e}")

        has_target = len(detected_codes) > 0
        
        if has_target:
            target_code = ",".join(detected_codes)
            target_name = ",".join(detected_names)
        else:
            target_code = "0000"
            target_name = "NoTarget"

        if has_target:
             logger.info(f"🎯 解析结果：HasTarget={has_target}, Code=[{target_code}], Name=[{target_name}]")
        else:
             logger.info(f"🎯 解析结果：HasTarget={has_target}, Code=[{target_code}]")
        
        return {
            "has_target": has_target,
            "target_code": target_code,
            "target_name": target_name
        }
