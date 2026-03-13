#!/bin/sh

# /usr/bin/ecmp-watchdog.sh
# ===== 可调参数 =====
WAN1_IF="wwan5"
WAN2_IF="wwan24"

WEIGHT1=1
WEIGHT2=1

CHECK_INTERVAL=5
PING_COUNT=1
PING_TIMEOUT=1

FAIL_THRESHOLD=2
RECOVER_THRESHOLD=2

TARGETS="119.29.29.29 223.5.5.5"

STATE_DIR="/var/run/ecmp-watchdog"
PIDFILE="$STATE_DIR/watchdog.pid"
MODEFILE="$STATE_DIR/route.mode"
LOGTAG="ecmp-watchdog"

mkdir -p "$STATE_DIR"

log_msg() {
    logger -t "$LOGTAG" "$*"
}

status_json() {
    ubus call "network.interface.$1" status 2>/dev/null
}

iface_up() {
    [ "$(status_json "$1" | jsonfilter -e '@["up"]' 2>/dev/null)" = "true" ]
}

iface_dev() {
    local sj dev
    sj="$(status_json "$1")"
    dev="$(echo "$sj" | jsonfilter -e '@["l3_device"]' 2>/dev/null)"
    [ -n "$dev" ] || dev="$(echo "$sj" | jsonfilter -e '@["device"]' 2>/dev/null)"
    [ -n "$dev" ] || return 1
    printf '%s\n' "$dev"
}

state_get() {
    [ -f "$STATE_DIR/$1.state" ] && cat "$STATE_DIR/$1.state" || echo "unknown"
}

state_set() {
    echo "$2" > "$STATE_DIR/$1.state"
}

counter_get() {
    [ -f "$STATE_DIR/$1.$2" ] && cat "$STATE_DIR/$1.$2" || echo "0"
}

counter_set() {
    echo "$3" > "$STATE_DIR/$1.$2"
}

probe_iface() {
    local iface dev host

    iface="$1"
    iface_up "$iface" || return 1
    dev="$(iface_dev "$iface")" || return 1

    for host in $TARGETS; do
        ping -n -I "$dev" -c "$PING_COUNT" -W "$PING_TIMEOUT" "$host" >/dev/null 2>&1 && return 0
    done

    return 1
}

update_iface_state() {
    local iface cur ok fail new

    iface="$1"
    cur="$(state_get "$iface")"
    ok="$(counter_get "$iface" ok)"
    fail="$(counter_get "$iface" fail)"

    if ! iface_up "$iface"; then
        state_set "$iface" "down"
        counter_set "$iface" ok 0
        counter_set "$iface" fail 0
        return 0
    fi

    if probe_iface "$iface"; then
        fail=0
        ok=$((ok + 1))

        case "$cur" in
            unhealthy|down)
                if [ "$ok" -ge "$RECOVER_THRESHOLD" ]; then
                    new="healthy"
                else
                    new="unknown"
                fi
                ;;
            *)
                new="healthy"
                ;;
        esac
    else
        ok=0
        fail=$((fail + 1))

        case "$cur" in
            healthy)
                if [ "$fail" -ge "$FAIL_THRESHOLD" ]; then
                    new="unhealthy"
                else
                    new="healthy"
                fi
                ;;
            *)
                if [ "$fail" -ge "$FAIL_THRESHOLD" ]; then
                    new="unhealthy"
                else
                    new="unknown"
                fi
                ;;
        esac
    fi

    counter_set "$iface" ok "$ok"
    counter_set "$iface" fail "$fail"
    state_set "$iface" "$new"
}

set_mode_log() {
    local mode old

    mode="$1"
    old=""
    [ -f "$MODEFILE" ] && old="$(cat "$MODEFILE" 2>/dev/null)"

    if [ "$old" != "$mode" ]; then
        echo "$mode" > "$MODEFILE"
        log_msg "$mode"
    fi
}

apply_single() {
    local dev why

    dev="$1"
    why="$2"

    ip route replace default dev "$dev"
    set_mode_log "route=single dev=$dev $why"
}

apply_ecmp() {
    local dev1 dev2 why

    dev1="$1"
    dev2="$2"
    why="$3"

    ip route replace default \
        nexthop dev "$dev1" weight "$WEIGHT1" \
        nexthop dev "$dev2" weight "$WEIGHT2"

    set_mode_log "route=ecmp dev1=$dev1 weight1=$WEIGHT1 dev2=$dev2 weight2=$WEIGHT2 $why"
}

apply_routes() {
    local dev1 dev2 s1 s2 up1 up2

    dev1="$(iface_dev "$WAN1_IF" 2>/dev/null)"
    dev2="$(iface_dev "$WAN2_IF" 2>/dev/null)"

    s1="$(state_get "$WAN1_IF")"
    s2="$(state_get "$WAN2_IF")"

    up1=0
    up2=0
    iface_up "$WAN1_IF" && up1=1
    iface_up "$WAN2_IF" && up2=1

    if [ "$up1" -eq 1 ] && [ "$up2" -eq 1 ] && \
       [ "$s1" = "healthy" ] && [ "$s2" = "healthy" ] && \
       [ -n "$dev1" ] && [ -n "$dev2" ]; then
        apply_ecmp "$dev1" "$dev2" "both-up both-healthy iface1=$WAN1_IF iface2=$WAN2_IF"
        return 0
    fi

    if [ "$up1" -eq 1 ] && [ "$up2" -eq 0 ] && [ -n "$dev1" ]; then
        apply_single "$dev1" "wan2-down fallback iface=$WAN1_IF state1=$s1 state2=$s2"
        return 0
    fi

    if [ "$up2" -eq 1 ] && [ "$up1" -eq 0 ] && [ -n "$dev2" ]; then
        apply_single "$dev2" "wan1-down fallback iface=$WAN2_IF state1=$s1 state2=$s2"
        return 0
    fi

    if [ "$up1" -eq 1 ] && [ "$up2" -eq 1 ] && [ -n "$dev1" ] && [ -n "$dev2" ]; then
        if [ "$s1" = "down" ] || [ "$s1" = "unhealthy" ]; then
            apply_single "$dev2" "wan1-bad switch-to-wan2 state1=$s1 state2=$s2"
            return 0
        fi

        if [ "$s2" = "down" ] || [ "$s2" = "unhealthy" ]; then
            apply_single "$dev1" "wan2-bad switch-to-wan1 state1=$s1 state2=$s2"
            return 0
        fi
    fi

    if [ "$up1" -eq 1 ] && [ "$up2" -eq 1 ] && [ -n "$dev1" ] && [ -n "$dev2" ]; then
        if [ "$s1" = "healthy" ] && [ "$s2" = "unknown" ]; then
            apply_single "$dev1" "prefer-healthy-wan1 state1=$s1 state2=$s2"
            return 0
        fi

        if [ "$s2" = "healthy" ] && [ "$s1" = "unknown" ]; then
            apply_single "$dev2" "prefer-healthy-wan2 state1=$s1 state2=$s2"
            return 0
        fi
    fi

    if [ "$up1" -eq 1 ] && [ "$up2" -eq 1 ] && [ -n "$dev1" ] && [ -n "$dev2" ] && \
       [ "$s1" != "down" ] && [ "$s1" != "unhealthy" ] && \
       [ "$s2" != "down" ] && [ "$s2" != "unhealthy" ]; then
        apply_ecmp "$dev1" "$dev2" "both-up transient state1=$s1 state2=$s2"
        return 0
    fi

    set_mode_log "route=keep-current iface1=$WAN1_IF state1=$s1 up1=$up1 iface2=$WAN2_IF state2=$s2 up2=$up2"
    return 1
}

run_once() {
    update_iface_state "$WAN1_IF"
    update_iface_state "$WAN2_IF"
    apply_routes
}

start_watchdog() {
    local pid

    if [ -f "$PIDFILE" ]; then
        pid="$(cat "$PIDFILE" 2>/dev/null)"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
        rm -f "$PIDFILE"
    fi

    "$0" loop >/dev/null 2>&1 &
    echo $! > "$PIDFILE"
    log_msg "watchdog-start pid=$(cat "$PIDFILE")"
}

stop_watchdog() {
    local pid

    if [ -f "$PIDFILE" ]; then
        pid="$(cat "$PIDFILE" 2>/dev/null)"
        [ -n "$pid" ] && kill "$pid" 2>/dev/null
        rm -f "$PIDFILE"
        log_msg "watchdog-stop"
    fi
}

loop_watchdog() {
    trap 'rm -f "$PIDFILE"; exit 0' INT TERM EXIT

    while :; do
        run_once
        sleep "$CHECK_INTERVAL"
    done
}

case "$1" in
    once)
        run_once
        ;;
    start)
        start_watchdog
        ;;
    stop)
        stop_watchdog
        ;;
    restart)
        stop_watchdog
        sleep 1
        start_watchdog
        ;;
    loop)
        loop_watchdog
        ;;
    *)
        echo "Usage: $0 {once|start|stop|restart|loop}"
        exit 1
        ;;
esac
