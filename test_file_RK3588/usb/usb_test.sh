#!/bin/bash
# USB 设备测试脚本（完整版）
# 功能：版本检测、读写性能、重新挂载、多接口热插拔、长时间稳定性
# 用法: sudo ./usb_test.sh

set -euo pipefail

# ---------- 配置 ----------
LOG_DIR="./log"
LOG_FILE_PERF="${LOG_DIR}/usb_perf.log"
LOG_FILE_REMOUNT="${LOG_DIR}/usb_remount.log"
LOG_FILE_HOTPLUG="${LOG_DIR}/usb_hotplug.log"
LOG_FILE_ENDURANCE="${LOG_DIR}/usb_endurance.log"
TEST_SIZE_GB=5
BLOCK_SIZE="1M"
FILE_PREFIX="usb_testfile"
HOTPLUG_COUNT=5
USB_PORTS=("USB 3.0 端口1" "USB 3.0 端口2" "USB 3.0 端口3" "USB 3.0 端口4")

# ---------- 颜色 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
INFO="${CYAN}[i]${NC}"; OK="${GREEN}[✓]${NC}"; ERR="${RED}[✗]${NC}"; WARN="${YELLOW}[!]${NC}"

check_deps() {
    local missing=""
    for cmd in mount umount lsblk dd awk lsusb udevadm; do
        command -v "$cmd" &>/dev/null || missing="$missing $cmd"
    done
    if [ -n "$missing" ]; then
        echo -e "${ERR} 缺少依赖: $missing"
        echo -e "${INFO} 请安装: sudo apt update && sudo apt install util-linux usbutils udev"
        exit 1
    fi
}

# ---------- 日志初始化（覆盖） ----------
init_log() {
    local log_file="$1"
    mkdir -p "$(dirname "$log_file")"
    > "$log_file"
    exec > >(tee -a "$log_file") 2>&1
    echo "====== USB 测试开始 $(date) ======"
}

# ---------- USB 版本检测 ----------
get_usb_version() {
    local dev="$1"
    local vendor=""
    local product=""
    vendor=$(udevadm info --query=property --name="/dev/$dev" 2>/dev/null | grep -E '^ID_VENDOR_ID=' | cut -d'=' -f2)
    product=$(udevadm info --query=property --name="/dev/$dev" 2>/dev/null | grep -E '^ID_MODEL_ID=' | cut -d'=' -f2)

    if [ -n "$vendor" ] && [ -n "$product" ]; then
        local bcdUSB=$(lsusb -d "$vendor:$product" -v 2>/dev/null | grep -i "bcdUSB" | head -1 | awk '{print $2}')
        case "$bcdUSB" in
            2.00|2.10) echo "USB 2.0" ;;
            3.00|3.10|3.20) echo "USB 3.0+" ;;
            *) echo "USB" ;;
        esac
    else
        echo "USB"
    fi
}

get_mount_info() {
    local disk="$1"
    local part=""
    local parts=$(lsblk -ln -o NAME,TYPE "$disk" 2>/dev/null | awk '$2=="part"{print $1}')
    if [ -n "$parts" ]; then
        part="/dev/$(echo "$parts" | head -1)"
    else
        part="$disk"
    fi
    if [ -b "$part" ] && findmnt "$part" &>/dev/null; then
        local mnt=$(findmnt -nro TARGET "$part")
        echo "→ 已挂载到 ${GREEN}${mnt}${NC}"
    else
        echo "→ 未挂载"
    fi
}

list_usb_devices() {
    echo -e "\n${BOLD}${CYAN}▌ 检测到以下 USB 存储设备${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    USB_DEVS=()
    local counter=1
    for disk in $(lsblk -d -n -o NAME,TRAN | grep usb | awk '{print $1}'); do
        local dev="/dev/$disk"
        [ ! -b "$dev" ] && continue
        local size=$(lsblk -d -n -o SIZE "$dev" 2>/dev/null || echo "?")
        local model=$(lsblk -d -n -o MODEL "$dev" 2>/dev/null || echo "未知")
        local version=$(get_usb_version "$disk")
        local mount_info=$(get_mount_info "$dev")
        
        echo -e "  ${GREEN}[${counter}]${NC} ${BOLD}${dev}${NC}"
        echo -e "      容量: ${YELLOW}${size}${NC} | 型号: ${model} | 版本: ${GREEN}${version}${NC}"
        echo -e "      状态: ${mount_info}"
        echo ""
        USB_DEVS+=("$disk")
        counter=$((counter+1))
    done
    if [ ${#USB_DEVS[@]} -eq 0 ]; then
        echo -e "${WARN} 未发现 USB 存储设备。"
        exit 0
    fi
}

select_device() {
    local count=${#USB_DEVS[@]}
    while true; do
        read -p "请选择要测试的设备编号 (1-$count): " idx
        if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le $count ]; then
            DEV_NAME="${USB_DEVS[$((idx-1))]}"
            DEV_PATH="/dev/$DEV_NAME"
            echo -e "${OK} 已选择: ${GREEN}${DEV_PATH}${NC}"
            return
        fi
        echo -e "${ERR} 无效选择，请重试"
    done
}

mount_partition() {
    local part=""
    local parts=$(lsblk -ln -o NAME,TYPE "$DEV_PATH" 2>/dev/null | awk '$2=="part"{print $1}')
    if [ -n "$parts" ]; then
        part="/dev/$(echo "$parts" | head -1)"
    else
        if blkid "$DEV_PATH" &>/dev/null; then
            part="$DEV_PATH"
        else
            echo -e "${ERR} 设备 $DEV_PATH 无分区且无文件系统，无法挂载。"
            return 1
        fi
    fi
    PART_PATH="$part"

    if findmnt "$PART_PATH" &>/dev/null; then
        local existing_mount=$(findmnt -nro TARGET "$PART_PATH")
        echo -e "${WARN} $PART_PATH 当前已挂载到 ${YELLOW}${existing_mount}${NC}，将尝试卸载..."
        if ! umount "$PART_PATH"; then
            echo -e "${ERR} 卸载失败，请手动卸载后重试。"
            return 1
        fi
        echo -e "${OK} 卸载成功"
    fi

    MOUNT_POINT="/mnt/usb_test_$$"
    mkdir -p "$MOUNT_POINT"
    if mount "$PART_PATH" "$MOUNT_POINT"; then
        echo -e "\n${BOLD}${GREEN}▌ 分区挂载成功${NC}"
        echo -e "${CYAN}─────────────────────────────────────────────────${NC}"
        echo -e "  ${BOLD}设备:${NC} ${GREEN}$PART_PATH${NC}"
        echo -e "  ${BOLD}挂载点:${NC} ${YELLOW}$MOUNT_POINT${NC}"
        local fs_type=$(findmnt -nro FSTYPE "$MOUNT_POINT")
        echo -e "  ${BOLD}文件系统:${NC} ${fs_type}"
        echo -e "  ${BOLD}可用空间:${NC} $(df -h "$MOUNT_POINT" | awk 'NR==2{print $4}')"
        echo -e "${CYAN}─────────────────────────────────────────────────${NC}"
        return 0
    else
        echo -e "${ERR} 挂载失败"
        rmdir "$MOUNT_POINT" 2>/dev/null
        return 1
    fi
}

get_fs_type() {
    findmnt -nro FSTYPE "$MOUNT_POINT" 2>/dev/null || echo "unknown"
}

# ---------- 顺序读写性能测试 ----------
run_dd_test() {
    init_log "$LOG_FILE_PERF"
    echo -e "\n${BOLD}${CYAN}▌ 顺序读写性能测试 (dd, 直接 I/O, ${TEST_SIZE_GB}G)${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    local fs_type=$(get_fs_type)
    local single_size_gb=5
    local file_count=1
    if [ "$fs_type" == "vfat" ]; then
        single_size_gb=1
        file_count=$TEST_SIZE_GB
        echo -e "${INFO} 检测到 ${YELLOW}VFAT${NC} 文件系统，将使用 ${file_count} 个 ${single_size_gb}G 文件进行测试。"
    fi

    local need_bytes=$((TEST_SIZE_GB * 1073741824))
    local avail=$(df -B1 --output=avail "$MOUNT_POINT" | tail -1)
    if [ "$avail" -lt "$need_bytes" ]; then
        echo -e "${ERR} 空间不足，需要至少 ${TEST_SIZE_GB}G 可用。"
        return 1
    fi

    echo -e "\n${BOLD}[写入测试]${NC}"
    local total_write_time=0
    local total_write_bytes=0
    for i in $(seq 1 $file_count); do
        local f="${MOUNT_POINT}/${FILE_PREFIX}_${i}"
        rm -f "$f"
        local t0=$(date +%s.%N)
        dd if=/dev/zero of="$f" bs=1M count=1024 oflag=direct conv=fdatasync status=progress 2>&1
        local t1=$(date +%s.%N)
        local elapsed=$(echo "$t1 - $t0" | bc)
        total_write_time=$(echo "$total_write_time + $elapsed" | bc)
        total_write_bytes=$((total_write_bytes + 1073741824))
    done
    sync

    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true

    echo -e "\n${BOLD}[读取测试]${NC}"
    local total_read_time=0
    local total_read_bytes=0
    for i in $(seq 1 $file_count); do
        local f="${MOUNT_POINT}/${FILE_PREFIX}_${i}"
        local t0=$(date +%s.%N)
        dd if="$f" of=/dev/null bs=1M iflag=direct status=progress 2>&1
        local t1=$(date +%s.%N)
        local elapsed=$(echo "$t1 - $t0" | bc)
        total_read_time=$(echo "$total_read_time + $elapsed" | bc)
        total_read_bytes=$((total_read_bytes + 1073741824))
    done
    sync

    local write_speed=$(awk "BEGIN {printf \"%.2f\", $total_write_bytes / $total_write_time / 1048576}")
    local read_speed=$(awk "BEGIN {printf \"%.2f\", $total_read_bytes / $total_read_time / 1048576}")

    echo -e "\n${BOLD}${GREEN}▌ 性能结果${NC}"
    echo -e "${CYAN}─────────────────────────────────────────────────${NC}"
    echo -e "  ${BOLD}写入速度:${NC} ${GREEN}${write_speed} MB/s${NC}"
    echo -e "  ${BOLD}读取速度:${NC} ${GREEN}${read_speed} MB/s${NC}"
    echo -e "${CYAN}─────────────────────────────────────────────────${NC}"

    rm -f ${MOUNT_POINT}/${FILE_PREFIX}_*
    return 0
}

# ---------- 重新挂载验证 ----------
verify_remount() {
    init_log "$LOG_FILE_REMOUNT"
    echo -e "\n${BOLD}${CYAN}▌ 重新挂载验证${NC}"
    echo "  卸载 $MOUNT_POINT ..."
    if umount "$MOUNT_POINT"; then
        echo -e "  ${OK} 卸载成功"
    else
        echo -e "  ${ERR} 卸载失败"
        return 1
    fi
    echo "  重新挂载 $PART_PATH 到 $MOUNT_POINT ..."
    if mount "$PART_PATH" "$MOUNT_POINT"; then
        echo -e "  ${OK} 重新挂载成功，分区完好。"
        return 0
    else
        echo -e "  ${ERR} 重新挂载失败"
        return 1
    fi
}

ask_umount() {
    echo -e "\n测试完成，分区仍挂载在 ${GREEN}${MOUNT_POINT}${NC}。"
    read -p "是否卸载？(y/N): " umount_choice
    if [[ "$umount_choice" =~ ^[yY]$ ]]; then
        umount "$MOUNT_POINT" && echo -e "${OK} 已卸载" || echo -e "${ERR} 卸载失败"
        rmdir "$MOUNT_POINT" 2>/dev/null
    else
        echo -e "${INFO} 保持挂载，可稍后手动执行: ${YELLOW}sudo umount $MOUNT_POINT${NC}"
    fi
}

# ---------- 长时间写入稳定性测试（写后自动删除）----------
run_endurance_test() {
    init_log "$LOG_FILE_ENDURANCE"
    echo -e "\n${BOLD}${CYAN}▌ 长时间写入稳定性测试${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${INFO} 将循环写入 1GiB 文件，每个文件写完后 ${YELLOW}自动删除${NC}，不占用磁盘空间"
    echo -e "${INFO} 写入过程中会显示每个文件的速度，最终统计总写入量和平均速度"
    echo -e "${INFO} 可按 ${YELLOW}Ctrl+C${NC} 随时停止"
    echo ""

    local count=0
    local total_write_bytes=0
    local total_write_time=0
    local start_time=$(date +%s)

    trap 'echo -e "\n${WARN} 用户中断，正在停止写入..."; end_endurance_test; return' SIGINT

    while true; do
        local avail=$(df -B1 --output=avail "$MOUNT_POINT" | tail -1)
        if [ "$avail" -lt 1073741824 ]; then
            echo -e "${WARN} 可用空间不足 1GiB，停止写入。"
            break
        fi

        local f="${MOUNT_POINT}/endurance_test_${count}.tmp"
        rm -f "$f"

        local t0=$(date +%s.%N)
        dd if=/dev/zero of="$f" bs=1M count=1024 oflag=direct conv=fdatasync status=progress 2>&1
        local t1=$(date +%s.%N)
        local elapsed=$(echo "$t1 - $t0" | bc)
        total_write_time=$(echo "$total_write_time + $elapsed" | bc)
        total_write_bytes=$((total_write_bytes + 1073741824))
        count=$((count + 1))

        rm -f "$f"

        echo -e "  已写入 $count 个文件 (累计 $((total_write_bytes / 1073741824)) GiB)"
    done

    end_endurance_test
}

end_endurance_test() {
    local end_time=$(date +%s)
    local total_duration=$((end_time - start_time))
    local avg_speed=0
    if [ "$total_write_time" != "0" ]; then
        avg_speed=$(awk "BEGIN {printf \"%.2f\", $total_write_bytes / $total_write_time / 1048576}")
    fi

    echo ""
    echo -e "${BOLD}${GREEN}▌ 稳定性测试结果${NC}"
    echo -e "${CYAN}─────────────────────────────────────────────────${NC}"
    echo -e "  写入文件数: ${count}"
    echo -e "  总写入量: ${GREEN}$((total_write_bytes / 1073741824)) GiB${NC}"
    echo -e "  总耗时: ${total_duration} 秒"
    echo -e "  平均写入速度: ${GREEN}${avg_speed} MB/s${NC}"
    echo -e "${CYAN}─────────────────────────────────────────────────${NC}"

    rm -f ${MOUNT_POINT}/endurance_test_*.tmp
    trap - SIGINT
}

# ---------- 热插拔测试（多接口）----------
test_hotplug() {
    init_log "$LOG_FILE_HOTPLUG"
    echo -e "\n${BOLD}${CYAN}▌ 多接口热插拔测试${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${INFO} 将依次测试以下 USB 3.0 接口："
    for port in "${USB_PORTS[@]}"; do
        echo -e "   - ${port}"
    done
    echo -e "${INFO} 每个接口将执行 ${HOTPLUG_COUNT} 次拔插循环。"
    echo -e "${INFO} 测试过程中可随时按 ${YELLOW}Ctrl+C${NC} 中断当前接口，跳到下一个接口。"
    echo ""

    local total_success=0
    local total_fail=0

    for port_index in "${!USB_PORTS[@]}"; do
        local port_name="${USB_PORTS[$port_index]}"
        echo -e "\n${BOLD}${GREEN}>>> 开始测试 ${port_name}${NC}"
        read -p "    请将 U 盘插入 ${port_name}，然后按 Enter 继续（按 q 跳过该端口）：" skip
        if [[ "$skip" == "q" ]]; then
            echo -e "${WARN} 跳过 ${port_name}"
            continue
        fi

        echo -n "    等待设备识别..."
        local timeout=15
        while [ $timeout -gt 0 ]; do
            if [ -b "$DEV_PATH" ]; then
                echo -e " ${OK} ${DEV_PATH} 已识别"
                break
            fi
            sleep 1
            timeout=$((timeout - 1))
        done
        if [ ! -b "$DEV_PATH" ]; then
            echo -e " ${ERR} 设备未出现，跳过此端口"
            ((total_fail+=HOTPLUG_COUNT))
            continue
        fi

        local port_success=0
        local port_fail=0
        set +e
        for i in $(seq 1 $HOTPLUG_COUNT); do
            echo -e "\n  ${BOLD}── ${port_name} 第 ${i}/${HOTPLUG_COUNT} 次 ──${NC}"
            
            echo -e "  ${YELLOW}>>> 请拔出 U 盘，然后按 Enter 继续...${NC}"
            read
            
            echo -n "    等待设备移除..."
            timeout=15
            while [ -b "$DEV_PATH" ] && [ $timeout -gt 0 ]; do
                sleep 1
                timeout=$((timeout - 1))
            done
            if [ -b "$DEV_PATH" ]; then
                echo -e " ${ERR} 设备未移除，跳过本次"
                ((port_fail++))
                continue
            fi
            echo -e " ${OK} 已移除"

            echo -e "  ${YELLOW}>>> 请插入 U 盘，然后按 Enter 继续...${NC}"
            read

            echo -n "    等待设备识别并自动挂载..."
            timeout=20
            local mounted=0
            while [ $timeout -gt 0 ]; do
                if [ -b "$DEV_PATH" ]; then
                    local part=$(lsblk -nlo NAME "$DEV_PATH" 2>/dev/null | tail -n +2 | head -1)
                    if [ -n "$part" ] && findmnt "/dev/$part" &>/dev/null; then
                        local mnt=$(findmnt -nro TARGET "/dev/$part")
                        echo -e "\n    ${OK} 自动挂载成功，挂载点: ${GREEN}${mnt}${NC}"
                        ((port_success++))
                        mounted=1
                        break
                    fi
                fi
                sleep 1
                timeout=$((timeout - 1))
            done
            if [ $mounted -eq 0 ]; then
                echo -e " ${ERR} 未自动挂载或超时"
                ((port_fail++))
            fi
        done
        set -e

        echo -e "\n  ${BOLD}${port_name} 完成：成功 ${port_success} 次, 失败 ${port_fail} 次${NC}"
        total_success=$((total_success + port_success))
        total_fail=$((total_fail + port_fail))

        if [ $port_index -lt $((${#USB_PORTS[@]} - 1)) ]; then
            read -p "是否继续测试下一个端口？(Y/n): " cont
            if [[ "$cont" =~ ^[nN]$ ]]; then
                echo -e "${INFO} 跳过剩余端口测试"
                break
            fi
        fi
    done

    echo -e "\n${BOLD}${GREEN}热插拔测试总结果：成功 ${total_success} 次, 失败 ${total_fail} 次${NC}"
}

# ---------- 主菜单 ----------
main() {
    [ "$(id -u)" -ne 0 ] && { echo -e "${ERR} 请使用 sudo 运行此脚本"; exit 1; }
    check_deps

    list_usb_devices
    select_device
    echo -e "\n${WARN} 警告：测试将写入数据，可能破坏原有内容。"
    read -p "是否继续？(y/N): " confirm
    [[ "$confirm" =~ ^[yY]$ ]] || exit 0

    local selected_dev="$DEV_PATH"

    while true; do
        echo ""
        echo -e "${BOLD}${CYAN}▌ USB 测试菜单${NC}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo "  1) 顺序读写性能测试 (dd 5G)"
        echo "  2) 重新挂载验证 (卸载后重新挂载)"
        echo "  3) 多接口热插拔测试 (每个接口 ${HOTPLUG_COUNT} 次)"
        echo "  4) 长时间写入稳定性测试 (循环1G写入，自动删除)"
        echo "  q) 退出 USB 测试"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        read -p "请选择 (1-4, q): " choice

        case $choice in
            1)
                DEV_PATH="$selected_dev"
                if ! mount_partition; then
                    echo -e "${ERR} 挂载失败，无法进行测试。"
                    continue
                fi
                run_dd_test
                verify_remount
                ask_umount
                ;;
            2)
                DEV_PATH="$selected_dev"
                if ! mount_partition; then
                    echo -e "${ERR} 挂载失败，无法进行测试。"
                    continue
                fi
                verify_remount
                ask_umount
                ;;
            3)
                DEV_PATH="$selected_dev"
                test_hotplug
                ;;
            4)
                DEV_PATH="$selected_dev"
                if ! mount_partition; then
                    echo -e "${ERR} 挂载失败，无法进行测试。"
                    continue
                fi
                run_endurance_test
                ask_umount
                ;;
            q|Q)
                echo -e "\n${INFO} 退出 USB 测试。"
                break
                ;;
            *)
                echo -e "${ERR} 无效选项，请重新输入"
                ;;
        esac
    done

    echo -e "\n${BOLD}${GREEN}USB 测试全部完成！${NC}"
}

main "$@"
