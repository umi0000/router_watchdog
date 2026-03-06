#!/usr/bin/env bash
# Router Watchdog (enhanced)
# 运行在 Ubuntu VM 上，用于检测网络并通过 SSH 重启 ImmortalWrt 接口

set -u   # 如果使用未定义变量则报错（避免脚本隐性 bug）

# ================= 配置区 =================

ROUTER_IP="192.168.0.1"      # 路由器 IP
ROUTER_USER="root"           # SSH 用户
ROUTER_IFACE="wwan24"        # 要重启的接口名

# ping 探测目标（任意一个成功即认为网络正常）
PING_TARGETS=("223.5.5.5" "114.114.114.114")

PING_COUNT=2                 # 每次 ping 发包数
PING_TIMEOUT=1               # 每个 ping 等待时间（秒）

FAIL_THRESHOLD=5             # 连续失败多少次后触发接口重启

FAST_CHECK_INTERVAL=3        # 离线后快速检测间隔（秒）

COOLDOWN_SECONDS=300         # 接口重启冷却时间

LOCK_FILE="/tmp/router_watchdog.lock"
STATE_FILE="/tmp/router_watchdog.state"

LOG_FILE="/var/log/router_watchdog.log"

# =========================================


# ---------------- 日志函数 ----------------
# 统一日志输出格式
log() {
    echo "$(date '+%F %T') $1" | tee -a "$LOG_FILE"
}


# ---------------- 网络检测函数 ----------------
# 尝试 ping 多个目标，只要一个成功就认为网络正常
check_net() {

    for ip in "${PING_TARGETS[@]}"; do

        if ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$ip" >/dev/null 2>&1; then
            return 0    # 成功
        fi

    done

    return 1            # 全部失败
}


# ---------------- 冷却时间检测 ----------------
# 判断是否还在“重启冷却期”
in_cooldown() {

    # 如果锁文件不存在，说明没有进入过冷却期
    [ -f "$LOCK_FILE" ] || return 1

    # 获取锁文件修改时间（上一次重启接口的时间）
    local last
    last=$(stat -c %Y "$LOCK_FILE" 2>/dev/null || echo 0)

    # 当前时间
    local now
    now=$(date +%s)

    # 如果当前时间 - 上次重启时间 < 冷却时间
    # 则仍然处于冷却期
    [ $((now - last)) -lt "$COOLDOWN_SECONDS" ]
}



# ================= 主逻辑 =================


# 第一次检测网络（正常 cron 调用时只执行一次）
if check_net; then

    # 网络正常 → 清空失败计数
    rm -f "$STATE_FILE"

    log "Network OK"

    exit 0
fi


# 如果执行到这里，说明网络已经失败
log "Network check failed -> entering fast detection mode"



# ---------------- 快速检测循环 ----------------
# 掉线后每 3 秒检测一次
while true
do

    # 读取当前失败次数
    fail_count=0
    [ -f "$STATE_FILE" ] && fail_count=$(cat "$STATE_FILE")

    fail_count=$((fail_count + 1))
    echo "$fail_count" > "$STATE_FILE"

    log "Fail count: $fail_count / $FAIL_THRESHOLD"


    # ---------------- 网络恢复检测 ----------------
    # 如果网络恢复
    if check_net; then

        log "Network recovered"

        rm -f "$STATE_FILE"

        exit 0
    fi


    # ---------------- 是否达到重启阈值 ----------------
    if [ "$fail_count" -ge "$FAIL_THRESHOLD" ]; then

        # 达到阈值后清零计数
        rm -f "$STATE_FILE"


        # 冷却期检查
        if in_cooldown; then

            log "Cooldown active, skip interface restart"

            exit 0
        fi


        # ---------------- 执行接口重启 ----------------

        log "Restarting router interface: $ROUTER_IFACE"

        # 写入锁文件（记录本次重启时间）
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
    fi


    # ---------------- 快速检测间隔 ----------------
    # 每 3 秒检测一次
    sleep "$FAST_CHECK_INTERVAL"

done