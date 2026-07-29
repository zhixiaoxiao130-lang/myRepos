#!/bin/bash
#=========================================================================
# 4G 联网测试脚本 v2.4 (稳健版)
# 功能：自动检测 4G 模块，显示基本信息，激活数据连接，测试网络延迟
# 用法: sudo ./4g_test.sh [目标地址] [ping次数]
# 默认: 测试 www.baidu.com，发送 20 个包
#=========================================================================

set -uo pipefail   # 不再使用 set -e，避免非关键命令失败退出

# ---------- 参数 ----------
TARGET="${1:-www.baidu.com}"
COUNT="${2:-20}"
APN="3GNET"

# 颜色与格式
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'
SEP="=================================================="

info() { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }
title() { echo -e "${BOLD}${CYAN}$*${NC}"; }

# ---------- 1. 环境准备 ----------
[ "$(id -u)" -ne 0 ] && err "请使用 sudo 运行此脚本"

if ! command -v mmcli &>/dev/null; then
    err "未找到 mmcli，请安装 ModemManager"
fi

if ! systemctl is-active --quiet ModemManager; then
    info "启动 ModemManager..."
    systemctl start ModemManager
    sleep 2
fi

# 查找 Modem
MODEM_NUM=$(mmcli -L 2>/dev/null | grep -oP 'Modem/\d+' | head -1 | grep -oP '\d+' || true)
[ -z "$MODEM_NUM" ] && err "未找到任何 Modem，请检查硬件连接"

# ---------- 2. 收集 4G 模块基本信息 ----------
title "\n$SEP"
title "   4G 模块基本信息"
title "$SEP"

# 使用函数安全获取信息，失败返回 "未知"
safe_get_kv() {
    local key="$1"
    local val
    val=$(mmcli -m "$MODEM_NUM" -K 2>/dev/null | grep "$key" | cut -d: -f2- | xargs 2>/dev/null || true)
    echo "${val:-未知}"
}

MFR=$(safe_get_kv 'modem.generic.manufacturer')
MODEL=$(safe_get_kv 'modem.generic.model')
REV=$(safe_get_kv 'modem.generic.revision')
IMEI=$(safe_get_kv 'modem.3gpp.imei')
STATE=$(safe_get_kv 'modem.generic.state' | awk '{print $1}')
[ -z "$STATE" ] && STATE="未知"
SIGNAL=$(safe_get_kv 'modem.generic.signal-quality.value')
[ -z "$SIGNAL" ] && SIGNAL="N/A"
OPERATOR=$(safe_get_kv 'modem.3gpp.operator-name')
ACCESS_TECH=$(safe_get_kv 'modem.generic.access-technologies')
ICCID=$(safe_get_kv 'modem.sim.iccid')

# 输出基本信息
printf "${BOLD}%-20s${NC} : %s\n" "模块厂商" "$MFR"
printf "%-20s : %s\n" "模块型号" "$MODEL"
printf "%-20s : %s\n" "固件版本" "$REV"
printf "%-20s : %s\n" "IMEI" "$IMEI"
printf "%-20s : %s\n" "SIM ICCID" "$ICCID"
printf "%-20s : ${GREEN}%s${NC}\n" "网络状态" "$STATE"
printf "%-20s : ${CYAN}%s${NC}\n" "运营商" "$OPERATOR"
printf "%-20s : ${YELLOW}%s%%${NC}\n" "信号强度" "$SIGNAL"
printf "%-20s : %s\n" "接入技术" "$ACCESS_TECH"

# ---------- 3. 网络状态检查 ----------
if ! echo "$STATE" | grep -qE "registered|connected"; then
    err "Modem 未就绪，当前状态: $STATE"
fi

# ---------- 4. 激活 / 查找数据承载 ----------
BEARER_ID=""
for bid in 0 1 2; do
    BINFO=$(mmcli -b "$bid" -K 2>/dev/null || true)
    [ -z "$BINFO" ] && continue
    if ! echo "$BINFO" | grep -q 'bearer.status.connected.*yes'; then continue; fi
    BTYPE=$(echo "$BINFO" | grep 'bearer.type' | cut -d: -f2 | xargs || true)
    [ "$BTYPE" != "default" ] && continue
    ADDR=$(echo "$BINFO" | grep 'bearer.ipv4-config.address' | cut -d: -f2 | xargs || true)
    if [ -n "$ADDR" ] && [ "$ADDR" != "--" ]; then
        BEARER_ID=$bid
        break
    fi
done

if [ -z "$BEARER_ID" ]; then
    info "发起数据连接 (APN: $APN)..."
    mmcli -m "$MODEM_NUM" --simple-connect="apn=$APN,ip-type=ipv4" >/dev/null 2>&1 || true
    sleep 4
    for bid in 0 1 2; do
        BINFO=$(mmcli -b "$bid" -K 2>/dev/null || true)
        [ -z "$BINFO" ] && continue
        if ! echo "$BINFO" | grep -q 'bearer.status.connected.*yes'; then continue; fi
        BTYPE=$(echo "$BINFO" | grep 'bearer.type' | cut -d: -f2 | xargs || true)
        [ "$BTYPE" != "default" ] && continue
        ADDR=$(echo "$BINFO" | grep 'bearer.ipv4-config.address' | cut -d: -f2 | xargs || true)
        if [ -n "$ADDR" ] && [ "$ADDR" != "--" ]; then
            BEARER_ID=$bid
            break
        fi
    done
    [ -z "$BEARER_ID" ] && err "无法建立数据连接"
fi

# ---------- 5. 提取网络配置 ----------
BINFO=$(mmcli -b "$BEARER_ID" -K 2>/dev/null || true)
IFACE=$(echo "$BINFO" | grep 'bearer.status.interface' | cut -d: -f2 | xargs || true)
ADDR=$(echo "$BINFO" | grep 'bearer.ipv4-config.address' | cut -d: -f2 | xargs || true)
PREFIX=$(echo "$BINFO" | grep 'bearer.ipv4-config.prefix' | cut -d: -f2 | xargs || true)
GATEWAY=$(echo "$BINFO" | grep 'bearer.ipv4-config.gateway' | cut -d: -f2 | xargs || true)
DNS_LIST=$(echo "$BINFO" | grep 'bearer.ipv4-config.dns.value' | cut -d: -f2- | xargs | tr '\n' ',' | sed 's/,$//' || true)

if [ -z "$IFACE" ] || [ -z "$ADDR" ] || [ -z "$GATEWAY" ]; then
    warn "网络参数不完整，无法继续"
    mmcli -b "$BEARER_ID" 2>/dev/null || true
    exit 1
fi

# ---------- 6. 配置网络 ----------
ip link set "$IFACE" up 2>/dev/null || true
CURRENT_IP=$(ip -4 addr show "$IFACE" 2>/dev/null | grep -oP '(?<=inet\s)\d+\.\d+\.\d+\.\d+' || true)
if [ "$CURRENT_IP" != "$ADDR" ]; then
    info "配置 IP $ADDR/$PREFIX"
    ip addr flush dev "$IFACE" 2>/dev/null || true
    ip addr add "${ADDR}/${PREFIX}" dev "$IFACE" 2>/dev/null || true
fi

if ! ip route show default 2>/dev/null | grep -q "dev $IFACE"; then
    ip route add default via "$GATEWAY" dev "$IFACE" metric 10 2>/dev/null || true
fi

echo -n > /etc/resolv.conf
IFS=',' read -ra DNS_ARR <<< "$DNS_LIST"
for dns in "${DNS_ARR[@]}"; do
    dns=$(echo "$dns" | xargs)
    [ -n "$dns" ] && echo "nameserver $dns" >> /etc/resolv.conf
done

# ---------- 7. 连通性测试 ----------
echo ""
title "$SEP"
title "   网络连通性测试"
title "$SEP"
printf "目标: ${BOLD}%s${NC}   次数: %s   接口: ${CYAN}%s${NC}\n" "$TARGET" "$COUNT" "$IFACE"
echo ""

TMP_PING="/tmp/.4g_ping_$$"
ping -I "$IFACE" -c "$COUNT" "$TARGET" > "$TMP_PING" 2>&1 && PING_RESULT=0 || PING_RESULT=1

# 显示 ping 结果
while IFS= read -r line; do
    if echo "$line" | grep -q "icmp_seq"; then
        seq=$(echo "$line" | sed -n 's/.*icmp_seq=\([0-9]*\).*/\1/p')
        ttl=$(echo "$line" | sed -n 's/.*ttl=\([0-9]*\).*/\1/p')
        time=$(echo "$line" | sed -n 's/.*time=\([0-9.]*\).*/\1/p')
        printf "  ${GREEN}▶${NC} 序号:%-4s TTL:%-4s 延迟:${YELLOW}%-8s${NC} ms\n" "$seq" "$ttl" "$time"
    fi
done < "$TMP_PING"

# 提取统计信息
LOSS=$(grep -oP '\d+(?=% packet loss)' "$TMP_PING" || echo "N/A")
RTT_MIN=$(grep -oP 'rtt min/avg/max/mdev = \K[\d.]+' "$TMP_PING" | cut -d/ -f1 || echo "N/A")
RTT_AVG=$(grep -oP 'rtt min/avg/max/mdev = [\d.]+/\K[\d.]+' "$TMP_PING" || echo "N/A")
RTT_MAX=$(grep -oP 'rtt min/avg/max/mdev = [\d.]+/[\d.]+/\K[\d.]+' "$TMP_PING" || echo "N/A")
RTT_MDEV=$(grep -oP 'rtt min/avg/max/mdev = [\d.]+/[\d.]+/[\d.]+/\K[\d.]+' "$TMP_PING" || echo "N/A")

rm -f "$TMP_PING"

# ---------- 8. 结果汇总 ----------
echo ""
title "$SEP"
title "   测试结果汇总"
title "$SEP"

printf "%-20s : ${GREEN}%s${NC}\n" "最终状态" "已连接"
printf "%-20s : %s\n" "接口/设备" "$IFACE"
printf "%-20s : %s\n" "IP 地址" "$ADDR"
printf "%-20s : %s\n" "子网掩码" "/$PREFIX"
printf "%-20s : %s\n" "网关" "$GATEWAY"
printf "%-20s : %s\n" "DNS" "$(cat /etc/resolv.conf 2>/dev/null | grep nameserver | awk '{print $2}' | tr '\n' ' ')"
printf "%-20s : %s\n" "信号强度" "${SIGNAL}%"
printf "%-20s : %s\n" "运营商" "$OPERATOR"
printf "%-20s : %s%%\n" "丢包率" "${LOSS:-N/A}"
printf "%-20s : ${YELLOW}%s ms${NC}\n" "平均延迟" "${RTT_AVG:-N/A}"
printf "%-20s : %s ms\n" "最小/最大" "${RTT_MIN:-N/A} / ${RTT_MAX:-N/A}"
printf "%-20s : %s ms\n" "抖动" "${RTT_MDEV:-N/A}"

echo ""
if [ $PING_RESULT -eq 0 ]; then
    info "4G 网络测试通过"
else
    warn "4G 网络测试失败"
fi
