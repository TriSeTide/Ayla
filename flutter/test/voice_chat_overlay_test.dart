/// 语音房回归锁：① 房内聊天图片可点开大图；② 窄屏聊天浮层**可命中**（点击穿透修复）。
///
/// ## 这条锁要钉住的根因（2026-10-24 用户实报）
///
/// 窄屏浮层用 `SizedBox(height: 0) + OverflowBox(alignment: bottomCenter)` 把
/// 300 高的聊天列表**溢出绘制**到输入卡上方。视觉上可见，但 Flutter 的命中测试
/// 只走**布局矩形**：
/// - `RenderBox.hitTest` 首行 `if (_size!.contains(position))`（`rendering/box.dart:2952`），
///   零高盒子的 size 不含任何向上 300px 的点 ⇒ 浮层内部永远收不到指针；
/// - 而且**从根到浮层的每个祖先 RenderBox 都必须包含该点**，聊天卡是一个
///   `mainAxisSize.min` 的 Column（盒高 = 卡片高），它上方 300px 不在其 size 内。
/// ⇒ 点击继续下沉到浮层背后的页面 = 用户说的「穿透」。
///
/// Flutter 等价实现（本锁锁住的结构）：把浮层 `Positioned` 在**语音卡槽的 Stack**
/// 里（该槽底边 = 聊天卡顶边 ⇒ 与 web 的 `bottom: 100%` 绘制几何重合），
/// 祖先盒覆盖那 300px ⇒ 可命中。
///
/// web 事实源：`VoiceRoomBody.tsx:186–205`（chatList）/ `voice.css:72–105`
/// （窄屏 `position:absolute; bottom:100%; height:300px; pointer-events:none` →
/// 展开 `auto`）。
///
/// ## 反向验证记录
/// 把 `_buildLayout` 的窄屏分支改回「浮层挂在聊天卡 Column 内 + 零高 OverflowBox」
/// ⇒ 「展开态点浮层内图片 → 打开查看器」与「点击坐标 = 图片视觉中心」两条会变红
/// （实测 `overlayTaps=0 / behindTaps=1`）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/preview_theme.dart';
import '../lib/theme/sample_media.dart';
import '../lib/widgets/base/resource_image.dart';
import '../lib/widgets/chat/image_viewer.dart';
import '../lib/widgets/voice/voice_room_body.dart';

AylaVoiceChatMessage _imageMessage() => const AylaVoiceChatMessage(
      id: 'm-img',
      senderNickname: '汐汐',
      content: '图片',
      mediaId: 'media-1',
      thumbnailUrl: '/api/v1/media/media-1/thumbnail',
    );

void main() {
  setUp(aylaEnableSampleMedia); // 示例图：走预览注入，直接就绪（不触签名）
  tearDown(aylaDisableSampleMedia);

  void setViewport(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  /// 宿主：`previewScope` 自带 Overlay（查看器插「最近」的 Overlay）。
  ///
  /// [behindTaps] = **浮层正下方**的观测器（语音卡槽里的一块可点区域）。
  /// 浮层吃到点击时它必须为 0（= 没穿透）；浮层收起时必须 +1（= 没拦截）。
  Widget host(
    WidgetTester tester, {
    required Size viewport,
    required ValueNotifier<int> behindTaps,
  }) {
    setViewport(tester, viewport);
    return MaterialApp(
      home: previewScope(
        Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(size: viewport),
            child: Stack(
              children: <Widget>[
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => behindTaps.value += 1,
                    child: const ColoredBox(color: Color(0xFF101010)),
                  ),
                ),
                Positioned.fill(
                  child: AylaVoiceRoomBody(
                    channelName: '深夜电台',
                    channelId: 'v1',
                    selfUserId: 'self',
                    visibilityLabels: const <String>['公开'],
                    messages: <AylaVoiceChatMessage>[_imageMessage()],
                    onBack: () {},
                    // 语音卡槽（浮层正下方）= 「穿透 / 拦截」的观测面：
                    // 展开态浮层盖住它 ⇒ 点击不该落到这里；收起态必须落下来。
                    voicePanelBuilder: (bool ownMaterial) => GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => behindTaps.value += 1,
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Finder chatImage() => find.byWidgetPredicate(
        (Widget w) =>
            w is SizedBox && w.width == 120 && w.height == 80, // voice.css 310–316
      );

  Finder expandToggle() => find.byWidgetPredicate(
        (Widget w) => w is Semantics && w.properties.label == '展开聊天',
      );

  group('窄屏聊天浮层可命中（点击穿透修复）', () {
    testWidgets('① 展开态：点浮层内图片的中心 → 打开查看器，且不穿透到背后', (WidgetTester tester) async {
      final ValueNotifier<int> behindTaps = ValueNotifier<int>(0);
      addTearDown(behindTaps.dispose);
      await tester.pumpWidget(
        host(tester, viewport: const Size(420, 900), behindTaps: behindTaps),
      );
      await settle(tester);

      await tester.tap(expandToggle());
      await settle(tester);

      // ② 几何断言：用图片的**真实矩形**取中心，而不是拍一个魔数坐标。
      //    浮层若仍用零高 OverflowBox 溢出绘制，这里 getRect 会是「布局坐标」
      //    （卡片内、y 远低于视觉位置）⇒ tapAt 打不到图片本体。
      final Rect imageRect = tester.getRect(chatImage());
      expect(
        imageRect.height,
        80,
        reason: '图片真实矩形必须是 120×80（voice.css 310–316）',
      );
      // 几何断言（守住「视觉位置没跑偏」+ 「绘制盒 / 命中盒一致」）：
      // 窄屏卡片堆叠 = 语音卡槽（上）+ 输入卡（下），浮层贴在**语音卡槽底边**、
      // 向上 300 高（voice.css:72–105 的 `bottom: 100%`）。
      // 视口 900 高时实测：输入卡顶 = 835、浮层 = 535..835 ⇒ 图片中心 671 在浮层内。
      // 若实现退回「零高 OverflowBox」，getRect 会给出卡片内的布局坐标（≈643）而非
      // 浮层绘制坐标 ⇒ 下面 tapAt 会打空。
      final Rect overlayRect = tester.getRect(find.byType(AylaResourceImage));
      expect(
        imageRect.center,
        overlayRect.center,
        reason: '图片按钮矩形与图片本体矩形必须重合（命中盒 = 绘制盒）',
      );
      expect(
        imageRect.center.dy,
        greaterThan(535 - 1),
        reason: '浮层贴在语音卡槽底边向上 300；实际 $imageRect',
      );
      expect(
        imageRect.center.dy,
        lessThan(835 + 1),
        reason: '图片必须落在浮层内（输入卡顶边之上）；实际 $imageRect',
      );

      await tester.tapAt(imageRect.center);
      await settle(tester);

      expect(
        find.byType(AylaImageViewer),
        findsOneWidget,
        reason: '点浮层内图片必须打开大图查看器（穿透的根因是浮层收不到指针）',
      );
      expect(
        behindTaps.value,
        0,
        reason: '点击必须被浮层吃掉，不能穿透到浮层下方的语音卡',
      );
    });

    testWidgets('② 收起态：同坐标不打开查看器，且不拦截背后点击', (WidgetTester tester) async {
      final ValueNotifier<int> behindTaps = ValueNotifier<int>(0);
      addTearDown(behindTaps.dispose);
      await tester.pumpWidget(
        host(tester, viewport: const Size(420, 900), behindTaps: behindTaps),
      );
      await settle(tester);

      // 收起态浮层仍挂载（opacity 0 + IgnorePointer），但**零命中**。
      // 取「展开态时图片所在的坐标」（浮层中部，那里没有别的可点件）
      // ⇒ 点击必须落到**背后**的全屏宿主按钮上（= 不拦截）。
      await tester.tapAt(const Offset(115, 671));
      await settle(tester);

      expect(
        find.byType(AylaImageViewer),
        findsNothing,
        reason: '收起态（pointer-events: none）不得打开查看器',
      );
      expect(
        behindTaps.value,
        1,
        reason: '收起态不得拦截点击（web voice.css:93 pointer-events: none）',
      );
    });
  });

  group('宽屏聊天列表图片可点开', () {
    testWidgets('③ 宽屏（≥769）：点卡片内图片中心 → 打开查看器', (WidgetTester tester) async {
      final ValueNotifier<int> behindTaps = ValueNotifier<int>(0);
      addTearDown(behindTaps.dispose);
      await tester.pumpWidget(
        host(tester, viewport: const Size(1200, 800), behindTaps: behindTaps),
      );
      await settle(tester);

      final Rect imageRect = tester.getRect(chatImage());
      await tester.tapAt(imageRect.center);
      await settle(tester);

      expect(
        find.byType(AylaImageViewer),
        findsOneWidget,
        reason: '宽屏与窄屏共用 _buildMessage ⇒ 图片同样可点开',
      );
      expect(behindTaps.value, 0);
    });
  });

  group('图片图源', () {
    testWidgets('④ 缩略图 src / fit / 尺寸与 web 逐值一致（voice.css 310–316）',
        (WidgetTester tester) async {
      final ValueNotifier<int> behindTaps = ValueNotifier<int>(0);
      addTearDown(behindTaps.dispose);
      await tester.pumpWidget(
        host(tester, viewport: const Size(1200, 800), behindTaps: behindTaps),
      );
      await settle(tester);

      final AylaResourceImage image = tester.widget<AylaResourceImage>(
        find.byType(AylaResourceImage),
      );
      expect(image.src, '/api/v1/media/media-1/thumbnail');
      expect(image.fit, BoxFit.cover); // object-fit: cover
      expect(tester.getSize(chatImage()), const Size(120, 80));
    });
  });
}