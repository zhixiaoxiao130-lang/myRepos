#!/bin/bash
# NVMe 设备信息检查脚本（健康状态修复版）
# 用法: sudo ./check_nvme.sh [--all-partitions]

set -euo pipefail

# ---------- 颜色 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

# ---------- 参数 ----------
TEST_ALL_PARTITIONS=0
if [[ "${1:-}" == "--all-partitions" ]]; then
    TEST_ALL_PARTITIONS=1
fi

# ---------- 依赖检查 ----------
check_deps() {
    local missing=""
    for cmd in lspci lsblk mount umount findmnt; do
        if ! command -v "$cmd" &> /dev/null; then
            missing="$missing $cmd"
        fi
    done
    if [ -n "$missing" ]; then
        echo -e "${RED}缺少依赖命令:$missing${NC}"
        echo "请安装: sudo apt update && sudo apt install pciutils util-linux"
        exit 1
    fi
}

# ---------- PCIe 速度 → 代际映射 ----------
pcie_generation() {
    local speed="$1"
    case "$speed" in
        16) echo "PCIe 4.0" ;;
        8)  echo "PCIe 3.0" ;;
        5)  echo "PCIe 2.0" ;;
        2.5) echo "PCIe 1.0" ;;
        *)   echo "PCIe ?.?" ;;
    esac
}

# ---------- 检查单个 NVMe 控制器 ----------
check_nvme_controller() {
    local slot="$1"
    echo -e "\n${GREEN}========== NVMe 控制器 ($slot) ==========${NC}"

    local numeric_line vendor_device rev
    numeric_line=$(lspci -n -s "$slot" 2>/dev/null)
    vendor_device=$(echo "$numeric_line" | awk '{print $3}')
    rev=$(echo "$numeric_line" | sed -n 's/.*(rev \([0-9a-f]*\)).*/\1/p')
    [ -z "$rev" ] && rev="未知"

    echo "  设备 ID:       ${vendor_device}"
    echo "  版本:          ${rev}"

    local full_line class_name subsys_name
    full_line=$(lspci -s "$slot" 2>/dev/null)
    class_name=$(echo "$full_line" | awk -F'"' '{print $2}')
    subsys_name=$(lspci -s "$slot" -vvv 2>/dev/null | grep -i "Subsystem" | head -1 | cut -d: -f2- | sed 's/^ *//')
    echo "  类别:          ${class_name:-NVMe}"
    echo "  子系统:        ${subsys_name:-未知}"

    local lspci_detailed
    lspci_detailed=$(lspci -vvv -s "$slot" 2>/dev/null)

    local cap_speed cap_width sta_speed sta_width
    cap_speed=$(echo "$lspci_detailed" | grep -oP 'LnkCap:.*?Speed \K[0-9.]+' || true)
    sta_speed=$(echo "$lspci_detailed" | grep -oP 'LnkSta:.*?Speed \K[0-9.]+' || true)
    cap_width=$(echo "$lspci_detailed" | grep -oP 'LnkCap:.*?Width x\K[0-9]+' || true)
    sta_width=$(echo "$lspci_detailed" | grep -oP 'LnkSta:.*?Width x\K[0-9]+' || true)

    local cap_desc sta_desc
    cap_desc=$(pcie_generation "${cap_speed:-0}")
    sta_desc=$(pcie_generation "${sta_speed:-0}")

    echo -e "\n  PCIe 能力 (设计最大):  ${cap_desc} (${cap_speed:-?}GT/s), Width x${cap_width:-?}"
    echo    "  PCIe 状态 (当前运行):  ${sta_desc} (${sta_speed:-?}GT/s), Width x${sta_width:-?}"

    if [ "${sta_width:-0}" = "4" ]; then
        echo -e "  当前链路宽度: x${sta_width} (${GREEN}OK${NC})"
    elif [ -n "${sta_width}" ]; then
        echo -e "  当前链路宽度: x${sta_width} (${YELLOW}可能未满带宽${NC})"
    else
        echo -e "  当前链路宽度: 未知 (${YELLOW}请检查连接${NC})"
    fi

    if [ -n "${sta_speed}" ]; then
        echo -e "  ${GREEN}✅ 当前运行在 ${sta_desc} 接口${NC}"
    else
        echo -e "  ${RED}❌ 无法判断接口类型${NC}"
    fi
}

# ---------- 分区挂载测试（默认仅第一个分区）----------
test_nvme_mount() {
    echo -e "\n${GREEN}========== NVMe 分区挂载测试 ==========${NC}"
    local tested=0

    for disk in /dev/nvme*n1; do
        [ -b "$disk" ] || continue

        local parts
        if [ $TEST_ALL_PARTITIONS -eq 1 ]; then
            parts=$(lsblk -nlo NAME,TYPE "$disk" 2>/dev/null | awk '/part/ {print $1}')
        else
            parts=$(lsblk -nlo NAME,TYPE "$disk" 2>/dev/null | awk '/part/ {print $1; exit}')
        fi

        if [ -z "$parts" ]; then
            echo -e "${YELLOW}设备 ${disk} 没有分区，跳过${NC}"
            continue
        fi

        for part in $parts; do
            local part_path="/dev/${part}"
            local mount_point="/mnt/nvme_test_${part}"

            if findmnt "$part_path" &>/dev/null; then
                echo -e "${YELLOW}[${part}] 已挂载，跳过测试${NC}"
                continue
            fi

            echo -e "\n测试分区: ${part_path}"
            tested=1

            mkdir -p "$mount_point"
            if ! mount "$part_path" "$mount_point" 2>/dev/null; then
                echo -e "  ${RED}❌ 挂载失败（可能是未知文件系统或分区表）${NC}"
                rmdir "$mount_point" 2>/dev/null || true
                continue
            fi
            echo -e "  ${GREEN}✅ 挂载成功${NC}"

            local fs_type
            fs_type=$(findmnt -nro FSTYPE "$mount_point" 2>/dev/null || echo "未知")
            echo "  文件系统类型: ${fs_type}"

            local ro_status
            ro_status=$(findmnt -nro OPTIONS "$mount_point" 2>/dev/null | grep -o 'ro' || true)
            if [ "$ro_status" = "ro" ]; then
                echo -e "  ${YELLOW}⚠️  分区以只读方式挂载，跳过写入测试${NC}"
            else
                local test_file="${mount_point}/.nvme_write_test_$$"
                if echo "test" > "$test_file" 2>/dev/null; then
                    echo -e "  ${GREEN}✅ 写入测试成功${NC}"
                    rm -f "$test_file"
                else
                    echo -e "  ${RED}❌ 写入测试失败${NC}"
                fi
            fi

            if umount "$mount_point" 2>/dev/null; then
                echo -e "  ${GREEN}✅ 卸载成功${NC}"
            else
                echo -e "  ${RED}❌ 卸载失败，请手动卸载: umount ${mount_point}${NC}"
            fi

            rmdir "$mount_point" 2>/dev/null || true
        done
    done

    if [ $tested -eq 0 ]; then
        echo -e "${YELLOW}未测试任何分区（可能无分区或全部已挂载）${NC}"
    fi
}

# ---------- NVMe 健康状态检查（修复显示格式）----------
check_nvme_health() {
    echo -e "\n${GREEN}========== NVMe 健康状态检查 ==========${NC}"

    local tool=""
    if command -v nvme &>/dev/null; then
        tool="nvme"
    elif command -v smartctl &>/dev/null; then
        tool="smartctl"
    else
        echo -e "${YELLOW}未找到 nvme-cli 或 smartctl，跳过健康检查。${NC}"
        echo -e "${YELLOW}安装 nvme-cli: sudo apt install nvme-cli${NC}"
        return
    fi

    for dev in /dev/nvme*n1; do
        [ -b "$dev" ] || continue
        local name=$(basename "$dev")
        echo -e "\n设备: /dev/$name"

        if [ "$tool" = "nvme" ]; then
            local smart_output
            smart_output=$(nvme smart-log "$dev" 2>&1) || {
                echo -e "  ${RED}❌ nvme smart-log 执行失败: $smart_output${NC}"
                continue
            }

            # 提取并清理字段
            local crit_warn temp_raw used_raw data_units
            crit_warn=$(echo "$smart_output" | awk '/critical_warning/ {print $3}')
            temp_raw=$(echo "$smart_output" | awk '/temperature/ {print $3}')
            used_raw=$(echo "$smart_output" | awk '/percentage_used/ {print $3}')
            data_units=$(echo "$smart_output" | awk '/data_units_written/ {print $3}')

            # 去掉温度后缀 °C 或 C
            local temp=$(echo "$temp_raw" | tr -d '°C' | xargs)
            # 去掉百分比后缀 %
            local used_num=$(echo "$used_raw" | tr -d '%' | xargs)

            # 计算写入量
            local total_write_gb="N/A"
            if [ -n "$data_units" ] && [ "$data_units" != "0" ]; then
                total_write_gb=$(awk "BEGIN {printf \"%.2f\", $data_units * 512 / 1073741824}")
            fi

            # 构造健康状态信息
            local health="✅ 正常"
            [ -n "$crit_warn" ] && [ "$crit_warn" != "0" ] && health="${RED}❌ 警告 (critical_warning=$crit_warn)${NC}"
            [ -n "$used_num" ] && [ "$used_num" != "0" ] && {
                if [ "$used_num" -gt 90 ]; then
                    health="${RED}⚠️ 写入寿命消耗超过 90%，即将耗尽 (当前 ${used_num}%)${NC}"
                else
                    health="✅ 正常 (写入寿命消耗 ${used_num}%)"
                fi
            }
            # 如果 used_num 为空或 0，不显示百分比
            if [ -z "$used_num" ] || [ "$used_num" = "0" ]; then
                health="✅ 正常"
            fi

            echo -e "  健康状态: $health"
            [ -n "$temp" ] && echo "  温度:      ${temp}°C"
            echo "  总写入量:  ${total_write_gb} GB"

        elif [ "$tool" = "smartctl" ]; then
            local smart_output
            smart_output=$(smartctl -a "$dev" 2>&1) || {
                echo -e "  ${RED}❌ smartctl 执行失败${NC}"
                continue
            }

            local health_line temp used_raw
            health_line=$(echo "$smart_output" | grep "SMART overall-health" | awk -F: '{print $2}' | xargs || echo "未知")
            temp=$(echo "$smart_output" | grep -i "Temperature" | head -1 | awk '{print $2}' | tr -d '°C' | xargs)
            used_raw=$(echo "$smart_output" | grep -i "Percentage Used" | awk '{print $3}' | tr -d '%' | xargs)

            echo -e "  整体健康:  $health_line"
            [ -n "$temp" ] && echo "  温度:      ${temp}°C"
            [ -n "$used_raw" ] && echo "  写入寿命消耗: ${used_raw}%"
        fi
    done
}

# ---------- 列出所有 NVMe 块设备 ----------
list_nvme_devices() {
    echo -e "\n${GREEN}========== NVMe 存储设备列表 ==========${NC}"
    local found=0
    for dev in /dev/nvme*n1; do
        [ -e "$dev" ] || continue
        local name size model
        name=$(basename "$dev")
        size=$(lsblk -dno SIZE "$dev" 2>/dev/null || echo "未知")
        model=$(cat "/sys/block/${name}/device/model" 2>/dev/null || echo "未知")
        echo "  设备路径: /dev/$name"
        echo "  型号:     $model"
        echo "  大小:     $size"
        echo "  ----------------------------------"
        found=1
    done
    if [ $found -eq 0 ]; then
        echo "  未检测到任何 NVMe 块设备 (可能未安装或未初始化)。"
    fi
}

# ---------- 主流程 ----------
main() {
    check_deps

    echo "=========================================="
    echo "  RK3588 NVMe 信息检查工具 (健康检查修复版)"
    [ $TEST_ALL_PARTITIONS -eq 1 ] && echo "  模式: 所有分区"
    echo "=========================================="

    local nvme_slots
    nvme_slots=$(lspci -n -d '::0108' 2>/dev/null | awk '{print $1}')
    if [ -z "$nvme_slots" ]; then
        echo -e "\n${YELLOW}未检测到 NVMe 控制器。请检查设备连接。${NC}"
        exit 0
    fi

    for slot in $nvme_slots; do
        check_nvme_controller "$slot"
    done

    list_nvme_devices
    test_nvme_mount
    check_nvme_health
}

main "$@"
