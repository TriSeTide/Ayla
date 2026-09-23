/// B2-1：画面飘弹幕层定向测试 —— 逐条对照 `components/live/DanmakuOverlay.tsx`(213)
/// 与 `components/live/danmakuTracks.ts`、`live.css:867–929 / 1006–1018`，
/// 并移植官方用例 `vitest/danmaku-overlay.test.tsx` 的行为断言。
///
/// 覆盖：挂载基线不重放 / 只飘新弹幕 / 起点与终点像素（关键帧
/// `translateX(calc(-100% - 24px))`）/ 飘完移除 / 同轨道最小间距与轨道分派 /
/// 图片弹幕（72×36、占位文案不飘文字、点击放大）/ 无缩略图不飘 / 头像位置 /
/// reduced-motion 整层不渲染 / 换台清屏 / MAX_FLYING 上限。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/media/media_signer.dart';
import '../lib/core/models/media_kind.dart';
import '../lib/core/models/post.dart' show AylaMediaDescriptor;
import '../lib/theme/preview_theme.dart';
import '../lib/theme/sample_media.dart';
import '../lib/widgets/danmaku.dart';
import '../lib/widgets/danmaku_tracks.dart';
import '../lib/widgets/image_viewer.dart';
import '../lib/widgets/resource_image.dart';

AylaDanmakuEntry _entry(
  String id, {
  String content = '',
  String avatar = '',
  String? mediaId,
  bool withThumbnail = true,
}) {
  return AylaDanmakuEntry(
    id: id,
    senderNickname: '观众',
    senderUserId: 'u1',
    senderAvatarUrl: avatar,
    content: content,
    mediaId: mediaId,
    media: mediaId == null
        ? null
        : AylaMediaDescriptor(
            mediaId: mediaId,
            kind: AylaMediaKind.image,
            thumbnail: withThumbnail
                ? '$kMediaPathPrefix$mediaId/thumbnail'
                : null,
          ),
  );
}

/// 舞台宿主：自持 items 与 channelKey，供测试驱动「追加 / 换台」。
class _Stage extends StatefulWidget {
  const _Stage({super.key, this.initial = const <AylaDanmakuEntry>[]});

  final List<AylaDanmakuEntry> initial;

  @override
  State<_Stage> createState() => _StageState();
}

class _StageState extends State<_Stage> {
  late List<AylaDanmakuEntry> items = widget.initial;
  int channel = 1;

  void append(AylaDanmakuEntry entry) =>
      setState(() => items = <AylaDanmakuEntry>[...items, entry]);

  void appendAll(Iterable<AylaDanmakuEntry> entries) =>
      setState(() => items = <AylaDanmakuEntry>[...items, ...entries]);

  void switchChannel([List<AylaDanmakuEntry> next = const <AylaDanmakuEntry>[]]) =>
      setState(() {
        channel += 1;
        items = next;
      });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: AylaDanmakuOverlay(items: items, channelKey: channel),
        ),
      ],
    );
  }
}

void main() {
  setUp(() {
    aylaDisableSampleMedia();
    MediaSigner.instance.detach();
  });
  tearDown(() {
    aylaDisableSampleMedia();
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
    /// 弹幕层所在「视频区」的尺寸（轨道数 / 起点都由它决定）。
    Size stage = const Size(640, 200),

    /// 应用窗口尺寸（查看器是全屏浮层，需要比视频区更高的可用高度）。
    Size window = const Size(640, 640),
    bool reduceMotion = false,
  }) {
    setViewport(tester, window);
    return MaterialApp(
      home: previewScope(
        Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              size: window,
              disableAnimations: reduceMotion,
            ),
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox.fromSize(size: stage, child: child),
            ),
          ),
        ),
      ),
    );
  }

  /// 飘条目（`_FlyingDanmaku` 的 key = 弹幕 id）。
  Finder fly(String id) => find.byKey(ValueKey<String>(id));

  /// 实际绘制位置：量**位移层内部**的内容（`Transform` 自身不随位移动，
  /// `getRect(fly(id))` 读到的是它的布局盒 —— 实测踩过）。
  Offset flyOrigin(WidgetTester tester, String id) => tester.getTopLeft(
    find.descendant(of: fly(id), matching: find.byType(Row)),
  );

  /// 自身内容宽（关键帧终点 `calc(-100% - 24px)` 的 `100%`）。
  double flyWidth(WidgetTester tester, String id) =>
      tester.getSize(fly(id)).width;

  int flyCount() => find
      .byWidgetPredicate((Widget w) => w.key is ValueKey<String>)
      .evaluate()
      .length;

  group('基线与去重（tsx 99–149）', () {
    testWidgets('进房历史（挂载基线）不重放', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          const _Stage(
            initial: <AylaDanmakuEntry>[
              AylaDanmakuEntry(id: 'h1', senderNickname: '观众', content: '历史1'),
              AylaDanmakuEntry(id: 'h2', senderNickname: '观众', content: '历史2'),
            ],
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('历史1'), findsNothing);
      expect(flyCount(), 0);
    });

    testWidgets('追加的新弹幕才飘（同一条重复帧也只飘一次）', (WidgetTester tester) async {
      final GlobalKey<_StageState> stage = GlobalKey<_StageState>();
      await tester.pumpWidget(
        host(tester, _Stage(key: stage, initial: <AylaDanmakuEntry>[_entry('h1')])),
      );
      await tester.pump();

      stage.currentState!.append(_entry('n1', content: '新弹幕飘过'));
      await tester.pump();
      expect(find.text('新弹幕飘过'), findsOneWidget);
      expect(flyCount(), 1);

      // 重连对账把同一批（含已飘过的 n1）再送进来：n1 不重飘
      stage.currentState!.appendAll(<AylaDanmakuEntry>[
        _entry('n1', content: '新弹幕飘过'),
        _entry('n2', content: '对账新弹幕'),
      ]);
      await tester.pump();
      expect(find.text('对账新弹幕'), findsOneWidget);
      expect(flyCount(), 2);
      expect(find.text('新弹幕飘过'), findsOneWidget);
    });
  });

  group('关键帧与几何（live.css 1006–1018 / tsx 117–140）', () {
    testWidgets('起点 = 容器宽；随后向左移动（量中间帧像素）', (WidgetTester tester) async {
      final GlobalKey<_StageState> stage = GlobalKey<_StageState>();
      await tester.pumpWidget(host(tester, _Stage(key: stage)));
      await tester.pump();

      stage.currentState!.append(_entry('n1', content: '飘'));
      await tester.pump();

      // `--fly-from` = 容器宽 640；top = 8 + 轨道 0×36
      expect(flyOrigin(tester, 'n1').dx, 640);
      expect(flyOrigin(tester, 'n1').dy, kDanmakuOverlayTopPad);

      await tester.pump(const Duration(milliseconds: 1000));
      final double moved = flyOrigin(tester, 'n1').dx;
      expect(moved, lessThan(640));
      // 线性：已走 1000ms / 总时长 × 行程（终点 = 自身宽 + 24）
      final double dur = flyDurationMs(640).toDouble();
      final double end = -(flyWidth(tester, 'n1') + 24);
      expect(moved, closeTo(640 + (end - 640) * (1000 / dur), 2));
    });

    testWidgets('终点 = 自身宽 + 24（calc(-100% - 24px)）；飘完从画面移除', (WidgetTester tester) async {
      final GlobalKey<_StageState> stage = GlobalKey<_StageState>();
      await tester.pumpWidget(host(tester, _Stage(key: stage)));
      await tester.pump();

      stage.currentState!.append(_entry('n1', content: '飘完就走'));
      await tester.pump();

      final double ownWidth = flyWidth(tester, 'n1');
      final int dur = flyDurationMs(640);

      await tester.pump(Duration(milliseconds: dur - 60));
      expect(
        flyOrigin(tester, 'n1').dx,
        closeTo(-(ownWidth + 24), 14),
      );

      await tester.pump(const Duration(milliseconds: 120));
      await tester.pump();
      expect(fly('n1'), findsNothing); // animationend → 移除
    });

    testWidgets('同轨道最小间距：后一条在前一条 gap 之后才开始（不重叠）', (WidgetTester tester) async {
      final GlobalKey<_StageState> stage = GlobalKey<_StageState>();
      await tester.pumpWidget(host(tester, _Stage(key: stage)));
      await tester.pump();

      // 容器高 200 ⇒ 轨道数 = floor(200/36) = 5
      expect(trackCountForHeight(200), 5);
      stage.currentState!.appendAll(<AylaDanmakuEntry>[
        for (int i = 0; i < 6; i += 1) _entry('b$i', content: '弹幕$i'),
      ]);
      await tester.pump();
      expect(flyCount(), 6);

      // 轨道分派：top = 8 + 轨道 × 36 ⇒ (dy - 8) % 36 == 0
      final Set<double> tops = <double>{
        for (int i = 0; i < 6; i += 1) flyOrigin(tester, 'b$i').dy,
      };
      expect(tops.length, greaterThanOrEqualTo(2));
      for (final double top in tops) {
        expect((top - kDanmakuOverlayTopPad) % kDanmakuTrackHeight, 0);
      }

      // 同轨道：第一条已移动，第二条仍在起点（gap ≈ 400ms 的延迟内）
      await tester.pump(const Duration(milliseconds: 200));
      final Map<double, List<String>> byTop = <double, List<String>>{};
      for (int i = 0; i < 6; i += 1) {
        byTop
            .putIfAbsent(flyOrigin(tester, 'b$i').dy, () => <String>[])
            .add('b$i');
      }
      for (final List<String> sameTrack in byTop.values) {
        if (sameTrack.length < 2) continue;
        expect(flyOrigin(tester, sameTrack[0]).dx, lessThan(640)); // 先发的已在飘
        expect(flyOrigin(tester, sameTrack[1]).dx, 640); // 后发的还在起点等 gap
      }
      expect(minGapMs(), greaterThan(200)); // 上一步断言的依据
    });
  });

  group('内容（tsx 173–201 + live.css 896–929）', () {
    testWidgets('头像 20×20 且在文字左侧；无头像不渲染', (WidgetTester tester) async {
      final GlobalKey<_StageState> stage = GlobalKey<_StageState>();
      await tester.pumpWidget(host(tester, _Stage(key: stage)));
      await tester.pump();

      stage.currentState!.append(
        _entry('a1', content: '带头像', avatar: 'https://x/a.png'),
      );
      await tester.pump();
      final Finder avatar = find.byWidgetPredicate(
        (Widget w) => w is Container && w.constraints?.maxWidth == 20,
      );
      expect(avatar, findsOneWidget);
      expect(
        tester.getTopLeft(avatar).dx,
        lessThan(tester.getTopLeft(find.text('带头像')).dx),
      );

      stage.currentState!.append(_entry('a2', content: '无头像'));
      await tester.pump();
      expect(avatar, findsOneWidget); // 仍只有 a1 那个
    });

    testWidgets('图片弹幕：72×36 缩略图 + 占位文案「图片」不飘文字 + 点击放大', (WidgetTester tester) async {
      aylaEnableSampleMedia();
      final GlobalKey<_StageState> stage = GlobalKey<_StageState>();
      await tester.pumpWidget(host(tester, _Stage(key: stage)));
      await tester.pump();

      stage.currentState!.append(_entry('m1', content: '图片', mediaId: 'm1'));
      await tester.pump();

      expect(find.text('图片'), findsNothing); // tsx 121
      final ResourceImage image = tester.widget<ResourceImage>(
        find.byType(ResourceImage),
      );
      expect(image.src, '${kMediaPathPrefix}m1/thumbnail'); // tsx 68–71
      final Finder frame = find.byWidgetPredicate(
        (Widget w) => w is Container && w.constraints?.maxWidth == 72,
      );
      expect(tester.getSize(frame), const Size(72, 36));

      // 起点在容器右缘之外 ⇒ 先推进 1s 让它飘进画面，再点图片钮本体
      // （ResourceImage 解码前可能是 0 尺寸，不可作点击目标）
      await tester.pump(const Duration(milliseconds: 1000));
      await tester.tap(frame, warnIfMissed: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(AylaImageViewer), findsOneWidget);
    });

    testWidgets('纯图弹幕无缩略图：整条不飘（tsx 123–124）', (WidgetTester tester) async {
      final GlobalKey<_StageState> stage = GlobalKey<_StageState>();
      await tester.pumpWidget(host(tester, _Stage(key: stage)));
      await tester.pump();

      stage.currentState!.append(
        _entry('m2', content: '图片', mediaId: 'm2', withThumbnail: false),
      );
      await tester.pump();
      expect(flyCount(), 0);
    });
  });

  group('降级与重置（tsx 155–156 / 100–106）', () {
    testWidgets('reduced-motion：整层不渲染', (WidgetTester tester) async {
      final GlobalKey<_StageState> stage = GlobalKey<_StageState>();
      await tester.pumpWidget(host(tester, _Stage(key: stage), reduceMotion: true));
      await tester.pump();

      stage.currentState!.append(_entry('n1', content: '不该出现'));
      await tester.pump();
      expect(find.text('不该出现'), findsNothing);
      expect(flyCount(), 0);
    });

    testWidgets('换台：清空画面 + 基线重建（切台无残留）', (WidgetTester tester) async {
      final GlobalKey<_StageState> stage = GlobalKey<_StageState>();
      await tester.pumpWidget(host(tester, _Stage(key: stage)));
      await tester.pump();

      stage.currentState!.append(_entry('n1', content: '上一台'));
      await tester.pump();
      expect(flyCount(), 1);

      // 换台：新频道的现有弹幕（历史）不重放
      stage.currentState!.switchChannel(<AylaDanmakuEntry>[
        _entry('c1', content: '新台历史'),
      ]);
      await tester.pump();
      expect(flyCount(), 0);
      expect(find.text('上一台'), findsNothing);

      // 新台之后到来的才是新弹幕
      stage.currentState!.append(_entry('c2', content: '新台新弹幕'));
      await tester.pump();
      expect(find.text('新台新弹幕'), findsOneWidget);
    });

    testWidgets('同时飘的上限 MAX_FLYING = 80（超限丢最旧）', (WidgetTester tester) async {
      final GlobalKey<_StageState> stage = GlobalKey<_StageState>();
      await tester.pumpWidget(host(tester, _Stage(key: stage)));
      await tester.pump();

      stage.currentState!.appendAll(<AylaDanmakuEntry>[
        for (int i = 0; i < 100; i += 1) _entry('e$i', content: '弹幕$i'),
      ]);
      await tester.pump();
      expect(flyCount(), kDanmakuMaxFlying);
      // 丢最旧 ⇒ 最新的仍在
      expect(fly('e99'), findsOneWidget);
      expect(fly('e0'), findsNothing);
    });
  });
}
