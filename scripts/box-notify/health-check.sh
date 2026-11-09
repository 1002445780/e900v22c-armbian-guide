#!/bin/sh
# Health check: container alive / DNS resolution / temperature / load / disk / memory.
# Cron: */5 * * * * root /root/health-check.sh >/dev/null 2>&1
# Pushes on entering abnormal state, 30-min cooldown while abnormal, one "recovered" push.
. /root/notify.conf
STATE=/var/tmp/box-health.state
issues=''
docker ps --format '{{.Names}}' 2>/dev/null | grep -qx adguardhome || issues="$issues
- AdGuard Home container not running"
if ! dig @127.0.0.1 www.baidu.com +time=3 +tries=1 +short 2>/dev/null | grep -q .; then
  issues="$issues
- Local DNS resolution failed (AdGuard port 53)"
fi
tempc=0
[ -r /sys/class/thermal/thermal_zone0/temp ] && tempc=$(( $(cat /sys/class/thermal/thermal_zone0/temp) / 1000 ))
[ "$tempc" -ge "$TEMP_MAX" ] && issues="$issues
- CPU temperature too high: ${tempc}C"
load=$(cut -d' ' -f2 /proc/loadavg)
heavy=$(awk -v l="$load" -v m="$LOAD_MAX" 'BEGIN{print (l>m)?1:0}')
[ "$heavy" = 1 ] && issues="$issues
- Load too high: $load"
usep=$(df / | tail -1 | awk '{print $5}' | tr -d '%')
[ "$usep" -ge "$DISK_MAX" ] && issues="$issues
- Root partition usage ${usep}%"
avail=$(free -m | awk '/^Mem/{print $7}')
[ "$avail" -le "$MEM_MIN" ] && issues="$issues
- Available memory only ${avail}MB"
now=$(date +%s)
last=0
[ -f "$STATE" ] && last=$(cat "$STATE" 2>/dev/null || echo 0)
if [ -n "$issues" ]; then
  if [ $((now - last)) -ge 1800 ]; then
    /root/notify.sh "[Alert] E900V22C box abnormal" "Issues found:$(printf '%b' "$issues") (checked at $(date '+%H:%M'))"
    echo "$now" > "$STATE"
  fi
else
  if [ "$last" != "0" ] && [ $((now - last)) -le 3600 ]; then
    /root/notify.sh "[Recovered] E900V22C box back to normal" "All checks passed. Time $(date '+%H:%M')"
  fi
  echo 0 > "$STATE"
fi
