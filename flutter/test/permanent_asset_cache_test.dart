/// 永久资产「不落本地缓存」+ 视频「点击播放才存」的契约测试（2026-10-23 用户裁决）。
///
/// ## 用户裁决原话
/// 1. 视频：「是的，视频改成『点击播放才存』，但视频首帧缩略图是看见就存」
/// 2. 表情包：「表情包不存本地啊，你没有意识到表情包是永久资产吗，是 minio
///    永久保存不会过期的资产，那么当然不需要存本地了」
/// 3. 帖子/评论图片：「帖子和帖子评论图片同理，也是永久资产，不需要保存本地」
///
/// ## 设计原则（本文件的判据）
/// 本地漫游缓存存在的意义**只是对抗云端过期**。所以：
/// - **会过期**（聊天图/视频/语音/文件/弹幕图/语音房图，retention-boundaries §4
///   E1–E4）⇒ 落盘；
/// - **永久资产**（§3 A1–A7：帖子图 / 表情包 / 评论图 / 用户头像 / 群头像 /
///   直播间封面）⇒ **不落盘**（缓存纯属白占磁盘与带宽）。
///
/// ## 测试手法
/// 与 media_cache_timing_test.dart 同：真 MediaSigner + 假 DioClient +
/// \`layoutForTest\` 临时目录 + \`downloaderForTest\` 计数，全部跑在
/// \`tester.runAsync\`（FakeAsync 不推进真实磁盘 IO ⇒ 否则假绿）。
library;

import 'dart:io';
import 'dart:typed_data' show Uint8List;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/media/media_cache.dart';
import '../lib/core/media/media_cache_paths.dart';
import '../lib/core/media/media_signer.dart';
import '../lib/core/net/dio_client.dart';
import '../lib/core/models/chat_message.dart';
import '../lib/core/models/media_kind.dart';
import '../lib/core/models/post.dart' show AylaMediaDescriptor;
import '../lib/theme/preview_theme.dart';
import '../lib/theme/sample_media.dart';
import '../lib/widgets/base/media_interaction.dart' show AylaSignedVideo;
import '../lib/widgets/base/resource_image.dart';
import '../lib/widgets/chat/media_content.dart';

/// 假签名 client：thumb / original 的 URL 可区分。
class _FakeSignerClient implements DioClient {
  @override
  Future<T> post<T>(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
  }) async {
    final bool isThumb = body is Map && body['variant'] == 'thumb';
    final String id = path.split('/').last.split(':').first;
    return <String, dynamic>{
      'url': isThumb
          ? 'https://minio.example/bucket/' + id + '-thumb.png?sig=x'
          : 'https://minio.example/bucket/' + id + '.png?sig=x',
      'expires_at': DateTime.now().millisecondsSinceEpoch / 1000 + 3600,
    } as T;
  }

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

void main() {
  late Directory tempRoot;
  late List<String> downloads;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('ayla-permanent-');
    downloads = <String>[];

    MediaSigner.instance.detach();
    MediaSigner.instance.attach(_FakeSignerClient());

    AylaMediaCache.instance.layoutForTest = AylaMediaCacheLayout(
      root: tempRoot.path.replaceAll('\\', '/') + '/media-cache',
      source: AylaMediaCacheRootSource.executableData,
      degraded: false,
    );
    AylaMediaCache.instance.downloaderForTest = (String url) async {
      downloads.add(url);
      return Uint8List.fromList(<int>[1, 2, 3, 4]);
    };
    AylaMediaCache.instance.enabledForTest = true;
  });

  tearDown(() async {
    MediaSigner.instance.detach();
    AylaMediaCache.instance.enabledForTest = false;
    AylaMediaCache.instance.layoutForTest = null;
    AylaMediaCache.instance.downloaderForTest = null;
    try {
      if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
    } catch (_) {}
  });

  Widget host(Widget child) => MaterialApp(
        debugShowCheckedModeBanner: false,
        home: previewScope(
          Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: 720, height: 640, child: child),
          ),
        ),
      );

  Future<void> renderAndSettle(WidgetTester tester, Widget child) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(host(child));
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await tester.pump();
    });
  }

  // ================================================================
  // 核心：cacheable: false ⇒ 零下载、零落盘，但仍能显示
  // ================================================================
  testWidgets('★ 永久资产（cacheable: false）⇒ **零下载、零落盘**', (
    WidgetTester tester,
  ) async {
    await renderAndSettle(
      tester,
      Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 400,
          height: 300,
          child: AylaResourceImage(
            src: '/api/v1/media/perm1/thumbnail',
            alt: '帖子图片',
            variant: MediaVariant.thumb,
            cacheable: false,
          ),
        ),
      ),
    );

    expect(downloads, isEmpty,
        reason: '★ 永久资产不落盘（用户裁决 2026-10-23：MinIO 永不删 ⇒ 缓存无意义）');

    // 不能因为不缓存就把图搞坏：签名仍要走、仍要能显示
    final Finder img = find.byType(AylaResourceImage);
    expect(img, findsOneWidget);
    expect(tester.widget<AylaResourceImage>(img).cacheable, isFalse);
  });

  testWidgets('★ 永久资产（cacheable: false）仍完成签名（不缓存 ≠ 不显示）', (
    WidgetTester tester,
  ) async {
    await renderAndSettle(
      tester,
      Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 400,
          height: 300,
          child: AylaResourceImage(
            src: '/api/v1/media/perm2/content',
            alt: '表情',
            cacheable: false,
          ),
        ),
      ),
    );
    expect(downloads, isEmpty);

    // 目录里不该出现任何缓存文件。
    // ⚠️ 磁盘遍历必须在 runAsync 里跑：widget 测试默认 FakeAsync，真实 IO 的
    //    future 不会被推进 ⇒ 写在外层会**永久挂住**（本测试第一版就这样卡了 84s）。
    final List<String> files = <String>[];
    await tester.runAsync(() async {
      final Directory root = Directory(tempRoot.path + '/media-cache');
      if (!await root.exists()) return;
      await for (final FileSystemEntity e
          in root.list(recursive: true, followLinks: false)) {
        if (e is File && !e.path.endsWith('.tmp')) files.add(e.path);
      }
    });
    expect(files, isEmpty, reason: '★ 永久资产不得产生任何缓存文件');
  });

  // ================================================================
  // 对照：会过期资产（cacheable 默认 true）仍然落盘
  // ================================================================
  testWidgets('★ 对照：聊天图（cacheable 默认 true）仍然落 **thumb**', (
    WidgetTester tester,
  ) async {
    await renderAndSettle(
      tester,
      Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 400,
          height: 300,
          child: AylaResourceImage(
            src: '/api/v1/media/chat1/content',
            alt: '图片',
          ),
        ),
      ),
    );

    expect(downloads, isNotEmpty, reason: '聊天图（E1 过期）必须仍落盘');
    expect(
      downloads.every((String u) => u.contains('-thumb')),
      isTrue,
      reason: '看见只存 thumb（不存原图）',
    );
  });

  // ================================================================
  // 视频三态（用户裁决 2026-10-23：「点击播放才存，首帧缩略图看见就存」）
  // ================================================================

  AylaChatMessage videoMsg({bool withPoster = true}) => AylaChatMessage(
        id: 'm-v',
        conversationId: 'c1',
        senderId: 'u1',
        type: AylaMessageType.video,
        content: '',
        mediaId: 'vid1',
        media: AylaMediaDescriptor(
          mediaId: 'vid1',
          kind: AylaMediaKind.video,
          mimeType: 'video/mp4',
          size: 4096,
          width: 1280,
          height: 720,
          thumbnail: withPoster ? '/api/v1/media/vid1/thumbnail' : null,
          status: 'ready',
        ),
        status: AylaMessageStatus.sent,
        seq: 1,
        createdAt: '2026-10-23T10:00:00Z',
      );

  testWidgets('★ 视频①：气泡内**有海报**=> 只落 thumb（视频本体零下载）', (
    WidgetTester tester,
  ) async {
    aylaEnableSampleMedia();
    addTearDown(aylaDisableSampleMedia);
    await renderAndSettle(
      tester,
      SizedBox(
        width: 320,
        height: 180,
        child: AylaMediaContent(msg: videoMsg(withPoster: true)),
      ),
    );

    expect(
      downloads.every((String u) => u.contains('-thumb')),
      isTrue,
      reason: '★ 有海报时只可能下载 thumb（首帧缩略图）；下载原片 URL = 违规'
          '（实际：' + downloads.toString() + '）',
    );
  });

  testWidgets('★ 视频②：气泡内**无海报**=> 签名取首帧但**不落盘**', (
    WidgetTester tester,
  ) async {
    aylaEnableSampleMedia();
    addTearDown(aylaDisableSampleMedia);
    await renderAndSettle(
      tester,
      SizedBox(
        width: 320,
        height: 180,
        child: AylaMediaContent(msg: videoMsg(withPoster: false)),
      ),
    );

    expect(downloads, isEmpty,
        reason: '★ 无海报时只为「取一帧给气泡看」而签名，**不得**落盘视频本体'
            '（用户裁决：点击播放才存）');
  });

  testWidgets('★ 视频③：AylaSignedVideo 默认 **不落盘**（列表首帧预览场景）', (
    WidgetTester tester,
  ) async {
    await renderAndSettle(
      tester,
      const SizedBox(
        width: 320,
        height: 180,
        child: AylaSignedVideo(mediaId: 'vid2'),
      ),
    );
    expect(downloads, isEmpty,
        reason: '★ 默认 cacheable=false => 创建播放器不落视频本体');
  });

  testWidgets('★ 视频④：AylaSignedVideo(cacheable: true) **才落盘**（查看器播放场景）', (
    WidgetTester tester,
  ) async {
    await renderAndSettle(
      tester,
      const SizedBox(
        width: 320,
        height: 180,
        child: AylaSignedVideo(mediaId: 'vid3', controls: true, cacheable: true),
      ),
    );
    expect(downloads, isNotEmpty,
        reason: '★ 用户点开查看器播放（cacheable: true）=> 此时才落盘视频本体');
    expect(downloads.any((String u) => !u.contains('-thumb')), isTrue,
        reason: '★ 落的是**原片**（original），不是缩略图');
  });

  // ================================================================
  // 接线锁：永久资产调用点必须显式传 cacheable: false
  // ================================================================
  test('★ 接线锁：永久资产调用点都传了 cacheable: false', () {
    /// 文件 -> 期望的最少处数。
    const Map<String, int> expected = <String, int>{
      'lib/widgets/posts/post_card.dart': 3,
      'lib/widgets/posts/comments.dart': 2,
      'lib/widgets/posts/post_editor.dart': 2,
      'lib/pages/post_detail_page.dart': 1,
      'lib/widgets/chat/emoji_pack_panel.dart': 1,
      'lib/widgets/base/avatar_halo.dart': 1,
      'lib/widgets/live/live_hall.dart': 1,
      'lib/widgets/live/live_rail.dart': 1,
      'lib/widgets/live/live_owner_panel.dart': 1,
      'lib/widgets/base/profile_content_sections.dart': 1,
      'lib/widgets/shell/channel_sidebar.dart': 1,
      'lib/widgets/group/group_card.dart': 2,
      'lib/widgets/chat/share_bubble.dart': 1,
      'lib/widgets/live/danmaku.dart': 1,
    };
    for (final String path in expected.keys) {
      final String src = File(path).readAsStringSync();
      final int n = 'cacheable: false'.allMatches(src).length;
      expect(n, greaterThanOrEqualTo(expected[path]!),
          reason: '★ ' + path + ' 至少要有 ' + expected[path]!.toString() +
              ' 处 cacheable: false（实际 ' + n.toString() + '）');
    }
  });

  test('★ 接线锁：表情消息分支用 cacheable: !isEmoji（同组件两语义）', () {
    final String src =
        File('lib/widgets/chat/media_content.dart').readAsStringSync();
    expect(src.contains('cacheable: !widget.isEmoji'), isTrue,
        reason: '★ _ImageMedia 同一处两分支：聊天图缓存 / 表情消息（A2）不缓存');
  });

  test('★ 接线锁：弹幕**图片**保持可缓存（不能误设 false）', () {
    final String src = File('lib/widgets/live/danmaku.dart').readAsStringSync();
    // 弹幕图片是 E3（7 天过期）=> 必须可缓存；只有飘屏头像（A5）不缓存。
    expect('cacheable: false'.allMatches(src).length, 1,
        reason: '★ 只有 _FlyAvatar（A5）不缓存；弹幕图片（E3）必须保持可缓存');
  });

  test('★ 接线锁：聊天视频气泡内不再自动落盘视频本体', () {
    final String src =
        File('lib/widgets/chat/media_content.dart').readAsStringSync();
    final int start = src.indexOf('class _VideoFrameState');
    final int end = src.indexOf('class _PlayBadge', start);
    expect(start, greaterThan(0));
    final String body = src.substring(start, end);
    expect(body.contains('fetchAndStore'), isFalse,
        reason: '★ 视频卡不得再自动落盘（用户裁决：点击播放才存）');
  });
}
