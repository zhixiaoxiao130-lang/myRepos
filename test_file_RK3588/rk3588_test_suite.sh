#!/bin/bash
# RK3588 自动化测试主控脚本（修复视频/CSI 图形环境问题）
# 用法: sudo ./rk3588_test_suite.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- 颜色 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
INFO="${CYAN}[i]${NC}"; OK="${GREEN}[✓]${NC}"; ERR="${RED}[✗]${NC}"

# ---------- 通用执行函数（以 root 运行，用于不需要图形环境的测试）----------
run_script() {
    local script_path="$1"; shift
    local script_dir=$(dirname "$script_path")
    if [ ! -f "$script_path" ]; then
        echo -e "${ERR} 脚本不存在: ${script_path}"
        read -p "按回车键返回菜单..."
        return
    fi

    local exec_cmd
    if [[ "$script_path" == *.py ]]; then
        exec_cmd="python3 $(basename "$script_path") $@"
    else
        exec_cmd="bash $(basename "$script_path") $@"
    fi
    echo -e "${INFO} 执行: cd ${script_dir} && ${exec_cmd}"

    (
        cd "$script_dir" || exit
        if [[ "$script_path" == *.py ]]; then
            python3 "$(basename "$script_path")" "$@"
        else
            bash "$(basename "$script_path")" "$@"
        fi
    )
    echo ""
    read -p "测试执行完毕，按回车键返回菜单..."
}

# ---------- 图形环境脚本专用函数（视频/摄像头/GPU 压测等）----------
run_graphical_script() {
    local script_path="$1"; shift
    local script_dir=$(dirname "$script_path")
    local script_name=$(basename "$script_path")
    if [ ! -f "$script_path" ]; then
        echo -e "${ERR} 脚本不存在: ${script_path}"
        read -p "按回车键返回菜单..."
        return
    fi

    # 如果存在 SUDO_USER，则以原始用户身份运行，并注入图形环境变量
    if [ -n "${SUDO_USER:-}" ]; then
        local user_uid=$(id -u "$SUDO_USER")
        local xdg_runtime="/run/user/${user_uid}"
        if [ ! -d "$xdg_runtime" ]; then
            echo -e "${YELLOW}⚠️  用户 ${SUDO_USER} 的运行时目录 ${xdg_runtime} 不存在，预览/播放可能失败。${NC}"
        fi

        local wayland_display=$(sudo -u "$SUDO_USER" bash -c 'echo $WAYLAND_DISPLAY' 2>/dev/null)
        echo -e "${INFO} 以用户 ${SUDO_USER} 身份执行图形测试..."

        sudo -u "$SUDO_USER" env \
            XDG_RUNTIME_DIR="$xdg_runtime" \
            WAYLAND_DISPLAY="${wayland_display:-wayland-0}" \
            DISPLAY="${DISPLAY:-}" \
            bash -c "cd '$script_dir' && exec bash '$script_name' $*"

        echo ""
        read -p "测试执行完毕，按回车键返回菜单..."
    else
        # 没有 SUDO_USER（直接 root 登录），回退到 root 运行，但警告可能失败
        echo -e "${YELLOW}⚠️  未检测到 sudo 用户（可能直接以 root 登录），将以 root 身份运行图形程序。${NC}"
        echo -e "${YELLOW}  如果程序需要图形界面（如视频播放/CSI 预览），可能会失败。${NC}"
        echo -e "${YELLOW}  建议通过 'sudo ./rk3588_test_suite.sh' 运行本工具。${NC}"
        echo ""
        read -p "按回车键继续尝试，或 Ctrl+C 取消..."
        run_script "$script_path" "$@"
    fi
}

# ---------- 子菜单 ----------
gpu_menu() {
    while true; do
        echo ""
        echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "          GPU / 视频测试"
        echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo "  1) 视频播放 (1080p/4K)"
        echo "  2) GPU 压力测试 (OpenCL)"
        echo "  3) 返回上级菜单"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        read -p "请输入选项 (1-3): " gpu_choice
        case $gpu_choice in
            1) run_graphical_script "$SCRIPT_DIR/gpu/play_video.sh" ;;
            2) run_graphical_script "$SCRIPT_DIR/gpu/stress_gpu.sh" ;;
            3) return ;;
            *) echo -e "${ERR} 无效选项"; sleep 1 ;;
        esac
    done
}

storage_menu() {
    while true; do
        echo ""
        echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "        存储设备测试"
        echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo "  1) NVMe SSD 测试"
        echo "  2) USB 设备测试"
        echo "  3) EEPROM 测试"
        echo "  4) 返回上级菜单"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        read -p "请输入选项 (1-4): " stor_choice
        case $stor_choice in
            1) run_script "$SCRIPT_DIR/ssd/pcie_test.sh" ;;
            2) run_script "$SCRIPT_DIR/usb/usb_test.sh" ;;
            3) run_script "$SCRIPT_DIR/eeprom/eeprom.sh" ;;
            4) return ;;
            *) echo -e "${ERR} 无效选项"; sleep 1 ;;
        esac
    done
}

peripheral_menu() {
    while true; do
        echo ""
        echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "       外设与接口测试"
        echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo "  1) GPIO 测试"
        echo "  2) 风扇控制测试"
        echo "  3) RTC 时钟测试"
        echo "  4) 4G 网络测试"
        echo "  5) 返回上级菜单"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        read -p "请输入选项 (1-5): " peri_choice
        case $peri_choice in
            1) run_script "$SCRIPT_DIR/gpio_test.py" ;;
            2) run_script "$SCRIPT_DIR/fan_test.sh" ;;
            3) run_script "$SCRIPT_DIR/rtc/rtc_test.sh" ;;
            4) run_script "$SCRIPT_DIR/4g_test.sh" ;;
            5) return ;;
            *) echo -e "${ERR} 无效选项"; sleep 1 ;;
        esac
    done
}

display_menu() {
    while true; do
        echo ""
        echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "       显示与多媒体测试"
        echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo "  1) DSI 屏幕测试"
        echo "  2) GPU / 视频测试"
        echo "  3) HDMI 输入测试"
        echo "  4) 返回上级菜单"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        read -p "请输入选项 (1-4): " disp_choice
        case $disp_choice in
            1) run_script "$SCRIPT_DIR/dsi.sh" ;;
            2) gpu_menu ;;
            3) run_script "$SCRIPT_DIR/hdmi_in/hdmi_in.sh" ;;
            4) return ;;
            *) echo -e "${ERR} 无效选项"; sleep 1 ;;
        esac
    done
}

# ---------- 主菜单 ----------
main_menu() {
    while true; do
        echo ""
        echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "       RK3588 自动化测试工具"
        echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo "  1) 基础配置检查"
        echo "  2) AI 加速测试 (NPU)"
        echo "  3) 摄像头测试 (CSI)"
        echo "  4) 显示与多媒体"
        echo "  5) 存储设备测试"
        echo "  6) 外设与接口测试"
        echo "  7) 系统监控 (温度/频率/负载)"
        echo "  8) 退出"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        read -p "请输入选项 (1-8): " main_choice

        case $main_choice in
            1) run_script "$SCRIPT_DIR/firmware_check.sh" ;;
            2) run_script "$SCRIPT_DIR/npu/npu_test_suite.py" ;;
            3) run_graphical_script "$SCRIPT_DIR/csi/csi.sh" ;;   # 改用图形环境函数
            4) display_menu ;;
            5) storage_menu ;;
            6) peripheral_menu ;;
            7) run_script "$SCRIPT_DIR/rk_monitor.py" "-v" ;;
            8) echo -e "${INFO} 退出测试工具。"; exit 0 ;;
            *) echo -e "${ERR} 无效选项，请重新输入"; sleep 1 ;;
        esac
    done
}

# ---------- 入口 ----------
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${ERR} 请使用 sudo 运行此脚本"
    exit 1
fi

main_menu
