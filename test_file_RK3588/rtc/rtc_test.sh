#!/bin/bash
# RTC 功能测试脚本（优化断电测试提示）
# 用法: sudo ./rtc_test.sh

set -euo pipefail

# ---------- 配置 ----------
LOG_DIR="./log"
LOG_FILE="${LOG_DIR}/rtc_test.log"

# ---------- 颜色 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
INFO="${CYAN}[i]${NC}"; OK="${GREEN}[✓]${NC}"; ERR="${RED}[✗]${NC}"; WARN="${YELLOW}[!]${NC}"

init_log() {
    mkdir -p "$(dirname "$LOG_FILE")"
    > "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
    echo "====== RTC 测试开始 $(date) ======"
}

check_cmd() {
    if ! command -v hwclock &>/dev/null; then
        echo -e "${ERR} 缺少 hwclock 命令，请安装 util-linux"
        exit 1
    fi
}

check_device() {
    if [ -e /dev/rtc0 ]; then
        echo -e "${OK} RTC 设备 /dev/rtc0 存在"
    else
        echo -e "${ERR} RTC 设备 /dev/rtc0 不存在"
        exit 1
    fi
}

read_hwclock() {
    local hw_time=$(sudo hwclock -r 2>/dev/null)
    if [ -n "$hw_time" ]; then
        echo "$hw_time"
    else
        echo ""
    fi
}

# ---------- 断电保持测试（仅提示）----------
poweroff_test_prompt() {
    echo -e "\n${BOLD}${CYAN}▌ 断电保持测试${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${INFO} 请按以下步骤验证 RTC 断电保持功能："
    echo ""
    echo -e "  1. 记录当前硬件时间（上方已显示）"
    echo ""
    echo -e "  2. ${BOLD}完全断开设备电源${NC}（拔掉所有电源适配器，保留 RTC 电池）"
    echo ""
    echo -e "  3. 等待 2~3 分钟后重新上电启动"
    echo ""
    echo -e "  4. 再次运行本脚本 ${YELLOW}sudo ./rtc_test.sh${NC}"
    echo -e "     或执行命令 ${YELLOW}sudo hwclock -r${NC} 查看硬件时间"
    echo ""
    echo -e "  5. 对比两次时间，如果时间在走（差值接近断电时长），则 RTC 正常。"
}

# ---------- 系统时间对比 ----------
sync_test() {
    echo -e "\n${BOLD}${CYAN}▌ 系统时间与硬件时间同步验证${NC}"
    echo -e "${CYAN}─────────────────────────────────────────────────${NC}"
    local sys_time=$(date "+%Y-%m-%d %H:%M:%S")
    local hw_time=$(read_hwclock)
    if [ -z "$hw_time" ]; then
        echo -e "${ERR} 无法读取硬件时间"
        return
    fi
    echo -e "  系统时间: ${sys_time}"
    echo -e "  硬件时间: ${hw_time}"

    local sys_epoch=$(date -d "$sys_time" +%s 2>/dev/null || echo 0)
    local hw_epoch=$(date -d "$hw_time" +%s 2>/dev/null || echo 0)
    if [ "$sys_epoch" -gt 0 ] && [ "$hw_epoch" -gt 0 ]; then
        local diff=$((sys_epoch - hw_epoch))
        diff=${diff#-}
        if [ "$diff" -le 5 ]; then
            echo -e "${OK} 系统时间与硬件时间基本一致 (差值 ${diff} 秒)"
        else
            echo -e "${WARN} 系统时间与硬件时间相差较大 (差值 ${diff} 秒)，可执行 sudo hwclock --systohc 同步"
        fi
    else
        echo -e "${WARN} 无法计算时间差，请手动检查"
    fi
}

# ---------- 主流程 ----------
main() {
    [ "$(id -u)" -ne 0 ] && { echo -e "${ERR} 请使用 sudo 运行此脚本"; exit 1; }
    init_log
    check_cmd
    check_device

    # 显示当前硬件时间
    local hw=$(read_hwclock)
    if [ -n "$hw" ]; then
        echo -e "${OK} 当前硬件时间: ${GREEN}${hw}${NC}"
    fi

    sync_test
    poweroff_test_prompt
    echo -e "\n${BOLD}${GREEN}RTC 测试完成。${NC}"
}

main "$@"
