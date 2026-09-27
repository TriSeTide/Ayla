#!/usr/bin/env bash
# 一键起预览环境（开发前第一件事）：预览服务 + CDP Chrome + 可用查看命令。
#
# 设计原则（2026-09-18 事故后重写）：
#   - **单实例**：已在跑就复用；发现多实例先清理（多实例会导致 hot reload 失败/白屏）
#   - **CDP 直连**：Chrome 跑在 Windows 侧并开远程调试端口 → 模型可截图+读元素，无需网络桥
#   - **不干扰用户**：独立 user-data-dir + 固定窗口位置，不 maximize、不抢焦点
#
# 用法（在 Ayla/flutter 下）：
#   bash tool/preview-up.sh           # 起/复用服务 + 起 CDP Chrome + 打印查看命令
#   bash tool/preview-up.sh --stop    # 停服务 + CDP Chrome
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
WIN_DIR="$(wslpath -w "$PWD")"
FLUTTER='E:\flutter-3.47.4\bin\flutter.bat'
NODE='E:\nodejs\node.exe'
CHROME='C:\Program Files\Google\Chrome\Application\chrome.exe'
CDP_PORT=9333
CDP_PROFILE='E:\dev-cache\chrome-cdp'
LOG=/tmp/ayla-preview-server.log

ps() { timeout 60 powershell.exe -NoProfile -Command "$1" 2>/dev/null | tr -d '\r'; }

# ---------- 清理工具 ----------
# ⚠️ 绝不能按 'flutter_tools' 匹配杀 dart.exe——VSCode 的 Dart 语言服务器
#    （language-server）命令行也含该路径，杀掉会中断用户的 IDE 补全/跳转（2026-09-18 事故）。
#    精确特征：预览服务命令行含 widget_preview / preview_scaffold，且不含 language-server。
PREVIEW_FILTER='$_.Name -eq "dart.exe" -and $_.CommandLine -notlike "*language-server*" -and ($_.CommandLine -like "*widget_preview*" -or $_.CommandLine -like "*preview_scaffold*" -or $_.CommandLine -like "*widget-preview*")'
kill_preview_apps() {
  ps "Get-CimInstance Win32_Process | Where-Object { $PREVIEW_FILTER } | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force -ErrorAction SilentlyContinue }" >/dev/null
  pkill -f "socat TCP-LISTEN" >/dev/null 2>&1 || true
  # 兜底：清理 flutter_tools 的 snapshot 进程（仅当它确实在跑 widget preview 时）
  ps "Get-CimInstance Win32_Process -Filter \"Name='dart.exe'\" | Where-Object { \$_.CommandLine -like '*flutter_tools.snapshot*' -and \$_.CommandLine -like '*preview*' -and \$_.CommandLine -notlike '*language-server*' } | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force -ErrorAction SilentlyContinue }" >/dev/null
}
kill_cdp_chrome() {
  ps "Get-CimInstance Win32_Process -Filter \"Name='chrome.exe'\" | Where-Object { \$_.CommandLine -like '*chrome-cdp*' } | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force -ErrorAction SilentlyContinue }" >/dev/null
}

if [ "${1:-}" = "--stop" ]; then
  kill_preview_apps; kill_cdp_chrome
  echo "预览服务与 CDP Chrome 已停"
  exit 0
fi

# ---------- 1) 服务（优先复用；健康时绝不动任何进程） ----------
detect_web() {
  timeout 60 cmd.exe /c "cd /d $WIN_DIR && $NODE tool\\preview-bridge.mjs detect" 2>/dev/null \
    | tr -d '\r' | tail -1 | sed -n 's/.*"web":\([0-9]*\).*/\1/p'
}

WEB_PORT="$(detect_web)"
if [ -n "$WEB_PORT" ]; then
  # PowerShell 的 curl 包装会把状态码带引号输出 → 去掉引号再比
  BOOT="$(timeout 15 cmd.exe /c "curl -s -o nul -w \"%{http_code}\" http://127.0.0.1:$WEB_PORT/flutter_bootstrap.js" 2>/dev/null | tr -d '\r\"' | tail -1)"
  if [ "$BOOT" = "200" ]; then
    echo "[1/4] 复用已在运行的预览服务（web=$WEB_PORT，健康）"
  else
    echo "[1/4] 端口 $WEB_PORT 有监听但页面不健康（boot=$BOOT）→ 清理后重启"
    kill_preview_apps; sleep 3; WEB_PORT=""
  fi
fi

if [ -z "$WEB_PORT" ]; then
  echo "[1/4] 启动 widget-preview（首次约 40~70s）..."
  rm -f "$LOG"
  nohup cmd.exe /c "cd /d $WIN_DIR && $FLUTTER widget-preview start --web-server" >"$LOG" 2>&1 &
  for _ in $(seq 1 60); do
    sleep 4
    WEB_PORT="$(grep -o 'is being served at http://localhost:[0-9]*' "$LOG" 2>/dev/null | tail -1 | grep -o '[0-9]*$')"
    [ -n "${WEB_PORT:-}" ] && break
  done
  [ -z "$WEB_PORT" ] && { echo "启动失败，日志尾部："; tail -15 "$LOG"; exit 1; }
  for _ in $(seq 1 30); do
    grep -q "Done loading previews" "$LOG" 2>/dev/null && break
    sleep 4
  done
  echo "[1/4] 服务就绪（web=$WEB_PORT）"
fi

# ---------- 2) CDP Chrome（模型看界面用，独立实例不打扰用户） ----------
echo "[2/4] 起 CDP Chrome（端口 $CDP_PORT，独立 profile）..."
ALIVE="$(timeout 15 cmd.exe /c "curl -s -o nul -w \"%{http_code}\" http://127.0.0.1:$CDP_PORT/json/version" 2>/dev/null | tr -d '\r' | tail -1)"
if [ "$ALIVE" = "200" ]; then
  echo "      CDP 已在运行，复用"
else
  ps "Start-Process '$CHROME' -ArgumentList '--remote-debugging-port=$CDP_PORT','--user-data-dir=$CDP_PROFILE','--app=http://localhost:$WEB_PORT/','--window-size=1400,900','--window-position=40,40','--no-first-run','--no-default-browser-check'" >/dev/null
  sleep 8
fi

# ---------- 3) 健康检查 ----------
echo "[3/4] 健康检查..."
BOOT="$(timeout 15 cmd.exe /c "curl -s -o nul -w \"%{http_code}\" http://127.0.0.1:$WEB_PORT/flutter_bootstrap.js" 2>/dev/null | tr -d '\r' | tail -1)"
INFO="$(timeout 60 cmd.exe /c "cd /d $WIN_DIR && $NODE tool\\cdp-look.mjs info" 2>/dev/null | tr -d '\r' | tail -1)"
echo "      web=$WEB_PORT boot=${BOOT:-fail}"
echo "      cdp=$INFO"

# ---------- 4) 用法 ----------
cat <<EOF
[4/4] 就绪：
  人看（大窗口）：http://localhost:$WEB_PORT/
  模型看（截图）：cmd.exe /c "cd /d $WIN_DIR && $NODE tool\\cdp-look.mjs shot E:\\path\\out.png"
  模型读元素：    cmd.exe /c "cd /d $WIN_DIR && $NODE tool\\cdp-look.mjs eval \"document.title\""
  停：bash tool/preview-up.sh --stop

⚠️ 改代码后若画面不更新：hot reload 可能失败（多实例/超时）→ 跑一次 --stop 再跑本脚本完整重启
EOF
