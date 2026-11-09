#!/bin/sh
# usage: notify.sh "title" "content"  -> sends to configured channel(s)
# channels are read from /root/notify.conf (WeCom webhook and/or pushplus)
TITLE="$1"; CONTENT="$2"
python3 - "$TITLE" "$CONTENT" <<'PYEOF'
import json, sys, urllib.request

title, content = sys.argv[1], sys.argv[2]
conf = {}
for line in open('/root/notify.conf'):
    line = line.strip()
    if '=' in line and not line.startswith('#'):
        k, v = line.split('=', 1)
        conf[k.strip()] = v.strip()

def post(url, payload):
    data = json.dumps(payload).encode()
    req = urllib.request.Request(url, data=data, headers={'Content-Type': 'application/json'})
    return urllib.request.urlopen(req, timeout=10).read().decode()[:150]

results = []

token = conf.get('PUSHPLUS_TOKEN', '')
if token:
    try:
        r = post('https://www.pushplus.plus/send',
                 {'token': token, 'title': title, 'content': content, 'template': 'txt'})
        results.append('pushplus: ' + r)
    except Exception as e:
        results.append('pushplus failed: ' + str(e))

wtype = conf.get('WEBHOOK_TYPE', '').lower()
wurl = conf.get('WEBHOOK_URL', '')
if wurl:
    full = title + '\n' + content
    try:
        if wtype == 'wecom':
            r = post(wurl, {'msgtype': 'text', 'text': {'content': full}})
        elif wtype == 'dingtalk':
            r = post(wurl, {'msgtype': 'text', 'text': {'content': full}})
        elif wtype == 'feishu':
            r = post(wurl, {'msg_type': 'text', 'content': {'text': full}})
        else:
            r = post(wurl, {'title': title, 'content': content})
        results.append('webhook(' + (wtype or 'generic') + '): ' + r)
    except Exception as e:
        results.append('webhook failed: ' + str(e))

if not results:
    print('no channel configured (PUSHPLUS_TOKEN / WEBHOOK_URL both empty), not sent')
else:
    for r in results:
        print(r)
PYEOF
