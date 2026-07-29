#!/bin/bash
# 风扇测试脚本（修复重复显示 + 稳定交互）
# 用法: sudo ./fan_test.sh

set -euo pipefail

# ---------- 颜色 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
INFO="${CYAN}[i]${NC}"; OK="${GREEN}[✓]${NC}"; ERR="${RED}[✗]${NC}"; WARN="${YELLOW}[!]${NC}"

# ---------- 寻找风扇设备 ----------
find_fan_path() {
    for dir in /sys/class/hwmon/hwmon*; do
        if [ -f "$dir/fan1_input" ]; then
            echo "$dir"
            return
        fi
    done
    echo -e "${WARN} 自动搜索未找到风扇设备"
    echo "系统中存在的 hwmon 设备:"
    for dir in /sys/class/hwmon/hwmon*; do
        [ -d "$dir" ] && echo "  ${dir##*/} ($(cat "$dir/name" 2>/dev/null || echo 未知))"
    done
    read -p "请输入正确的 hwmon 路径 (如 /sys/class/hwmon/hwmon10): " custom_path || true
    if [ -d "$custom_path" ] && [ -f "$custom_path/fan1_input" ]; then
        echo "$custom_path"
    else
        echo ""
    fi
}

FAN_PATH=$(find_fan_path)
if [ -z "$FAN_PATH" ]; then
    echo -e "${ERR} 未找到有效的风扇设备路径，退出。"
    exit 1
fi
echo -e "${OK} 风扇设备路径: ${FAN_PATH}"

# ---------- 工具函数（永远返回成功）----------
read_sysfs() {
    cat "$1" 2>/dev/null || { echo "N/A"; return 0; }
}
write_sysfs() {
    [ -f "$1" ] && echo "$2" | sudo tee "$1" > /dev/null 2>&1 || return 0
}

show_status() {
    echo -e "\n${BOLD}${CYAN}▌ 当前风扇状态${NC}"
    echo -e "${CYAN}─────────────────────────────────────────────────${NC}"
    echo -e "  转速: ${GREEN}$(read_sysfs ${FAN_PATH}/fan1_input) RPM${NC}"
    echo -e "  PWM 值: ${YELLOW}$(read_sysfs ${FAN_PATH}/pwm1)${NC} (0-255)"
    echo -e "  PWM 模式: $(read_sysfs ${FAN_PATH}/pwm1_mode) (0: 手动)"
    echo -e "${CYAN}─────────────────────────────────────────────────${NC}"
}

set_pwm_test() {
    local pwm_mode_file="${FAN_PATH}/pwm1_mode"
    local orig_mode=$(read_sysfs "$pwm_mode_file")
    write_sysfs "$pwm_mode_file" 0
    sleep 1

    while true; do
        show_status
        read -p "请输入 PWM 值 (0-255)，或输入 q 退出: " pwm_val || break
        if [ "$pwm_val" = "q" ] || [ "$pwm_val" = "Q" ]; then
            break
        fi
        if ! [[ "$pwm_val" =~ ^[0-9]+$ ]] || [ "$pwm_val" -lt 0 ] || [ "$pwm_val" -gt 255 ]; then
            echo -e "${ERR} 请输入 0-255 之间的数字"
            continue
        fi
        write_sysfs "${FAN_PATH}/pwm1" "$pwm_val"
        sleep 2
        echo -e "${OK} PWM 已设置为 ${pwm_val}"
    done

    if [ -n "$orig_mode" ]; then
        write_sysfs "$pwm_mode_file" "$orig_mode"
        echo -e "${INFO} PWM 模式已恢复为 ${orig_mode}"
    fi
}

# ---------- 主流程 ----------
main() {
    [ "$(id -u)" -ne 0 ] && { echo -e "${ERR} 请使用 sudo 运行此脚本"; exit 1; }
    # 直接进入 PWM 测试，不再额外调用 show_status（避免重复）
    set_pwm_test
    echo -e "\n${BOLD}${GREEN}风扇测试完成。${NC}"
}

main "$@"
