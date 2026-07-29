#!/bin/bash
# ======================================================
# RK3588 GPU 压力测试脚本 (glmark2)  -  本地运行版
# 功能：持续运行 glmark2 满负载渲染，显示 GPU 负载与温度。
# 要求：必须在本地图形桌面环境执行，不可通过 SSH 运行。
# 用法：sudo ./stress_gpu.sh
# ======================================================

set -euo pipefail

# ---------- 颜色 ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ---------- 本地终端检测 ----------
check_local_session() {
    # 检查常见的 SSH 环境变量
    if [[ -n "${SSH_TTY:-}" || -n "${SSH_CLIENT:-}" || -n "${SSH_CONNECTION:-}" ]]; then
        echo -e "${RED}╔══════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║  ❌ 错误：检测到 SSH 远程连接！                     ║${NC}"
        echo -e "${RED}║  此测试需要直接在设备本地运行，原因：               ║${NC}"
        echo -e "${RED}║  · GPU 渲染必须依赖本地图形桌面环境 (X11/Wayland)  ║${NC}"
        echo -e "${RED}║  · SSH 会话无 DISPLAY 变量，GPU 无法产生负载        ║${NC}"
        echo -e "${RED}║  请登录设备本地桌面，打开终端后执行本脚本。          ║${NC}"
        echo -e "${RED}╚══════════════════════════════════════════════════════╝${NC}"
        exit 1
    fi

    # 额外检查 DISPLAY 或 WAYLAND_DISPLAY 是否存在
    if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
        echo -e "${YELLOW}⚠️  警告：未检测到 DISPLAY 或 WAYLAND_DISPLAY 变量。${NC}"
        echo -e "${YELLOW}  如果这是本地桌面终端，请确认图形环境已启动。${NC}"
        echo -e "${YELLOW}  继续执行可能导致 GPU 无负载或 glmark2 失败。${NC}"
        read -p "是否仍然尝试运行？(y/N): " yn
        if [[ ! "$yn" =~ ^[Yy]$ ]]; then
            exit 0
        fi
    fi
}

# ---------- 环境检查 ----------
check_environment() {
    echo -e "${CYAN}===== 环境检查 =====${NC}"

    # root 权限
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}❌ 需要 root 权限以设置 GPU 频率。${NC}"
        echo "请使用 sudo 重新运行："
        echo "  sudo $0"
        exit 1
    fi
    echo -e "${GREEN}✅ 已获取 root 权限${NC}"

    # glmark2 可用性
    if ! command -v glmark2 &>/dev/null; then
        echo -e "${RED}❌ glmark2 未安装。${NC}"
        echo "请安装：sudo apt install -y glmark2"
        exit 1
    fi
    echo -e "${GREEN}✅ glmark2 可用${NC}"

    # GPU 设备节点探测
    GPU_LOAD_NODE=""
    for node in /sys/class/devfreq/fb000000.gpu-panthor/load /sys/class/devfreq/fb000000.gpu/load; do
        if [ -f "$node" ]; then
            GPU_LOAD_NODE="$node"
            break
        fi
    done
    if [ -z "$GPU_LOAD_NODE" ]; then
        echo -e "${RED}❌ GPU 负载节点不存在。${NC}"
        echo "请确认 GPU 驱动已加载（桌面版固件），或尝试 'sudo modprobe panthor'。"
        exit 1
    fi
    echo -e "${GREEN}✅ GPU 负载节点: $GPU_LOAD_NODE${NC}"

    # Governor 控制路径
    GPU_GOVERNOR="$(dirname "$GPU_LOAD_NODE")/governor"
    if [ ! -f "$GPU_GOVERNOR" ]; then
        echo -e "${YELLOW}⚠️  GPU governor 文件未找到，将跳过性能模式设置。${NC}"
        GPU_GOVERNOR=""
    fi
}

# ---------- 清理与恢复 ----------
cleanup() {
    echo -e "\n${YELLOW}[!] 正在停止 GPU 压测...${NC}"
    if [ -n "${GL_PID:-}" ]; then
        kill "$GL_PID" 2>/dev/null || true
        sleep 0.3
        kill -9 "$GL_PID" 2>/dev/null || true
    fi
    # 杀掉所有残留 glmark2 进程
    pkill -9 -f "glmark2" 2>/dev/null || true

    # 恢复 GPU 调度器
    if [ -n "${GPU_GOVERNOR:-}" ] && [ -f "$GPU_GOVERNOR" ]; then
        echo "simple_ondemand" | tee "$GPU_GOVERNOR" >/dev/null 2>&1 || true
    fi

    stty sane 2>/dev/null
    echo -e "${GREEN}✅ GPU 负载已恢复，清理完成。${NC}"
}

# ---------- 主程序 ----------
main() {
    check_local_session        # 第1步：必须本地
    check_environment

    # 设置性能模式
    if [ -n "${GPU_GOVERNOR:-}" ] && [ -f "$GPU_GOVERNOR" ]; then
        echo "performance" | tee "$GPU_GOVERNOR" >/dev/null
        echo -e "${GREEN}⚡ GPU 已切换至 performance 模式${NC}"
    fi

    echo -e "${YELLOW}🔥 启动 GPU 渲染满载压测 (glmark2 --run-forever)...${NC}"
    glmark2 --run-forever >/dev/null 2>&1 &
    GL_PID=$!
    echo -e "${GREEN}  glmark2 压测进程 PID: $GL_PID${NC}"

    trap cleanup INT TERM EXIT
    sleep 2

    # 打印表头
    printf "\n${CYAN}%-14s | %-14s${NC}\n" "GPU 负载 (%)" "核心温度"
    printf "${CYAN}%-14s-+-%-14s${NC}\n" "--------------" "--------------"

    # 监控循环
    while true; do
        LOAD=$(cat "$GPU_LOAD_NODE" 2>/dev/null | awk -F'@' '{print $1}')
        TEMP_RAW=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
        TEMP=$(awk "BEGIN {printf \"%.1f°C\", $TEMP_RAW/1000}")
        printf "%-14s | %-14s\n" "${LOAD}%" "$TEMP"
        sleep 1
    done
}

main "$@"
