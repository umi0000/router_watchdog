# router_watchdog

本仓库包含两套脚本：

- V1: Ubuntu VM 定时检测网络，失败后通过 SSH 重启路由器接口
- V2: OpenWrt 上基于热插拔 + 守护进程的双 WAN（ECMP）健康检查与自动切换

---

## V1: WiFi + DHCP（Ubuntu VM 侧）

脚本路径：

- 仓库内：`V1_wifi-dhcp/router_watchdog.sh`
- 建议安装到：`/usr/local/bin/router_watchdog.sh`

### 1) 安装

```bash
sudo cp V1_wifi-dhcp/router_watchdog.sh /usr/local/bin/router_watchdog.sh
sudo chmod +x /usr/local/bin/router_watchdog.sh
```

### 2) 修改配置

编辑脚本中的以下变量：

- `ROUTER_IP`
- `ROUTER_USER`
- `ROUTER_IFACE`
- `PING_TARGETS`
- `FAIL_THRESHOLD`

### 3) 手动测试（建议先断网试一次）

```bash
sudo /usr/local/bin/router_watchdog.sh
```

查看日志：

```bash
tail -f /var/log/router_watchdog.log
```

### 4) 定时执行（cron）

例如每 2 分钟检测一次：

```bash
sudo crontab -e
```

加入：

```cron
*/2 * * * * /usr/local/bin/router_watchdog.sh
```

---

## V2: PPPoE over WiFi + ECMP（OpenWrt 侧）

相关文件：

- `V2_pppoe-over-wifi/ecmp-load_balance/ecmp-watchdog.sh`
- `V2_pppoe-over-wifi/ecmp-load_balance/99-ecmp`

### 1) 安装到 OpenWrt

```sh
cp ecmp-watchdog.sh /usr/bin/ecmp-watchdog.sh
chmod +x /usr/bin/ecmp-watchdog.sh

cp 99-ecmp /etc/hotplug.d/iface/99-ecmp
chmod +x /etc/hotplug.d/iface/99-ecmp
```

### 2) 修改接口名与参数

在 `/usr/bin/ecmp-watchdog.sh` 中按实际网络调整：

- `WAN1_IF`、`WAN2_IF`
- `WEIGHT1`、`WEIGHT2`
- `TARGETS`
- `FAIL_THRESHOLD`、`RECOVER_THRESHOLD`
- `CHECK_INTERVAL`

### 3) 手动验证

单次检测并应用路由：

```sh
/usr/bin/ecmp-watchdog.sh once
```

启动守护（后台循环检测）：

```sh
/usr/bin/ecmp-watchdog.sh start
```

停止守护：

```sh
/usr/bin/ecmp-watchdog.sh stop
```

查看系统日志（脚本使用 logger 写入）：

```sh
logread -f | grep ecmp-watchdog
```

### 4) 自动触发机制

- 当 `WAN1_IF` 或 `WAN2_IF` 发生 `ifup/ifupdate/ifdown` 事件时，`/etc/hotplug.d/iface/99-ecmp` 会触发 watchdog。
- 正常情况下无需额外 cron。

---

## 注意事项

- V1 依赖 SSH 免密或可自动认证，否则接口重启命令会失败。
- V2 依赖 OpenWrt 的 `ubus`、`jsonfilter`、`ip`、`ping`、`logger`。
- 上线前建议先做断网/弱网演练，确认恢复策略符合预期。