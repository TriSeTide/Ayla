/// 弹幕图片**解码尺寸 / 变体**回归锁 + 「大图（动图）弹幕之后列表仍继续渲染」。
///
/// ## 为什么要有这个文件（用户实报 → 根因）
///
/// 用户实报：直播弹幕**发送一张过大的图片（测试用的是动图 GIF）**之后，
/// 发送完成会导致**弹幕列表刷新不出来**，必须退出直播间重进才能看到新弹幕。
///
/// 根因（渲染层，本文件锁的就是它）：
/// - `widgets/live/danmaku.dart` 的列表图片钮（`_DanmakuImageButton`，96×64 槽位）
///   **没有给 `AylaResourceImage` 传 width/height** ⇒ `resource_image.dart:549–567` 的
///   `if (widget.width == null && widget.height == null)` 命中 ⇒ `decodeW/decodeH` 全为 null
///   ⇒ `Image.network` 的 `cacheWidth/cacheHeight` 为空 ⇒ **按原始分辨率完整解码**。
///   一张 4000×3000 的图 ≈ 48MB RGBA；动图（GIF）还会逐帧解码、逐帧上传纹理
///   ⇒ 光栅线程/UI 线程被持续占满 ⇒ 后续弹幕的 build/layout/paint 排不上
///   ⇒ 表现为「列表不再刷新，要退出直播间重进才恢复」。
/// - 列表图片钮**也没有传 `variant`** ⇒ 签名走 original（
///   `MediaSigner.sign(mediaId)` 的 `variant == null` 分支，`core/media/media_signer.dart:97`）
///   ⇒ 「为了 96×64 的槽位去签名 + 下载 + 解码整整一张原图」。
///
/// ## 为什么 web 没这个问题（所以这里是**有意偏离** web）
/// - `web/src/components/live/DanmakuList.tsx:72–78`：`ResourceImage` 不传 variant、
///   也无 width/height（尺寸由 `.danmaku-image` CSS 决定），最终是
///   `ResourceImage.tsx:173–185` 的 `<img loading="lazy">`；
/// - 浏览器 `<img>` 是原生渐进解码 + HTTP 缓存，位图按**布局尺寸**进渲染引擎缓存，
///   不会像 Flutter 的 `Image.network` 那样把整幅原图解码进内存/纹理。
///   ⇒ 同样的写法在 web 上无害，在 Flutter 上是性能缺陷 ⇒ 必须偏离。
/// - 偏离形式：**显式 size + `variant: MediaVariant.thumb`**（原图只在查看器里取，
///   与「先缩略图、点开才原图」的 2026-10-23 用户裁决一致）。详见
///   `danmaku.dart` 文件头「与 web 的有意偏离」。
///
/// ## 与聊天气泡的边界
/// `widgets/chat/media_content.dart:538–539` 有「GIF 例外 → 走原图保动画」的既有做法。
/// 那是**聊天气泡**的语义（气泡随图放大，动起来是内容本身）；
/// 弹幕的 96×64 / 72×36 槽位是「缩略预览 + 点击看大图」，**不得复用**该策略
/// （否则一张大 GIF 就会拖死 UI）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/media/media_cache.dart';
import '../lib/core/media/media_signer.dart';
import '../lib/core/models/media_kind.dart';
import '../lib/core/models/post.dart' show AylaMediaDescriptor;
import '../lib/core/net/dio_client.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/sample_media.dart';
import '../lib/widgets/base/resource_image.dart';
import '../lib/widgets/live/danmaku.dart';

/// 假签名客户端：记录**每次签发请求的 body**（区分 original / thumb），
/// 并按 variant 返回可区分的 URL。
///
/// 用它而不是「detach」（既有测试的做法）的原因：detach 只会让图片进失败态，
/// **量不到「到底签的是原图还是缩略图」**——而那正是本次缺陷的一半。
class _SignClient implements DioClient {
  final List<Map<String, dynamic>?> bodies = <Map<String, dynamic>?>[];

  @override
  Future<T> post<T>(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
  }) async {
    bodies.add(body is Map<String, dynamic> ? body : null);
    final bool isThumb = body is Map && body['variant'] == 'thumb';
    return <String, dynamic>{
      'url': 'https://minio.local/bucket/' + (isThumb ? 'thumb' : 'orig') + '.gif?sig=x',
      'expires_at': DateTime.now().millisecondsSinceEpoch / 1000 + 3600,
    } as T;
  }

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

/// 一张「巨大动图」的媒体描述符（用户实测形态：4000×3000 GIF ≈ 12M 像素，
/// 按 RGBA 完整解码约 48MB；动图还会逐帧解码）。
AylaMediaDescriptor _hugeGif(String mediaId) => AylaMediaDescriptor(
      mediaId: mediaId,
      kind: AylaMediaKind.image,
      mimeType: 'image/gif',
      size: 12 * 1024 * 1024,
      status: 'ready',
      width: 4000,
      height: 3000,
      thumbnail: kMediaPathPrefix + mediaId + '/thumbnail',
    );

AylaDanmakuEntry _mediaEntry(String id, String mediaId, {String content = '图片'}) =>
    AylaDanmakuEntry(
      id: id,
      senderNickname: '观众',
      senderUserId: 'u1',
      content: content,
      mediaId: mediaId,
      media: _hugeGif(mediaId),
    );

AylaDanmakuEntry _textEntry(String id, String content) => AylaDanmakuEntry(
      id: id,
      senderNickname: '观众',
      senderUserId: 'u2',
      content: content,
    );

void main() {
  late _SignClient client;

  setUp(() {
    aylaDisableSampleMedia();
    // 关掉本地漫游缓存：widget 测试跑在 FakeAsync 下，真实磁盘 IO 的 future
    // 不会被推进（同 danmaku_list_test.dart 既有做法）。
    AylaMediaCache.instance.enabledForTest = false;
    client = _SignClient();
    MediaSigner.instance.detach();
    MediaSigner.instance.attach(client);
  });

  tearDown(() {
    aylaDisableSampleMedia();
    MediaSigner.instance.detach();
    AylaMediaCache.instance.enabledForTest = true;
  });

  void setViewport(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Widget host(WidgetTester tester, Widget child) {
    const Size viewport = Size(420, 480);
    setViewport(tester, viewport);
    return MaterialApp(
      home: previewScope(
        Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(size: viewport),
            child: SizedBox.fromSize(size: viewport, child: child),
          ),
        ),
      ),
    );
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// 图片弹幕的**槽位图**（按 96×64 / 72×36 认；头像等件不在其中）。
  List<AylaResourceImage> slotImages(WidgetTester tester) => tester
      .widgetList<AylaResourceImage>(find.byType(AylaResourceImage))
      .where(
        (AylaResourceImage w) =>
            (w.width == 96 && w.height == 64) ||
            (w.width == 72 && w.height == 36),
      )
      .toList();

  group('列表图片槽位：显式显示尺寸（解码尺寸的唯一来源）', () {
    testWidgets('★ 大 GIF 弹幕的图片钮必须传 width=96 / height=64（否则按原图解码）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaDanmakuList(
            items: <AylaDanmakuEntry>[_mediaEntry('d1', 'm-huge')],
          ),
        ),
      );
      await settle(tester);

      final AylaResourceImage image = tester.widget<AylaResourceImage>(
        find.byType(AylaResourceImage),
      );
      expect(
        image.width,
        96,
        reason: '★ .danmaku-image width: 96px 必须传给 AylaResourceImage —— '
            'resource_image.dart:552–554 只在 width/height 任一非空时才产生 decodeW/decodeH；'
            '两者都 null ⇒ 按原图完整解码（4000×3000 GIF ≈ 48MB RGBA + 逐帧解码）',
      );
      expect(
        image.height,
        64,
        reason: '★ .danmaku-image height: 64px（同 width，缺一个也会退化）',
      );

      // 交叉验证：解码尺寸确实按「显示尺寸 × DPR」算出来了
      // （resource_image.dart:549–567；DPR=1 ⇒ 长边 96 ≥ 短边 64 ⇒ 只卡 width）。
      final Image rendered = tester.widget<Image>(find.byType(Image));
      final ImageProvider provider = rendered.image;
      expect(
        provider is ResizeImage ? provider.width : null,
        96,
        reason: '★ 解码宽度必须是 96（显示尺寸 × DPR），不是 4000（原图宽度）',
      );
      expect(
        provider is ResizeImage ? provider.height : 'not-resized',
        isNot(3000),
        reason: '★ 解码高度绝不能是原图高度 3000（只挑一条边，避免 exact 压变宽高比）',
      );
    });

    testWidgets('★ 列表图片钮必须走 thumb 变体（96×64 槽位不拉原图）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaDanmakuList(
            items: <AylaDanmakuEntry>[_mediaEntry('d1', 'm-thumb')],
          ),
        ),
      );
      await settle(tester);

      final AylaResourceImage image = tester.widget<AylaResourceImage>(
        find.byType(AylaResourceImage),
      );
      expect(
        image.variant,
        MediaVariant.thumb,
        reason: '★ 不传 variant ⇒ MediaSigner.sign(mediaId) 的 variant==null 分支 = '
            'original（media_signer.dart:97）⇒ 为 96×64 的槽位签名 + 下载 + 解码整张原图',
      );

      // 把「变体」从组件参数锁到真实网络契约上（签发请求体）。
      final bool sawThumb = client.bodies.any(
        (Map<String, dynamic>? body) =>
            body != null && body['variant'] == 'thumb',
      );
      expect(
        sawThumb,
        isTrue,
        reason: '★ 弹幕图片必须签发 thumb 变体（POST /media/<id>:sign {variant:"thumb"}）；'
            '实发请求体 = ' + client.bodies.toString(),
      );
      final bool sawOriginal = client.bodies.any(
        (Map<String, dynamic>? body) =>
            body == null || !body.containsKey('variant'),
      );
      expect(
        sawOriginal,
        isFalse,
        reason: '★ 列表槽位**不得**签发 original（那次请求就是「拉整张原图」的入口）；'
            '实发请求体 = ' + client.bodies.toString(),
      );
    });
  });

  group('飘弹幕层图片槽位：同样显式尺寸 + thumb', () {
    testWidgets('★ 飘层图片钮传 72×36 + thumb 变体', (WidgetTester tester) async {
      final GlobalKey<_OverlayStageState> key = GlobalKey<_OverlayStageState>();
      await tester.pumpWidget(
        host(
          tester,
          // 挂载时只有文字（基线不重放），随后追加一条大 GIF 弹幕
          _OverlayStage(
            key: key,
            initial: <AylaDanmakuEntry>[_textEntry('t0', '基线弹幕')],
          ),
        ),
      );
      await settle(tester);
      key.currentState!.append(_mediaEntry('f1', 'm-fly'));
      await settle(tester);

      final List<AylaResourceImage> images = slotImages(tester);
      expect(images, hasLength(1), reason: '飘层应渲染 1 个图片槽位');
      expect(images.single.width, 72, reason: '★ .danmaku-fly-img width: 72px');
      expect(images.single.height, 36, reason: '★ .danmaku-fly-img height: 36px');
      expect(
        images.single.variant,
        MediaVariant.thumb,
        reason: '★ tsx 196 variant="thumb"（飘层更不该取原图：动图会逐帧解码）',
      );
    });
  });

  group('★ 用户实报回归：大图/动图弹幕到达后，列表仍继续渲染后续弹幕', () {
    testWidgets('大 GIF 弹幕 + 之后两条文字弹幕 ⇒ 列表条数 +2（不卡死、不丢刷新）', (
      WidgetTester tester,
    ) async {
      final GlobalKey<_ListStageState> key = GlobalKey<_ListStageState>();
      await tester.pumpWidget(host(tester, _ListStage(key: key)));
      await settle(tester);

      // ① 先到一条「巨大的动图」弹幕（用户实测形态：4000×3000 GIF）
      key.currentState!.append(_mediaEntry('big', 'm-big-gif'));
      await settle(tester);
      expect(find.byType(AylaDanmakuList), findsOneWidget);
      expect(slotImages(tester), hasLength(1), reason: '大图弹幕的槽位应已渲染');

      // ② 紧接着到两条后续弹幕 —— 修复前这里「列表不刷新」；现在两条都必须出现。
      const String first = '第一条后续弹幕';
      const String second = '第二条后续弹幕';
      key.currentState!.append(_textEntry('t1', first));
      key.currentState!.append(_textEntry('t2', second));
      await settle(tester);

      expect(
        find.text(first),
        findsOneWidget,
        reason: '★ 大图弹幕到达后，后续文字弹幕必须能渲染出来（用户实报：不能）',
      );
      expect(
        find.text(second),
        findsOneWidget,
        reason: '★ 连续两条都要出现（证明列表没有卡在某一帧）',
      );

      // ③ 所有条目都在（id 作 key，等价 web data-history-id）
      expect(find.byKey(const ValueKey<String>('big')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('t1')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('t2')), findsOneWidget);

      // ④ 关键口径：所有图片槽位都带了尺寸（= 没有一处退回「按原图解码」）
      for (final AylaResourceImage image in slotImages(tester)) {
        expect(image.width, isNotNull);
        expect(image.height, isNotNull);
      }
    });
  });
}

/// 自持 items 的列表宿主（测试里追加弹幕 = 模拟 WS 回帧后的列表增长）。
class _ListStage extends StatefulWidget {
  const _ListStage({super.key, this.initial = const <AylaDanmakuEntry>[]});

  final List<AylaDanmakuEntry> initial;

  @override
  State<_ListStage> createState() => _ListStageState();
}

class _ListStageState extends State<_ListStage> {
  late List<AylaDanmakuEntry> items = widget.initial;

  void append(AylaDanmakuEntry entry) =>
      setState(() => items = <AylaDanmakuEntry>[...items, entry]);

  @override
  Widget build(BuildContext context) => AylaDanmakuList(items: items);
}

/// 自持 items 的飘层宿主（挂载基线不重放；追加 = 只飘新的那条）。
class _OverlayStage extends StatefulWidget {
  const _OverlayStage({super.key, this.initial = const <AylaDanmakuEntry>[]});

  final List<AylaDanmakuEntry> initial;

  @override
  State<_OverlayStage> createState() => _OverlayStageState();
}

class _OverlayStageState extends State<_OverlayStage> {
  late List<AylaDanmakuEntry> items = widget.initial;

  void append(AylaDanmakuEntry entry) =>
      setState(() => items = <AylaDanmakuEntry>[...items, entry]);

  @override
  Widget build(BuildContext context) => Stack(
        children: <Widget>[
          Positioned.fill(
            child: AylaDanmakuOverlay(items: items, channelKey: 1),
          ),
        ],
      );
}
