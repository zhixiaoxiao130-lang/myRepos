#!/bin/bash
# ======================================================
# CSI 摄像头测试脚本 (CSI0/CSI1) - 完整版（含预热）
# 功能：拍照 / 预览 / 录屏，自动降权保留图形环境
# 新增：拍照/录屏前自动丢弃前10帧，稳定传感器曝光
# ======================================================
set -euo pipefail

# ---------- 颜色 ----------
BOLD='\033[1m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ---------- 权限处理：root 时降权为 sudo 用户，并保留完整会话环境 ----------
if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
    mkdir -p ./log ./csi_capture 2>/dev/null
    chown -R "${SUDO_USER}:${SUDO_USER}" ./log ./csi_capture 2>/dev/null
    setfacl -R -m "u:${SUDO_USER}:rwx" ./log ./csi_capture 2>/dev/null || true
    usermod -a -G video,render "${SUDO_USER}" 2>/dev/null || true

    # 使用 sudo -i 启动登录 shell，自动继承 WAYLAND / XDG_RUNTIME_DIR 等变量
    exec sudo -u "$SUDO_USER" -i bash -c "
        cd '$PWD' && exec bash '$0' $*
    " -- "$@"
fi

# ---------- 环境检查 ----------
check_env() {
    if ! command -v gst-launch-1.0 &> /dev/null; then
        echo -e "${RED}${BOLD}✗ 未找到 gst-launch-1.0，请先安装 GStreamer 工具。${NC}"
        echo -e "${YELLOW}安装命令（适用于 Debian/Ubuntu）：${NC}"
        echo "  sudo apt update && sudo apt install -y gstreamer1.0-tools \\"
        echo "      gstreamer1.0-plugins-base gstreamer1.0-plugins-good \\"
        echo "      gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly \\"
        echo "      gstreamer1.0-libav"
        echo ""
        echo -e "${YELLOW}备注：waylandsink 已包含在 gstreamer1.0-plugins-bad 中，无需额外安装。${NC}"
        exit 1
    fi
}

# ---------- Overlay 检查（带完整修复指引）----------
check_csi_overlays() {
    local env_file="/boot/armbianEnv.txt"
    local needed=("recomputer-rk3588-devkit-cam0-rpi-v3" "recomputer-rk3588-devkit-cam1-rpi-v3")
    local overlay_line="overlays=${needed[*]}"

    if [ ! -f "$env_file" ]; then
        echo -e "${RED}✗ 配置文件 ${env_file} 不存在！${NC}"
        echo -e "${YELLOW}请创建该文件并添加以下行：${NC}"
        echo "  sudo bash -c 'echo \"${overlay_line}\" >> ${env_file}'"
        echo "  sudo sync"
        echo "  sudo reboot"
        echo "重启后 CSI 摄像头才能正常工作。"
        return 1
    fi

    local current_line=$(grep -E '^\s*overlays=' "$env_file" | head -1)
    if [ -z "$current_line" ]; then
        echo -e "${RED}✗ ${env_file} 中未找到 overlays 配置。${NC}"
        echo -e "${YELLOW}请在 ${env_file} 中添加以下行：${NC}"
        echo "  ${overlay_line}"
        echo "如果文件已有其他配置，请用空格分隔多个 overlays。"
        echo "添加后执行："
        echo "  sudo sync"
        echo "  sudo reboot"
        echo "重启后 CSI 摄像头才能正常工作。"
        return 1
    fi

    local missing=()
    for ov in "${needed[@]}"; do
        if ! echo "$current_line" | grep -qF "$ov"; then
            missing+=("$ov")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${RED}✗ 缺少必要的 CSI Overlay: ${missing[*]}${NC}"
        echo -e "${YELLOW}当前配置行：${current_line}${NC}"
        echo -e "${YELLOW}请修改 ${env_file}，确保 overlays 行包含以下项（用空格分隔）：${NC}"
        echo "  ${overlay_line}"
        echo "例如，如果当前行已有其他 overlay，可追加所需项："
        echo "  overlays=原有项 ${missing[*]}"
        echo "修改完成后执行："
        echo "  sudo sync"
        echo "  sudo reboot"
        echo "重启后 CSI 摄像头才能正常工作。"
        return 1
    fi

    echo -e "${GREEN}✅ CSI Overlay 配置正确${NC}"
    return 0
}

# ---------- 设备定义 ----------
CSI0_DEV="/dev/video22"
CSI1_DEV="/dev/video31"

LOG_DIR="./log"
CAPTURE_DIR="./csi_capture"
mkdir -p "$LOG_DIR" "$CAPTURE_DIR" 2>/dev/null || true

# ---------- 摄像头预热：丢弃前 N 帧，稳定曝光 ----------
sensor_warmup() {
    local dev="$1" warmup_frames="${2:-10}"
    echo -e "${YELLOW}⏳ 摄像头预热中（丢弃前 ${warmup_frames} 帧）...${NC}"
    timeout --signal=INT 10 gst-launch-1.0 v4l2src device="$dev" num-buffers="$warmup_frames" ! \
        video/x-raw ! videoconvert ! fakesink &>/dev/null
}

# ---------- 拍照（自动格式降级 + 超时保护）----------
take_photo() {
    check_csi_overlays || return
    local cam=$1 dev out log_file
    out="${CAPTURE_DIR}/csi${cam}_photo_$(date +%Y%m%d_%H%M%S).jpg"
    log_file="${LOG_DIR}/csi_photo.log"
    [ "$cam" -eq 0 ] && dev="$CSI0_DEV" || dev="$CSI1_DEV"

    echo -e "\n${BOLD}${CYAN}═══ CSI${cam} 拍照测试 ═══${NC}"
    echo -e "  设备: ${BOLD}${dev}${NC}"
    echo -e "  输出: ${BOLD}${out}${NC}\n"

    # 预热传感器
    sensor_warmup "$dev" 10

    echo "拍照尝试 (1) 高分辨率 NV12 → (2) 自动格式" > "$log_file"

    # 尝试 1：4608x2592 NV12（3 秒超时）
    echo "尝试 4608x2592 NV12..." | tee -a "$log_file"
    if timeout --signal=INT 3 gst-launch-1.0 v4l2src device="$dev" num-buffers=1 ! \
        video/x-raw,format=NV12,width=4608,height=2592 ! videoconvert ! jpegenc ! \
        filesink location="$out" &>> "$log_file"; then
        echo -e "\n${GREEN}✓ 拍照成功（高分辨率）${NC} 文件: ${BOLD}${out}${NC}"
        return
    fi

    # 尝试 2：自动协商格式（5 秒超时）
    echo "尝试自动格式..." | tee -a "$log_file"
    if timeout --signal=INT 5 gst-launch-1.0 v4l2src device="$dev" num-buffers=1 ! \
        video/x-raw ! videoconvert ! jpegenc ! filesink location="$out" &>> "$log_file"; then
        echo -e "\n${GREEN}✓ 拍照成功（自动格式）${NC} 文件: ${BOLD}${out}${NC}"
        return
    fi

    echo -e "\n${RED}✗ 拍照失败，请检查摄像头连接或 overlay。${NC}"
}

# ---------- 预览（仅本地桌面，Wayland）----------
start_preview() {
    if [[ -n "${SSH_TTY:-}" || -n "${SSH_CLIENT:-}" ]]; then
        echo -e "${RED}✗ 预览不支持 SSH，请在设备本地桌面终端中执行。${NC}"
        return
    fi
    check_csi_overlays || return
    local cam=$1 dev log_file
    log_file="${LOG_DIR}/csi_preview.log"
    [ "$cam" -eq 0 ] && dev="$CSI0_DEV" || dev="$CSI1_DEV"

    echo -e "\n${BOLD}${CYAN}═══ CSI${cam} 预览测试 ═══${NC}"
    echo -e "  设备: ${BOLD}${dev}${NC}  按 Ctrl+C 退出预览\n"

    echo "预览命令: $(date)" > "$log_file"
    gst-launch-1.0 -e \
        v4l2src device="$dev" do-timestamp=true ! \
        video/x-raw ! videoconvert ! \
        waylandsink sync=false enable-last-sample=false 2>&1 | tee -a "$log_file"
}

# ---------- 录屏（30 秒，MP4 浏览器可播放）----------
record_video() {
    check_csi_overlays || return
    local cam=$1 dev out log_file
    out="${CAPTURE_DIR}/csi${cam}_video_$(date +%Y%m%d_%H%M%S).mp4"
    log_file="${LOG_DIR}/csi_video.log"
    [ "$cam" -eq 0 ] && dev="$CSI0_DEV" || dev="$CSI1_DEV"

    echo -e "\n${BOLD}${CYAN}═══ CSI${cam} 录屏测试 ═══${NC}"
    echo -e "  设备: ${BOLD}${dev}${NC}  时长 30 秒  输出: ${BOLD}${out}${NC}\n"

    # 预热传感器
    sensor_warmup "$dev" 10

    echo "录屏命令: $(date)" > "$log_file"
    timeout --signal=INT 30 gst-launch-1.0 -e \
        v4l2src device="$dev" do-timestamp=true ! \
        videoconvert ! videoscale ! video/x-raw,width=1920,height=1080 ! \
        queue ! x264enc bitrate=8000 speed-preset=medium ! \
        h264parse ! mp4mux ! filesink location="$out" 2>&1 | tee -a "$log_file"

    local ret=$?
    if [ $ret -eq 0 ] || [ $ret -eq 130 ]; then
        echo -e "\n${GREEN}✓ 录屏完成！${NC} 文件: ${BOLD}${out}${NC}"
    else
        echo -e "\n${RED}✗ 录屏失败！${NC}"
    fi
}

# ---------- 主菜单 ----------
main_menu() {
    check_env
    while true; do
        local available=""
        [ -e "$CSI0_DEV" ] && available="$available 0"
        [ -e "$CSI1_DEV" ] && available="$available 1"
        available=$(echo $available | xargs)
        if [ -z "$available" ]; then
            echo -e "${RED}未检测到任何 CSI 摄像头设备。${NC}"
            echo -e "${YELLOW}可能的原因：CSI overlay 未配置或摄像头未连接。${NC}"
            check_csi_overlays
            exit 1
        fi

        echo ""
        echo -e "${BOLD}${CYAN}========================================${NC}"
        echo -e "${BOLD}       RK3588 CSI 摄像头测试工具${NC}"
        echo -e "${BOLD}${CYAN}========================================${NC}"
        echo "  可用摄像头: ${available}"
        echo "  1) 拍照"
        echo "  2) 预览        (需本地桌面)"
        echo "  3) 录屏        (30 秒 MP4)"
        echo "  q) 退出"
        echo -e "${BOLD}${CYAN}========================================${NC}"
        read -p "请输入选项 [1-3, q]: " action

        case "$action" in
            1|2|3)
                read -p "选择摄像头编号 (${available}): " cam
                if ! echo "$available" | grep -qw "$cam"; then
                    echo -e "${RED}✗ 无效的摄像头编号。${NC}"
                    continue
                fi
                case "$action" in
                    1) take_photo "$cam" ;;
                    2) start_preview "$cam" ;;
                    3) record_video "$cam" ;;
                esac
                ;;
            q|Q)
                echo -e "\n${GREEN}退出测试。${NC}"
                exit 0
                ;;
            *) echo -e "${RED}✗ 无效选项。${NC}" ;;
        esac
    done
}

main_menu
