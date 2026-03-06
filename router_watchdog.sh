#!/usr/bin/env bash
# Router Watchdog (with cooldown protection)
# Run on Ubuntu VM

set -u

# ================= 配置区 =================
ROUTER_IP="192.168.0.1"
ROUTER_USER="root"
ROUTER_IFACE="wwan24"

#ping参数
PING_TARGETS=("223.5.5.5" "114.114.114.114")
PING_COUNT=2
PING_TIMEOUT=2

#失败阈值，达到后才执行重启，避免偶尔的网络波动导致频繁重启
FAIL_THRESHOLD=5
COOLDOWN_SECONDS=300        # 冷却时间（秒），5 分钟

#文件
LOCK_FILE="/tmp/router_watchdog.lock"
LOG_FILE="/var/log/router_watchdog.log"
# =========================================

log() {
    echo "$(date '+%F %T') $1" | tee -a "$LOG_FILE"
}

check_net() {
    for ip in "${PING_TARGETS[@]}"; do
        if ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$ip" >/dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}

in_cooldown() {
    [ -f "$LOCK_FILE" ] || return 1
    local last
    last=$(stat -c %Y "$LOCK_FILE" 2>/dev/null || echo 0)
    local now
    now=$(date +%s)
    [ $((now - last)) -lt "$COOLDOWN_SECONDS" ]
}

# ================= 主逻辑 =================

if check_net; then
    log "Network OK"
    exit 0
fi

log "Network check failed"

# 连续失败控制（基于状态文件）
STATE_FILE="/tmp/router_watchdog.state"
fail_count=0

[ -f "$STATE_FILE" ] && fail_count=$(cat "$STATE_FILE")
fail_count=$((fail_count + 1))
echo "$fail_count" > "$STATE_FILE"

log "Fail count: $fail_count / $FAIL_THRESHOLD"

if [ "$fail_count" -lt "$FAIL_THRESHOLD" ]; then
    exit 0
fi

# 达到失败阈值，清零计数
rm -f "$STATE_FILE"

# 冷却期判断
if in_cooldown; then
    log "Cooldown active, skip interface restart"
    exit 0
fi

log "Restarting router interface: $ROUTER_IFACE"

touch "$LOCK_FILE"

ssh -o ConnectTimeout=5 \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=no \
    ${ROUTER_USER}@${ROUTER_IP} \
    "ifdown ${ROUTER_IFACE}; sleep 5; ifup ${ROUTER_IFACE}"

if [ $? -eq 0 ]; then
    log "Interface ${ROUTER_IFACE} restarted successfully"
else
    log "ERROR: Failed to restart interface ${ROUTER_IFACE}"
fi

exit 0
