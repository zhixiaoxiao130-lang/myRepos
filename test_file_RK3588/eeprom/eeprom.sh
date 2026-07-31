#!/bin/bash
# 文件名: eeprom_test.sh
# 功能: EEPROM 读写、清空、SN 写入、只读测试（优化版 - 后台写保护，瞬间出菜单）
# 特性:
#   - 自动检测 gpioset 版本 (v1/v2)，生成正确的写保护开关命令
#   - 使用后台持续拉低 WP 引脚，脚本启动后立刻进入菜单，无需等待
#   - 退出时自动杀掉后台进程，恢复写保护（有外部上拉时可靠恢复高电平）
#   - SN 写入支持合法/非法选择，非法 SN 附带精准警告（低地址风险）
#   - 自动备份仅保留最新一份 (eeprom_backup_latest.bin)
#   - 支持只读测试，安全查看内容
#   - 强制用户指定写入偏移，检测低地址安全区域
#   - 增加 trap 确保 Ctrl+C 退出时也能恢复写保护
# 用法: sudo ./eeprom_test.sh

# ---------- 配置 ----------
BUS_ID=4
DEV_ADDR="0x57"
EEPROM_NODE="/sys/bus/i2c/devices/${BUS_ID}-00${DEV_ADDR#0x}/eeprom"
WP_GPIOCHIP=3
WP_LINE=18
BACKUP_DIR="./backups"
BACKUP_FILE="${BACKUP_DIR}/eeprom_backup_latest.bin"
DEFAULT_SAFE_OFFSET=0x100
HIGH_SAFE_OFFSET=0x200
TEST_DATA="${1:-EEPROM_Test_$(date +%s)}"
LEGAL_SN="rk3588_SN00000001"
ILLEGAL_SN="rk3576_SN00000001"

# ---------- 颜色和图标 ----------
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
PASS_ICON="✅"; FAIL_ICON="❌"; WARN_ICON="⚠️"

# ---------- 检测 gpioset 版本 ----------
detect_gpio_version() {
    if gpioset --version 2>/dev/null | head -1 | grep -q "v2"; then
        GPIO_VERSION=2
    else
        GPIO_VERSION=1
    fi
    echo -e "${GREEN}检测到 gpioset 版本: v${GPIO_VERSION}${NC}"
}
detect_gpio_version

# ---------- 工具函数 ----------
die() { echo -e "${RED}${FAIL_ICON} $1${NC}"; return 1; }
success() { echo -e "${GREEN}${PASS_ICON} $1${NC}"; }
warn() { echo -e "${YELLOW}${WARN_ICON} $1${NC}"; }
show_cmd() { echo -e "${YELLOW}[执行] $1${NC}"; }

# ---------- 全局变量：保存后台 gpioset 进程 PID ----------
WP_PID=""

# ---------- 解除写保护（后台运行，不阻塞）----------
wp_off() {
    # 先清理可能残留的旧进程
    [ -n "$WP_PID" ] && kill "$WP_PID" 2>/dev/null && wait "$WP_PID" 2>/dev/null

    if [ "$GPIO_VERSION" -eq 2 ]; then
        # v2: 使用 -c 指定芯片，后台运行即可持续输出
        show_cmd "gpioset -c ${WP_GPIOCHIP} ${WP_LINE}=0 &"
        gpioset -c "$WP_GPIOCHIP" "$WP_LINE=0" &
        WP_PID=$!
    else
        # v1: 使用 -m signal 后台运行，芯片作为位置参数，不要 -c
        show_cmd "gpioset -m signal ${WP_GPIOCHIP} ${WP_LINE}=0 &"
        gpioset -m signal "$WP_GPIOCHIP" "$WP_LINE=0" &
        WP_PID=$!
    fi
    sleep 0.2  # 确保后台进程已拉起
    echo -e "${GREEN}写保护已解除（后台 PID: $WP_PID），菜单已就绪${NC}"
}

# ---------- 恢复写保护（杀掉后台进程）----------
wp_on() {
    if [ -n "$WP_PID" ] && kill -0 "$WP_PID" 2>/dev/null; then
        show_cmd "kill ${WP_PID} (恢复写保护)"
        kill "$WP_PID" 2>/dev/null
        wait "$WP_PID" 2>/dev/null
    fi
    WP_PID=""
    echo -e "${GREEN}写保护已恢复${NC}"
}

# ---------- 退出清理（确保写保护恢复）----------
cleanup() {
    wp_on
    echo -e "\n${GREEN}脚本已退出，写保护已恢复。${NC}"
}
trap cleanup EXIT

auto_backup() {
    mkdir -p "$BACKUP_DIR"
    echo -n "正在备份 EEPROM 到 ${BACKUP_FILE} ... "
    show_cmd "dd if=${EEPROM_NODE} of=${BACKUP_FILE} bs=1 count=32768"
    if dd if="$EEPROM_NODE" of="$BACKUP_FILE" bs=1 count=32768 status=none 2>/dev/null; then
        echo -e "${GREEN}完成${NC}"
        return 0
    else
        echo -e "${RED}失败${NC}"
        return 1
    fi
}

confirm() {
    local msg="$1"
    read -p "${msg} (输入 yes 继续): " answer
    [ "$answer" == "yes" ]
}

check_safe_zone() {
    local head_data
    show_cmd "dd if=${EEPROM_NODE} bs=1 count=16 | hexdump"
    head_data=$(dd if="$EEPROM_NODE" bs=1 count=16 2>/dev/null | od -A n -t x1 | tr -d ' \n')
    if [[ "$head_data" =~ ^(ff)*$ ]]; then
        success "低地址区域为空，使用安全偏移风险较低"
        return 0
    else
        warn "低地址区域存在非空数据！可能包含 MAC/板卡 ID 等"
        warn "强烈建议使用偏移 >= ${HIGH_SAFE_OFFSET}，避免覆盖系统信息"
        return 1
    fi
}

# ---------- 只读测试 ----------
test_readonly() {
    echo -e "\n${CYAN}===== 只读测试（安全查看） =====${NC}"
    local read_len=256
    show_cmd "dd if=${EEPROM_NODE} bs=1 count=${read_len} | hexdump -C"
    echo "EEPROM 前 ${read_len} 字节内容："
    dd if="$EEPROM_NODE" bs=1 count=$read_len 2>/dev/null | hexdump -C
    success "只读测试完成（未修改任何数据）"
}

# ---------- 读写测试 ----------
test_rw() {
    echo -e "\n${CYAN}===== 读写功能测试 =====${NC}"
    check_safe_zone

    local eeprom_size=$(stat -c%s "$EEPROM_NODE" 2>/dev/null || echo 32768)
    local len=${#TEST_DATA}
    local max_offset=$((eeprom_size - len))
    local recommended_offset=$DEFAULT_SAFE_OFFSET
    [ $? -eq 1 ] && recommended_offset=$HIGH_SAFE_OFFSET

    echo "EEPROM 总大小: $eeprom_size 字节"
    echo -n "请输入写入偏移地址（十六进制，默认 0x$(printf "%x" $recommended_offset)，最大 0x$(printf "%x" $max_offset)）: "
    read offset_str
    offset_str=${offset_str:-0x$(printf "%x" $recommended_offset)}
    local offset=$(($offset_str))
    if [ $offset -lt 0 ] || [ $offset -gt $max_offset ]; then
        die "偏移超出有效范围"; return 1
    fi

    echo ""
    echo -e "${YELLOW}即将执行：${NC}"
    echo "  写入内容: $TEST_DATA"
    echo "  数据长度: $len 字节"
    echo "  写入偏移: 0x$(printf "%x" $offset)"
    if ! confirm "是否继续？"; then echo "已取消"; return 1; fi

    auto_backup || die "备份失败，停止操作"

    show_cmd "echo -n \"${TEST_DATA}\" | dd of=${EEPROM_NODE} bs=1 seek=${offset} count=${len} conv=notrunc"
    echo -n "$TEST_DATA" | dd of="$EEPROM_NODE" bs=1 seek=$offset count=$len conv=notrunc 2>/dev/null
    if [ $? -ne 0 ]; then die "写入失败"; return 1; fi
    sync; sleep 1

    show_cmd "dd if=${EEPROM_NODE} bs=1 skip=${offset} count=${len}"
    local readback
    readback=$(dd if="$EEPROM_NODE" bs=1 skip=$offset count=$len 2>/dev/null)
    echo "读回数据: $readback"
    if [ "$readback" == "$TEST_DATA" ]; then
        success "读写一致，测试通过"; return 0
    else
        die "读写不一致，测试失败"; return 1
    fi
}

# ---------- 全部清空测试 ----------
test_clear() {
    echo -e "\n${CYAN}===== 全部清空测试（擦除为 0xFF）=====${NC}"
    echo -e "${RED}警告：此操作将擦除整个 EEPROM！${NC}"
    if ! confirm "是否继续？"; then echo "已取消"; return 1; fi

    auto_backup || die "备份失败，停止操作"

    local total_bytes=$(stat -c%s "$EEPROM_NODE" 2>/dev/null || echo 32768)
    show_cmd "tr '\\0' '\\377' < /dev/zero | head -c ${total_bytes} | tee ${EEPROM_NODE} > /dev/null"
    if tr '\0' '\377' < /dev/zero | head -c $total_bytes | tee "$EEPROM_NODE" > /dev/null; then
        success "EEPROM 已全部擦除为 0xFF"; return 0
    else
        die "擦除失败"; return 1
    fi
}

# ---------- SN 写入测试（增强版）----------
test_sn() {
    echo -e "\n${CYAN}===== SN 写入测试 =====${NC}"
    echo "请选择 SN 类型："
    echo "  1) 合法 SN  ($LEGAL_SN)"
    echo "  2) 非法 SN  ($ILLEGAL_SN)  ⚠️ 危险！"
    read -p "请输入选项 (1 或 2): " sn_type

    local selected_sn=""
    case "$sn_type" in
        1)
            selected_sn="$LEGAL_SN"
            ;;
        2)
            selected_sn="$ILLEGAL_SN"
            echo -e "\n${RED}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
            echo -e "${RED}${BOLD}║  ⚠️  重要：非法 SN 的风险仅限于低地址区域！              ║${NC}"
            echo -e "${RED}${BOLD}║  - 在偏移 0 附近写入 \"rk3576\" 或 \"35xx\" 等数据会导致    ║${NC}"
            echo -e "${RED}${BOLD}║    板卡被误识别，系统无法启动。                          ║${NC}"
            echo -e "${RED}${BOLD}║  - 在安全偏移（如 0x100）写入任何数据（含非法 SN）是     ║${NC}"
            echo -e "${RED}${BOLD}║    安全的，不会影响系统启动。                            ║${NC}"
            echo -e "${RED}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
            echo -e "${YELLOW}"
            echo "  🔧 若误写入低地址导致无法启动，修复方案："
            echo "     1. 连接设备 UART 串口，打开串口终端工具。"
            echo "     2. 设备上电时，在终端中快速按下 Ctrl+C。"
            echo "        成功进入 U-Boot 后，终端会显示类似 \"=>\" 或 \"rk3588#\" 的提示符。"
            echo "     3. 依次输入以下命令："
            echo -e "     ${GREEN}load mmc 1:1 0x08300000 /boot/dtb-6.1.115-vendor-seeed-rk3588/rockchip/rk3588-recomputer-rk3588-devkit.dtb${NC}"
            echo -e "     ${GREEN}load mmc 1:1 0x00800000 /boot/vmlinuz-6.1.115-vendor-seeed-rk3588${NC}"
            echo -e "     ${GREEN}load mmc 1:1 0x0a200000 /boot/uInitrd-6.1.115-vendor-seeed-rk3588${NC}"
            echo -e "     ${GREEN}booti 0x00800000 0x0a200000:\${filesize} 0x08300000${NC}"
            echo "     4. 系统启动后，运行本脚本，选择「从备份恢复」或「全部清空」"
            echo -e "${NC}"
            ;;
        *)
            echo -e "${RED}无效选项，已取消${NC}"; return 1
            ;;
    esac

    check_safe_zone

    local len=${#selected_sn}
    local eeprom_size=$(stat -c%s "$EEPROM_NODE" 2>/dev/null || echo 32768)
    local max_offset=$((eeprom_size - len))
    local recommended_offset=$DEFAULT_SAFE_OFFSET
    [ $? -eq 1 ] && recommended_offset=$HIGH_SAFE_OFFSET

    echo "SN 内容: $selected_sn (${len} 字节)"
    echo -n "请输入写入偏移地址（十六进制，默认 0x$(printf "%x" $recommended_offset)，最大 0x$(printf "%x" $max_offset)）: "
    read offset_str
    offset_str=${offset_str:-0x$(printf "%x" $recommended_offset)}
    local offset=$(($offset_str))
    if [ $offset -lt 0 ] || [ $offset -gt $max_offset ]; then
        die "偏移超出有效范围"; return 1
    fi

    if [ "$offset" -lt "$DEFAULT_SAFE_OFFSET" ]; then
        echo -e "\n${RED}${BOLD}⚠️  您指定的偏移 0x$(printf "%x" $offset) 位于低地址区域！${NC}"
        echo -e "${RED}写入非法 SN 将导致板卡识别错误，系统无法启动。${NC}"
        if ! confirm "是否仍要继续？"; then echo "已取消"; return 1; fi
    fi

    echo ""
    echo -e "${YELLOW}即将写入 SN：${NC}"
    echo "  内容: $selected_sn"
    echo "  偏移: 0x$(printf "%x" $offset)"
    if ! confirm "是否继续？"; then echo "已取消"; return 1; fi

    auto_backup || die "备份失败，停止操作"

    show_cmd "echo -n \"${selected_sn}\" | dd of=${EEPROM_NODE} bs=1 seek=${offset} count=${len} conv=notrunc"
    echo -n "$selected_sn" | dd of="$EEPROM_NODE" bs=1 seek=$offset count=$len conv=notrunc 2>/dev/null
    if [ $? -ne 0 ]; then die "写入失败"; return 1; fi
    sync; sleep 1

    show_cmd "dd if=${EEPROM_NODE} bs=1 skip=${offset} count=${len}"
    local readback
    readback=$(dd if="$EEPROM_NODE" bs=1 skip=$offset count=$len 2>/dev/null)
    echo "读回数据: $readback"
    if [ "$readback" == "$selected_sn" ]; then
        success "SN 写入成功"; return 0
    else
        die "SN 验证失败"; return 1
    fi
}

# ---------- 从备份恢复 ----------
restore_backup() {
    echo -e "\n${CYAN}===== 从备份恢复 EEPROM =====${NC}"
    if [ ! -f "$BACKUP_FILE" ]; then
        die "备份文件不存在: $BACKUP_FILE"; return 1
    fi
    echo -e "${YELLOW}即将用 ${BACKUP_FILE} 恢复 EEPROM。${NC}"
    if ! confirm "是否继续？"; then echo "已取消"; return 1; fi

    wp_off
    show_cmd "dd if=${BACKUP_FILE} of=${EEPROM_NODE} bs=256 count=128 conv=fsync"
    dd if="$BACKUP_FILE" of="$EEPROM_NODE" bs=256 count=128 conv=fsync status=progress
    sync; sleep 1
    wp_on
    success "恢复完成"
}

# ---------- 主菜单 ----------
main() {
    if [ "$(id -u)" -ne 0 ]; then
        die "请使用 sudo 运行此脚本"; exit 1
    fi
    if [ ! -f "$EEPROM_NODE" ]; then
        die "EEPROM节点不存在: $EEPROM_NODE"; exit 1
    fi

    wp_off

    while true; do
        echo ""
        echo -e "${CYAN}=====================================${NC}"
        echo -e "${CYAN}     EEPROM 测试工具（优化版）${NC}"
        echo -e "${CYAN}=====================================${NC}"
        echo "  1) 读写功能测试（可指定偏移）"
        echo "  2) 全部清空测试（擦除为0xFF）"
        echo "  3) SN 写入测试（合法/非法）"
        echo "  4) 从备份恢复 EEPROM"
        echo "  5) 只读测试（安全查看内容）"
        echo "  q) 退出"
        echo -e "${CYAN}=====================================${NC}"
        read -p "请选择 (1-5, q): " choice

        case $choice in
            1) test_rw ;;
            2) test_clear ;;
            3) test_sn ;;
            4) restore_backup ;;
            5) test_readonly ;;
            q|Q) echo "退出测试工具..."; break ;;
            *) echo -e "${RED}无效选项，请重新输入${NC}" ;;
        esac
    done
}

main "$@"
