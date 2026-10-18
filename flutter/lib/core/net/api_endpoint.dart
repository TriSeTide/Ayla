/// API / WebSocket / 媒体同源地址的**唯一推导处**。
///
/// ## 为什么需要
/// 旧实现把 `http://127.0.0.1:8100`（Android 模拟器 `10.0.2.2`）散落在
/// `DioClient` / `WsManager` / `LiveWs` / 语音中继 / 媒体签名五处。本地开发没问题，
/// 但 **release 版必须连远端 Ayla 后端**（`https://s.ayla.trise.top:26211`），否则
/// 真机/他人的 Windows 机器根本登录不上。用户本次需求明确要求「各端 release 构建产物
/// 使用远端的 ayla 后端」，因此这里把「服务根地址」收敛为一个可配置常量：
///
/// ```bash
/// flutter build windows --release \
///   --dart-define=AYLA_API_BASE=https://s.ayla.trise.top:26211
/// ```
///
/// ## 默认值的边界（刻意保留本地开发语义）
/// - 未传 `AYLA_API_BASE`：Android 模拟器仍指向 `10.0.2.2:8100`（宿主 loopback 映射），
///   桌面/Web 仍指向 `127.0.0.1:8100` —— `flutter run` 的既有体验一字不变；
/// - 传了 `AYLA_API_BASE`：**所有** HTTP、WS、媒体签名 URL 都改用该 origin
///   （http→ws / https→wss 自动换算），不再有第二处硬编码。
///
/// 该常量只影响「去哪找服务器」，不改变任何接口路径；路径前缀仍固定 `/api/v1`。
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

/// 编译期注入的服务根地址（**不带** `/api/v1`，可带端口；末尾斜杠自动去掉）。
///
/// 例：`--dart-define=AYLA_API_BASE=https://s.ayla.trise.top:26211`
const String kAylaApiBaseOverride = String.fromEnvironment(
  'AYLA_API_BASE',
  defaultValue: '',
);

/// 默认本地后端端口（Ayla daphne；8000 被 Elysium 主进程占用）。
const int kAylaDefaultLocalPort = 8100;

/// 当前生效的服务根地址（scheme://host[:port]，无尾斜杠、无路径）。
String aylaApiBase() {
  final String override = kAylaApiBaseOverride.trim();
  if (override.isNotEmpty) return _stripTrailingSlashes(override);
  if (kIsWeb) return 'http://127.0.0.1:$kAylaDefaultLocalPort';
  if (Platform.isAndroid) return 'http://10.0.2.2:$kAylaDefaultLocalPort';
  return 'http://127.0.0.1:$kAylaDefaultLocalPort';
}

/// 是否显式配置了远端服务（用于诊断/界面展示，不做安全判定）。
bool get aylaUsesConfiguredApiBase => kAylaApiBaseOverride.trim().isNotEmpty;

/// 与 [aylaApiBase] 同源的 WebSocket 根（http→ws / https→wss）。
///
/// 返回形如 `ws://127.0.0.1:8100` / `wss://s.ayla.trise.top:26211`，无尾斜杠。
String aylaWsBase() {
  final Uri base = Uri.parse(aylaApiBase());
  final String scheme = switch (base.scheme.toLowerCase()) {
    'https' => 'wss',
    'http' => 'ws',
    _ => throw StateError('AYLA_API_BASE 只支持 http/https：${base.scheme}'),
  };
  return Uri(
    scheme: scheme,
    host: base.host,
    port: base.hasPort ? base.port : null,
  ).toString();
}

/// 拼接 API 路径（[path] 以 `/` 开头），用于需要**绝对地址**的非 dio 调用
/// （媒体直读、下载、签名 URL 归一）。
String aylaAbsoluteApiUrl(String path) {
  final String p = path.startsWith('/') ? path : '/$path';
  return '${aylaApiBase()}${p.startsWith('/api/') ? '' : '/api/v1'}$p';
}

String _stripTrailingSlashes(String value) {
  String out = value;
  while (out.endsWith('/')) {
    out = out.substring(0, out.length - 1);
  }
  return out;
}
