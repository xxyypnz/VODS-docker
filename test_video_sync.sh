#!/bin/bash

# ================= 配置区域 =================
API_BASE_URL="http://localhost:8000"
API_ENDPOINT="/api/v1/video/recognize"
MODE="syn"
VIDEO_SOURCE="rtsp://192.168.0.52:8554/h264ESVideoTest"
SOURCE_TYPE="rtsp"
SKIP_FRAMES=20
DURATION_SECONDS=20

echo "----------------------------------------"
echo "🚀 开始执行视频识别测试 (模式: $MODE)"
echo "📹 视频源: $VIDEO_SOURCE"
echo "⏱️ 持续时间: ${DURATION_SECONDS}s, 跳帧: $SKIP_FRAMES"
echo "----------------------------------------"
echo ""

# 调用 Python 进行流式处理和完美对齐
python3 << 'PYEOF'
import sys
import requests
import json

# 配置
url = "http://localhost:8000/api/v1/video/recognize?mode=syn"
payload = {
    "video_source": "rtsp://192.168.0.52:8554/h264ESVideoTest",
    "source_type": "rtsp",
    "skip_frames": 20,
    "duration_seconds": 10
}

# 定义列宽 (根据显示效果调整)
# 中文字符在大多数终端占 2 个单位，英文占 1 个。
# 为了简单对齐，我们直接使用固定宽度的字符串格式化，
# 并假设中文不超过一定长度。
# 更好的方式是使用 wcwidth 库，但为了不依赖额外库，我们采用“足够大”的固定宽度策略。

COL_CODE_WIDTH = 10   # [1001] + 空格
COL_NAME_WIDTH = 24   # 足够容纳 "人形 + 绝缘手套" (8 汉字=16 宽 + 余量)

def print_header():
    # 手动构造表头，确保与下方内容对齐
    # %-Ns 表示左对齐，占 N 个字符位置
    # 注意：这里为了视觉对齐，需要根据中文字符的实际显示宽度微调
    # 简单策略：直接打印固定空格间隔
    print(f"{'目标码':<10} {'目标名称':<24} -> 保存文件")
    print("-" * 60)

def format_line(code, name, filename):
    # 计算填充空格
    # 这里的逻辑是：我们希望总长度固定。
    # 但由于中文宽度问题，简单的 ljust 在混合环境下可能不准。
    # 妥协方案：使用制表符 \t 或者 固定足够大的空格数
    
    # 最稳健的 Bash/Python 混合方案：
    # 直接输出特定数量的空格，不依赖自动计算，而是依赖“最大可能长度”
    
    # 假设：
    # Code 部分最多显示 "[XXXX] " (8 字符)
    # Name 部分最长中文约 10 个字 (20 显示宽度)
    
    # 我们直接使用 ljust，Python 3 对 unicode 支持较好，但在某些终端仍需调整
    # 这里采用：Code 固定 10 字符宽，Name 固定 30 字符宽 (留足余量)
    
    part1 = f"[{code}]".ljust(COL_CODE_WIDTH)
    part2 = name.ljust(COL_NAME_WIDTH) # Python 的 ljust 按字符数，不是显示宽度
    
    # 修正：如果终端是 UTF-8 且支持宽字符，ljust 可能会少算空格。
    # 暴力修正法：手动追加空格直到达到视觉平衡，或者使用 wcwidth。
    # 为了不安装 wcwidth，我们采用“动态计算显示宽度”的简易函数：
    
    def get_display_width(s):
        width = 0
        for char in s:
            if '\u4e00' <= char <= '\u9fff': # 常用汉字范围
                width += 2
            else:
                width += 1
        return width

    def pad_to(s, target_width):
        current_w = get_display_width(s)
        spaces_needed = target_width - current_w
        if spaces_needed < 0: spaces_needed = 0
        return s + ' ' * spaces_needed

    p1 = pad_to(f"[{code}]", 10)
    p2 = pad_to(name, 24) # 24 显示宽度 ≈ 12 个汉字
    
    return f"{p1} {p2} -> {filename}"

try:
    print_header()
    
    with requests.post(url, json=payload, stream=True, timeout=60) as resp:
        for line in resp.iter_lines():
            if line:
                decoded = line.decode('utf-8')
                if decoded.startswith('data: '):
                    data = json.loads(decoded[6:])
                    event = data.get('event')
                    
                    if event == 'start':
                        print(f"\n🟢 {data['message']}\n")
                        print_header()
                    elif event == 'frame':
                        code = data.get('target_code')
                        name = data.get('target_name')
                        file = data.get('renamed_file')
                        print(format_line(code, name, file))
                    elif event == 'complete':
                        print("-" * 60)
                        print(f"✅ {data['message']}")
                        print(f"   总帧数：{data.get('total_frames_saved')} | 目标数：{data.get('frames_with_target')} | 耗时：{data.get('duration_seconds')}s")
                        print("-" * 60)
                    elif event == 'error':
                        print(f"\n❌ 错误：{data.get('message')}\n")

except Exception as e:
    print(f"发生错误：{e}")
PYEOF

echo ""
echo "测试结束"
