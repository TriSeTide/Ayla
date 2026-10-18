/// 直播播放地址归一 —— 把 HLS/FLV 地址收敛到「当前 API 同源」。
///
/// ## 为什么需要（2026-10-18 用户实报：手机/电脑 App 直播一直转圈，web 正常）
/// 后端把 `hls_url` / `flv_url` 拼成 `SRS_PLAY_URL` 的**绝对地址**，
/// 生产是独立拉流入口 `https://live.trise.top:7882`（frp 隧道 → 本机 nginx 8443）。
///
/// 实测（Windows + media_kit/mpv，ffmpeg mbedTLS）：
/// ```
/// ffmpeg: tcp: Successfully connected to 47.108.85.223 port 7882
/// ffmpeg: tcp: ffurl_read returned 0xffffd8ba
/// ffmpeg: tls: mbedtls_ssl_handshake returned -0x4e
/// stream: Failed to open https://live.trise.top:7882/live/<key>.m3u8
/// ```
/// 该端口在本机/部分网络下 TLS 握手被中间设备直接重置（浏览器走 BoringSSL/系统栈
/// 能过，所以 web 一直正常）；Android ExoPlayer / iOS AVPlayer 同属原生栈，同样受影响。
///
/// 而同一个流经**应用同源**（`https://s.ayla.trise.top:26211/live/...` → nginx `/live/`
/// → SRS 8089）实测可正常起播（mpv 位置推进到 23.8s，分段持续加载）。
///
/// ## 规则（刻意保守）
/// - 只重写**直播流路径** `/live/<name>.m3u8|flv|ts`，其它 URL 一律原样返回；
/// - 只在**显式配置了远端 API**（`--dart-define=AYLA_API_BASE=...`）时重写：
///   本地开发（默认 `127.0.0.1:8100`）没有 `/live/` 反代，重写会把能播的地址改坏；
/// - 已经是同源（scheme/host/port 全等）→ 原样返回，不做无谓改动；
/// - 保留 query（SRS 的 `hls_ctx` 是播放会话上下文，丢了要重新协商）。
library;

import 'api_endpoint.dart';

/// 直播流路径（SRS：`/live/<stream_key>.m3u8|.flv|.ts`）。
final RegExp _liveStreamPath = RegExp(r'^/live/[^/]+\.(?:m3u8|flv|ts)$');

/// 把 [url] 归一到 [apiBase] 同源；不满足条件时原样返回。
///
/// [apiBase] / [configured] 仅供测试注入；生产不传，读 [aylaApiBase] /
/// [aylaUsesConfiguredApiBase]。
String aylaNormalizeLivePlayUrl(
  String url, {
  String? apiBase,
  bool? configured,
}) {
  final String raw = url.trim();
  if (raw.isEmpty) return url;
  final bool useRemote = configured ?? aylaUsesConfiguredApiBase;
  if (!useRemote) return url;
  final Uri? parsed = Uri.tryParse(raw);
  if (parsed == null || !parsed.hasScheme) return url;
  if (!_liveStreamPath.hasMatch(parsed.path)) return url;
  final Uri base = Uri.parse(apiBase ?? aylaApiBase());
  if (!base.hasScheme || base.host.isEmpty) return url;
  if (parsed.scheme == base.scheme &&
      parsed.host == base.host &&
      parsed.port == base.port) {
    return url;
  }
  return Uri(
    scheme: base.scheme,
    host: base.host,
    port: base.hasPort ? base.port : null,
    path: parsed.path,
    query: parsed.hasQuery ? parsed.query : null,
  ).toString();
}
