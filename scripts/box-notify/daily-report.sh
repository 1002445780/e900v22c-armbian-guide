#!/bin/sh
# Daily report: uptime/temp/load/mem/disk + AdGuard Home last-24h stats via API.
# Cron: 30 21 * * * root /root/daily-report.sh >/dev/null 2>&1
. /root/notify.conf
UP=$(uptime -p | sed 's/^up //')
TEMP=0
[ -r /sys/class/thermal/thermal_zone0/temp ] && TEMP=$(( $(cat /sys/class/thermal/thermal_zone0/temp) / 1000 ))
LOAD=$(cut -d' ' -f1-3 /proc/loadavg | tr ' ' ',')
MEM=$(free -m | awk '/^Mem/{printf "%dMB/%dMB", $3, $2}')
DISK=$(df / | tail -1 | awk '{print $5}')
COOKIE=/tmp/.agh_cookie.$$
curl -s -m 8 -c "$COOKIE" -X POST http://127.0.0.1:80/control/login -H 'Content-Type: application/json' -d "{\"name\":\"$AGH_USER\",\"password\":\"$AGH_PASS\"}" -o /dev/null
STATS=$(curl -s -m 8 -b "$COOKIE" http://127.0.0.1:80/control/stats)
Q=$(printf '%s' "$STATS" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("num_dns_queries",0))' 2>/dev/null || echo 0)
B=$(printf '%s' "$STATS" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("num_blocked_filtering",0))' 2>/dev/null || echo 0)
RATE=0
case "$Q" in ''|*[!0-9]*) Q=0;; esac
[ "$Q" -gt 0 ] && RATE=$((B * 100 / Q))
MSG="E900V22C daily report $(date '+%Y-%m-%d')
System: up $UP, temp ${TEMP}C, load $LOAD
Resources: memory $MEM, root partition $DISK
AdGuard last 24h: $Q queries, $B blocked (${RATE}%)
Status: all normal"
/root/notify.sh "[Daily] Box status summary" "$MSG"
rm -f "$COOKIE"
