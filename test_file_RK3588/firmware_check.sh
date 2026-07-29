#!/bin/bash
# 固件基础配置检查脚本（已适配 Panthor GPU 和 DDR 频率容错）
# 用法: sudo ./firmware_check.sh --ab       (检查 AB 分区固件)
#       sudo ./firmware_check.sh --recovery  (检查 Recovery 固件)
# 如果不带参数，脚本会交互询问选择固件类型。

set -euo pipefail

# ---------- 颜色 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
PASS="${GREEN}[PASS]${NC}"; FAIL="${RED}[FAIL]${NC}"; WARN="${YELLOW}[WARN]${NC}"
OVERALL_RESULT=0

log_pass() { echo -e "$PASS $1"; }
log_fail() { local msg="${1:-}"; local detail="${2:-}"; echo -e "$FAIL $msg ($detail)"; OVERALL_RESULT=1; }
log_warn() { local msg="${1:-}"; local detail="${2:-}"; echo -e "$WARN $msg ($detail)"; }

# ---------- 固件类型预设 ----------
FIRMWARE_TYPE=""

if [[ $# -ge 1 ]]; then
    case "$1" in
        --ab)        FIRMWARE_TYPE="AB" ;;
        --recovery)  FIRMWARE_TYPE="RECOVERY" ;;
        *) echo "用法: $0 [--ab|--recovery]"; exit 1 ;;
    esac
else
    echo "请选择固件类型:"
    echo "  1) AB 分区固件"
    echo "  2) Recovery 固件"
    read -p "输入 1 或 2: " choice
    case "$choice" in
        1) FIRMWARE_TYPE="AB" ;;
        2) FIRMWARE_TYPE="RECOVERY" ;;
        *) echo "无效选择"; exit 1 ;;
    esac
fi

# ---------- 公共检查项 (两种固件通用) ----------
EXPECTED_MODEL="Seeed Studio Recomputer rk3588 Devkit"
KERNEL_MIN="6.1.115"
EXPECTED_DDR_FREQ="2400000000"
OVERLAYS="recomputer-rk3588-devkit-cam0-rpi-v3 recomputer-rk3588-devkit-cam1-rpi-v3"
KERNEL_CMDLINE_MUST_HAVE="root=UUID="
REQUIRED_MODULES="rknpu mali rk816"

# ---------- 增强检查：内存、CPU、磁盘 ----------
check_memory() {
    local total_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    if [ -n "$total_kb" ]; then
        local total_gb=$(awk "BEGIN {printf \"%.1f\", $total_kb/1024/1024}")
        log_pass "系统内存: ${total_gb}G"
    else
        log_warn "无法获取内存信息"
    fi
}

check_cpu() {
    local model="" cores=0
    model=$(grep -m1 "^Hardware" /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^ *//' || true)
    if [ -z "$model" ]; then
        local impl=$(grep -m1 "CPU implementer" /proc/cpuinfo 2>/dev/null | awk '{print $3}' || true)
        local part=$(grep -m1 "CPU part" /proc/cpuinfo 2>/dev/null | awk '{print $4}' || true)
        if [ -n "$impl" ] && [ -n "$part" ]; then
            model="ARM (implementer=$impl, part=$part)"
        else
            model="Unknown ARM CPU"
        fi
    fi
    cores=$(grep -c "^processor" /proc/cpuinfo 2>/dev/null || true)
    log_pass "CPU: $model ($cores 核)"
}

check_disk_space() {
    local usage=$(df -h / | awk 'NR==2 {print $5}' | tr -d '%')
    local avail=$(df -h / | awk 'NR==2 {print $4}')
    if [ -n "$usage" ]; then
        if [ "$usage" -gt 90 ]; then
            log_fail "根分区空间不足" "已使用 ${usage}%, 可用 ${avail}"
        else
            log_pass "根分区空间: 已用 ${usage}%, 可用 ${avail}"
        fi
    else
        log_warn "无法获取根分区使用情况"
    fi
}

# ---------- 原有检查函数 ----------
check_model() {
    local actual=$(cat /proc/device-tree/model 2>/dev/null | tr -d '\0')
    if [ "$actual" == "$EXPECTED_MODEL" ]; then
        log_pass "设备树型号: $actual"
    else
        log_fail "设备树型号" "预期: $EXPECTED_MODEL, 实际: $actual"
    fi
}

check_partitions() {
    local labels=$(lsblk -o LABEL -n | sort -u)
    if [ "$FIRMWARE_TYPE" == "AB" ]; then
        for lbl in armbi_boota armbi_bootb armbi_roota armbi_rootb armbi_usrdata; do
            if echo "$labels" | grep -qw "$lbl"; then
                log_pass "分区标签 $lbl 存在"
            else
                log_fail "分区标签 $lbl 缺失" "请检查分区表"
            fi
        done
        if grep -Eq "^(UUID=|PARTLABEL=)" /etc/fstab; then
            log_pass "/etc/fstab 使用 UUID/PARTLABEL 挂载"
        else
            log_fail "/etc/fstab 挂载方式" "未使用 UUID 或 PARTLABEL"
        fi
    else  # RECOVERY
        if echo "$labels" | grep -qw "armbi_root"; then
            log_pass "分区标签 armbi_root 存在"
        else
            log_fail "分区标签 armbi_root 缺失" "请检查分区表"
        fi
    fi
}

check_kernel_version() {
    local ver=$(uname -r | cut -d'-' -f1)
    if [ "$(printf '%s\n' "$KERNEL_MIN" "$ver" | sort -V | head -1)" == "$KERNEL_MIN" ]; then
        log_pass "内核版本: $ver >= $KERNEL_MIN"
    else
        log_fail "内核版本: $ver 低于最低要求 $KERNEL_MIN" "请升级内核"
    fi
}

check_kernel_cmdline() {
    local cmdline=$(cat /proc/cmdline)
    if echo "$cmdline" | grep -q "$KERNEL_CMDLINE_MUST_HAVE"; then
        log_pass "内核命令行包含 '$KERNEL_CMDLINE_MUST_HAVE'"
    else
        log_fail "内核命令行缺少 '$KERNEL_CMDLINE_MUST_HAVE'" "请检查引导配置"
    fi
}

check_overlays() {
    local env_file="/boot/armbianEnv.txt"
    if [ ! -f "$env_file" ]; then
        log_warn "armbianEnv.txt 不存在" "CSI overlay 可能未配置（可选）"
        return
    fi
    local overlays_line=$(grep -E "^overlays=" "$env_file" | head -1)
    for ov in $OVERLAYS; do
        if echo "$overlays_line" | grep -qw "$ov"; then
            log_pass "CSI Overlay $ov 已配置"
        else
            log_warn "CSI Overlay $ov 未配置" "如需使用摄像头，请编辑 $env_file"
        fi
    done
}

check_ddr_freq() {
    local freq=$(cat /sys/class/devfreq/dmc/cur_freq 2>/dev/null)
    local avail_freqs=$(cat /sys/class/devfreq/dmc/available_frequencies 2>/dev/null)

    # 先检查支持列表中是否包含期望值
    if [ -n "$avail_freqs" ] && echo "$avail_freqs" | grep -qw "$EXPECTED_DDR_FREQ"; then
        if [ "$freq" == "$EXPECTED_DDR_FREQ" ]; then
            log_pass "DDR 频率: ${freq}Hz"
        else
            log_warn "DDR 当前频率: ${freq:-N/A}Hz" "支持列表包含 ${EXPECTED_DDR_FREQ} Hz，当前值可能因省电策略未满速"
        fi
    else
        # 支持列表不存在或不包含期望值，按原逻辑检查
        if [ "$freq" == "$EXPECTED_DDR_FREQ" ]; then
            log_pass "DDR 频率: ${freq}Hz"
        else
            log_fail "DDR 频率" "预期 $EXPECTED_DDR_FREQ Hz, 实际 ${freq:-N/A}"
        fi
    fi
}

check_hardware_nodes() {
    # NPU
    if [ -f /sys/kernel/debug/rknpu/load ]; then
        log_pass "NPU 设备节点正常"
    else
        log_fail "NPU 设备节点缺失" "请检查 NPU 驱动"
    fi
    # GPU（适配 Panthor 驱动）
    if [ -f /sys/class/devfreq/fb000000.gpu/load ] || [ -f /sys/class/devfreq/fb000000.gpu-panthor/load ]; then
        log_pass "GPU 设备节点正常"
    else
        log_fail "GPU 设备节点缺失" "请检查 GPU 驱动"
    fi
    # CSI 摄像头（警告）
    for dev in /dev/video22 /dev/video31; do
        if [ -e "$dev" ]; then
            log_pass "摄像头节点 $dev 存在"
        else
            log_warn "摄像头节点 $dev 缺失" "如需使用摄像头，请检查 CSI overlay 配置"
        fi
    done
    # NVMe SSD
    if lsblk -dno NAME | grep -q nvme; then
        log_pass "NVMe SSD 已识别"
    else
        log_warn "NVMe SSD 未检测到" "可能未安装"
    fi
    # eMMC
    if lsblk -dno NAME | grep -q mmcblk0; then
        log_pass "eMMC 设备存在 (mmcblk0)"
    else
        log_warn "eMMC 设备缺失 (mmcblk0)" "如果硬件无 eMMC，此为正常"
    fi
}

check_ethernet() {
    local eth_up=""
    eth_up=$(ip -4 a show up scope global 2>/dev/null | grep -v lo)
    if [ -n "$eth_up" ]; then
        local iface=$(echo "$eth_up" | head -1 | awk '{print $2}' | tr -d ':')
        local ip_addr=$(echo "$eth_up" | head -1 | awk '{print $4}')
        log_pass "以太网接口已启用 ($iface: $ip_addr)"
    else
        log_fail "以太网接口未找到或未获取 IP 地址" "请检查网线连接与 DHCP"
    fi
}

check_modules() {
    for mod in $REQUIRED_MODULES; do
        if lsmod | grep -q "^$mod\b"; then
            log_pass "内核模块 $mod 已加载"
        else
            log_warn "内核模块 $mod 未加载" "可能不影响启动，但建议检查"
        fi
    done
}

check_ota_status() {
    if command -v armbian-ota &>/dev/null; then
        local status=$(armbian-ota status 2>/dev/null | grep "Mode:" | awk '{print $2}')
        case "$status" in
            ab|recovery) log_pass "OTA 状态: $status" ;;
            unknown) log_warn "OTA 状态: unknown (未初始化)" "执行 OTA 后将自动生成状态文件" ;;
            *) log_fail "OTA 状态异常" "$status" ;;
        esac
    else
        log_warn "armbian-ota 命令不存在，跳过 OTA 状态检查" "仅限 AB/Recovery 固件"
    fi
}

# ---------- 主流程 ----------
echo "============================================"
echo "  固件基础配置检查 (类型: $FIRMWARE_TYPE)"
echo "============================================"
check_model
check_partitions
check_kernel_version
check_kernel_cmdline
check_memory
check_cpu
check_disk_space
check_overlays
check_ddr_freq
check_hardware_nodes
check_ethernet
check_modules
check_ota_status

echo ""
echo "============================================"
if [ $OVERALL_RESULT -eq 0 ]; then
    echo -e "${GREEN}所有必要检查项通过！${NC}"
else
    echo -e "${RED}存在失败的检查项，请核查配置。${NC}"
fi
echo "============================================"
exit $OVERALL_RESULT
