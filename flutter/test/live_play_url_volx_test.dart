/// 拉流入口统一契约（`core/net/live_play_url.dart`）。
///
/// ## 2026-11-03 语义变更（用户裁定）
///
/// 用户原话：「全部统一成 s.ayla.trise.top:26211。因为他很快。不需要改写。」
///
/// 旧语义（已停用）：Windows 把 `/live/` 地址重写到 volx 裸 IP（47.108.85.223:7882），
/// 理由是阿里云 ICP 备案过滤器会 RST 掉 SNI 含 trise.top 的握手，而裸 IP 不发 SNI。
///
/// 为什么要停用它（实测）：
/// - 裸 IP 出示的证书 SAN 只有域名（`*.trise.top` / `s.ayla.trise.top` / `trise.top`），
///   **没有 IP** ⇒ 浏览器与 ExoPlayer/AVPlayer 强制校验必然失败；
/// - 只有 mpv/ffmpeg 默认不校验证书 ⇒ 此前**只有 Windows 能靠裸 IP 播**，
///   Web 端直接加载不出来（用户实报「web 端完全加载不出来」）；
/// - 樱花链路实测反而更快：TLS 38ms vs 裸 IP 118ms。
///
/// 新语义：拉流入口由**后端统一下发**（`LIVE_PULL_BASE_URL`），客户端只做
/// 「收敛到 API 同源」这一层。三端拿到的都是 `s.ayla.trise.top:26211`。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/net/live_play_url.dart';

const String kKey = 'be86d4a1deb369a224b9cd4805d1a984b9e6413ba9fe056e';
const String kUpstream = 'https://live.trise.top:7882';
const String kSakuraApi = 'https://s.ayla.trise.top:26211';

void onPlatform(TargetPlatform platform, void Function() body) {
  debugDefaultTargetPlatformOverride = platform;
  try {
    body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('常量仍保留（aylaIsVolxPullHost 等仍需引用）', () {
    expect(kAylaVolxPullHost, isNotEmpty);
    expect(kAylaVolxPullPort, inInclusiveRange(1, 65535));
    expect(kAylaVolxPullSniHost, 'live.trise.top');
  });

  test('Windows **不再**重写到 volx 裸 IP（2026-11-03 裁定停用）', () {
    onPlatform(TargetPlatform.windows, () {
      final String out = aylaNormalizeLivePlayUrl(
        '$kUpstream/live/$kKey.m3u8',
        apiBase: kSakuraApi,
        configured: true,
      );
      expect(out, '$kSakuraApi/live/$kKey.m3u8');
      expect(out, isNot(contains(kAylaVolxPullHost)));
    });
  });

  test('三端（Windows / Android / iOS）归一化结果完全一致', () {
    const String input = '$kUpstream/live/$kKey.m3u8?hls_ctx=abc';
    const String expectOut = '$kSakuraApi/live/$kKey.m3u8?hls_ctx=abc';
    final List<String> results = <String>[];
    for (final TargetPlatform p in <TargetPlatform>[
      TargetPlatform.windows,
      TargetPlatform.android,
      TargetPlatform.iOS,
    ]) {
      onPlatform(p, () {
        results.add(
          aylaNormalizeLivePlayUrl(input, apiBase: kSakuraApi, configured: true),
        );
      });
    }
    expect(results, <String>[expectOut, expectOut, expectOut]);
  });

  test('query（hls_ctx）必须保留', () {
    onPlatform(TargetPlatform.windows, () {
      expect(
        aylaNormalizeLivePlayUrl(
          '$kUpstream/live/$kKey.m3u8?hls_ctx=abc',
          apiBase: kSakuraApi,
          configured: true,
        ),
        '$kSakuraApi/live/$kKey.m3u8?hls_ctx=abc',
      );
      expect(
        aylaNormalizeLivePlayUrl(
          '$kUpstream/live/$kKey.m3u8?hls_ctx=abc&token=t1',
          apiBase: kSakuraApi,
          configured: true,
        ),
        '$kSakuraApi/live/$kKey.m3u8?hls_ctx=abc&token=t1',
      );
    });
  });

  test('未配置远端 API（本地开发）⇒ 原样返回，不做无谓改写', () {
    onPlatform(TargetPlatform.windows, () {
      expect(
        aylaNormalizeLivePlayUrl('$kUpstream/live/$kKey.m3u8', configured: false),
        '$kUpstream/live/$kKey.m3u8',
      );
    });
  });

  test('已经是目标 origin ⇒ 幂等（不重复改写）', () {
    onPlatform(TargetPlatform.windows, () {
      const String already = '$kSakuraApi/live/$kKey.m3u8?hls_ctx=x';
      expect(
        aylaNormalizeLivePlayUrl(already, apiBase: kSakuraApi, configured: true),
        already,
      );
    });
  });

  test('非 /live/ 路径不重写（不误伤媒体/接口/相对地址）', () {
    onPlatform(TargetPlatform.windows, () {
      for (final String url in <String>[
        'https://live.trise.top:7882/other/x.m3u8',
        'https://cdn.example.com/vod/movie.mp4',
        '$kSakuraApi/api/v1/media/m1/content',
        '$kSakuraApi/live/nested/deep.m3u8',
        '/live/$kKey.m3u8',
        'not a url',
        '',
      ]) {
        expect(
          aylaNormalizeLivePlayUrl(url, apiBase: kSakuraApi, configured: true),
          url,
          reason: url,
        );
      }
    });
  });

  test('aylaUsesVolxPullDirect 恒 false（裸 IP 直连已停用）', () {
    for (final TargetPlatform p in <TargetPlatform>[
      TargetPlatform.windows,
      TargetPlatform.android,
      TargetPlatform.iOS,
    ]) {
      onPlatform(p, () {
        expect(aylaUsesVolxPullDirect(), isFalse, reason: '$p');
      });
    }
  });
}
