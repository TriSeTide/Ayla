/// 拉流入口「volx 裸 IP 直连」契约（`core/net/live_play_url.dart`）。
///
/// 背景：`live.trise.top:7882` 的 HTTPS 被阿里云 ICP 备案过滤器按 SNI 重置，
/// 裸 IP（不发 SNI）正常；Windows 走 media_kit/mpv，因此可以直连。
/// 移动端 ExoPlayer/AVPlayer 强制校验证书 ⇒ 本期保持樱花（API 同源）。
///
/// 平台分派靠 `defaultTargetPlatform`，测试里用 `debugDefaultTargetPlatformOverride`
/// 显式指定，避免依赖跑测试那一端的宿主平台。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/net/live_play_url.dart';
import '../lib/widgets/live/live_channel_snapshot.dart';

const String kKey = 'be86d4a1deb369a224b9cd4805d1a984b9e6413ba9fe056e';
const String kUpstream = 'https://live.trise.top:7882';
const String kSakuraApi = 'https://s.ayla.trise.top:26211';

/// 在 [platform] 的假宿主下跑 [body]（结束后务必复位，否则污染其他测试）。
void onPlatform(TargetPlatform platform, void Function() body) {
  debugDefaultTargetPlatformOverride = platform;
  try {
    body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

/// 期望的 volx 前缀（跟随 `--dart-define=AYLA_LIVE_PULL_HOST/PORT` 的覆盖）。
String get volxOrigin => 'https://$kAylaVolxPullHost:$kAylaVolxPullPort';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('常量：默认值是 volx 裸 IP + 7882（可被 dart-define 覆盖）', () {
    // 默认值断言只在**没有**注入 dart-define 时成立；注入了就断言跟随注入值，
    // 这样 `flutter test --dart-define=AYLA_LIVE_PULL_HOST=...` 也能验证覆盖链路。
    const String hostEnv = String.fromEnvironment(
      'AYLA_LIVE_PULL_HOST',
      defaultValue: '47.108.85.223',
    );
    expect(kAylaVolxPullHost, hostEnv);
    expect(kAylaVolxPullHost, isNotEmpty);
    expect(kAylaVolxPullPort, inInclusiveRange(1, 65535));
    expect(kAylaVolxPullSniHost, 'live.trise.top');
  });

  test('Windows：`/live/` 流地址重写到 volx 裸 IP（保留路径）', () {
    onPlatform(TargetPlatform.windows, () {
      expect(
        aylaNormalizeLivePlayUrl('$kUpstream/live/$kKey.m3u8'),
        '$volxOrigin/live/$kKey.m3u8',
      );
      expect(
        aylaNormalizeLivePlayUrl('$kUpstream/live/$kKey.flv'),
        '$volxOrigin/live/$kKey.flv',
      );
      expect(
        aylaNormalizeLivePlayUrl('$kUpstream/live/$kKey-57.ts'),
        '$volxOrigin/live/$kKey-57.ts',
      );
    });
  });

  test('Windows：query（hls_ctx）必须保留', () {
    onPlatform(TargetPlatform.windows, () {
      expect(
        aylaNormalizeLivePlayUrl('$kUpstream/live/$kKey.m3u8?hls_ctx=abc'),
        '$volxOrigin/live/$kKey.m3u8?hls_ctx=abc',
      );
      expect(
        aylaNormalizeLivePlayUrl(
          '$kUpstream/live/$kKey.m3u8?hls_ctx=abc&token=t1',
        ),
        '$volxOrigin/live/$kKey.m3u8?hls_ctx=abc&token=t1',
      );
    });
  });

  test('Windows：不依赖 AYLA_API_BASE（本地开发也重写）', () {
    onPlatform(TargetPlatform.windows, () {
      // configured:false 模拟「没配远端 API 的本地开发」——旧实现会原样返回，
      // 新实现必须照样收敛到 volx（本地没有 /live/ 反代，重写无害）。
      expect(
        aylaNormalizeLivePlayUrl('$kUpstream/live/$kKey.m3u8', configured: false),
        '$volxOrigin/live/$kKey.m3u8',
      );
      expect(
        aylaNormalizeLivePlayUrl('$kUpstream/live/$kKey.m3u8', configured: true),
        '$volxOrigin/live/$kKey.m3u8',
      );
    });
  });
  test('Windows：非 `/live/` 路径不重写（不误伤媒体/接口/相对地址）', () {
    onPlatform(TargetPlatform.windows, () {
      for (final String url in <String>[
        'https://live.trise.top:7882/other/x.m3u8',
        'https://cdn.example.com/vod/movie.mp4',
        'https://s.ayla.trise.top:26211/api/v1/media/m1/content',
        'https://s.ayla.trise.top:26211/live/nested/deep.m3u8',
        '/live/$kKey.m3u8', // 相对路径：没有 origin 可判定
        'not a url',
        '',
      ]) {
        expect(aylaNormalizeLivePlayUrl(url), url, reason: url);
      }
    });
  });

  test('Windows：已经指向 volx 且 scheme/port 正确 ⇒ 幂等（不重复改写）', () {
    onPlatform(TargetPlatform.windows, () {
      const String already =
          'https://47.108.85.223:7882/live/$kKey.m3u8?hls_ctx=abc';
      // 仅当默认常量就是 47.108.85.223:7882 时才是同一地址；被 dart-define 覆盖时
      // 用当前生效的 origin 构造，断言「二次调用不再变化」这一性质本身。
      final String same = '$volxOrigin/live/$kKey.m3u8?hls_ctx=abc';
      expect(aylaNormalizeLivePlayUrl(same), same);
      if (volxOrigin == 'https://47.108.85.223:7882') {
        expect(aylaNormalizeLivePlayUrl(already), already);
      }
    });
  });

  test('Windows：http 上游地址提升到 https', () {
    onPlatform(TargetPlatform.windows, () {
      expect(
        aylaNormalizeLivePlayUrl('http://live.trise.top:7882/live/$kKey.m3u8'),
        '$volxOrigin/live/$kKey.m3u8',
      );
    });
  });

  test('移动端（android / ios）保持原地址：不重写裸 IP', () {
    for (final TargetPlatform platform in <TargetPlatform>[
      TargetPlatform.android,
      TargetPlatform.iOS,
    ]) {
      onPlatform(platform, () {
        // 未配置远端 API ⇒ 原样（本地开发语义不变）。
        const String local = '$kUpstream/live/$kKey.m3u8';
        expect(
          aylaNormalizeLivePlayUrl(local, configured: false),
          local,
          reason: '$platform 未配置远端 API 时应原样返回',
        );
        // 配置了远端 API ⇒ 仍走樱花（API 同源），**不是** volx 裸 IP。
        expect(
          aylaNormalizeLivePlayUrl(
            local,
            apiBase: kSakuraApi,
            configured: true,
          ),
          '$kSakuraApi/live/$kKey.m3u8',
          reason: '$platform 本期继续走 API 同源（樱花）',
        );
        // 明确的负向断言：移动端绝不出现 volx 裸 IP。
        expect(
          aylaNormalizeLivePlayUrl(
            local,
            apiBase: kSakuraApi,
            configured: true,
          ),
          isNot(contains(kAylaVolxPullHost)),
        );
      });
    }
  });

  test('aylaUsesVolxPullDirect：只有 Windows 为真', () {
    for (final TargetPlatform platform in <TargetPlatform>[
      TargetPlatform.windows,
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.macOS,
      TargetPlatform.linux,
    ]) {
      onPlatform(platform, () {
        expect(
          aylaUsesVolxPullDirect(),
          platform == TargetPlatform.windows,
          reason: platform.name,
        );
      });
    }
  });

  test('aylaIsVolxPullHost：只认当前生效的拉流 IP', () {
    onPlatform(TargetPlatform.windows, () {
      expect(aylaIsVolxPullHost(kAylaVolxPullHost), isTrue);
      expect(aylaIsVolxPullHost('live.trise.top'), isFalse);
      expect(aylaIsVolxPullHost('s.ayla.trise.top'), isFalse);
      expect(aylaIsVolxPullHost(''), isFalse);
    });
  });

  test('快照解析（GET /live/channels/<id>/）在 Windows 上落到 volx 裸 IP', () {
    onPlatform(TargetPlatform.windows, () {
      final AylaLiveChannelSnapshot? channel =
          AylaLiveChannelSnapshot.fromJson(<String, Object?>{
        'id': 2,
        'title': 'test',
        'status': 'live',
        'hls_url': '$kUpstream/live/$kKey.m3u8',
        'flv_url': '$kUpstream/live/$kKey.flv',
      });
      expect(channel, isNotNull);
      expect(channel!.hlsUrl, '$volxOrigin/live/$kKey.m3u8');
      expect(channel.flvUrl, '$volxOrigin/live/$kKey.flv');
    });
  });

  test('dart-define 覆盖口：宿主/端口常量一致且可被注入值替换', () {
    // 该用例不做字符串硬编码断言，而是验证「读取链路成立」：
    // 默认构建下等于默认值；`flutter test --dart-define=AYLA_LIVE_PULL_HOST=1.2.3.4
    // --dart-define=AYLA_LIVE_PULL_PORT=9000` 时原样跟随注入值。
    const String hostEnv = String.fromEnvironment(
      'AYLA_LIVE_PULL_HOST',
      defaultValue: '47.108.85.223',
    );
    const String portEnv = String.fromEnvironment(
      'AYLA_LIVE_PULL_PORT',
      defaultValue: '7882',
    );
    expect(kAylaVolxPullHost, hostEnv);
    expect(kAylaVolxPullPort, int.tryParse(portEnv) ?? 7882);

    onPlatform(TargetPlatform.windows, () {
      final String rewritten = aylaNormalizeLivePlayUrl(
        '$kUpstream/live/$kKey.m3u8?hls_ctx=xyz',
      );
      final Uri uri = Uri.parse(rewritten);
      expect(uri.host, hostEnv, reason: '重写目标必须跟随注入的 host');
      expect(uri.port, int.tryParse(portEnv) ?? 7882);
      expect(uri.path, '/live/$kKey.m3u8');
      expect(uri.query, 'hls_ctx=xyz');
    });
  });
}
