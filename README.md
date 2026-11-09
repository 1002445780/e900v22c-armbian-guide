# 创维 E900V22C 刷 Armbian + AdGuard Home 完整实战指南

> 实测于 2026-11-09/10，创维 E900V22C（移动定制版，SoC **Amlogic S905L3A**）一次成功。
> 本指南基于真实刷机过程整理，包含大量**搜索引擎里查不到的实测坑与解法**，按本文顺序操作可复现。

## 成果一览

刷完后你得到一台 7×24 低功耗家庭服务器：

- 🛡️ **全家 DNS 广告拦截**：AdGuard Home（Docker），路由器 DHCP 一改全家生效
- 📊 **实时监控网页**：Glances，CPU/内存/磁盘/温度，手机电脑都能看
- 📲 **微信告警 + 每日日报**：盒子挂了/过热自动推企业微信，每天 21:30 推统计摘要
- 🌐 **出门远程访问**：Tailscale 组网，不开任何公网端口
- 🔄 **免维护闭环**：断电自恢复、Docker 日志封顶、每月自动重启使安全补丁生效
- ⚡ **功耗约 3W**，年电费约 15 元，比路由器还省

## 设备信息

| 项目 | 规格 |
|------|------|
| SoC | Amlogic S905L3A / S905L3A-B（4×Cortex-A53 @ 1.8GHz） |
| 内存/存储 | 2GB DDR4 / 8GB eMMC |
| 有线网口 | 10/100M（够用） |
| WiFi | 紫光 UWE5621DS，**Armbian 下无驱动，必须用有线** |
| Armbian DTB 编号 | **304** = `meson-g12a-s905l3a-e900v22c.dtb` |
| 默认镜像 | ophub/amlogic-s9xxx-armbian（本指南实测 bookworm server 6.12.114-ophub） |

## 准备清单

- 一台与盒子**同一局域网**的电脑（Windows，本指南以 Windows + PowerShell 5.1 为准）
- **两个 U 盘**：一个做 Armbian 启动盘（≥4GB），一个普通 U 盘传文件（可复用）
- 工具：[platform-tools (adb)](https://dl.google.com/android/repository/platform-tools-latest-windows.zip)
- 镜像：[ophub releases](https://github.com/ophub/amlogic-s9xxx-armbian/releases) 选 `bookworm` server 版（≈837MB）
  - ⚠️ 直连 GitHub 不通的网络：用 API 通道下载，见 [常见问题 #1](#faq)

---

## 步骤 1：盒子联网与定位

盒子插网线（或原系统 WiFi），进入 设置→网络设置 记下 IP。

电脑侧定位（ARP 扫描 + 厂商查询）：

```powershell
arp -a                                 # 看局域网在线设备
# 创维设备 MAC OUI 查询：https://api.macvendors.com/A0:4C:0C
```

实测中创维盒子 MAC 前缀为 `A0:4C:0C`（Shenzhen Skyworth Digital）。

## 步骤 2：开启 ADB —— ⚠️ 新固件锁死 ADB 的解法

移动定制**新版固件没有图形菜单开 ADB**，遥控器快捷键也被封死。解法：**先开 Telnet，再命令行启动 adbd**。

1. 盒子开机进爱家 TV 主界面，遥控器对准盒子：**连按 菜单键 10 次 → 再按 1 次向下键**，屏幕下方出现 `open` 即 Telnet 已开（老固件有效；若无效请搜索 TTL 线刷方案）
2. 电脑连 Telnet（注意**端口是 3000**，不是 23）：

```powershell
# scripts/telnet-cmd.ps1 是一个处理了 Telnet 协议协商的 PowerShell 小工具
.\scripts\telnet-cmd.ps1 -Ip 盒子IP -Port 3000 -CommandText "cd /system/bin;;./adbd &"
```

3. 验证 ADB 并提权：

```powershell
adb connect 盒子IP:5555
adb -s 盒子IP:5555 root        # 本机型的 ro.debuggable=1，可直接提权为 root
```

> ⚠️ 坑：`adb root` 会重启 adbd 导致断连，等几秒重新 `adb connect` 即可。
> ⚠️ 坑：此方法启动的 adbd 是**临时进程**，盒子重启后失效（对我们反而是安全加分项）。

## 步骤 3：备份原厂分区（强烈建议，后悔药）

⚠️ **移动定制版的三码（序列号/MAC/授权）刷机后会丢**，备份是恢复原厂的唯一途径。

实测分区清单（8GB eMMC，共 16 个要备份的分区）：

| 分区 | 大小 | 用途 |
|------|------|------|
| bootloader / boot / recovery / dtbo / vbmeta / logo / env / misc | 2-24MB | 引导与恢复 |
| **skparam / skmac / ctc / cri_data / param** | 4-256MB | **三码与运营商数据（最关键）** |
| system / vendor | 1.25GB / 320MB | 安卓系统 |
| skbackup | 768MB | 创维原厂备份 |

流式备份到电脑（**不占盒子存储**）：

```bat
:: scripts/adb-backup-partitions.bat
:: 小分区裸镜像，大分区 gzip 压缩；注意 dd 后面必须加 2>/dev/null
adb -s 盒子IP:5555 exec-out "dd if=/dev/block/bootloader bs=1048576 2>/dev/null" > bootloader.img
adb -s 盒子IP:5555 exec-out "dd if=/dev/block/system bs=1048576 2>/dev/null | gzip -4" > system.img.gz
```

⚠️ **坑：`adb exec-out` 会把 dd 的 stderr 统计信息（约 91 字节）混进二进制流**，污染镜像。必须在盒子端命令里加 `2>/dev/null`，并用 `blockdev --getsize64 /dev/block/分区名` 逐个校验文件字节数。

⚠️ **坑：skparam 是"活分区"**，系统服务会周期性重写 `sk_syspara`。备份后若校验失败不是数据坏了——重新备份，并在读前/读后各算一次盒子端 `sha256sum`，三者一致才算通过。

## 步骤 4：U 盘引导 Armbian

1. 用 [Rufus](https://rufus.ie) 把 ophub 镜像写入启动 U 盘（或用 `write-usb.ps1` 类似的裸写脚本）
2. U 盘插盒子**靠近电源口的 USB 口**
3. ADB 发引导命令：`adb shell reboot update`
4. 盒子重启跑 Linux 启动码（正常现象），等 2-3 分钟后扫描局域网 22 端口找 Armbian 的新 IP（IP 会变，MAC 不一样了）

## 步骤 5：首次登录

ophub 镜像首次登录是**交互式向导**（创建 root 密码 → 重复密码 → 选 shell → 创建普通用户）：

- 密码自定；shell 选 `1`（bash）；创建用户一步按 `Ctrl-C` 跳过（无头服务器不需要，跳过后向导不再出现）
- ⚠️ 坑：向导没走完之前**每次登录都会重来**，且在密码提示时发送的任何命令都会被当成密码吃掉——自动化脚本必须在**一个 SSH 会话里连续应答**直到出现 `root@...#` 提示符（参考 `scripts/armbian-exec.ps1`）

## 步骤 6：ddbr 整机备份（第二重保险）

```bash
armbian-ddbr        # 选 b，生成 /ddbr/BACKUP-arm-64-emmc.img.gz（约 2.9GB，gzip 自校验）
```

用 SFTP 拉回电脑存档。恢复原厂：把文件放回 `/ddbr/`，`armbian-ddbr` 选 `r`，输入 `YES`。

## 步骤 7：写入 eMMC —— ⚠️ I/O error 的解法（本机型最大坑）

```bash
armbian-install
# 机型输 304（E900V22C 专属 DTB），文件系统输 1（ext4）
```

⚠️ **高概率报错**：`Error: Input/output error during write on /dev/mmcblk2` —— 这是本机型 eMMC 体质问题（200MHz 高频不稳定）。**解法：DTB 降频**：

```bash
apt-get install -y device-tree-compiler
cd /boot/dtb/amlogic
cp meson-g12a-s905l3a-e900v22c.dtb meson-g12a-s905l3a-e900v22c.dtb.bak
dtc -I dtb -O dts -o m.dts meson-g12a-s905l3a-e900v22c.dtb
# 编辑 m.dts：mmc@ffe07000 节点的 max-frequency = <0xbebc200>（200MHz）改为 <0x2faf080>（50MHz）
dtc -I dts -O dtb -o meson-g12a-s905l3a-e900v22c.dtb m.dts
sync && reboot
# 重启后再跑 armbian-install，一次成功
```

50MHz 对 DNS 服务器用途毫无影响（瓶颈在网络不在磁盘）。写入成功后 `poweroff` → **拔 U 盘** → 重新上电，盒子从 eMMC 启动。

## 步骤 8：静态 IP + 固定 MAC

⚠️ **坑：Armbian 每次启动生成随机 MAC，导致 DHCP 每次分配不同 IP**。DNS 服务器必须固定：

```bash
nmcli connection modify "Wired connection 1" \
  ipv4.method manual ipv4.addresses 192.168.0.2/24 ipv4.gateway 192.168.0.1 \
  ipv4.dns "223.5.5.5 119.29.29.29" \
  802-3-ethernet.cloned-mac-address 盒子当前MAC
nmcli connection up "Wired connection 1"
# 再到路由器做一遍 IP-MAC 绑定双保险
```

## 步骤 9：Docker + AdGuard Home

```bash
curl -fsSL https://get.docker.com -o get-docker.sh   # 被墙则用阿里云源手动装，见 FAQ
sh get-docker.sh --mirror Aliyun

# 53 端口被 systemd-resolved 占用时的处理：
sed -i 's/#DNSStubListener=yes/DNSStubListener=no/' /etc/systemd/resolved.conf
systemctl restart systemd-resolved
rm -f /etc/resolv.conf && ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf

mkdir -p /opt/adguardhome/work /opt/adguardhome/conf
docker run --name adguardhome --restart unless-stopped \
  --log-opt max-size=10m --log-opt max-file=3 \
  -v /opt/adguardhome/work:/opt/adguardhome/work \
  -v /opt/adguardhome/conf:/opt/adguardhome/conf \
  -p 53:53/tcp -p 53:53/udp -p 3000:3000/tcp -p 80:80/tcp \
  -d adguard/adguardhome
```

⚠️ 坑：Docker Hub 直连超时。`/etc/docker/daemon.json` 配多个镜像源，且 `docker.m.daocloud.io` 会卡在最后一层不动，此时**显式**拉取：`docker pull docker.1ms.run/adguard/adguardhome`（实测成功）。

⚠️ `--log-opt` 参数很重要：容器日志默认无上限，不加的话一年能涨几百 MB。浏览器打开 `:3000` 走初始化向导，上游 DNS、拦截规则在后台自行配置。

## 步骤 10：Glances 监控网页 —— ⚠️ 两个坑

```bash
# ⚠️ 坑 1：Debian apt 版 glances(3.3.1) 的网页是空壳——打包政策不带编译好的 glances.js，页面永远空白
# 解法：pip 装官方完整版（自带编译好的前端）：
apt-get install -y python3-pip
pip3 install --break-system-packages glances fastapi uvicorn   # v4 网页模式基于 FastAPI

# ⚠️ 坑 2：glances 默认会同步访问外网查"公网 IP"，墙内环境会把网页服务卡死
# 解法：/etc/glances/glances.conf 写入：
#   [ip]
#   disable=True
#   [cloud]
#   disable=True

# systemd 服务（开机自启）：
cat > /etc/systemd/system/glances-web.service <<'EOF'
[Unit]
Description=Glances Web Dashboard
After=network.target
[Service]
ExecStart=/usr/local/bin/glances -w --port 61208
Restart=always
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload && systemctl enable --now glances-web
```

## 步骤 11：告警推送（cron + 企业微信 webhook）

零常驻内存的方案：cron 每 5 分钟巡检（容器存活/DNS 解析/温度/负载/磁盘/内存），异常时推企业微信群机器人，30 分钟冷却防轰炸；每天 21:30 推日报（含 AdGuard 24h 查询/拦截统计）。

脚本在 [`scripts/box-notify/`](scripts/box-notify/)：
- `notify.conf.example` → 复制为 `/root/notify.conf`，填入你的 webhook key 和阈值
- `notify.sh` / `health-check.sh` / `daily-report.sh` → 拷到盒子 `/root/` 并 `chmod 700`
- `box-notify.cron` → 放到 `/etc/cron.d/`

⚠️ 坑：**不要"每拦一条广告就推一条"**（一天几百条，企业微信限频 20 条/分钟）。聚合推送 + 冷却期才是正确姿势。

⚠️ 坑：告警体系的盲区是"盒子挂了没人报信"——可用 healthchecks.io 等死人开关服务补上（盒子每 5 分钟 curl 报到，失联时服务端反向推送）。

## 步骤 12：Tailscale 远程访问

```bash
curl -fsSL https://tailscale.com/install.sh | sh   # pkgs.tailscale.com 墙内实测可达
tailscale up --accept-dns=false                    # ⚠️ 盒子自己是 DNS 服务器，绝不能让它改 resolv.conf
```

⚠️ 坑：国区应用商店没有 Tailscale APK。解法：**在盒子上走 api.github.com 通道下载**（此通道墙内可达）：

```bash
# 取 releases/latest 里 tailscale-android-universal-*.apk 的 asset id，然后：
curl -L -H "Accept: application/octet-stream" \
  https://api.github.com/repos/tailscale/tailscale-android/releases/assets/<asset_id> \
  -o /root/tailscale.apk
# 局域网分发给手机：
python3 -m http.server 8000    # 手机连家里 WiFi 浏览器开 http://盒子IP:8000/tailscale.apk
```

手机装好后登录同一账号，之后在任何网络访问 `http://100.x.x.x:61208`（监控）和 `http://100.x.x.x`（AdGuard）。

## 步骤 13：免维护收尾

```bash
# Docker 日志全局封顶（daemon.json，新容器生效）：
# "log-driver": "json-file", "log-opts": {"max-size": "10m", "max-file": "3"}

# 每月 1 号 04:00 自动重启（使 unattended-upgrades 的内核补丁生效）：
# systemd timer OnCalendar=*-*-01 04:00:00，重启前先发一条企业微信留痕消息
```

⚠️ eMMC 每周 fstrim 定时器 Armbian 自带，无需配置——长期运行写入性能不衰减。

## <a id="faq"></a>常见问题

| 问题 | 解法 |
|------|------|
| GitHub 直连不通 | 用 API 通道：`curl -L -H "Accept: application/octet-stream" https://api.github.com/repos/<owner>/<repo>/releases/assets/<id>` |
| U 盘引导失败 | 换靠电源侧 USB 口、换 USB2.0 U 盘、重发 `reboot update` |
| 断电后服务会自动恢复吗 | 会，所有服务 systemd enable + 容器 unless-stopped，约 30-60 秒恢复 |
| 想回原厂安卓 | `armbian-ddbr` 选 `r`（前提：做过步骤 6 备份） |
| eMMC 会越用越卡吗 | 不会：DNS 是内存型负载；日志写 zram 不落盘；每周 fstrim 自带 |
| WiFi 能用吗 | 不能，UWE5621DS 无主线驱动，用有线 |
| ADB 会一直开着吗 | 不会：adbd 是手动临时进程，重启即消失；刷完 Armbian 后根本没有 ADB，管理走 SSH |
| 磁盘会满吗 | 各日志均已封顶（journald 自动滚动、Docker 30MB、AGH 90 天保留期自动裁剪） |

## 脚本说明

见 [`scripts/`](scripts/) 目录，均为本次实战中使用过的脚本，已把 IP/密码/key 替换为占位符：

| 脚本 | 用途 |
|------|------|
| `telnet-cmd.ps1` | Windows Telnet 客户端（处理协议协商），用于开启 ADB |
| `armbian-exec.ps1` | SSH 命令执行器（自动处理首次登录向导） |
| `adb-backup-partitions.bat` | 16 分区流式备份（含 stderr 污染修复） |
| `verify-partitions.ps1` | 备份完整性校验（字节 + SHA256 双端比对） |
| `box-notify/*` | 企业微信告警 + 日报全套 |
| `fix-bom.ps1` | 修复 PowerShell 中文脚本编码（见下） |

⚠️ Windows 自动化提醒：**PowerShell 5.1 会把无 BOM 的 UTF-8 中文脚本按 GBK 解析**，导致引号被"吞"而报语法错误。中文 .ps1 文件需先加 UTF-8 BOM（用 `scripts/fix-bom.ps1`），中文 shell 脚本则要用 `[IO.File]::ReadAllBytes` 原始字节 + base64 传输。

## 免责声明

- 刷机有风险，**备份是唯一后悔药**，请务必完成步骤 3 和 6 再动 eMMC
- 三码丢失可能影响运营商售后与 IPTV 功能，备份分区包含完整三码数据
- 本指南仅供学习研究，请遵守当地法律法规

## 致谢与参考

- [ophub/amlogic-s9xxx-armbian](https://github.com/ophub/amlogic-s9xxx-armbian) — Armbian 镜像
- [Calmact/e900v22c](https://github.com/Calmact/e900v22c) — 机型资料汇总（QQ 群 320724049）
- [unifreq/openwrt_packit](https://github.com/unifreq/openwrt_packit) — ddbr 工具原始出处
- [AdGuardTeam/AdGuardHome](https://github.com/AdguardTeam/AdGuardHome) — DNS 拦截服务
- [glances](https://github.com/nicolargo/glances) / [tailscale](https://tailscale.com) / [healthchecks.io](https://healthchecks.io)