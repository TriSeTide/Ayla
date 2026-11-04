#!/usr/bin/env bash
# Ayla Flutter Windows —— 把 flutter run 的后端绑到**服务器**（而非本机 8100）。
#
# 用法（在 Ayla/flutter 或任意目录）：
#   ./dev-server.sh              # 热重载调试，后端 = 服务器
#   ./dev-server.sh --release    # 额外参数原样透传给 flutter run
#
# 事实源：lib/core/net/api_endpoint.dart —— AYLA_API_BASE 是 HTTP / WS / 媒体签名
# **唯一**的推导处；不传则回落到 127.0.0.1:8100（本地开发语义，一字不变）。
#
# ⚠️ 换后端后**旧 token 会失效**（服务器与本地是两套账号库）：
# 首次进 App 若停在登录页属正常，重新登录即可（401 会自动清 token 并登出）。
set -euo pipefail

cd "$(dirname "$0")"

FLUTTER="${FLUTTER_BIN:-E:/flutter-3.47.4/bin/flutter.bat}"
: "${AYLA_API_BASE:=https://s.ayla.trise.top:26211}"

echo "后端 = $AYLA_API_BASE"
exec "$FLUTTER" run -d windows --dart-define="AYLA_API_BASE=$AYLA_API_BASE" "$@"
