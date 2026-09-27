#!/usr/bin/env bash
# Widget Preview 预览桥（一键）：让 WSL 侧（Playwright / 浏览器）能访问 Windows 上的预览页。
#
# 为什么需要：`flutter widget-preview start --web-server` 的页面里写死了
# `ws://127.0.0.1:<DTD端口>`；WSL 里的浏览器连不到 Windows 的 127.0.0.1 → 白屏。
# 本脚本自动：① Windows 侧把 dart 的 loopback 端口在 0.0.0.0 再监听一份（纯用户态，
# 无需管理员/UAC）② WSL 侧用 socat 把 127.0.0.1:<port> 接到 Windows。
#
# 用法（在 Ayla/flutter 下）：
#   bash tool/preview-bridge.sh              # 自动桥接全部 dart loopback 端口
#   bash tool/preview-bridge.sh --stop       # 停止桥（Windows 侧 node + WSL 侧 socat）
#
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
WIN_DIR="$(wslpath -w "$PWD")"
NODE='E:\nodejs\node.exe'

win_ip() {
  powershell.exe -NoProfile -Command \
    "(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { \$_.IPAddress -notlike '127.*' -and \$_.IPAddress -notlike '169.254*' -and \$_.InterfaceAlias -like 'WLAN*' } | Select-Object -First 1 -ExpandProperty IPAddress)" \
    2>/dev/null | tr -d '\r'
}

if [ "${1:-}" = "--stop" ]; then
  taskkill.exe /F /IM node.exe >/dev/null 2>&1 || true
  pkill -f "socat TCP-LISTEN" >/dev/null 2>&1 || true
  echo "preview bridge stopped"
  exit 0
fi

IP="$(win_ip)"
[ -z "$IP" ] && { echo "无法获取 Windows WLAN IP"; exit 1; }
echo "Windows IP: $IP"

# 1) Windows 侧：探测 dart 端口（含已在跑的预览服务）
PORTS_JSON="$(timeout 60 cmd.exe /c "cd /d $WIN_DIR && $NODE tool\\preview-bridge.mjs detect" 2>/dev/null | tr -d '\r' | tail -1)"
WEB_PORT_DETECTED="$(echo "$PORTS_JSON" | sed -n 's/.*"web":\([0-9]*\).*/\1/p')"
PORTS="$(echo "$PORTS_JSON" | sed -n 's/.*"all":\[\([^]]*\)\].*/\1/p' | tr -d '"' | tr ',' ' ')"
[ -z "$PORTS" ] && { echo "未发现 dart 监听端口（widget-preview 起了吗？先跑 tool/preview-up.sh）"; exit 1; }
echo "dart ports: $PORTS${WEB_PORT_DETECTED:+   (web=$WEB_PORT_DETECTED)}"

# 2) Windows 侧：起桥（隐藏窗口，纯用户态）
PORTS_CSV="$(echo "$PORTS" | tr ' ' ',')"
powershell.exe -NoProfile -Command \
  "Start-Process -WindowStyle Hidden -FilePath '$NODE' -ArgumentList @('tool\\preview-bridge.mjs','start','$(echo "$PORTS" | sed "s/ /','/g")') -WorkingDirectory '$WIN_DIR'" \
  >/dev/null 2>&1
echo "Windows-side bridges started (ports: $PORTS_CSV)"

# 2) WSL 侧：为每个端口起 socat 跳板
pkill -f "socat TCP-LISTEN" >/dev/null 2>&1 || true
for p in $PORTS; do
  nohup socat "TCP-LISTEN:$p,reuseaddr,fork" "TCP:$IP:$p" >/tmp/socat-$p.log 2>&1 &
done
sleep 2

# 3) 校验 + 输出可访问地址
echo "--- check ---"
for p in $PORTS; do
  code=$(curl -s --max-time 4 -o /dev/null -w "%{http_code}" "http://127.0.0.1:$p/" 2>/dev/null)
  echo "  127.0.0.1:$p -> ${code:-fail}"
done
echo
echo "预览页（web 端口见 flutter 输出的 'is being served at'）："
echo "  WSL/Playwright:  http://$IP:<web端口>/"
echo "  Windows Chrome:  http://localhost:<web端口>/"
