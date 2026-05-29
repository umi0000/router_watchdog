#!/bin/sh

# 1. 过滤事件：只在接口上线 (ifup) 或 IP 更新 (ifupdate) 时触发
[ "$ACTION" = "ifup" ] || [ "$ACTION" = "ifupdate" ] || exit 0

# 2. 过滤接口：只处理 wwan5 和 wwan24 的事件，其他接口（如 lan）变动直接退出
[ "$INTERFACE" = "wwan5" ] || [ "$INTERFACE" = "wwan24" ] || exit 0

# === 配置区域 ===
API_TOKEN=""
ZONE_ID=""
DOMAIN="" 

# 对应接口的记录 ID
RECORD_ID_5=""
RECORD_ID_24=""
# ==============

# 3. 根据当前触发事件的接口，动态决定要使用的 RECORD_ID
if [ "$INTERFACE" = "wwan5" ]; then
    CURRENT_RECORD_ID=$RECORD_ID_5
elif [ "$INTERFACE" = "wwan24" ]; then
    CURRENT_RECORD_ID=$RECORD_ID_24
fi

# 确保配置了对应的 RECORD_ID，否则退出
[ -z "$CURRENT_RECORD_ID" ] && exit 0

# 4. 获取当前触发接口的 IPv4 地址
# Hotplug 会自动传递 $DEVICE 变量（例如 pppoe-wwan5），我们直接利用它获取 IP
CURRENT_IP=$(ip -4 addr show dev "$DEVICE" 2>/dev/null | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b" | head -n 1)

# 如果没获取到 IP，退出
[ -z "$CURRENT_IP" ] && exit 0

# 5. 将执行动作写入系统日志，方便排错
logger -t CF_DDNS "检测到 $INTERFACE 状态变动 ($ACTION)，准备将 IP 更新为: $CURRENT_IP"

# 6. 发送更新请求到 Cloudflare
curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$CURRENT_RECORD_ID" \
     -H "Authorization: Bearer $API_TOKEN" \
     -H "Content-Type: application/json" \
     --data "{\"type\":\"A\",\"name\":\"$DOMAIN\",\"content\":\"$CURRENT_IP\",\"ttl\":60,\"proxied\":false}" > /dev/null

# 判断 curl 执行是否成功
if [ $? -eq 0 ]; then
    logger -t CF_DDNS "$INTERFACE 域名记录更新成功！"
else
    logger -t CF_DDNS "$INTERFACE 域名记录更新失败，请检查网络或 API 设置。"
fi
