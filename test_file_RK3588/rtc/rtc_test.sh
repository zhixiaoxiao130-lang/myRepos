#!/bin/bash
# RTC 功能测试脚本（支持无 hwclock、自动处理时区差异）
# 用法: sudo ./rtc_test.sh

set -euo pipefail

LOG_DIR="./log"
LOG_FILE="${LOG_DIR}/rtc_test.log"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
INFO="${CYAN}[i]${NC}"; OK="${GREEN}[✓]${NC}"; ERR="${RED}[✗]${NC}"; WARN="${YELLOW}[!]${NC}"

HWCLOCK_PATH=""
USE_SYSFS=0

init_log() {
    mkdir -p "$(dirname "$LOG_FILE")"
    > "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
    echo "====== RTC 测试开始 $(date) ======"
}

find_hwclock() {
    if command -v hwclock &>/dev/null; then
        HWCLOCK_PATH=$(command -v hwclock)
        return 0
    fi
    for candidate in /usr/sbin/hwclock /sbin/hwclock /usr/bin/hwclock /bin/hwclock; do
        if [ -x "$candidate" ]; then
            HWCLOCK_PATH="$candidate"
            return 0
        fi
    done
    return 1
}

check_cmd() {
    if find_hwclock; then
        echo -e "${OK} 找到 hwclock: ${HWCLOCK_PATH}"
    else
        echo -e "${WARN} 未找到 hwclock 命令，将使用 sysfs 直接读取硬件时间"
        USE_SYSFS=1
    fi
}

check_device() {
    if [ -e /dev/rtc0 ]; then
        echo -e "${OK} RTC 设备 /dev/rtc0 存在"
    else
        echo -e "${ERR} RTC 设备 /dev/rtc0 不存在"
        echo "可能未加载 RTC 内核模块或硬件未连接。"
        echo "请尝试加载常见 RTC 模块，例如:"
        echo "  ${BOLD}sudo modprobe rtc-ds1307${NC}   (DS1307)"
        echo "  ${BOLD}sudo modprobe rtc-pcf8563${NC}  (PCF8563)"
        echo "  ${BOLD}sudo modprobe rtc-hym8563${NC}  (HYM8563)"
        echo "若仍无设备，请检查设备树配置或 RTC 硬件连接。"
        echo "可执行 ${BOLD}dmesg | grep rtc${NC} 查看内核日志。"
        exit 1
    fi
}

# 读取硬件时间（总是返回 UTC 时间）
read_hwclock() {
    if [ "$USE_SYSFS" -eq 0 ] && [ -n "$HWCLOCK_PATH" ]; then
        sudo "$HWCLOCK_PATH" -r 2>/dev/null
    else
        if [ -f /sys/class/rtc/rtc0/time ]; then
            cat /sys/class/rtc/rtc0/time 2>/dev/null
        else
            echo ""
        fi
    fi
}

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

sync_test() {
    echo -e "\n${BOLD}${CYAN}▌ 系统时间与硬件时间同步验证${NC}"
    echo -e "${CYAN}─────────────────────────────────────────────────${NC}"

    # 获取系统 UTC 时间
    local sys_time_utc=$(date -u "+%Y-%m-%d %H:%M:%S")
    # 硬件时间（RTC）在 Linux 中默认也是 UTC
    local hw_time=$(read_hwclock)

    if [ -z "$hw_time" ]; then
        echo -e "${ERR} 无法读取硬件时间"
        return
    fi

    echo -e "  系统时间(UTC): ${sys_time_utc}"
    echo -e "  硬件时间(UTC): ${hw_time}"

    local sys_epoch=$(date -d "$sys_time_utc" +%s 2>/dev/null || echo 0)
    local hw_epoch=$(date -d "$hw_time" +%s 2>/dev/null || echo 0)

    if [ "$sys_epoch" -gt 0 ] && [ "$hw_epoch" -gt 0 ]; then
        local diff=$((sys_epoch - hw_epoch))
        local abs_diff=${diff#-}

        if [ "$abs_diff" -le 5 ]; then
            echo -e "${OK} 系统时间与硬件时间基本一致 (差值 ${abs_diff} 秒)"
        else
            echo -e "${WARN} 系统时间(UTC)与硬件时间(UTC)相差 ${abs_diff} 秒"
            # 检测是否可能为时区配置问题
            if [ $((abs_diff % 3600)) -eq 0 ]; then
                local hours=$((abs_diff / 3600))
                echo -e "${WARN} 差值恰好为 ${hours} 小时，可能是时区配置不一致导致"
                echo "  (例如硬件时钟使用本地时间，而系统预期为 UTC，或相反)"
                echo ""
                echo "  当前 RTC 时间标准可通过以下命令查看:"
                echo "    ${BOLD}timedatectl | grep 'RTC in local'${NC}"
                echo ""
                echo "  若要将当前系统时间写入硬件时钟并采用 UTC 标准:"
                echo "    ${BOLD}sudo hwclock --systohc --utc${NC}"
                echo "  若硬件时钟需使用本地时间:"
                echo "    ${BOLD}sudo hwclock --systohc --localtime${NC}"
                echo "  若没有 hwclock 命令，可手动修改 /etc/adjtime 后重启"
            fi
        fi
    else
        echo -e "${WARN} 无法计算时间差，请手动检查"
    fi
}

main() {
    [ "$(id -u)" -ne 0 ] && { echo -e "${ERR} 请使用 sudo 运行此脚本"; exit 1; }
    init_log
    check_cmd
    check_device

    local hw=$(read_hwclock)
    if [ -n "$hw" ]; then
        echo -e "${OK} 当前硬件时间(UTC): ${GREEN}${hw}${NC}"
    fi

    sync_test
    poweroff_test_prompt
    echo -e "\n${BOLD}${GREEN}RTC 测试完成。${NC}"
}

main "$@"
