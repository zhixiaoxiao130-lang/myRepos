#!/bin/bash
# ============================================
# 视频播放脚本 (支持 1080p / 4K，自动检测浏览器)
# 用法: ./play_video.sh
# ============================================

set -euo pipefail

# ---------- 浏览器检测 ----------
if command -v chromium &>/dev/null; then
    BROWSER="chromium"
    # 使用 --start-fullscreen 代替 --kiosk，允许用户按 Alt+F4 或 F11 退出全屏
    BROWSER_ARGS="--start-fullscreen --no-first-run --disable-infobars --autoplay-policy=no-user-gesture-required"
elif command -v firefox &>/dev/null; then
    BROWSER="firefox"
    BROWSER_ARGS="--kiosk"   # firefox kiosk 下可按 Alt+F4 关闭
elif command -v firefox-esr &>/dev/null; then
    BROWSER="firefox-esr"
    BROWSER_ARGS="--kiosk"
else
    echo "❌ 未找到可用的浏览器（firefox / chromium）。"
    echo "请安装其中一个："
    echo "  sudo apt install -y firefox-esr"
    exit 1
fi

# ---------- 依赖检查 ----------
if ! command -v ffprobe &>/dev/null; then
    echo "❌ 缺少 ffprobe (ffmpeg)，请安装: sudo apt install -y ffmpeg"
    exit 1
fi

# ---------- 获取视频信息 ----------
get_video_info() {
    local file="$1"
    local width height duration
    width=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$file")
    height=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$file")
    duration=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$file" 2>/dev/null | awk -F. '{print $1}')

    if [ "$height" -ge 2160 ]; then
        type="4K"
    elif [ "$height" -ge 1080 ]; then
        type="1080p"
    else
        type="${width}x${height}"
    fi

    echo "----------------------------------"
    echo "文件: $file"
    echo "分辨率: ${width}x${height}"
    echo "类型: $type"
    echo "时长: ${duration} 秒"
    echo "----------------------------------"
}

# ---------- 生成 HTML 页面（循环播放）----------
create_html() {
    local video_file="$1"
    local html_file="/tmp/video_player.html"
    cat > "$html_file" <<EOF
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>视频循环播放</title>
    <style>
        body { margin: 0; background: #000; display: flex; justify-content: center; align-items: center; height: 100vh; }
        video { max-width: 100%; max-height: 100%; }
        .hint {
            position: absolute; bottom: 20px; left: 20px; color: rgba(255,255,255,0.6);
            font-size: 14px; font-family: Arial, sans-serif;
        }
    </style>
</head>
<body>
    <video autoplay loop muted playsinline>
        <source src="file://$video_file" type="video/mp4">
    </video>
    <div class="hint">按 Alt+F4 或 F11 退出全屏</div>
</body>
</html>
EOF
    echo "$html_file"
}

# ---------- 主程序 ----------
main() {
    echo "请选择要播放的视频:"
    echo "1) 1080p.mp4"
    echo "2) 4k.mp4"
    read -p "输入选项 (1 或 2): " choice

    case "$choice" in
        1) VIDEO="1080p.mp4" ;;
        2) VIDEO="4k.mp4" ;;
        *) echo "❌ 无效选择"; exit 1 ;;
    esac

    if [ ! -f "$VIDEO" ]; then
        echo "❌ 文件 $VIDEO 不存在于当前目录"
        exit 1
    fi

    # 输出视频信息
    get_video_info "$VIDEO"

    # 生成 HTML
    VIDEO_ABS="$(realpath "$VIDEO")"
    HTML_PATH=$(create_html "$VIDEO_ABS")

    echo "启动浏览器循环播放 ($BROWSER) ..."
    echo "如需关闭，按 Alt+F4 或 F11 退出全屏，或在本终端按 Ctrl+C"

    # 启动浏览器
    $BROWSER $BROWSER_ARGS "file://$HTML_PATH" 2>/dev/null
}

main
