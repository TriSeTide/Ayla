# 直播拉流改走 volx 裸 IP 直连：SNI 过滤根因与实施记录

> 日期：2026-11-01　范围：Ayla Flutter 客户端（Windows）　状态：已实施，待真机验收
> 相关代码：`Ayla/flutter/lib/core/net/live_play_url.dart`、`Ayla/flutter/lib/player/platforms/media_kit_impl.dart`
> 相关设计：`Ayla/docs/plans/直播性能与稳定性优化-开发文档.md` §4.3

## 1. 结论先说

1. **2026-10-18 的结论是误判。** 当时把 `live.trise.top:7882` 拉流失败归因于
   「mbedTLS 与该端口的 TLS 兼容性问题」，因此把播放地址改写到 API 同源（樱花
   `s.ayla.trise.top:26211`）。真实根因是**阿里云 ICP 备案过滤器按 SNI 拦截**。
2. **裸 IP `https://47.108.85.223:7882` 直连可用**（不发 SNI，不触发过滤）。
3. Windows 侧裸 IP **不需要任何证书特殊配置**即能起播（随包 ffmpeg 默认不校验证书）。
4. 移动端（ExoPlayer / AVPlayer）**本期不动**，继续走樱花；等 volx 换带 IP SAN 的证书再切。

## 2. 根因证据（2026-11-01 实测）

同一条流、同一台机器、同一时段，**只改 SNI**：

| 目标 | 客户端 | 结果 |
| --- | --- | --- |
| `live.trise.top:7882` | curl（schannel） | `failed to receive handshake` |
| `live.trise.top:7882` | Dart / boringssl | `Connection terminated during handshake` |
| `live.trise.top:7882` | mpv / ffmpeg | `tls: mbedtls_ssl_handshake returned -0x4e` |
| `47.108.85.223:7882`（裸 IP，无 SNI） | openssl | 握手成功，证书链完整 |
| `47.108.85.223:7882`（裸 IP，无 SNI） | Dart / boringssl | 握手成功（仅 IP 主机名不匹配） |
| `47.108.85.223:7882`（裸 IP，无 SNI） | mpv / ffmpeg | 握手成功，取到 HTTP 响应 |

关键对照：`curl --resolve live.trise.top:7882:47.108.85.223`（强制真实 IP + 仍发
SNI）**同样失败** ⇒ 排除「DNS 解析到别处」的解释，确认是 SNI 触发拦截。

注意：本机 DNS 把 `live.trise.top` 解析到 `198.18.0.x`（本地代理的 fake-ip 段），
所以直接用域名连接并不能到达真实服务器；这也是必须用裸 IP 的另一个独立原因。

## 3. 证书事实（同一时间实测）

`47.108.85.223:7882` 出示的是 Let's Encrypt 证书：
- `CN = trise.top`
- `SAN = *.trise.top, s.ayla.trise.top, trise.top`（**没有 IP SAN**）

因此用 IP 连接必然 hostname mismatch。各端表现：

| 端 | 默认是否校验证书 | 裸 IP 直连结果 |
| --- | --- | --- |
| Windows mpv（随包 ffmpeg 20230924 mbedTLS） | **不校验** | ✅ 可用 |
| Dart / boringssl | 校验 | ❌ `CERTIFICATE_VERIFY_FAILED: IP address mismatch` |
| Android ExoPlayer | 校验 | ❌ 预期失败（未实测，与 Dart 同属系统栈） |
| iOS AVPlayer | 校验 | ❌ 同上 |

## 4. 一个必须记住的坑：随包 mpv 的证书校验是**关着**的

直接以 FFI 驱动本仓库打包的 `libmpv-2.dll`（`build/windows/x64/runner/Release/`）实测：

- 默认（不加任何 tls 选项）：`https://expired.badssl.com`、
  `https://self-signed.badssl.com`、`https://wrong.host.badssl.com` **全部握手成功**；
- 加上 `stream-lavf-o tls_verify=1` 后：连 `https://example.com` 都
  `mbedtls_ssl_handshake returned -0x2700`；
- 试图用 `tls-ca-file` 指向导出的 Windows 根证书：
  `mbedtls_x509_crt_parse_file for CA cert returned 2`（该构建没有可用 CA 源）。

**结论：这个构建既默认不校验、也无法开启校验。** 所以裸 IP 能连上并不是靠
`tls_verify=0` 生效，而是默认就没有校验。这也意味着：不能声称「已做了证书加固」。

真正加固的前提是 volx 换一张带 `IP:47.108.85.223` SAN 的证书（开发文档 §4.3 方案 A1），
届时应**同时**：
1. 服务器换证书；
2. 客户端移除 `verifyhost` 覆盖；
3. 移动端才能切到裸 IP。

## 5. 已实施的改动

| 文件 | 改动 |
| --- | --- |
| `Ayla/flutter/lib/core/net/live_play_url.dart` | 新增 `kAylaVolxPullHost` / `kAylaVolxPullPort` / `kAylaVolxPullSniHost`、`aylaUsesVolxPullDirect()`、`aylaIsVolxPullHost()`；`aylaNormalizeLivePlayUrl` 按平台分派 |
| `Ayla/flutter/lib/player/platforms/media_kit_impl.dart` | `attach` 中识别 volx URL 后下发 `stream-lavf-o verifyhost=live.trise.top` |
| `Ayla/flutter/test/live_play_url_volx_test.dart` | 新增 12 条契约用例 |

行为矩阵：

| 平台 | 上游地址 | 归一结果 |
| --- | --- | --- |
| Windows | `https://live.trise.top:7882/live/k.m3u8` | `https://47.108.85.223:7882/live/k.m3u8` |
| Windows | 同上 + `?hls_ctx=abc` | 保留 query |
| Windows | 已配置 / 未配置 `AYLA_API_BASE` | **都是 volx**（不再依赖配置） |
| Android / iOS | 配置了远端 API | `https://s.ayla.trise.top:26211/live/...`（樱花，保持不变） |
| Android / iOS | 未配置 | 原样返回（本地开发语义不变） |
| 任意 | 非 `/live/` 路径 | 原样返回 |

覆盖口：`--dart-define=AYLA_LIVE_PULL_HOST=...` / `--dart-define=AYLA_LIVE_PULL_PORT=...`。

## 6. 本期明确**没有**做的事（边界）

1. **移动端仍走樱花**：ExoPlayer / AVPlayer 强制校验，裸 IP 必然失败；
   `network_security_config` 只能整站放行或按证书指纹，没有「覆盖主机名」的等价入口。
2. **没有启用真正的证书校验**：当前 ffmpeg 构建做不到（见 §4）。
3. **没碰服务器 / nginx / frp**：本记录只覆盖客户端。
4. **没有真机端到端验收**：需要一条**正在直播**的频道才能验证 m3u8 真的被播放；
   本次实测用固定 stream key 取到的是 `404 Not Found`（说明 TLS 与 HTTP 层都通了，
   但流本身不在播）。**裸 IP 直连播放成功仍需用户在有直播时点一次确认。**

## 7. 后续待办

- [ ] 有直播时，Windows 客户端确认裸 IP 起播（本记录唯一未闭环项）；
- [ ] volx 换带 `IP:47.108.85.223` SAN 的证书（方案 A1）；
- [ ] 换证后：移除 `verifyhost` 覆盖 + 移动端切裸 IP + 复测；
- [ ] 移动端切换后，移除 `live_play_url.dart` 里的平台分派，统一走 volx。

## 8. 如何复现本次诊断

```bash
# 1) 裸 IP 的证书与链（应为 Let's Encrypt，SAN 只有 *.trise.top）
echo | openssl s_client -connect 47.108.85.223:7882 2>/dev/null \
  | openssl x509 -noout -subject -ext subjectAltName

# 2) 带 SNI 被拦截（应失败）
openssl s_client -connect 47.108.85.223:7882 -servername live.trise.top </dev/null

# 3) mpv 侧默认不校验证书（三个必坏证书都应握手成功）
#    用任意 mpv/ffmpeg 打开 https://expired.badssl.com/ 观察是否出画面
```
