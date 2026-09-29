/// `AylaPanelSwap` 的**玻璃安全换场**（2026-09-29）：Impeller 校验刷屏修复的定向锁。
///
/// 背景：`Opacity` 祖先 + `BackdropFilter` 后代会被 Impeller 拒绝并刷屏
/// （`Contents::SetInheritedOpacity should never be called when
/// Contents::CanAcceptOpacity returns false`）。处置与逐条依据见
/// `lib/widgets/motion/panel_swap.dart` 文件头（论证与 `lib/widgets/base/reveal.dart`
/// 文件头同源：`RenderOpacity.paint` + `OpacityLayer.addToScene` 的 `alpha == 255` 分支）。
/// 本文件锁三件事：
///
/// ① **位移仍随动画推进**：tab 档 300ms 单段 `x +20 → 0`、swap 档 600ms 双段
///    `y +20 → 0` —— 玻璃档只是不淡入，位移不许丢；
/// ② **含玻璃子树在动画中不产生 pushOpacity**：玻璃子树向上最近的 `Opacity` 恒为 1.0，
///    且 layer 树里不得出现「`alpha != 255` 的 `OpacityLayer` 祖先 → `BackdropFilterLayer`
///    后代」（依据 `rendering/layer.dart:2186–2200`：`OpacityLayer.addToScene` 只在
///    `alpha < 255` 时 `pushOpacity`，`alpha == 255` 走 `pushOffset`）；
/// ③ **默认档 = 改前行为**（对照组）：不声明 `fadeGlass` 时玻璃子树**确实**进 opacity
///    中间态 —— 证明 ② 的探针不是恒 false 的假绿，也证明「漏声明」是**可见的**刷屏
///    而不是静默的视觉退化。
///
/// ② 的子树用的是**真实调用点的件**（`AylaMessageList` 的他人气泡 /
/// `AylaMessageInput` 的 `.composer`），不是替身 —— 与 `group_chat_page.dart`
/// 的两处含玻璃调用点同源。
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/chat_message.dart';
import '../lib/theme/glass.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/widgets/chat/message_input.dart';
import '../lib/widgets/chat/message_list.dart' show AylaMessageList;
import '../lib/widgets/motion/panel_swap.dart';

/// 换场宿主：`identity` 可切（[swapIdentity] 一次 = 触发就地重播）。
class _SwapHost extends StatefulWidget {
  const _SwapHost({
    required this.mode,
    required this.fadeGlass,
    required this.child,
  });

  final AylaPanelSwapMode mode;
  final bool fadeGlass;
  final Widget child;

  @override
  State<_SwapHost> createState() => _SwapHostState();
}

class _SwapHostState extends State<_SwapHost> {
  String _identity = 'a';

  /// 切一次身份 ⇒ `didUpdateWidget` 判定 changed 并 `forward(from: 0)`。
  void swapIdentity() => setState(() => _identity = _identity == 'a' ? 'b' : 'a');

  @override
  Widget build(BuildContext context) => Center(
        child: SizedBox(
          width: 320,
          height: 360,
          child: AylaPanelSwap(
            identity: _identity,
            mode: widget.mode,
            fadeGlass: widget.fadeGlass,
            child: widget.child,
          ),
        ),
      );
}

void main() {
  Widget host(Widget child) => MaterialApp(home: previewScope(child));

  /// 玻璃子树（真实件，与群聊页调用点同源）——
  /// tab 档：消息区的**他人气泡**（`.bubble-other` 的 `AylaGlassBackdrop`，
  /// `message_bubble.dart:700–707`）；
  /// swap 档：输入框（`.composer` 顶层恒为 `AylaGlassSurface`，
  /// `message_input.dart:559/575` 窄宽两分支）。
  ///
  /// ⚠️ tab 档**不能**用空列表：空态 `_empty()` 是纯文本（`message_list.dart:837–854`），
  /// 回底键的玻璃被 `AnimatedOpacity(0)` 挡住不 paint（`message_list.dart:913–922`）
  /// ⇒ 空列表**一个玻璃层都不画**，拿它做断言是假绿（首版实测踩到）。
  Widget glassList() => AylaMessageList(
        messages: <AylaChatMessage>[
          AylaChatMessage(
            id: 'm1',
            conversationId: 'c1',
            senderId: 'u-other',
            type: AylaMessageType.text,
            content: '你好',
            status: AylaMessageStatus.sent,
            seq: 1,
            createdAt: '2026-01-01T00:00:00Z',
          ),
        ],
        currentUserId: 'u-me',
      );
  Widget glassComposer() => AylaMessageInput(onSubmit: (_) {});
  Widget glassCard() => AylaGlassSurface(
        padding: const EdgeInsets.all(12),
        child: const Text('玻璃内容'),
      );

  Future<_SwapHostState> pumpSwap(
    WidgetTester tester, {
    required AylaPanelSwapMode mode,
    required bool fadeGlass,
    required Widget child,
  }) async {
    await tester.pumpWidget(
      host(_SwapHost(mode: mode, fadeGlass: fadeGlass, child: child)),
    );
    await tester.pump();
    return tester.state<_SwapHostState>(find.byType(_SwapHost));
  }

  /// `AylaPanelSwap` 当前呈现的 (opacity, dx, dy)：读它内部第一个 Opacity/Transform
  /// （与 `panel_swap_test.dart` 同口径 —— `AnimatedBuilder > Opacity > Transform`）。
  ({double opacity, double dx, double dy}) sample(WidgetTester tester) {
    final Opacity op = tester.widget<Opacity>(
      find
          .descendant(
            of: find.byType(AylaPanelSwap).first,
            matching: find.byType(Opacity),
          )
          .first,
    );
    final Transform tr = tester.widget<Transform>(
      find
          .descendant(
            of: find.byType(AylaPanelSwap).first,
            matching: find.byType(Transform),
          )
          .first,
    );
    final Matrix4 m = tr.transform;
    return (opacity: op.opacity, dx: m.storage[12], dy: m.storage[13]);
  }

  /// 目标子树向上**最近**的 `Opacity` 的取值（`find.ancestor` 的 `.first` = 最近祖先）。
  double nearestOpacity(WidgetTester tester, Finder target) => tester
      .widget<Opacity>(
        find.ancestor(of: target, matching: find.byType(Opacity)).first,
      )
      .opacity;

  /// layer 树里是否存在「`alpha != 255` 的 `OpacityLayer` 祖先 → `BackdropFilterLayer` 后代」。
  ///
  /// 这正是 Impeller 报错的触发条件：`alpha < 255` 才 `pushOpacity`，引擎把继承不透明度
  /// 传给子树内容，而 `BackdropFilter` 的 Contents `CanAcceptOpacity == false`。
  /// 拿不到 layer（`debugLayer == null`）时返回 false —— 失败方向是「漏报」，不会误报。
  bool hasOpacityAncestorOfBackdropFilter(WidgetTester tester) {
    bool walk(Layer? layer, bool underOpacity) {
      for (Layer? l = layer; l != null; l = l.nextSibling) {
        final bool under =
            underOpacity || (l is OpacityLayer && (l.alpha ?? 255) != 255);
        if (l is BackdropFilterLayer && under) return true;
        if (l is ContainerLayer && walk(l.firstChild, under)) return true;
      }
      return false;
    }

    final ContainerLayer? rootLayer = tester.binding.renderViews.first.debugLayer;
    return walk(rootLayer, false);
  }

  /// layer 树里是否存在 `BackdropFilterLayer`（= 玻璃**真的被绘制**）。
  ///
  /// 与上一条配对使用：只断言「没有 `alpha != 255` 的 `OpacityLayer` 祖先」而不证明
  /// 玻璃层存在，会在「子树根本没画玻璃」时**假绿**（首版用空列表就踩到了）。
  bool hasBackdropFilterLayer(WidgetTester tester) {
    bool walk(Layer? layer) {
      for (Layer? l = layer; l != null; l = l.nextSibling) {
        if (l is BackdropFilterLayer) return true;
        if (l is ContainerLayer && walk(l.firstChild)) return true;
      }
      return false;
    }

    return walk(tester.binding.renderViews.first.debugLayer);
  }

  // ======================= ① 位移仍随动画推进 =======================

  group('① 位移仍随动画推进（玻璃档只是不淡入）', () {
    testWidgets('tab 档：起点 x +20 → 中段推进 → 0，opacity 恒 1.0', (
      WidgetTester tester,
    ) async {
      final _SwapHostState h = await pumpSwap(
        tester,
        mode: AylaPanelSwapMode.tab,
        fadeGlass: false,
        child: glassCard(),
      );
      expect(sample(tester).dx, 0, reason: '静止态应在 center');

      h.swapIdentity();
      await tester.pump(); // 起点帧：t = 0
      final ({double opacity, double dx, double dy}) early = sample(tester);
      expect(
        early.dx,
        closeTo(AylaPanelSwap.distance, 0.5),
        reason: 'tab 档起点应是 x +20',
      );
      expect(early.opacity, 1.0, reason: '玻璃档的整层 opacity 恒 1.0');

      await tester.pump(const Duration(milliseconds: 150));
      final ({double opacity, double dx, double dy}) mid = sample(tester);
      expect(mid.dx, lessThan(AylaPanelSwap.distance), reason: '位移应从 +20 向 0 推进');
      expect(mid.dx, greaterThan(0.0));
      expect(mid.opacity, 1.0, reason: '玻璃档连中间帧也不许推 opacity');

      await tester.pumpAndSettle();
      expect(sample(tester).dx, moreOrLessEquals(0.0, epsilon: 0.001));
      expect(sample(tester).opacity, 1.0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('swap 档：起点 y 0 → 中点 y +20 → 回 0，opacity 恒 1.0', (
      WidgetTester tester,
    ) async {
      final _SwapHostState h = await pumpSwap(
        tester,
        mode: AylaPanelSwapMode.swap,
        fadeGlass: false,
        child: glassCard(),
      );

      h.swapIdentity();
      await tester.pump(); // 起点帧：t = 0（= 当前样式）
      expect(sample(tester).dy, 0, reason: 'swap 档起点 = 当前样式（不位移）');
      expect(sample(tester).opacity, 1.0);

      await tester.pump(const Duration(milliseconds: 300)); // 中点 = 完全下移
      final ({double opacity, double dx, double dy}) half = sample(tester);
      expect(
        half.dy,
        closeTo(AylaPanelSwap.distance, 1.5),
        reason: '中点应是 y +20（玻璃档同样走完整位移）',
      );
      expect(half.opacity, 1.0);

      await tester.pumpAndSettle();
      expect(sample(tester).dy, moreOrLessEquals(0.0, epsilon: 0.001));
      expect(sample(tester).opacity, 1.0);
      expect(tester.takeException(), isNull);
    });
  });

  // ======================= ② 含玻璃子树不产生 pushOpacity =======================

  group('② 含玻璃子树不产生 pushOpacity', () {
    testWidgets('tab 档 + 真实消息区（AylaMessageList）：动画中段不推 opacity', (
      WidgetTester tester,
    ) async {
      final _SwapHostState h = await pumpSwap(
        tester,
        mode: AylaPanelSwapMode.tab,
        fadeGlass: false,
        child: glassList(),
      );
      h.swapIdentity();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      // 动画中段 = 唯一可能推 opacity 的时刻（两端由 alpha 0 / alpha 255 分支免掉）
      await tester.pump(const Duration(milliseconds: 150));

      expect(find.byType(BackdropFilter), findsWidgets, reason: '玻璃不许被去掉');
      expect(
        hasBackdropFilterLayer(tester),
        isTrue,
        reason: '先证明玻璃真的进了 layer 树（否则下面的「无 opacity 祖先」是假绿）',
      );
      expect(
        nearestOpacity(tester, find.byType(AylaMessageList)),
        1.0,
        reason: '玻璃档的整层 opacity 必须恒为 1.0',
      );
      expect(
        hasOpacityAncestorOfBackdropFilter(tester),
        isFalse,
        reason: 'Impeller 会拒绝「OpacityLayer(alpha<255) 祖先 + BackdropFilterLayer」并刷屏',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('swap 档 + 真实输入框（AylaMessageInput）：动画中段不推 opacity', (
      WidgetTester tester,
    ) async {
      final _SwapHostState h = await pumpSwap(
        tester,
        mode: AylaPanelSwapMode.swap,
        fadeGlass: false,
        child: glassComposer(),
      );
      h.swapIdentity();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      // 150ms（t = .25）—— 避开中点 t = .5 的 opacity == 0（那时不 paint 子树）
      await tester.pump(const Duration(milliseconds: 150));

      expect(find.byType(BackdropFilter), findsWidgets, reason: '玻璃不许被去掉');
      expect(
        hasBackdropFilterLayer(tester),
        isTrue,
        reason: '先证明玻璃真的进了 layer 树（否则下面的「无 opacity 祖先」是假绿）',
      );
      expect(
        nearestOpacity(tester, find.byType(AylaMessageInput)),
        1.0,
        reason: '玻璃档的整层 opacity 必须恒为 1.0',
      );
      expect(
        hasOpacityAncestorOfBackdropFilter(tester),
        isFalse,
        reason: 'Impeller 会拒绝「OpacityLayer(alpha<255) 祖先 + BackdropFilterLayer」并刷屏',
      );
      expect(tester.takeException(), isNull);
    });
  });

  // ======================= ③ 对照组（证明探针不是假绿） =======================

  group('③ 对照组：默认档 = 改前行为 + 探针有效性', () {
    testWidgets('默认（fadeGlass: true）tab 档：玻璃子树**确实**进 opacity 中间态，探针必须命中', (
      WidgetTester tester,
    ) async {
      // 这条锁住「默认值 = 改前行为」：漏声明的调用点表现**可见**（opacity 中间态 +
      // 控制台刷屏），而不是静默退化 —— 也正是必须逐个显式声明 `fadeGlass: false` 的原因。
      final _SwapHostState h = await pumpSwap(
        tester,
        mode: AylaPanelSwapMode.tab,
        fadeGlass: true,
        child: glassList(),
      );
      h.swapIdentity();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 150));

      final double o = nearestOpacity(tester, find.byType(AylaMessageList));
      expect(o, greaterThan(0.0));
      expect(o, lessThan(1.0), reason: '默认档仍走整层 opacity（= 改前行为）');
      expect(
        hasOpacityAncestorOfBackdropFilter(tester),
        isTrue,
        reason: '探针有效性：真出现「Opacity 祖先 + BackdropFilter」时它必须命中',
      );
    });

    testWidgets('默认（fadeGlass: true）swap 档：中段 opacity 落在中间态', (
      WidgetTester tester,
    ) async {
      final _SwapHostState h = await pumpSwap(
        tester,
        mode: AylaPanelSwapMode.swap,
        fadeGlass: true,
        child: glassComposer(),
      );
      h.swapIdentity();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 150)); // t = .25（避开中点 0）

      final ({double opacity, double dx, double dy}) mid = sample(tester);
      expect(mid.opacity, greaterThan(0.0));
      expect(mid.opacity, lessThan(1.0), reason: '默认档仍走整层 opacity（= 改前行为）');
      expect(mid.dy, greaterThan(0.0), reason: '位移照常推进');
      expect(hasOpacityAncestorOfBackdropFilter(tester), isTrue);
    });

    testWidgets('探针有效性：整层 Opacity(0.5) 包玻璃 ⇒ 必须命中', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(Center(child: Opacity(opacity: 0.5, child: glassCard()))),
      );
      await tester.pump();
      expect(
        hasOpacityAncestorOfBackdropFilter(tester),
        isTrue,
        reason: '探针有效性：真出现「Opacity 祖先 + BackdropFilter」时它必须命中',
      );
    });
  });
}
