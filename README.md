位置
/usr/local/bin/router_watchdog.sh
手动测试（推荐先断网试一次）
sudo /usr/local/bin/router_watchdog.sh
日志：
tail -f /var/log/router_watchdog.log

定时执行（cron）
例如 每 2 分钟检测一次：
sudo crontab -e
加入：
*/2 * * * * /usr/local/bin/router_watchdog.sh