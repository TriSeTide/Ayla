/// 直播播放地址归一 —— 把直播流地址收敛到「真正的拉流入口」。
///
/// ## 当前结论（2026-11-01 实测，**推翻 2026-10-18 的判断**）
///
/// 旧结论（见文末「历史」）把拉流失败归因于「mbedTLS 与 live.trise.top:7882 的
/// 兼容性问题」，并据此把地址改写成 API 同源（樱花 s.ayla.trise.top:26211）。
/// **这是误判。** 2026-11-01 逐层实测确认真实根因是**阿里云 ICP 备案过滤器**：
/// TLS ClientHello 的 SNI 只要含 trise.top 就被中间设备直接 RST。
///
/// 证据（同一条流、同一台机器、同一时段，只改 SNI）：
///
/// | 目标 | 客户端 | 结果 |
/// | --- | --- | --- |
/// | live.trise.top:7882 | curl(schannel) | failed to receive handshake |
/// | live.trise.top:7882 | Dart/boringssl | Connection terminated during handshake |
/// | live.trise.top:7882 | mpv/ffmpeg | mbedtls_ssl_handshake returned -0x4e |
/// | 47.108.85.223:7882（裸 IP，无 SNI） | openssl / Dart / mpv | **TLS 握手成功** |
///
/// 所以问题不在 mbedTLS，也不在证书（证书链完整有效，Let's Encrypt 签发）；
/// 只要不发 SNI 就一切正常。裸 IP 直连天然不发 SNI ⇒ 不触发过滤。
///
/// ## 证书（同一时间实测）
///
/// 47.108.85.223:7882 出示的是 Let's Encrypt 证书：
/// CN=trise.top，SAN 为 *.trise.top / s.ayla.trise.top / trise.top。
/// 用 IP 连接必然 hostname mismatch —— **但 mpv 侧不构成障碍**：随 App 打包的
/// ffmpeg（20230924 mbedTLS 构建）默认 **不做证书校验**。实测
/// https://expired.badssl.com / self-signed.badssl.com / wrong.host.badssl.com
/// 三个「必坏」证书全部握手通过，即默认等价 tls_verify=0。
/// 反过来把校验打开（stream-lavf-o tls_verify=1）会**连 example.com 都握手失败**
/// （该构建没有可用的系统 CA 源；tls-ca-file 指向导出的 Windows 根证书也返回
/// mbedtls_x509_crt_parse_file ... returned 2）⇒ **本构建无法启用真校验**。
///
/// 结论：Windows 侧裸 IP 直连**开箱可用**，不需要（也无法）配 CA。播放器侧只做一件事：
/// 在 lavf 层声明 verifyhost=live.trise.top，让「万一将来换成默认开启校验的 ffmpeg」
/// 时比对的是证书真正覆盖的主机名，而不是必然不匹配的 IP。
/// 见 lib/player/platforms/media_kit_impl.dart。
///
/// ## 移动端边界（本期不改拉流路径）
///
/// Android ExoPlayer / iOS AVPlayer 走系统 TLS 栈，**默认强制校验**证书。
/// 实测 Dart/boringssl 对裸 IP 报 CERTIFICATE_VERIFY_FAILED: IP address mismatch。
/// 移动端没有等价于 mpv verifyhost 的「只覆盖主机名、仍验链」入口
/// （network_security_config 只能整站放行或按证书指纹，没有「改主机名比对」），
/// 所以 **移动端继续走 API 同源（樱花）**，等 volx 换上带 IP:47.108.85.223 SAN 的
/// 证书后再切裸 IP。用户主要在 Windows 看直播，本期以此落地。
///
/// ## 历史（2026-10-18 当时的记录，结论已被上面推翻，保留以备追溯）
///
/// 后端把 hls_url / flv_url 拼成 SRS_PLAY_URL 的**绝对地址**，
/// 生产是独立拉流入口 https://live.trise.top:7882（frp 隧道 → 本机 nginx 8443）。
/// 当时 mpv 日志：
///
///     ffmpeg: tcp: Successfully connected to 47.108.85.223 port 7882
///     ffmpeg: tcp: ffurl_read returned 0xffffd8ba
///     ffmpeg: tls: mbedtls_ssl_handshake returned -0x4e
///
/// 当时判断为「时有时无的 TLS 重置」而绕道樱花；现在知道它就是 SNI 过滤，
/// 绕过它的正确方式是**不发 SNI**（裸 IP），而不是换 Origin。
///
/// ## 规则
/// - 只重写**直播流路径** `/live/<name>.m3u8|flv|ts`，其它 URL 一律原样返回；
/// - **Windows（media_kit/mpv）**：始终重写到 volx 裸 IP，不依赖
///   aylaUsesConfiguredApiBase —— 本地开发即使没有 /live/ 反代也无害
///   （原本就播不了的地址，重写后依然播不了，不会把能播的改坏）；
/// - **移动端 / Web**：保持原行为（配置了远端 API 才收敛到 API 同源，樱花）；
/// - 已经是目标 origin → 原样返回，不做无谓改动；
/// - 保留 query（SRS 的 hls_ctx 是播放会话上下文，丢了要重新协商）。
library;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;

import 'api_endpoint.dart';

/// volx 拉流入口（裸 IP 直连）；可用
/// `--dart-define=AYLA_LIVE_PULL_HOST=...` 覆盖。
///
/// 为什么要 IP 而不是域名：见文件头（SNI 含 trise.top 会被 ICP 过滤器 RST）。
const String kAylaVolxPullHost = String.fromEnvironment(
  'AYLA_LIVE_PULL_HOST',
  defaultValue: '47.108.85.223',
);

/// 端口原始值（`--dart-define=AYLA_LIVE_PULL_PORT=...`）；解析见 [kAylaVolxPullPort]。
const String kAylaVolxPullPortRaw = String.fromEnvironment(
  'AYLA_LIVE_PULL_PORT',
  defaultValue: '7882',
);

/// volx 拉流端口。
///
/// [String.fromEnvironment] 只能在编译期取到字符串；Dart 不允许在 const 上下文里把
/// 它 parse 成 int，所以这里是 top-level final（编译期常量 + 一次解析）。
/// 非法值（空串 / 非数字 / 越界）回落到默认 7882，绝不抛异常。
final int kAylaVolxPullPort = _parsePort(kAylaVolxPullPortRaw);

int _parsePort(String raw) {
  final int? parsed = int.tryParse(raw.trim());
  if (parsed == null || parsed <= 0 || parsed > 65535) return 7882;
  return parsed;
}

/// 证书真正覆盖的主机名（SAN *.trise.top 命中 live.trise.top）。
///
/// 只用于播放器 lavf 层的 verifyhost：裸 IP 与证书的 IP SAN 天然不匹配，
/// 声明它等于「仍然按域名校验证书，只是不按 IP 比」。
const String kAylaVolxPullSniHost = 'live.trise.top';

/// 直播流路径（SRS：`/live/<stream_key>.m3u8|.flv|.ts`）。
final RegExp _liveStreamPath = RegExp(r'^/live/[^/]+\.(?:m3u8|flv|ts)$');

/// 当前端是否走 volx 裸 IP 直连。
///
/// 只有 Windows 的播放内核（media_kit/mpv）能在证书 hostname 不匹配时继续工作；
/// ExoPlayer / AVPlayer / 浏览器都强制校验 ⇒ 那三者保持 API 同源（樱花）。
/// 移动端待 volx 换 IP SAN 证书后再切，见文件头「移动端边界」。
bool aylaUsesVolxPullDirect() {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.windows;
}

/// [host] 是否就是 volx 拉流入口（幂等判定用）。
bool aylaIsVolxPullHost(String host) => host == kAylaVolxPullHost;

/// 把 [url] 收敛到该端应使用的拉流入口；不满足条件时原样返回。
///
/// [apiBase] / [configured] 仅供测试注入；生产不传，读 [aylaApiBase] /
/// [aylaUsesConfiguredApiBase]。移动端/Web 分支沿用 2026-10-18 的旧行为。
String aylaNormalizeLivePlayUrl(
  String url, {
  String? apiBase,
  bool? configured,
}) {
  final String raw = url.trim();
  if (raw.isEmpty) return url;
  final Uri? parsed = Uri.tryParse(raw);
  if (parsed == null || !parsed.hasScheme) return url;
  if (!_liveStreamPath.hasMatch(parsed.path)) return url;

  // ---- Windows：volx 裸 IP（与是否配置了远端 API 无关）----
  if (aylaUsesVolxPullDirect()) {
    // 已经是 volx 且 scheme/port 正确 ⇒ 幂等返回，不做无谓改写。
    if (parsed.scheme == 'https' &&
        parsed.host == kAylaVolxPullHost &&
        parsed.port == kAylaVolxPullPort) {
      return url;
    }
    return Uri(
      scheme: 'https',
      host: kAylaVolxPullHost,
      port: kAylaVolxPullPort,
      path: parsed.path,
      query: parsed.hasQuery ? parsed.query : null,
    ).toString();
  }

  // ---- 移动端 / Web：沿用旧行为（配置了远端 API 才收敛到 API 同源）----
  final bool useRemote = configured ?? aylaUsesConfiguredApiBase;
  if (!useRemote) return url;
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
