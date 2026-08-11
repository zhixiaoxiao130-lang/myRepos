#!/bin/bash
# RK3588 NVMe 综合测试脚本（交互优化 + Trim 支持）
#   - 清晰展示设备 PCIe 速率和型号
#   - 测试前可选 Trim，恢复 SSD 性能
#   - 动态理论带宽，先写后读，自动清理，全覆盖日志
# 用法：sudo ./pcie_test.sh

export LC_ALL=C
export LANG=C

# ---------- 固定日志目录及文件名 ----------
LOG_DIR="./log"
mkdir -p "$LOG_DIR"

DD_LOG="${LOG_DIR}/dd_result.txt"
FIO_LOG="${LOG_DIR}/bench_result.txt"
FULL_LOG="${LOG_DIR}/ssd_full.log"
IOSTAT_LOG="${LOG_DIR}/iostat.log"
CPU_LOG="${LOG_DIR}/cpu.log"
FIO_JSON_DIR="${LOG_DIR}/fio_json"
mkdir -p "$FIO_JSON_DIR"

# ---------- 配置 ----------
SIZE="10G"
RUNTIME=30

# ---------- 依赖检查 ----------
check_cmd() {
    local missing=""
    for cmd in fio jq iostat bc lspci mount umount lsblk dd parted partprobe mkfs.ext4 sgdisk; do
        if ! command -v "$cmd" &>/dev/null; then
            missing="$missing $cmd"
        fi
    done
    if [ -n "$missing" ]; then
        echo "❌ 缺少依赖: $missing"
        echo "请执行以下命令安装："
        echo "  sudo apt update && sudo apt install -y fio jq sysstat bc pciutils util-linux parted e2fsprogs gdisk"
        exit 1
    fi
    if ! fio --version &>/dev/null; then
        echo "❌ fio 命令已安装但无法执行，请重新安装："
        echo "  sudo apt install --reinstall fio"
        exit 1
    fi
}

check_cmd

# ---------- 清理函数（trap EXIT 自动调用）----------
PART_CREATED=0
CLEANUP_PART_NUM=""
CLEANUP_DONE=0

do_cleanup() {
    if [ "$CLEANUP_DONE" -eq 1 ]; then
        return
    fi
    CLEANUP_DONE=1

    # 卸载测试挂载点
    if [ -n "$TEST_MOUNT" ] && mountpoint -q "$TEST_MOUNT" 2>/dev/null; then
        umount "$TEST_MOUNT" 2>/dev/null
    fi
    rmdir "$TEST_MOUNT" 2>/dev/null

    # 如果创建了测试分区，询问是否删除
    if [ "$PART_CREATED" -eq 1 ] && [ -n "$CLEANUP_PART_NUM" ] && [ -n "$SELECTED_DEV_PATH" ]; then
        echo ""
        echo "┌─────────────────────────────────────────┐"
        echo "│  测试分区 $PART_PATH 是本次测试创建的   │"
        echo "│  删除后将恢复原始磁盘分区布局           │"
        echo "└─────────────────────────────────────────┘"
        read -p "是否删除测试分区 $PART_PATH？(Y/n): " DEL_PART
        if [[ ! "$DEL_PART" =~ ^[Nn]$ ]]; then
            echo "正在删除分区 $PART_PATH ..."
            parted -s "$SELECTED_DEV_PATH" rm "$CLEANUP_PART_NUM" 2>/dev/null && \
                echo "✅ 分区 $PART_PATH 已删除" || \
                echo "⚠️ 删除分区失败，请手动处理: parted $SELECTED_DEV_PATH rm $CLEANUP_PART_NUM"
        else
            echo "保留分区 $PART_PATH"
        fi
    fi
}

trap do_cleanup EXIT

# ---------- 1. 设备选择 ----------
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║      RK3588 NVMe 性能测试工具           ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "检测到以下 NVMe 设备："
mapfile -t DEVICES < <(ls /dev/nvme*n1 2>/dev/null)
if [ ${#DEVICES[@]} -eq 0 ]; then
    echo "❌ 未检测到任何 NVMe 设备，退出。"
    exit 1
fi

declare -a DEV_NAME DEV_SIZE DEV_MODEL DEV_PCIE
for i in "${!DEVICES[@]}"; do
    DEV_NAME[$i]=$(basename "${DEVICES[$i]}")
    DEV_SIZE[$i]=$(lsblk -dno SIZE "/dev/${DEV_NAME[$i]}" 2>/dev/null)
    DEV_MODEL[$i]=$(cat "/sys/block/${DEV_NAME[$i]}/device/model" 2>/dev/null || echo "未知")
    # 获取 PCIe 协商速率
    pci_addr=$(readlink -f "/sys/block/${DEV_NAME[$i]}/device" 2>/dev/null | grep -oP '[0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f]' | tail -1)
    if [ -n "$pci_addr" ]; then
        link_info=$(lspci -vvv -s "$pci_addr" 2>/dev/null | grep "LnkSta:")
        speed=$(echo "$link_info" | grep -oP 'Speed \K\S+' | tr -d ',')
        width=$(echo "$link_info" | grep -oP 'Width \K\S+' | tr -d ',')
        [ -n "$speed" ] && [ -n "$width" ] && DEV_PCIE[$i]="PCIe ${speed} ${width}" || DEV_PCIE[$i]="未知"
    else
        DEV_PCIE[$i]="未知"
    fi
    echo "  [$((i+1))] /dev/${DEV_NAME[$i]}  ${DEV_SIZE[$i]}  ${DEV_MODEL[$i]}  (${DEV_PCIE[$i]})"
done
echo ""
read -p "请选择要测试的设备编号 (1-${#DEVICES[@]}): " CHOICE
if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || [ "$CHOICE" -lt 1 ] || [ "$CHOICE" -gt ${#DEVICES[@]} ]; then
    echo "无效选择，退出。"
    exit 1
fi

SELECTED_DEV="${DEV_NAME[$((CHOICE-1))]}"
SELECTED_DEV_PATH="/dev/$SELECTED_DEV"
SELECTED_PCIE="${DEV_PCIE[$((CHOICE-1))]}"
echo "已选择: $SELECTED_DEV_PATH (${SELECTED_PCIE})"

# ---------- 2. 创建测试分区 ----------
echo ""
echo "┌─────────────────────────────────────────┐"
echo "│  自动创建测试分区                        │"
echo "│  在 SSD 未分配空间上创建临时测试分区     │"
echo "│  测试完成后可选择自动删除                │"
echo "└─────────────────────────────────────────┘"

# 检测未分配空间
FREE_START=$(parted -s "$SELECTED_DEV_PATH" unit s print free 2>/dev/null | grep "Free Space" | tail -1 | awk '{print $1}' | tr -d 's')
DISK_SIZE_SECTORS=$(parted -s "$SELECTED_DEV_PATH" unit s print 2>/dev/null | grep "^Disk ${SELECTED_DEV_PATH}" | awk '{print $3}' | tr -d 's')

# 检查是否有现有分区
EXISTING_PARTS=$(lsblk -nlo NAME "$SELECTED_DEV_PATH" 2>/dev/null | tail -n +2)

# 磁盘无分区时，从对齐位置开始
if [ -z "$EXISTING_PARTS" ]; then
    FREE_START=2048
fi

if [ -n "$FREE_START" ] && [ "$FREE_START" -ge 2048 ] && [ -n "$DISK_SIZE_SECTORS" ]; then
    FREE_SIZE_SECTORS=$((DISK_SIZE_SECTORS - FREE_START))
    FREE_SIZE_GB=$(echo "scale=1; $FREE_SIZE_SECTORS * 512 / 1073741824" | bc)

    if [ "${FREE_SIZE_GB%.*}" -ge 1 ]; then
        echo "检测到未分配空间: ${FREE_SIZE_GB}GB"
        read -p "是否创建测试分区？(Y/n): " CREATE_PART
        if [[ ! "$CREATE_PART" =~ ^[Nn]$ ]]; then
            echo "正在创建测试分区..."
            # 修复 GPT 备份表位置（常见于镜像被写入更大磁盘的场景）
            echo "  → 检查并修复 GPT 表..."
            sgdisk -e "$SELECTED_DEV_PATH" 2>/dev/null
            partprobe "$SELECTED_DEV_PATH" 2>/dev/null
            sleep 1
            # 重新获取可用空间起始位置（GPT 修复后可能变化）
            FREE_START=$(parted -s "$SELECTED_DEV_PATH" unit s print free 2>/dev/null | grep "Free Space" | tail -1 | awk '{print $1}' | tr -d 's')
            parted -s "$SELECTED_DEV_PATH" mkpart primary ext4 ${FREE_START}s 100%
            if [ $? -ne 0 ]; then
                echo "⚠️ 分区创建失败，回退到使用现有分区。"
            else
                partprobe "$SELECTED_DEV_PATH"
                sleep 2
                NEW_PART=$(lsblk -nlo NAME "$SELECTED_DEV_PATH" | tail -1)
                PART_PATH="/dev/$NEW_PART"
                PART_CREATED=1
                CLEANUP_PART_NUM=$(echo "$NEW_PART" | grep -oP '\d+$')

                echo "正在格式化 $PART_PATH 为 ext4 ..."
                mkfs.ext4 -F "$PART_PATH" 2>/dev/null
                if [ $? -ne 0 ]; then
                    echo "❌ 格式化失败"
                    parted -s "$SELECTED_DEV_PATH" rm "$CLEANUP_PART_NUM" 2>/dev/null
                    PART_CREATED=0
                    CLEANUP_PART_NUM=""
                else
                    echo "✅ 测试分区 $PART_PATH (${FREE_SIZE_GB}GB) 已就绪"
                fi
            fi
        else
            echo "跳过分区创建。"
        fi
    fi
fi

# 如果未创建新分区，回退到使用现有最大分区
if [ "$PART_CREATED" -eq 0 ]; then
    if [ -z "$EXISTING_PARTS" ]; then
        echo "❌ 设备 $SELECTED_DEV_PATH 没有分区，且无法创建测试分区。"
        exit 1
    fi
    PART=$(lsblk -nlo NAME,SIZE "$SELECTED_DEV_PATH" 2>/dev/null | tail -n +2 | sort -k2 -hr | head -1 | awk '{print $1}')
    if [ -z "$PART" ]; then
        echo "❌ 无法找到可用分区。"
        exit 1
    fi
    PART_PATH="/dev/$PART"
    echo "使用现有分区: $PART_PATH"
fi

if findmnt "$PART_PATH" &>/dev/null; then
    echo "❌ 分区 $PART_PATH 已经被挂载，请先卸载后再试。"
    exit 1
fi

# ---------- 3. 挂载到临时目录 ----------
TEST_MOUNT="/mnt/nvme_bench_$$"
mkdir -p "$TEST_MOUNT"
mount "$PART_PATH" "$TEST_MOUNT" || {
    echo "❌ 挂载 $PART_PATH 到 $TEST_MOUNT 失败。"
    rmdir "$TEST_MOUNT" 2>/dev/null
    exit 1
}
echo "已挂载 $PART_PATH -> $TEST_MOUNT"

# ---------- 4. Trim 支持（测试前清理 SSD 垃圾）----------
echo ""
echo "┌─────────────────────────────────────────┐"
echo "│  SSD Trim 维护说明                      │"
echo "│  定期 Trim 可清理无效数据，恢复写入性能  │"
echo "│  测试前执行一次，能获得稳定基准数据      │"
echo "└─────────────────────────────────────────┘"
if command -v fstrim &>/dev/null; then
    read -p "是否在执行测试前 Trim SSD？(y/N): " DO_TRIM
    if [[ "$DO_TRIM" =~ ^[Yy]$ ]]; then
        echo "正在执行 fstrim $TEST_MOUNT ..."
        sync
        fstrim -v "$TEST_MOUNT" && echo "✅ Trim 完成" || echo "⚠️ Trim 执行失败，继续测试。"
    else
        echo "跳过 Trim。"
    fi
else
    echo "⚠️ 未找到 fstrim 命令（需 util-linux 包），跳过 Trim。"
fi

# ---------- 5. 选择测试类型 ----------
echo ""
echo "┌──────────────────────────────────────┐"
echo "│ 请选择测试类型：                      │"
echo "│ 1) 基础读写测试 (dd 5G)               │"
echo "│ 2) 性能压测 (fio 顺序/随机)           │"
echo "│ 3) SSD 写满测试 (填满剩余空间)        │"
echo "└──────────────────────────────────────┘"
read -p "请输入选项 (1, 2 或 3): " TEST_TYPE
if [[ ! "$TEST_TYPE" =~ ^[1-3]$ ]]; then
    echo "无效选择，退出。"
    umount "$TEST_MOUNT"
    rmdir "$TEST_MOUNT" 2>/dev/null
    exit 1
fi

TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# ---------- PCIe 理论带宽计算 ----------
get_pcie_info() {
    # 已通过 SELECTED_PCIE 获得，直接返回
    echo "$SELECTED_PCIE"
}

get_theoretical_bw() {
    local info="$1"
    case "$info" in
        *2.5GT/s*x1*)  echo 250 ;;
        *2.5GT/s*x2*)  echo 500 ;;
        *2.5GT/s*x4*)  echo 1000 ;;
        *5GT/s*x1*)    echo 500 ;;
        *5GT/s*x2*)    echo 1000 ;;
        *5GT/s*x4*)    echo 2000 ;;
        *8GT/s*x1*)    echo 1000 ;;
        *8GT/s*x2*)    echo 2000 ;;
        *8GT/s*x4*)    echo 3940 ;;
        *16GT/s*x1*)   echo 2000 ;;
        *16GT/s*x2*)   echo 3940 ;;
        *16GT/s*x4*)   echo 7880 ;;
        *)             echo 3940 ;;
    esac
}

PCIe_INFO=$(get_pcie_info)
THEO_BW_MB=$(get_theoretical_bw "$PCIe_INFO")

# ---------- 分析函数 ----------
analyze_dd() {
    local w_speed="$1" r_speed="$2"
    echo "" | tee -a "$DD_LOG"
    echo "▸▸▸ 结果分析" | tee -a "$DD_LOG"
    echo "PCIe 协商速率: $PCIe_INFO  (理论带宽 ${THEO_BW_MB} MB/s)" | tee -a "$DD_LOG"
    echo "写入速度: ${w_speed} MB/s" | tee -a "$DD_LOG"
    echo "读取速度: ${r_speed} MB/s" | tee -a "$DD_LOG"
    if (( $(echo "$r_speed < $THEO_BW_MB * 0.8" | bc -l) )); then
        echo "⚠️ 读取速度偏低，仅达到理论带宽的 $(echo "scale=0; $r_speed*100/$THEO_BW_MB" | bc)%" | tee -a "$DD_LOG"
    else
        echo "✅ 读取速度正常" | tee -a "$DD_LOG"
    fi
    if (( $(echo "$w_speed < $THEO_BW_MB * 0.8" | bc -l) )); then
        echo "⚠️ 写入速度偏低，可能受 SSD 自身性能或缓存状态影响" | tee -a "$DD_LOG"
    else
        echo "✅ 写入速度正常" | tee -a "$DD_LOG"
    fi
    echo "─────────────────────────────────────────" | tee -a "$DD_LOG"
    echo "详细日志已覆盖: $DD_LOG" | tee -a "$DD_LOG"
}

analyze_fio() {
    echo "" | tee -a "$FIO_LOG"
    echo "▸▸▸ 结果分析" | tee -a "$FIO_LOG"
    echo "PCIe 协商速率: $PCIe_INFO  (理论带宽 ${THEO_BW_MB} MB/s)" | tee -a "$FIO_LOG"
    echo "重点关注：" | tee -a "$FIO_LOG"
    echo "  · 顺序读/写带宽（seq-read / seq-write）" | tee -a "$FIO_LOG"
    echo "  · 随机读/写 IOPS（rand-read / rand-write）" | tee -a "$FIO_LOG"
    echo "  · 利用率 < 60% → 读取未跑满接口；利用率高但数值低 → SSD 写入限制" | tee -a "$FIO_LOG"
    echo "─────────────────────────────────────────" | tee -a "$FIO_LOG"
    echo "详细日志已覆盖: $FIO_LOG" | tee -a "$FIO_LOG"
}

analyze_full() {
    local total_mb="$1" elapsed="$2" avg_speed="$3"
    echo "" | tee -a "$FULL_LOG"
    echo "▸▸▸ 结果分析" | tee -a "$FULL_LOG"
    echo "写入总量: ${total_mb} MiB" | tee -a "$FULL_LOG"
    echo "耗时: ${elapsed}s" | tee -a "$FULL_LOG"
    echo "平均写入速度: ${avg_speed} MiB/s" | tee -a "$FULL_LOG"
    echo "✅ 磁盘已成功填满至剩余空间不足 100MB" | tee -a "$FULL_LOG"
    echo "─────────────────────────────────────────" | tee -a "$FULL_LOG"
    echo "详细日志已覆盖: $FULL_LOG" | tee -a "$FULL_LOG"
}

# ---------- 测试模块 ----------

# --- 基础读写测试 (dd) ---
if [ "$TEST_TYPE" == "1" ]; then
    TEST_FILE="${TEST_MOUNT}/dd_testfile"
    > "$DD_LOG"
    echo "========================================" | tee -a "$DD_LOG"
    echo "  NVMe 基础读写测试 (dd 5G, direct I/O)" | tee -a "$DD_LOG"
    echo "  设备: $SELECTED_DEV_PATH  $PCIe_INFO" | tee -a "$DD_LOG"
    echo "  理论带宽: ${THEO_BW_MB} MB/s" | tee -a "$DD_LOG"
    echo "  时间: $(date)" | tee -a "$DD_LOG"
    echo "========================================" | tee -a "$DD_LOG"

    # 动态计算测试大小：取可用空间80%与5GB的较小值，最小100MB
    AVAIL_BYTES=$(df -B1 --output=avail "$TEST_MOUNT" | tail -1)
    MAX_TEST_BYTES=$((5*1024*1024*1024))
    SAFE_BYTES=$(echo "$AVAIL_BYTES * 0.8 / 1" | bc)
    if [ "$SAFE_BYTES" -lt $((100*1024*1024)) ]; then
        echo "❌ 可用空间不足 100MB，无法测试" | tee -a "$DD_LOG"
        umount "$TEST_MOUNT"
        rmdir "$TEST_MOUNT" 2>/dev/null
        exit 1
    fi
    if [ "$SAFE_BYTES" -gt "$MAX_TEST_BYTES" ]; then
        TEST_COUNT=5120
    else
        TEST_COUNT=$(echo "$SAFE_BYTES / 1048576" | bc)
    fi
    TEST_SIZE_GB=$(echo "scale=1; $TEST_COUNT / 1024" | bc)
    echo "可用空间: $(df -h --output=avail "$TEST_MOUNT" | tail -1 | tr -d ' '), 测试大小: ${TEST_SIZE_GB}GB" | tee -a "$DD_LOG"

    echo "▶ 写入测试中 (${TEST_SIZE_GB}GB) ..." | tee -a "$DD_LOG"
    sync
    WRITE_START=$(date +%s%N)
    dd if=/dev/zero of="$TEST_FILE" bs=1M count=$TEST_COUNT oflag=direct conv=fdatasync 2>&1 | tee -a "$DD_LOG"
    WRITE_END=$(date +%s%N)
    WRITE_TIME=$(echo "scale=2; ($WRITE_END - $WRITE_START) / 1000000000" | bc)
    WRITE_SPEED=$(echo "scale=2; $TEST_COUNT / $WRITE_TIME" | bc)

    echo "▶ 读取测试中 (${TEST_SIZE_GB}GB) ..." | tee -a "$DD_LOG"
    sync
    READ_START=$(date +%s%N)
    dd if="$TEST_FILE" of=/dev/null bs=1M iflag=direct 2>&1 | tee -a "$DD_LOG"
    READ_END=$(date +%s%N)
    READ_TIME=$(echo "scale=2; ($READ_END - $READ_START) / 1000000000" | bc)
    READ_SPEED=$(echo "scale=2; $TEST_COUNT / $READ_TIME" | bc)

    echo "" | tee -a "$DD_LOG"
    echo "═══ 测试结果 ═══" | tee -a "$DD_LOG"
    echo "写入速度: ${WRITE_SPEED} MB/s" | tee -a "$DD_LOG"
    echo "读取速度: ${READ_SPEED} MB/s" | tee -a "$DD_LOG"

    rm -f "$TEST_FILE"
    analyze_dd "$WRITE_SPEED" "$READ_SPEED"
fi

# --- 性能压测 (fio) ---
if [ "$TEST_TYPE" == "2" ]; then
    if ! fio --version &>/dev/null; then
        echo "❌ fio 不可用，请先安装"
        umount "$TEST_MOUNT"
        rmdir "$TEST_MOUNT" 2>/dev/null
        exit 1
    fi

    > "$FIO_LOG"
    > "$CPU_LOG"
    > "$IOSTAT_LOG"

    # 动态调整测试大小：取可用空间80%与配置SIZE的较小值
    CFG_SIZE_BYTES=$(echo "$SIZE" | sed 's/G/*1073741824/; s/M/*1048576/; s/K/*1024/' | bc)
    AVAIL_BYTES=$(df -B1 --output=avail "$TEST_MOUNT" | tail -1)
    SAFE_SIZE_BYTES=$(echo "$AVAIL_BYTES * 0.8 / 1" | bc)
    if [ "$SAFE_SIZE_BYTES" -lt $((100*1024*1024)) ]; then
        echo "❌ 可用空间不足 100MB" | tee -a "$FIO_LOG"
        umount "$TEST_MOUNT"
        rmdir "$TEST_MOUNT" 2>/dev/null
        exit 1
    fi
    if [ "$SAFE_SIZE_BYTES" -lt "$CFG_SIZE_BYTES" ]; then
        SIZE="$(echo "$SAFE_SIZE_BYTES / 1073741824" | bc)G"
        echo "⚠️ 可用空间不足，测试大小自动调整为 $SIZE" | tee -a "$FIO_LOG"
    fi

    TEST_FILE="${TEST_MOUNT}/fio_testfile"

    start_cpu_monitor() {
        vmstat 1 > "$CPU_LOG" 2>&1 &
        CPU_MON_PID=$!
    }
    stop_cpu_monitor() {
        [ -n "$CPU_MON_PID" ] && kill $CPU_MON_PID 2>/dev/null
        wait $CPU_MON_PID 2>/dev/null
    }

    start_iostat_monitor() {
        iostat -x 1 > "$IOSTAT_LOG" 2>&1 &
        IOSTAT_PID=$!
    }
    stop_iostat_monitor() {
        [ -n "$IOSTAT_PID" ] && kill $IOSTAT_PID 2>/dev/null
    }

    run_fio_test() {
        local name="$1" rw="$2" bs="$3" iodepth="$4" numjobs="$5" extra="$6"
        local json_file="${FIO_JSON_DIR}/${name}.json"   # 固定名覆盖
        printf "  ▶ %-12s ... " "$name" | tee -a "$FIO_LOG" >&2
        fio --name="$name" --filename="$TEST_FILE" --ioengine=libaio --direct=1 \
            --rw="$rw" --bs="$bs" --iodepth="$iodepth" --numjobs="$numjobs" \
            --size="$SIZE" --runtime="$RUNTIME" --time_based --group_reporting \
            --output-format=json --output="$json_file" $extra >> /dev/null 2>&1
        if [ $? -eq 0 ]; then
            echo "完成" | tee -a "$FIO_LOG" >&2
            echo "$json_file"
        else
            echo "失败" | tee -a "$FIO_LOG" >&2
            return 1
        fi
    }

    extract_results() {
        local json="$1"
        local rb=$(jq '.jobs[0].read.bw_bytes // 0' "$json")
        local wb=$(jq '.jobs[0].write.bw_bytes // 0' "$json")
        local ri=$(jq '.jobs[0].read.iops // 0' "$json")
        local wi=$(jq '.jobs[0].write.iops // 0' "$json")
        local rb_mb=$(echo "scale=0; $rb / 1048576" | bc)
        local wb_mb=$(echo "scale=0; $wb / 1048576" | bc)
        local ri_int=$(printf "%.0f" "$ri")
        local wi_int=$(printf "%.0f" "$wi")
        local ru=$(echo "scale=1; if($rb_mb > 0) $rb_mb * 100 / $THEO_BW_MB else 0" | bc)
        local wu=$(echo "scale=1; if($wb_mb > 0) $wb_mb * 100 / $THEO_BW_MB else 0" | bc)
        echo "$rb_mb $wb_mb $ri_int $wi_int $ru $wu"
    }

    echo "╔══════════════════════════════════════════╗" | tee -a "$FIO_LOG"
    echo "║     RK3588 NVMe 性能压测                ║" | tee -a "$FIO_LOG"
    echo "╚══════════════════════════════════════════╝" | tee -a "$FIO_LOG"
    echo "  设备: $SELECTED_DEV_PATH  $PCIe_INFO" | tee -a "$FIO_LOG"
    echo "  理论带宽: ${THEO_BW_MB} MB/s" | tee -a "$FIO_LOG"
    echo "  时间: $(date)" | tee -a "$FIO_LOG"
    echo "" | tee -a "$FIO_LOG"

    start_cpu_monitor
    start_iostat_monitor
    sleep 2

    tests=(
        "seq-write   write     1M   32  2  "
        "seq-read    read      1M   64  2  "
        "rand-read   randread  4K   32  4  "
        "rand-write  randwrite 4K   32  4  "
        "rand-rw     randrw    4K   16  2  --rwmixread=70"
    )

    printf "%-12s %8s %8s %9s %9s %8s %8s\n" "测试项" "读MB/s" "写MB/s" "读IOPS" "写IOPS" "读利用%" "写利用%" | tee -a "$FIO_LOG"
    printf "%-12s %8s %8s %9s %9s %8s %8s\n" "────────────" "────────" "────────" "─────────" "─────────" "────────" "────────" | tee -a "$FIO_LOG"

    for test in "${tests[@]}"; do
        read -r name rw bs iodepth numjobs extra <<< "$test"
        json=$(run_fio_test "$name" "$rw" "$bs" "$iodepth" "$numjobs" "$extra")
        if [ $? -eq 0 ]; then
            read -r rb wb ri wi ru wu <<< $(extract_results "$json")
            printf "%-12s %8s %8s %9s %9s %7s%% %7s%%\n" "$name" "$rb" "$wb" "$ri" "$wi" "$ru" "$wu" | tee -a "$FIO_LOG"
        else
            printf "%-12s %8s %8s %9s %9s %8s %8s\n" "$name" "失败" "失败" "失败" "失败" "失败" "失败" | tee -a "$FIO_LOG"
        fi
    done

    stop_cpu_monitor
    stop_iostat_monitor

    echo "" | tee -a "$FIO_LOG"
    echo "═══ 平均资源占用 ═══" | tee -a "$FIO_LOG"

    if [ -s "$CPU_LOG" ]; then
        avg_cpu=$(awk 'NR>1 {sum += 100 - $15; count++} END {if(count>0) printf "%.1f", sum/count; else print "0"}' "$CPU_LOG")
        echo "CPU 平均使用率: ${avg_cpu}%" | tee -a "$FIO_LOG"
    fi

    if [ -s "$IOSTAT_LOG" ]; then
        util_avg=$(grep "$SELECTED_DEV " "$IOSTAT_LOG" | awk '{print $NF}' | awk '{sum+=$1; count++} END {if(count>0) printf "%.1f", sum/count; else print "0"}')
        echo "NVMe 平均 %util: ${util_avg}%" | tee -a "$FIO_LOG"
    fi

    rm -f "$TEST_FILE"
    echo "✅ 已清理 fio 临时测试文件" | tee -a "$FIO_LOG"

    analyze_fio
fi

# --- SSD 写满测试 ---
if [ "$TEST_TYPE" == "3" ]; then
    > "$FULL_LOG"
    exec > >(tee -a "$FULL_LOG") 2>&1
    echo "╔══════════════════════════════════════════╗"
    echo "║       SSD 写满测试                      ║"
    echo "╚══════════════════════════════════════════╝"
    echo "  设备: $SELECTED_DEV_PATH  $PCIe_INFO"
    echo "  时间: $(date)"

    TEST_DIR="${TEST_MOUNT}/testdir"
    mkdir -p "$TEST_DIR"
    BLOCK_SIZE="10M"
    MIN_FREE=104857600
    total_bytes=0
    file_count=0
    start_time=$(date +%s)

    while true; do
        avail=$(df -B1 --output=avail "$TEST_MOUNT" | tail -1)
        if [ "$avail" -lt "$MIN_FREE" ]; then
            echo "[$(date '+%H:%M:%S')] 剩余空间不足 100MB，写入停止。"
            break
        fi
        file_name="$TEST_DIR/fill_${file_count}.tmp"
        if dd if=/dev/urandom of="$file_name" bs="$BLOCK_SIZE" count=1 status=none 2>>"$FULL_LOG"; then
            total_bytes=$((total_bytes + 10*1024*1024))
            file_count=$((file_count + 1))
            if [ $((file_count % 100)) -eq 0 ]; then
                written_mb=$((total_bytes/1024/1024))
                echo "[$(date '+%H:%M:%S')] 已写入 ${written_mb} MiB ($file_count 个文件)"
            fi
        else
            echo "[$(date '+%H:%M:%S')] 写入失败，停止。"
            break
        fi
    done

    end_time=$(date +%s)
    elapsed=$((end_time - start_time))
    total_mb=$((total_bytes/1024/1024))
    if [ $elapsed -gt 0 ]; then
        avg_speed=$(echo "scale=2; $total_mb / $elapsed" | bc)
    else
        avg_speed="0"
    fi

    echo ""
    echo "═══ 测试结果 ═══"
    echo "  共创建 $file_count 个文件"
    echo "  写入总量: $total_mb MiB ($((total_mb/1024)) GiB)"
    echo "  耗时: ${elapsed}s"
    echo "  平均写入速度: ${avg_speed} MiB/s"
    df -h "$TEST_MOUNT"

    echo ""
    echo "正在删除测试文件..."
    rm -rf "$TEST_DIR"
    echo "✅ 测试文件已删除，磁盘空间已恢复。"
    df -h "$TEST_MOUNT"

    analyze_full "$total_mb" "$elapsed" "$avg_speed"
fi

# ---------- 卸载与清理 ----------
umount "$TEST_MOUNT" 2>/dev/null && echo "卸载成功" || echo "卸载失败，请手动卸载 $TEST_MOUNT"
rmdir "$TEST_MOUNT" 2>/dev/null

# 如果创建了测试分区，询问是否删除（正常退出路径）
if [ "$PART_CREATED" -eq 1 ] && [ -n "$CLEANUP_PART_NUM" ] && [ "$CLEANUP_DONE" -eq 0 ]; then
    echo ""
    echo "┌─────────────────────────────────────────┐"
    echo "│  测试分区 $PART_PATH 是本次测试创建的   │"
    echo "│  删除后将恢复原始磁盘分区布局           │"
    echo "└─────────────────────────────────────────┘"
    read -p "是否删除测试分区 $PART_PATH？(Y/n): " DEL_PART
    if [[ ! "$DEL_PART" =~ ^[Nn]$ ]]; then
        echo "正在删除分区 $PART_PATH ..."
        parted -s "$SELECTED_DEV_PATH" rm "$CLEANUP_PART_NUM" 2>/dev/null && \
            echo "✅ 分区 $PART_PATH 已删除" || \
            echo "⚠️ 删除分区失败，请手动处理: parted $SELECTED_DEV_PATH rm $CLEANUP_PART_NUM"
    else
        echo "保留分区 $PART_PATH"
    fi
    CLEANUP_DONE=1
fi

echo ""
echo "测试全部完成。"
