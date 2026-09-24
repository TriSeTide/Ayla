/// B3 chat 域第一批：媒体消息定向测试 —— 逐条对照
/// `components/chat/MediaContent.tsx`(883) 与 `app.css:1383–1639`（媒体帧/播放键/语音卡）、
/// `app.css:1839–1979`（文件卡/占位/混排）、`app.css:2328–2355`（`.mention-token`）、
/// `api/media.ts:192–213`（resolveMediaPath / formatBytes / formatDuration）。
///
/// 覆盖：类型分派（image/emoji/video/voice/file/mixed/未知）/ 关键尺寸（帧尺寸计算与
/// 不放大、emoji 96、播放键 48、混排 180 与 240×180、文件卡 240–320）/ descriptor 补拉与
/// 失败重试 / 语音播放（引擎注入 + 全局互斥）/ 查看器 host / 占位三态 / 乐观文件消息。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/media/audio_playback.dart';
import '../lib/core/media/media_signer.dart';
import '../lib/core/models/chat_message.dart';
import '../lib/core/models/media_kind.dart';
import '../lib/core/models/post.dart' show AylaMediaDescriptor;
import '../lib/theme/preview_theme.dart';
import '../lib/theme/sample_media.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/image_viewer.dart';
import '../lib/widgets/loading.dart';
import '../lib/widgets/media_content.dart';
import '../lib/widgets/resource_image.dart';

AylaMediaDescriptor _media({
  String id = 'm1',
  AylaMediaKind kind = AylaMediaKind.image,
  String mime = 'image/png',
  int? width,
  int? height,
  double? duration,
  bool thumbnail = false,
  bool waveform = false,
  int size = 240000,
}) =>
    AylaMediaDescriptor(
      mediaId: id,
      kind: kind,
      mimeType: mime,
      size: size,
      width: width,
      height: height,
      duration: duration,
      thumbnail: thumbnail ? '/api/v1/media/$id/thumbnail' : null,
      waveform: waveform ? '/api/v1/media/$id/waveform' : null,
      status: 'ready',
    );

AylaChatMessage _msg({
  String id = 'msg1',
  AylaMessageType type = AylaMessageType.image,
  String content = '',
  AylaMediaDescriptor? media,
  String? mediaId,
  List<AylaMediaSegment> segments = const <AylaMediaSegment>[],
  List<AylaLocalMediaPreview> localMedia = const <AylaLocalMediaPreview>[],
}) =>
    AylaChatMessage(
      id: id,
      conversationId: 'c1',
      senderId: 'u1',
      type: type,
      content: content,
      mediaId: mediaId ?? media?.mediaId,
      media: media,
      segments: segments,
      localMedia: localMedia,
      status: AylaMessageStatus.sent,
      seq: 1,
      createdAt: '2026-09-24T10:00:00Z',
    );

class _FakeAudioEngine implements AylaAudioEngine {
  @override
  void Function(AylaAudioPlaybackState state)? onStateChange;

  bool opened = false;
  int plays = 0;
  int pauses = 0;
  Duration? seeked;
  bool disposed = false;

  @override
  Future<void> open(String url, {Map<String, String>? headers}) async {
    opened = true;
    onStateChange?.call(
      const AylaAudioPlaybackState(duration: Duration(seconds: 12)),
    );
  }

  @override
  Future<void> play() async {
    plays++;
    onStateChange?.call(
      const AylaAudioPlaybackState(playing: true, duration: Duration(seconds: 12)),
    );
  }

  @override
  Future<void> pause() async {
    pauses++;
    onStateChange?.call(
      const AylaAudioPlaybackState(playing: false, duration: Duration(seconds: 12)),
    );
  }

  @override
  Future<void> seek(Duration position) async => seeked = position;

  @override
  Future<void> dispose() async => disposed = true;
}

void main() {
  setUp(() {
    // 媒体图走**程序生成的示例图**（就绪态、尺寸确定）；签名链路在 setUp 里 detach
    // （示例图优先于签名，见 `ResourceImage._resolveInjectedImage`）
    aylaEnableSampleMedia();
    AylaAudioClaims.reset();
    MediaSigner.instance.detach();
  });
  tearDown(() {
    aylaDisableSampleMedia();
    AylaAudioClaims.reset();
    MediaSigner.instance.detach();
  });

  void setViewport(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Widget host(
    WidgetTester tester,
    Widget child, {
    Size viewport = const Size(560, 420),
    Alignment alignment = Alignment.topLeft,
  }) {
    setViewport(tester, viewport);
    return MaterialApp(
      home: previewScope(
        Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(size: viewport),
            child: Align(
              alignment: alignment,
              child: SizedBox(width: viewport.width, height: viewport.height, child: child),
            ),
          ),
        ),
      ),
    );
  }

  // ======================= 类型分派与尺寸 =======================

  testWidgets('图片消息：按宽高算最终尺寸（640×480 → 320×240）且点击开查看器', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaMediaContent(
          msg: _msg(media: _media(width: 640, height: 480, thumbnail: true)),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    final Rect frame = tester.getRect(find.byType(ResourceImage));
    expect(frame.width, 320, reason: 'scale = min(320/640, 320/480) = 0.5');
    expect(frame.height, 240);

    await tester.tap(find.byType(ResourceImage));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(AylaImageViewer), findsOneWidget, reason: '点击 → root overlay 查看器');

    // 关闭（查看器关闭钮的语义标签是「关闭查看」）
    await tester.tap(find.bySemanticsLabel('关闭查看').first);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(AylaImageViewer), findsNothing);
  });

  testWidgets('图片尺寸：小图不放大；无宽高 → 320×240（tsx 86–97）', (WidgetTester tester) async {
    expect(aylaMediaFrameSize(_media(width: 100, height: 80)), (width: 100, height: 80));
    expect(aylaMediaFrameSize(_media()), (width: 320, height: 240));

    await tester.pumpWidget(
      host(tester, AylaMediaContent(msg: _msg(media: _media(width: 100, height: 80)))),
    );
    await tester.pump(const Duration(milliseconds: 50));
    final Rect small = tester.getRect(find.byType(ResourceImage));
    expect(small.width, 100, reason: 'scale 上限 1（不放大）');
    expect(small.height, 80);
  });

  testWidgets('表情消息：固定 96×96', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaMediaContent(
          msg: _msg(
            type: AylaMessageType.emoji,
            media: _media(kind: AylaMediaKind.emoji, width: 240, height: 240),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    final Rect frame = tester.getRect(find.byType(ResourceImage));
    expect(frame.size, const Size(96, 96), reason: '.media-emoji 96×96（app.css 1506–1511）');
  });

  testWidgets('视频消息（有海报帧）：封面 + 48 播放键徽标', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaMediaContent(
          msg: _msg(
            type: AylaMessageType.video,
            media: _media(
              kind: AylaMediaKind.video,
              mime: 'video/mp4',
              width: 1280,
              height: 720,
              thumbnail: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(ResourceImage), findsOneWidget, reason: '海报帧封面（秒出，不挂播放器）');
    // 播放键徽标 48×48（`.video-play-badge`，app.css 1423–1439）
    final Finder badge = find
        .ancestor(
          of: find.byIcon(Icons.play_arrow_rounded),
          matching: find.byType(AnimatedContainer),
        )
        .first;
    expect(tester.getRect(badge).size, const Size(48, 48));
  });

  testWidgets('文件消息：乐观消息显示本地文件名与大小（tsx 822–839）', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaMediaContent(
          msg: _msg(
            type: AylaMessageType.file,
            mediaId: null,
            localMedia: <AylaLocalMediaPreview>[
              const AylaLocalMediaPreview(
                id: 'l1',
                kind: AylaMediaKind.file,
                mimeType: 'application/pdf',
                url: '/tmp/设计规范.pdf',
                fileName: '设计规范.pdf',
                fileSize: 2411724,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('设计规范.pdf'), findsOneWidget);
    expect(find.text('2.3 MB'), findsOneWidget, reason: 'formatBytes（api/media.ts 202–207）');
  });

  testWidgets('非媒体类型（poke）→ 媒体占位（unknown 态不显示重试）', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(tester, AylaMediaContent(msg: _msg(type: AylaMessageType.poke))),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('暂不支持的媒体类型'), findsOneWidget);
    expect(find.text('重试'), findsNothing, reason: 'unknown 态不显示重试（tsx 70–75）');
  });

  testWidgets('mixed 空 segments → 图文消息占位', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(tester, AylaMediaContent(msg: _msg(type: AylaMessageType.mixed))),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('暂不支持的图文消息类型'), findsOneWidget);
  });

  // ======================= descriptor 补拉 =======================

  testWidgets('WS 帧路径：无 descriptor 时补拉 → 渲染 + 回调持有方', (WidgetTester tester) async {
    int fetched = 0;
    AylaMediaDescriptor? delivered;
    await tester.pumpWidget(
      host(
        tester,
        AylaMediaContent(
          msg: _msg(media: null, mediaId: 'm-ws'),
          descriptorFetcher: (String id) async {
            fetched++;
            return _media(id: id, width: 200, height: 100);
          },
          onDescriptorFetched: (AylaMediaDescriptor m) => delivered = m,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(fetched, 1, reason: 'media_id 存在时补拉一次（tsx 781–804）');
    expect(delivered?.mediaId, 'm-ws', reason: '拉回后交回持有方（mergeMedia 等价）');
    expect(find.byType(ResourceImage), findsOneWidget);
  });

  testWidgets('补拉失败 → 失败占位 + 重试；重试后成功', (WidgetTester tester) async {
    int calls = 0;
    await tester.pumpWidget(
      host(
        tester,
        AylaMediaContent(
          msg: _msg(media: null, mediaId: 'm-fail'),
          descriptorFetcher: (String id) async {
            calls++;
            return calls == 1 ? null : _media(id: id, width: 200, height: 100);
          },
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('图片加载失败'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pump(); // setState → rebuild → 触发补拉
    await tester.pump(const Duration(milliseconds: 50)); // 补拉完成 → 渲染媒体
    expect(calls, 2);
    expect(find.byType(ResourceImage), findsOneWidget, reason: '重试成功后渲染媒体');
  });

  testWidgets('既无 descriptor 也无 media_id → 直接失败态（tsx 785–788）', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(tester, AylaMediaContent(msg: _msg(media: null, mediaId: null))),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('图片加载失败'), findsOneWidget);
  });

  // ======================= 语音 =======================

  testWidgets('语音消息：播放 / 暂停 + 时长 + 全局互斥（新语音抢占旧语音）', (WidgetTester tester) async {
    final _FakeAudioEngine a = _FakeAudioEngine();
    final _FakeAudioEngine b = _FakeAudioEngine();
    int created = 0;
    AylaAudioEngine factory() => created++ == 0 ? a : b;

    await tester.pumpWidget(
      host(
        tester,
        Column(
          children: <Widget>[
            AylaMediaContent(
              msg: _msg(
                id: 'v1',
                type: AylaMessageType.voice,
                media: _media(
                  id: 'mv1',
                  kind: AylaMediaKind.voice,
                  mime: 'audio/ogg',
                  duration: 12,
                  waveform: true,
                ),
              ),
              audioEngineFactory: factory,
            ),
            AylaMediaContent(
              msg: _msg(
                id: 'v2',
                type: AylaMessageType.voice,
                media: _media(
                  id: 'mv2',
                  kind: AylaMediaKind.voice,
                  mime: 'audio/ogg',
                  duration: 12,
                  waveform: true,
                ),
              ),
              audioEngineFactory: factory,
            ),
          ],
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('0:12'), findsNWidgets(2), reason: 'formatDuration（descriptor duration）');

    // 播第一条
    await tester.tap(find.byIcon(Icons.play_arrow_rounded).first);
    await tester.pump(const Duration(milliseconds: 50));
    expect(a.plays, 1);
    expect(a.opened, isTrue);

    // 播第二条 → 抢占：第一条被停
    await tester.tap(find.byIcon(Icons.play_arrow_rounded).first);
    await tester.pump(const Duration(milliseconds: 50));
    expect(b.plays, 1);
    expect(a.pauses, greaterThanOrEqualTo(1), reason: '全局同时只播一条（mediaPlayback.ts）');
  });

  testWidgets('语音消息：引擎打开失败 → 「语音播放失败」+ 重试键', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaMediaContent(
          msg: _msg(
            type: AylaMessageType.voice,
            media: _media(id: 'mv3', kind: AylaMediaKind.voice, duration: 5),
          ),
          audioEngineFactory: () => _ThrowingAudioEngine(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('语音播放失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  // ======================= 图文混排 =======================

  testWidgets('混排：text + @胶囊（@我加 glow 环）+ 180 方块图 + 240×180 视频段', (
    WidgetTester tester,
  ) async {
    final AylaMediaDescriptor pic = _media(id: 'p1', width: 400, height: 400);
    final AylaMediaDescriptor clip = _media(
      id: 'p2',
      kind: AylaMediaKind.video,
      mime: 'video/mp4',
      width: 640,
      height: 480,
      thumbnail: true,
    );
    String? tappedMention;
    await tester.pumpWidget(
      host(
        tester,
        AylaMediaContent(
          currentUserId: 'me',
          onMentionTap: (String id) => tappedMention = id,
          msg: _msg(
            type: AylaMessageType.mixed,
            segments: <AylaMediaSegment>[
              const AylaMediaSegment(type: AylaSegmentType.text, text: '看这张：'),
              const AylaMediaSegment(
                type: AylaSegmentType.mention,
                userId: 'me',
                userNickname: '我自己',
              ),
              AylaMediaSegment(
                type: AylaSegmentType.image,
                mediaId: pic.mediaId,
                media: pic,
              ),
              AylaMediaSegment(
                type: AylaSegmentType.video,
                mediaId: clip.mediaId,
                media: clip,
              ),
            ],
          ),
        ),
        viewport: const Size(600, 460),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('看这张：'), findsOneWidget);
    expect(find.text('@我自己'), findsOneWidget);

    // 图片段 180×180（`.mixed-img`，app.css 1951–1962）
    final Rect img = tester.getRect(find.byType(ResourceImage).first);
    expect(img.width, 180);
    expect(img.height, 180);

    // 视频段 240×180（tsx 461）
    final Rect video = tester.getRect(find.byType(ResourceImage).last);
    expect(video.width, 240);
    expect(video.height, 180);

    await tester.tap(find.text('@我自己'));
    await tester.pump();
    expect(tappedMention, 'me');
  });

  testWidgets('混排 mention 回退链：nickname → username → name → 未知用户', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaMediaContent(
          msg: _msg(
            type: AylaMessageType.mixed,
            segments: <AylaMediaSegment>[
              const AylaMediaSegment(type: AylaSegmentType.mention, userId: 'u9'),
              const AylaMediaSegment(
                type: AylaSegmentType.mention,
                userId: 'u8',
                userUsername: 'sakura',
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('@未知用户'), findsOneWidget);
    expect(find.text('@sakura'), findsOneWidget);
  });

  // ======================= 占位三态 =======================

  testWidgets('占位：加载中（36×36 骨架 + 文案）', (WidgetTester tester) async {
    // 永不完成的补拉 → 保持 loading 态。
    // ⚠️ 用 `Completer` 而不是 `Future.delayed`：后者会留下 pending timer，
    // 测试收尾时报「A Timer is still pending even after the widget tree was disposed」。
    final Completer<AylaMediaDescriptor?> pending =
        Completer<AylaMediaDescriptor?>();
    await tester.pumpWidget(
      host(
        tester,
        AylaMediaContent(
          msg: _msg(media: null, mediaId: 'pending'),
          descriptorFetcher: (String id) => pending.future,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('图片加载中…'), findsOneWidget);
    expect(find.byType(AylaSkeleton), findsWidgets, reason: '36×36 骨架（tsx 59–66）');
  });
}

class _ThrowingAudioEngine implements AylaAudioEngine {
  @override
  void Function(AylaAudioPlaybackState state)? onStateChange;

  @override
  Future<void> open(String url, {Map<String, String>? headers}) async {
    throw StateError('open failed');
  }

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> dispose() async {}
}
