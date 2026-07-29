#!/bin/bash
# ============================================================
# SSD 爆满测试脚本（多 SSD 选择 + 自动挂载）
# 功能：1. 列出系统中所有 NVMe SSD，用户选择要测试的磁盘；
#       2. 自动挂载所选 SSD 的第一个分区，若挂载失败则退出；
#       3. 持续写入文件直到剩余空间 < 100MB。
# 运行方式：sudo ./ssd_full_test.sh
# ============================================================

set -euo pipefail
mkdir -p "$(dirname "$LOG_FILE")"   # 自动创建 log 目录
> "$LOG_FILE"                       # 清空或创建日志文件
MOUNT_POINT="/mnt/ssd_test"                # 统一挂载点
LOG_FILE="./log/ssd_full_test.log"
BLOCK_SIZE="10M"
MIN_FREE=104857600                         # 100MB 停止阈值 (字节)

# ---------- 颜色输出 ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ---------- 函数：打印标题 ----------
print_header() {
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  $1${NC}"
    echo -e "${GREEN}========================================${NC}"
}

# ---------- 函数：错误退出 ----------
die() {
    echo -e "${RED}❌ $1${NC}" | tee -a "$LOG_FILE"
    exit 1
}

# ---------- 函数：列出 NVMe 设备 ----------
list_nvme_devices() {
    echo "正在扫描 NVMe SSD 设备..."
    nvme_devs=($(ls /dev/nvme*n1 2>/dev/null || true))
    if [ ${#nvme_devs[@]} -eq 0 ]; then
        die "未检测到任何 NVMe SSD 设备 (/dev/nvme*n1)。"
    fi

    echo -e "\n检测到以下 NVMe SSD 设备："
    echo "----------------------------------------------------------"
    for i in "${!nvme_devs[@]}"; do
        dev="${nvme_devs[$i]}"
        # 获取设备大小
        size=$(lsblk -dno SIZE "$dev" 2>/dev/null || echo "未知")
        # 获取型号（可能为空）
        model=$(lsblk -dno MODEL "$dev" 2>/dev/null || echo "未知")
        printf "  %d) %-15s  容量: %-8s  型号: %s\n" $((i+1)) "$dev" "$size" "$model"
    done
    echo "----------------------------------------------------------"
}

# ---------- 函数：选择 SSD 设备 ----------
select_ssd() {
    local choice
    while true; do
        read -p "请输入要测试的 SSD 编号 (1-${#nvme_devs[@]}): " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#nvme_devs[@]}" ]; then
            selected_dev="${nvme_devs[$((choice-1))]}"
            echo -e "已选择设备: ${GREEN}$selected_dev${NC}"
            break
        else
            echo -e "${RED}输入无效，请重新输入。${NC}"
        fi
    done
}

# ---------- 函数：挂载分区 ----------
mount_ssd_partition() {
    local dev="$1"
    local part="${dev}p1"   # 默认使用第一个分区

    if [ ! -b "$part" ]; then
        die "分区 $part 不存在。请先创建分区（例如使用 fdisk 或 parted）。"
    fi

    # 如果挂载点已挂载，先卸载
    if mountpoint -q "$MOUNT_POINT"; then
        echo -e "${YELLOW}⚠️  $MOUNT_POINT 已挂载，正在卸载旧挂载...${NC}"
        umount "$MOUNT_POINT" || die "卸载 $MOUNT_POINT 失败，请手动检查。"
    fi

    mkdir -p "$MOUNT_POINT"
    if mount "$part" "$MOUNT_POINT"; then
        echo -e "${GREEN}✅ 分区 $part 已成功挂载到 $MOUNT_POINT${NC}"
    else
        die "挂载分区 $part 失败。请检查文件系统是否正常（可能需要 mkfs）。"
    fi
}

# ---------- 主逻辑 ----------
main() {
    # 1. 初始化日志
    mkdir -p "$(dirname "$LOG_FILE")"
    > "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1   # 之后所有输出同时记录到日志文件

    print_header "SSD 爆满测试工具"

    # 2. 列出并选择 SSD
    list_nvme_devices
    select_ssd

    # 3. 挂载所选 SSD 的分区
    mount_ssd_partition "$selected_dev"

    # 4. 显示当前状态
    echo ""
    echo "挂载点: $MOUNT_POINT"
    echo "剩余空间: $(df -h "$MOUNT_POINT" | tail -1 | awk '{print $4}')"

    # 5. 开始填满测试
    local test_dir="$MOUNT_POINT/testdir"
    mkdir -p "$test_dir"
    echo -e "\n开始写入测试文件（每个 ${BLOCK_SIZE}）..."
    local total_bytes=0 file_count=0
    local start_time=$(date +%s)

    while true; do
        local avail=$(df -B1 --output=avail "$MOUNT_POINT" | tail -1)
        if [ "$avail" -lt "$MIN_FREE" ]; then
            echo "[$(date '+%H:%M:%S')] 剩余空间不足 100MB，写入停止。"
            break
        fi

        local file_name="$test_dir/fill_${file_count}.tmp"
        if dd if=/dev/urandom of="$file_name" bs="$BLOCK_SIZE" count=1 status=none 2>>"$LOG_FILE"; then
            total_bytes=$((total_bytes + 10*1024*1024))
            file_count=$((file_count + 1))
            if [ $((file_count % 100)) -eq 0 ]; then
                local written_mb=$((total_bytes/1024/1024))
                echo "[$(date '+%H:%M:%S')] 已写入 ${written_mb} MiB ($file_count 个文件)"
            fi
        else
            echo "[$(date '+%H:%M:%S')] 写入失败，停止。"
            break
        fi
    done

    local end_time=$(date +%s)
    local elapsed=$((end_time - start_time))

    # 6. 输出统计
    echo ""
    print_header "测试结果"
    echo "  设备: $selected_dev"
    echo "  共创建 $file_count 个文件"
    echo "  写入总量: $((total_bytes/1024/1024)) MiB ($((total_bytes/1024/1024/1024)) GiB)"
    echo "  耗时: ${elapsed}s"
    if [ $elapsed -gt 0 ]; then
        local speed=$(echo "scale=2; $total_bytes / $elapsed / 1048576" | bc)
        echo "  平均写入速度: ${speed} MiB/s"
    fi
    df -h "$MOUNT_POINT"

    # 7. 清理测试文件
    echo -e "\n正在删除测试文件..."
    rm -rf "$test_dir"
    echo "测试文件已删除，磁盘空间已恢复。"
    df -h "$MOUNT_POINT"

    # 8. 卸载（可选，保留给用户决定）
    echo -e "\n💡 提示：测试完成，磁盘仍挂载在 $MOUNT_POINT。如需卸载，请执行：sudo umount $MOUNT_POINT"
}

# 检查 root 权限
if [ "$(id -u)" -ne 0 ]; then
    echo "此脚本需要 root 权限，请使用 sudo 运行。"
    exit 1
fi

main
