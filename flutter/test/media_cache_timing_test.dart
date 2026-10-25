/// 本地媒体缓存**落盘时机**的契约测试（2026-10-23 用户改版）。
///
/// ## 用户明确拍板的三条产品规则（不是技术优化）
/// 1. **文件消息不再自动保存** —— 「前面我说的看见媒体消息直接保存，这一点不包括
///    保存文件消息，文件消息需要手动点击保存才保存到本地」
/// 2. **图片：看见先存缩略图，点开大图才用原图替换缩略图** —— 「看到了图片是保存
///    缩略图，只有点开图片后才取代刚保存的缩略图保存原图」
/// 3. **语音：点击才存，不点击不存** —— 「语音则是点击语音即保存本地，不点击不保存」
///
/// ## 为什么要有这个文件
/// 这三条与旧裁决 D1（只缓存 original）/ D4（加载即存）**直接冲突**。缓存层
/// （test/media_cache_test.dart）只锁「能存什么」；本文件锁「**什么时候存**」——
/// 那是组件层的职责，也是本次改版真正容易退回去的地方。
///
/// ## 测试手法（关键，别改坏）
/// 组件内部写死两处单例：AylaMediaCache.instance 与 MediaSigner.instance。
/// 所以本文件同时注入：
/// - **真 MediaSigner + 假 DioClient**（项目既有手法，见 media_dialog_test.dart:175）
///   ⇒ 签名链路是真的，能拿到真实 SignedMediaResult，且 thumb/original 的
///   URL 可区分（-thumb 后缀）；
/// - **AylaMediaCache.instance 的 layoutForTest** 指到临时目录、downloaderForTest
///   计数 ⇒ 真实落盘 + 可断言「下载了哪个 URL」。
/// - 测试必须跑在 tester.runAsync 里：FakeAsync 不推进真实磁盘 IO，
///   否则缓存层永远卡在第一个 await，测出来的是假绿。
library;

import 'dart:io';
import 'dart:typed_data' show Uint8List;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/media/audio_playback.dart';
import '../lib/core/media/media_cache.dart';
import '../lib/core/media/media_cache_paths.dart';
import '../lib/core/media/media_signer.dart';
import '../lib/core/net/dio_client.dart';
import '../lib/core/models/chat_message.dart';
import '../lib/core/models/media_kind.dart';
import '../lib/core/models/post.dart' show AylaMediaDescriptor;
import '../lib/theme/preview_theme.dart';
import '../lib/theme/sample_media.dart';
import '../lib/widgets/base/resource_image.dart';
import '../lib/widgets/chat/media_content.dart';

/// 假签名 client：thumb 与原图的签名 URL 带不同后缀，便于断言「存的是哪一种」。
///
/// 走的是**真实** MediaSigner 代码路径（缓存、并发去重、410 降级都在）。
class _FakeSignerClient implements DioClient {
  @override
  Future<T> post<T>(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
  }) async {
    final bool isThumb = body is Map && body['variant'] == 'thumb';
    // path 形如 /media/<id>:sign
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

/// 空音频引擎：语音规则只要「渲染不崩 + 不落盘」，不需要真播放。
class _NullAudioEngine implements AylaAudioEngine {
  @override
  void Function(AylaAudioPlaybackState state)? onStateChange;

  @override
  Future<void> open(String url, {Map<String, String>? headers}) async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> dispose() async {}
}

AylaMediaDescriptor _media({
  required String id,
  required AylaMediaKind kind,
  String mime = 'image/png',
  bool waveform = false,
}) =>
    AylaMediaDescriptor(
      mediaId: id,
      kind: kind,
      mimeType: mime,
      size: 1024,
      duration: kind == AylaMediaKind.voice ? 12 : null,
      waveform: waveform ? '/api/v1/media/' + id + '/waveform' : null,
      status: 'ready',
    );

AylaChatMessage _msg({
  required AylaMessageType type,
  required AylaMediaDescriptor media,
}) =>
    AylaChatMessage(
      id: 'm-' + media.mediaId,
      conversationId: 'c1',
      senderId: 'u1',
      type: type,
      content: '',
      mediaId: media.mediaId,
      media: media,
      status: AylaMessageStatus.sent,
      seq: 1,
      createdAt: '2026-10-23T10:00:00Z',
    );

void main() {
  late Directory tempRoot;

  /// 记录缓存层实际**下载**了哪些 URL（-thumb ⇒ 缩略图）。
  late List<String> downloads;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('ayla-cache-timing-');
    downloads = <String>[];

    // ① 真 MediaSigner + 假 DioClient（签名链路真实）
    MediaSigner.instance.detach();
    MediaSigner.instance.attach(_FakeSignerClient());

    // ② 缓存层：临时目录 + 计数下载器
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
    } catch (_) {
      // Windows 偶有句柄未释放：临时目录删不掉不影响断言
    }
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

  /// 在真实异步环境里渲染并等落盘链路跑完。
  ///
  /// ⚠️ 必须 runAsync：widget 测试默认 FakeAsync，真实磁盘 IO 的 future
  /// 不会被推进 ⇒ 缓存层永远停在第一个 await，所有「没下载」的断言都是假绿。
  Future<void> renderAndSettle(WidgetTester tester, Widget child) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(host(child));
      // 给签名 + 下载 + 原子写盘留足时间
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await tester.pump();
    });
  }

  // ================================================================
  // 规则 1：文件消息 **不自动保存**
  // ================================================================
  //
  // 用户原话「文件消息需要手动点击保存才保存到本地」。
  // 旧实现：_FileMediaState._sign() 签完就 fetchAndStore(kind: file)。
  testWidgets('★ 规则1：文件消息渲染**不触发任何下载**（不再自动保存）', (
    WidgetTester tester,
  ) async {
    await renderAndSettle(
      tester,
      AylaMediaContent(
        msg: _msg(
          type: AylaMessageType.file,
          media: _media(
            id: 'file1',
            kind: AylaMediaKind.file,
            mime: 'application/pdf',
          ),
        ),
      ),
    );

    expect(downloads, isEmpty,
        reason: '★ 文件消息不得自动下载落盘（旧 D4「加载即存」已作废，'
            '2026-10-23 用户明确要求「手动点击保存」）');
  });

  // ================================================================
  // 规则 3：语音 **点击才存**
  // ================================================================
  //
  // 用户原话「语音则是点击语音即保存本地，不点击不保存」。
  // 现状：_ensureEngine 只由 _toggle（播放键）调用 ⇒ 渲染期不该有下载。
  testWidgets('★ 规则3：语音渲染**不落盘**（不点击不保存）', (
    WidgetTester tester,
  ) async {
    aylaEnableSampleMedia();
    addTearDown(aylaDisableSampleMedia);
    await renderAndSettle(
      tester,
      AylaMediaContent(
        msg: _msg(
          type: AylaMessageType.voice,
          media: _media(
            id: 'voice1',
            kind: AylaMediaKind.voice,
            mime: 'audio/ogg',
            waveform: true,
          ),
        ),
        audioEngineFactory: () => _NullAudioEngine(),
      ),
    );

    expect(downloads, isEmpty,
        reason: '★ 语音渲染期不得落盘（只渲染波形/时长，不下载音频本体）');
  });

  testWidgets('★ 规则3：语音长时间挂屏也不落盘（时机是「点击」不是「入视口」）', (
    WidgetTester tester,
  ) async {
    aylaEnableSampleMedia();
    addTearDown(aylaDisableSampleMedia);
    await tester.runAsync(() async {
      await tester.pumpWidget(host(
        AylaMediaContent(
          msg: _msg(
            type: AylaMessageType.voice,
            media: _media(id: 'voice2', kind: AylaMediaKind.voice, mime: 'audio/ogg'),
          ),
          audioEngineFactory: () => _NullAudioEngine(),
        ),
      ));
      for (int i = 0; i < 6; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
        await tester.pump();
      }
    });

    expect(downloads, isEmpty,
        reason: '★ 长时间停留也不得落盘（时机是「点击」，不是「入视口」）');
  });

  // ================================================================
  // 规则 2：图片 **看见存 thumb / 点开存 original**
  // ================================================================
  //
  // 用户原话「看到了图片是保存缩略图，只有点开图片后才取代刚保存的缩略图保存原图」。
  testWidgets('★ 规则2：图片（thumb 变体）渲染 ⇒ 只下载 **thumb** URL', (
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
            src: '/api/v1/media/img1/thumbnail',
            alt: '图片',
            variant: MediaVariant.thumb,
          ),
        ),
      ),
    );

    expect(downloads, isNotEmpty, reason: '★ 看见图片就该存一份（缩略图）');
    expect(
      downloads.every((String u) => u.contains('-thumb')),
      isTrue,
      reason: '★ 只允许下载 **thumb** URL；下载原图 URL 即违反用户规则'
          '（实际：' + downloads.toString() + '）',
    );
  });

  testWidgets('★ 规则2：非 thumb 变体的图片组件也存 thumb，不存原图', (
    WidgetTester tester,
  ) async {
    await renderAndSettle(
      tester,
      Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 400,
          height: 300,
          child: AylaResourceImage(src: '/api/v1/media/img2/content', alt: '图片'),
        ),
      ),
    );

    expect(downloads, isNotEmpty, reason: '★ 看见图片就该存缩略图');
    expect(
      downloads.every((String u) => u.contains('-thumb')),
      isTrue,
      reason: '★ 2026-10-23 起：气泡内一律只存缩略图，原图只在查看器存'
          '（实际：' + downloads.toString() + '）',
    );
  });

  // ================================================================
  // 缓存层语义（组件无关，纯 API）：thumb 落盘后 lookup 仍能区分两形态
  // ================================================================
  test('★ 规则2：缩略图落盘后 lookupForDisplay 先给 thumb，原图落盘后改为优先原图',
      () async {
    const String id = 'imglayer0001';
    // 先走「看见」：只存 thumb
    final File? thumb = await AylaMediaCache.instance.fetchAndStore(
      mediaId: id,
      kind: AylaMediaKind.image,
      variant: AylaMediaCacheVariant.thumb,
    );
    expect(thumb, isNotNull, reason: '缩略图必须能落盘');
    expect(thumb!.path.replaceAll('\\', '/'), contains('.thumb.'));

    AylaMediaCacheHit? hit = await AylaMediaCache.instance
        .lookupForDisplay(id, kind: AylaMediaKind.image);
    expect(hit, isNotNull);
    expect(hit!.isThumb, isTrue, reason: '只有 thumb 时展示用的是缩略图');

    // 再走「点开大图」：存 original
    final File? original = await AylaMediaCache.instance.fetchAndStore(
      mediaId: id,
      kind: AylaMediaKind.image,
    );
    expect(original, isNotNull, reason: '查看器必须能存原图');
    expect(original!.path.replaceAll('\\', '/'), isNot(contains('.thumb.')));

    hit = await AylaMediaCache.instance
        .lookupForDisplay(id, kind: AylaMediaKind.image);
    expect(hit!.isThumb, isFalse,
        reason: '★ 原图存下后就该优先原图（用户的「取代缩略图」语义）');
    expect(hit.file.path, original.path);

    // 两份物理共存（不是覆盖）
    expect(await thumb.exists(), isTrue, reason: '★ 缩略图不被原图覆盖');
    expect(await original.exists(), isTrue);
  });
}
