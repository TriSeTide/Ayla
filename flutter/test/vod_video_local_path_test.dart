/// 点播播放器「本地文件 vs 网络源」契约锁。
///
/// ## 背景
/// `widgets/chat/media_content.dart` 在漫游缓存命中时把 `localPath`（**裸绝对路径**，
/// 来自 `AylaMediaCache` 的 `File.path`）直接交给 `AylaVodVideo` ⇒
/// `VideoPlayerController.networkUrl(Uri.parse(path))` 在 Android/iOS 上拿到的
/// 不是合法 URL，`initialize()` 必然失败（视频永远黑屏/报错）。
///
/// 修复：本地文件 → `VideoPlayerController.file`，其余维持 `networkUrl`。
/// 本文件锁死判定与**真实构造出来的控制器**的 `dataSourceType`（video_player 的
/// 公开字段，构造过程不碰原生通道，纯 Dart 可断言）。
///
/// ⚠️ 真机解码不在此覆盖：`flutter test` 里没有 ExoPlayer/AVPlayer。
library;

import 'package:ayla_flutter/player/platforms/vod_video_player_impl.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('aylaIsLocalVideoPath', () {
    test('http / https 判为网络源', () {
      expect(aylaIsLocalVideoPath('http://10.0.2.2:8100/api/v1/media/x/content'),
          isFalse);
      expect(
          aylaIsLocalVideoPath(
              'https://s.ayla.trise.top:26211/api/v1/media/x/content'),
          isFalse);
    });

    test('裸绝对路径 / file:// 判为本地文件', () {
      expect(aylaIsLocalVideoPath('/data/user/0/com.ayla/files/v.m4a'), isTrue);
      expect(aylaIsLocalVideoPath(r'E:\Elysium\data\cache\v.mp4'), isTrue);
      expect(aylaIsLocalVideoPath('file:///E:/Elysium/data/cache/v.mp4'), isTrue);
    });
  });

  group('aylaVodVideoPlayerController', () {
    test('本地路径 → file 源（不再是 networkUrl）', () {
      final VideoPlayerController c =
          aylaVodVideoPlayerController(r'E:\Elysium\data\cache\voice\x.m4a');
      expect(c.dataSourceType, DataSourceType.file);
      // video_player 的 file 控制器会把路径归一成 file:// URI 字符串（其自身契约），
      // 关键是**类型是 file 源**、且路径里带着缓存文件本身。
      expect(c.dataSource, contains('x.m4a'));
      expect(c.dataSource, isNot(startsWith('http')));
    });

    test('file:// URI → 归一成平台绝对路径再交给 file 源', () {
      final VideoPlayerController c =
          aylaVodVideoPlayerController('file:///E:/Elysium/data/cache/v.mp4');
      expect(c.dataSourceType, DataSourceType.file);
      expect(aylaLocalVideoFilePath('file:///E:/Elysium/data/cache/v.mp4'),
          isNot(contains('file:')));
    });

    test('网络地址 → network 源（行为不变）', () {
      final VideoPlayerController c =
          aylaVodVideoPlayerController('https://example.com/a.mp4');
      expect(c.dataSourceType, DataSourceType.network);
      expect(c.dataSource, 'https://example.com/a.mp4');
    });
  });
}
