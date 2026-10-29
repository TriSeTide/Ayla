/// 语音播放内核「平台分派」契约锁（2026-10 用户实报「手机端无法播放语音」）。
///
/// ## 根因（已定位）
/// `pubspec.yaml` 只声明了 `media_kit_libs_windows_video`，Android/iOS 上**没有
/// libmpv** ⇒ 旧实现（移动端也用 media_kit）的 `player.open()` 必然失败。
/// 修复：移动端改走 just_audio（ExoPlayer / AVPlayer），桌面保留 media_kit。
///
/// ## 本文件锁死什么
/// 1. 分派结果：android/iOS → justAudio；windows/macOS/linux → mediaKit；
/// 2. [createAylaAudioEngine] 真的按分派结果构造（不初始化内核，纯 Dart 可断言）；
/// 3. 本地路径判定 [aylaIsLocalMediaPath]（缓存命中给的是裸绝对路径，不能当 URL）。
///
/// ⚠️ **真机播放本身不在此覆盖**：just_audio 是平台插件，`flutter test` 里没有
/// 原生实现。这里只锁「选哪个内核」和「怎么判定本地/网络」，不谎报播放成功。
library;

import 'package:ayla_flutter/core/media/audio_playback.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('aylaAudioEngineKind 平台分派', () {
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('Android 走 just_audio（移动端没有 libmpv）', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(aylaAudioEngineKind(), AylaAudioEngineKind.justAudio);
    });

    test('iOS 走 just_audio', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(aylaAudioEngineKind(), AylaAudioEngineKind.justAudio);
    });

    test('Windows 保留 media_kit（现状可用，不得回退）', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(aylaAudioEngineKind(), AylaAudioEngineKind.mediaKit);
    });

    test('macOS / Linux 也走 media_kit', () {
      for (final TargetPlatform p in <TargetPlatform>[
        TargetPlatform.macOS,
        TargetPlatform.linux,
      ]) {
        debugDefaultTargetPlatformOverride = p;
        expect(aylaAudioEngineKind(), AylaAudioEngineKind.mediaKit, reason: '$p');
      }
    });
  });

  group('createAylaAudioEngine 按分派结果构造', () {
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('移动端构造出的引擎不是 media_kit 实现（open 前无副作用）', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final AylaAudioEngine engine = createAylaAudioEngine();
      addTearDown(engine.dispose);
      // 两个实现都是私有类，这里用运行时类型名区分（避免为了断言把实现类公开）。
      expect(engine.runtimeType.toString(), contains('JustAudio'));
    });

    test('桌面构造出的引擎是 media_kit 实现', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final AylaAudioEngine engine = createAylaAudioEngine();
      addTearDown(engine.dispose);
      expect(engine.runtimeType.toString(), contains('MediaKit'));
    });

    test('接口契约未变：仍是可注入的 AylaAudioEngine', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final AylaAudioEngine engine = createAylaAudioEngine();
      addTearDown(engine.dispose);
      // 注入点（widgets/chat/media_content.dart 的 audioEngineFactory）依赖这三项。
      expect(engine, isA<AylaAudioEngine>());
      engine.onStateChange = (AylaAudioPlaybackState _) {};
      expect(engine.onStateChange, isNotNull);
    });
  });

  group('aylaIsLocalMediaPath', () {
    test('http / https 是网络源（需要 Authorization 头）', () {
      expect(aylaIsLocalMediaPath('http://127.0.0.1:8100/api/v1/media/x/content'),
          isFalse);
      expect(
          aylaIsLocalMediaPath(
              'https://s.ayla.trise.top:26211/api/v1/media/x/content'),
          isFalse);
      expect(aylaIsLocalMediaPath('HTTPS://EXAMPLE.COM/a.m4a'), isFalse);
    });

    test('裸绝对路径是本地文件（缓存命中路径，不能带 headers 分支）', () {
      // AylaMediaCache.lookup 返回的 File.path。
      expect(aylaIsLocalMediaPath('/data/user/0/com.ayla/files/media-cache/voice/ab/x.m4a'),
          isTrue);
      expect(aylaIsLocalMediaPath('C:/Users/x/AppData/Local/ayla/x.m4a'), isTrue);
      // Windows 盘符路径会被 Uri 解析成单字母 scheme（e:），必须仍判为本地。
      expect(aylaIsLocalMediaPath(r'E:\Elysium\data\voice\x.m4a'), isTrue);
      expect(aylaIsLocalMediaPath('file:///E:/x.m4a'), isTrue);
      expect(aylaIsLocalMediaPath('/tmp/rel.m4a'), isTrue);
    });
  });
}
