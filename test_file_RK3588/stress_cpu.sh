#!/bin/bash
# ======================================================
# CPU 压力测试脚本 (stress-ng)
# 功能：对 CPU 进行满载压力测试，测试时长可选
# 用法：sudo ./stress_cpu.sh [测试秒数，默认 60]
# ======================================================

set -euo pipefail

# ---------- 颜色 ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ---------- 参数 ----------
TEST_DURATION="${1:-60}"   # 默认 60 秒

# ---------- 环境检查 ----------
check_environment() {
    if ! command -v stress-ng &>/dev/null; then
        echo -e "${RED}${BOLD}✗ 未找到 stress-ng 命令，请先安装。${NC}"
        echo -e "${YELLOW}安装方法：${NC}"
        echo "  sudo apt update && sudo apt install -y stress-ng"
        echo ""
        echo "或通过 pip 安装："
        echo "  pip install stress-ng"
        exit 1
    fi

    if [ "$EUID" -ne 0 ]; then
        echo -e "${YELLOW}⚠️  建议使用 root 权限运行，以获得更稳定的压力测试效果。${NC}"
        echo "请使用 sudo 重新运行："
        echo "  sudo $0 $@"
        exit 1
    fi
    echo -e "${GREEN}✅ 环境检查通过${NC}"
}

# ---------- 清理函数 ----------
cleanup() {
    echo -e "\n${YELLOW}[!] 正在停止 CPU 压力测试...${NC}"
    # 杀掉所有 stress-ng 进程
    pkill -9 -f stress-ng 2>/dev/null || true
    echo -e "${GREEN}✅ 已停止所有 stress-ng 进程${NC}"
}
trap cleanup INT TERM EXIT

# ---------- 主程序 ----------
main() {
    check_environment

    echo -e "${CYAN}=====================================${NC}"
    echo -e "${BOLD}  CPU 压力测试 (stress-ng)${NC}"
    echo -e "${CYAN}=====================================${NC}"
    echo -e "  测试时长: ${TEST_DURATION} 秒"
    echo -e "  压力方法: matrixprod (浮点矩阵乘法)"
    echo -e "  使用核心: 8 (全部 CPU)"
    echo -e "${CYAN}=====================================${NC}"
    echo ""

    # 启动 stress-ng 并实时显示进度
    stress-ng --cpu 8 --cpu-method matrixprod --timeout "${TEST_DURATION}s" --metrics-brief &
    STRESS_PID=$!

    # 等待完成或手动中断
    wait $STRESS_PID || true
}

main "$@"
