#!/bin/bash
# HDMI 输入综合测试脚本（最终稳定版）
# 用法: sudo ./hdmi_test.sh

set -euo pipefail

# ---------- 配置 ----------
VIDEO_DEV="/dev/video40"
CAPTURE_DIR="./hdmi_capture"
LOG_DIR="./log"
SINGLE_LOG="${LOG_DIR}/hdmi_single.log"
CONTINUOUS_LOG="${LOG_DIR}/hdmi_continuous.log"
INTERVAL=5
RECORD_DURATION=30   # 目标录制时长（秒），实际文件可能略长，属正常现象

# ---------- 颜色 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
INFO="${CYAN}[i]${NC}"; OK="${GREEN}[✓]${NC}"; ERR="${RED}[✗]${NC}"; WARN="${YELLOW}[!]${NC}"

check_deps() {
    local missing=""
    for cmd in v4l2-ctl gst-launch-1.0; do
        command -v "$cmd" &>/dev/null || missing="$missing $cmd"
    done
    if [ -n "$missing" ]; then
        echo -e "${ERR} 缺少依赖: $missing"
        echo -e "${INFO} 请安装: sudo apt install v4l-utils gstreamer1.0-tools gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-plugins-ugly"
        exit 1
    fi
}

device_node_exists() { [ -e "$VIDEO_DEV" ]; }

has_valid_signal() {
    local width=$(v4l2-ctl -d "$VIDEO_DEV" --get-dv-timings 2>/dev/null | grep -oP 'Active width: \K[0-9]+' || true)
    [ -n "$width" ] && [ "$width" -gt 0 ]
}

ensure_signal() {
    if ! device_node_exists; then
        echo -e "${ERR} 设备节点 $VIDEO_DEV 不存在"
        return 1
    fi
    if ! has_valid_signal; then
        echo -e "${WARN} 设备未接入或无 HDMI 输入信号，无法执行该测试"
        return 1
    fi
    return 0
}

log_tee() {
    echo -e "$@" | tee -a "$LOG_FILE" 2>/dev/null || echo -e "$@" >&2
}

# ---------- 单次检测 ----------
do_single_check() {
    (
        set +e
        mkdir -p "$LOG_DIR"
        LOG_FILE="$SINGLE_LOG"
        > "$LOG_FILE"

        log_tee "${INFO} 单次设备与音频检测开始..."
        ensure_signal || return 1
        log_tee "${OK} HDMI 输入信号有效"

        log_tee "\n${BOLD}${CYAN}▌ 视频信号状态${NC}"
        log_tee "${CYAN}─────────────────────────────────────────────────${NC}"
        local dv_timings=$(v4l2-ctl -d "$VIDEO_DEV" --get-dv-timings 2>/dev/null)
        local width=$(echo "$dv_timings" | grep -oP 'Active width: \K[0-9]+' || true)
        local height=$(echo "$dv_timings" | grep -oP 'Active height: \K[0-9]+' || true)
        local frame_format=$(echo "$dv_timings" | grep -oP 'Frame format: \K[^\n]+' || true)
        local pixelclock=$(echo "$dv_timings" | grep -oP 'Pixelclock: \K[0-9]+' || true)
        log_tee "  分辨率: ${GREEN}${width:-未知}x${height:-未知}${NC}"
        log_tee "  帧格式: ${frame_format:-未知}"
        log_tee "  像素时钟: ${pixelclock:-未知} Hz"
        log_tee "${CYAN}─────────────────────────────────────────────────${NC}"

        if v4l2-ctl -d "$VIDEO_DEV" --get-ctrl audio_present &>/dev/null; then
            local state=$(v4l2-ctl -d "$VIDEO_DEV" --get-ctrl audio_present | awk '{print $2}')
            if [ "$state" == "1" ]; then
                log_tee "${OK} 检测到 HDMI 音频信号"
            else
                log_tee "${WARN} 未检测到 HDMI 音频信号"
            fi
        else
            log_tee "${ERR} 此设备不支持 audio_present 控件"
        fi

        log_tee "\n${OK} 单次检测完成。日志: $SINGLE_LOG"
    )
}

# ---------- 拍照 ----------
take_photo() {
    echo -e "${INFO} 正在检查 HDMI 输入状态..."
    ensure_signal || return

    mkdir -p "$CAPTURE_DIR"
    local filename="${CAPTURE_DIR}/hdmi_photo_$(date +%Y%m%d_%H%M%S).jpg"
    echo -e "${INFO} 正在拍照，保存至 ${filename} ..."
    if gst-launch-1.0 -e v4l2src device="$VIDEO_DEV" num-buffers=1 ! \
        videoconvert ! jpegenc ! filesink location="$filename" >/dev/null 2>&1; then
        echo -e "${OK} 拍照完成: ${GREEN}${filename}${NC}"
    else
        echo -e "${ERR} 拍照失败。可尝试手动命令："
        echo "       gst-launch-1.0 v4l2src device=$VIDEO_DEV num-buffers=1 ! videoconvert ! jpegenc ! filesink location=test.jpg"
    fi
}

# ---------- 录屏（使用 splitmuxsink + 超时自动停止）----------
record_video() {
    echo -e "${INFO} 正在检查 HDMI 输入状态..."
    ensure_signal || return

    mkdir -p "$CAPTURE_DIR"
    local basename="${CAPTURE_DIR}/hdmi_video_$(date +%Y%m%d_%H%M%S)"
    local temp_prefix="${basename}_part_"
    local final_file="${basename}.mp4"

    echo -e "${INFO} 正在录屏 ${RECORD_DURATION} 秒，保存至 ${final_file} ..."

    # 后台启动录制管道
    gst-launch-1.0 -e v4l2src device="$VIDEO_DEV" ! \
        video/x-raw ! videoconvert ! \
        x264enc bitrate=8000 speed-preset=medium ! \
        h264parse ! splitmuxsink location="${temp_prefix}%02d.mp4" max-size-time=$((RECORD_DURATION * 1000000000)) \
        >/dev/null 2>&1 &
    local pid=$!

    # 等待 RECORD_DURATION 秒后停止，额外增加 4 秒缓冲（确保至少一个片段写入）
    sleep "$RECORD_DURATION"
    sleep 4

    # 发送 SIGINT 并等待进程结束
    kill -INT "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null

    # 处理生成的文件：只保留第一个分割文件，重命名为最终文件名
    if [ -f "${temp_prefix}00.mp4" ]; then
        mv "${temp_prefix}00.mp4" "$final_file"
        rm -f "${temp_prefix}"*.mp4   # 删除其他可能的分割文件
        echo -e "${OK} 录屏完成: ${GREEN}${final_file}${NC}"
    else
        rm -f "${temp_prefix}"*.mp4
        echo -e "${ERR} 录屏失败：未生成视频文件。请检查 HDMI 信号源。"
    fi
}

# ---------- 持续检测 ----------
do_continuous_check() {
    mkdir -p "$LOG_DIR"
    > "$CONTINUOUS_LOG"
    local total=0
    echo -e "${INFO} 持续设备与音频检测开始 (间隔 ${INTERVAL} 秒，按 Ctrl+C 停止)"
    echo "时间戳,设备状态,音频状态" | tee "$CONTINUOUS_LOG"
    trap 'echo ""; echo "监测结束，共检测 ${total} 次。日志: $CONTINUOUS_LOG"; exit 0' SIGINT SIGTERM

    while true; do
        local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        local dev_status="无信号"
        local audio_status="无"
        if device_node_exists; then
            if has_valid_signal; then
                dev_status="有信号"
                if v4l2-ctl -d "$VIDEO_DEV" --get-ctrl audio_present &>/dev/null; then
                    local state=$(v4l2-ctl -d "$VIDEO_DEV" --get-ctrl audio_present | awk '{print $2}')
                    [ "$state" == "1" ] && audio_status="有"
                fi
            else
                dev_status="无信号"
            fi
        else
            dev_status="节点缺失"
        fi
        echo "$timestamp | 设备$dev_status | 音频$audio_status" | tee -a "$CONTINUOUS_LOG"
        total=$((total + 1))
        sleep $INTERVAL
    done
}

# ---------- 主菜单 ----------
main() {
    [ "$(id -u)" -ne 0 ] && { echo -e "${ERR} 请使用 sudo 运行此脚本"; exit 1; }
    check_deps

    while true; do
        echo ""
        echo -e "${BOLD}${CYAN}========================================${NC}"
        echo -e "${BOLD}${CYAN}     HDMI 输入综合测试工具${NC}"
        echo -e "${BOLD}${CYAN}========================================${NC}"
        echo "  1) 设备与音频检测（单次，含视频状态）"
        echo "  2) 拍照（保存到 ${CAPTURE_DIR}/）"
        echo "  3) 录屏（${RECORD_DURATION} 秒，保存到 ${CAPTURE_DIR}/）"
        echo "  4) 持续设备与音频检测（每隔 ${INTERVAL} 秒）"
        echo "  q) 退出"
        echo -e "${CYAN}========================================${NC}"
        read -p "请选择 (1-4, q): " choice

        case $choice in
            1) do_single_check ;;
            2) take_photo ;;
            3) record_video ;;
            4) do_continuous_check ;;
            q|Q) echo "退出。"; break ;;
            *) echo -e "${ERR} 无效选项" ;;
        esac
    done
}

main "$@"
