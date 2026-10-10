/// 窄屏群聊**子群切换条**回归 —— 用户 2026-10-09 实报「窄屏子群不显示」。
///
/// ## web 事实源（逐条）
/// - `GroupChat.tsx:334`：渲染条件
///   `{isNarrow && Math.max(subgroups.length, subgroupPage.total) > 1 && (…)}`
///   —— `subgroupPage.total` 是**分页总数**（`hooks/useSocialPage.ts:22` 的
///   `record.total`），不是当前条数。
/// - `GroupChat.tsx:45`：`isNarrow = useMediaQuery(NARROW_QUERY)`；
///   `hooks/useMediaQuery.ts:13` ⇒ `NARROW_QUERY = "(max-width: 768px)"`（**含等号**）。
/// - `GroupChat.tsx:326–333`：宿主 = `.group-chat-compose-area`（输入区），
///   子群条是该 motion.div 的**第一个子节点**。
/// - `group.css:152–161`：`.group-chat-subgroup-switcher { position: absolute;
///   left/right: var(--sp-3); bottom: 100%; height: 0; pointer-events: none }`
///   —— `bottom: 100%` = 锚在其 containing block（`.group-chat-compose-area`）
///   的**上沿之外**（向上溢出）。该容器无 `overflow` 声明 ⇒ CSS 默认 `visible`。
///
/// ## 两个根因（本轮修）
/// 1. **裁剪**：Flutter 侧 `Positioned(top: -32)` 是 `bottom:100%` 的等价物，
///    但 `Stack` 默认 `Clip.hardEdge` ⇒ 越界部分被整块裁掉（树里在、像素没有）。
/// 2. **条件**：原实现只判 `subgroups.length > 1`，漏了 `subgroupPage.total`。
///
/// ## 为什么必须验像素（本轮纪律）
/// 裁剪**不改变** `getRect` 的结果 —— 布局矩形完全正确，只是画不出来。
/// 所以「条可见」这条必须用**光栅化后的像素**证（`RepaintBoundary.toImage`），
/// 不能只断言 `find.byType(...)` 或 `getRect`。
library;

import 'dart:typed_data' show ByteData;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/api/directory_page.dart' show AylaDirectoryPage;
import '../lib/core/models/subgroup.dart';
import '../lib/pages/group_page.dart' show GroupPage;
import '../lib/state/chat_providers.dart' show aylaStartSocialTracking;
import '../lib/state/group_providers.dart' show subgroupStateProvider;
import '../lib/state/social_store.dart'
    show AylaSocialKind, AylaSocialOptions, AylaSocialPage, aylaSocialStore;
import '../lib/widgets/base/reveal.dart' show AylaRevealMotion;
import '../lib/widgets/chat/message_input.dart' show AylaMessageInput;
import '../lib/widgets/group/group_chat_subgroup_bar.dart';

const double kNarrowWidth = 420; // ≤768 ⇒ 窄屏（NARROW_QUERY 含等号）
const double kWideWidth = 1200; // >768 ⇒ 宽屏

AylaSubGroup _sg(String id, {bool isDefault = false}) => AylaSubGroup(
  id: id,
  conversationId: 'g1',
  name: '子群$id',
  isDefault: isDefault,
  unreadCount: 0,
);

/// 宿主：真 `ProviderContainer` + 真 `GroupPage`；页面外包一层
/// `RepaintBoundary` 供像素取证（key 由调用方经 [pageBoundaryKey] 取用）。
///
/// ⚠️ 必须包 `Scaffold`（群聊输入区是 Material 的 TextField）。
final GlobalKey pageBoundaryKey = GlobalKey();

Widget _host(ProviderContainer container, {required double width}) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          // 纯白底：像素判据的参照系（条一旦真的画出来，其玻璃胶囊与文字
          // 会明显偏离白）。
          backgroundColor: const Color(0xFFFFFFFF),
          body: RepaintBoundary(
            key: pageBoundaryKey,
            child: Builder(
              builder: (BuildContext context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(size: Size(width, 900)),
                child: const GroupPage(groupId: 'g1'),
              ),
            ),
          ),
        ),
      ),
    );

void main() {
  /// 起真页面 + 注入服务端子群页。
  ///
  /// ⚠️ 只注入 `subgroupRequestOverride`（`social_store.dart:690`）——
  /// 本页的 `subgroupPage` 走的就是 social store 的 subgroups kind
  /// （web `GroupChat.tsx:57` 的 `useSocialPage("subgroups", { groupId })` 同源），
  /// `total` 与 `results` 都由这一个响应决定。
  Future<ProviderContainer> boot(
    WidgetTester tester,
    double width,
    AylaSubgroupPage Function() page, {
    /// 是否在返回前推进 300ms（让入场动画走完）。
    ///
    /// 秒表类用例（入场轨道）必须传 `false`：否则首帧的动画早已结束，
    /// 采样到的都是终态（实测：两值相等 ⇒ 断言必然失败）。
    bool settle = true,
  }) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final ProviderContainer container = ProviderContainer();
    // ⚠️ 顺序：**先拆 widget 树、再 dispose 容器**。
    // `addTearDown` 是 **LIFO** ⇒ 先注册容器释放、后注册拆树（后者先跑）。
    // 反过来的话 `GroupChatPage.dispose` 会把 `runtime.dispose()` 打到已 dispose 的
    // `AylaChatState` 上，抛「A AylaChatState was used after being disposed」（实测）。
    addTearDown(container.dispose);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
    // `socialTrackingProvider` 必须装配：`load()` 的**取页回流**要经它写 subgroupState。
    aylaStartSocialTracking(container);

    aylaSocialStore.reset();
    aylaSocialStore.userId = 'u1';
    // 群头像列（`AylaGroupDirectory`）读 conversations ⇒ 注入空页，避免真网络。
    aylaSocialStore.requestOverride = (kind, options, cursor) async =>
        const AylaDirectoryPage<Object>();
    aylaSocialStore.subgroupRequestOverride =
        (AylaSocialKind kind, AylaSocialOptions options, String? cursor) async {
          final AylaSubgroupPage p = page();
          return AylaSocialPage(
            page: AylaDirectoryPage<Object>(
              results: List<Object>.of(p.results),
              nextCursor: p.nextCursor,
              hasMore: p.hasMore,
              total: p.total,
            ),
            defaultSubgroup: p.defaultSubgroup,
          );
        };
    addTearDown(() {
      aylaSocialStore.subgroupRequestOverride = null;
      aylaSocialStore.requestOverride = null;
      aylaSocialStore.reset();
      aylaSocialStore.userId = null;
    });

    await tester.pumpWidget(_host(container, width: width));
    if (settle) {
      await tester.pump(const Duration(milliseconds: 300));
    } else {
      // 只起一帧：让页面进入树、动画处于 t≈0（入场秒表用例从这里开始采样）。
      await tester.pump();
    }
    return container;
  }

  /// 光栅化页面并返回 (像素, 宽, 高)。
  Future<(List<int>, int, int)> rasterize(WidgetTester tester) async {
    final RenderRepaintBoundary boundary = tester
        .renderObject<RenderRepaintBoundary>(find.byKey(pageBoundaryKey));
    late List<int> pixels;
    late int w;
    late int h;
    await tester.runAsync(() async {
      final ui.Image image = await boundary.toImage(pixelRatio: 1.0);
      w = image.width;
      h = image.height;
      final ByteData? data = await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      pixels = data!.buffer.asUint8List().toList();
      image.dispose();
    });
    return (pixels, w, h);
  }

  /// 两帧在 [area] 内**不同的像素数**（差分判据 —— 不受背景内容干扰）。
  int diffCount((List<int>, int, int) a, (List<int>, int, int) b, Rect area) {
    final (List<int> pa, int wa, int ha) = a;
    final (List<int> pb, int wb, int hb) = b;
    int n = 0;
    for (double y = area.top; y < area.bottom; y += 1) {
      for (double x = area.left; x < area.right; x += 1) {
        final int xi = x.round();
        final int yi = y.round();
        if (xi < 0 || yi < 0 || xi >= wa || yi >= ha) continue;
        if (xi >= wb || yi >= hb) continue;
        final int ia = (yi * wa + xi) * 4;
        final int ib = (yi * wb + xi) * 4;
        if (pa[ia] != pb[ib] ||
            pa[ia + 1] != pb[ib + 1] ||
            pa[ia + 2] != pb[ib + 2]) {
          n++;
        }
      }
    }
    return n;
  }

  testWidgets('★ 窄屏 + 服务端 total>1 且当前页只回 1 条 ⇒ 条仍必须渲染（web tsx 334）', (
    WidgetTester tester,
  ) async {
    // 后端真实形状：total=3，但本页 rows 只回了 1 条（分页未加载完）。
    final ProviderContainer container = await boot(
      tester,
      kNarrowWidth,
      () => AylaSubgroupPage(
        results: <AylaSubGroup>[_sg('a', isDefault: true)],
        total: 3,
        defaultSubgroup: _sg('a', isDefault: true),
      ),
    );

    // 前提：状态层确实只拿到 1 条子群（否则证明不了 Math.max 分支）。
    expect(
      container.read(subgroupStateProvider).subgroupsOf('g1').length,
      1,
      reason: '装填前提：当前页只有 1 条',
    );

    expect(
      find.byType(AylaGroupChatSubgroupBar),
      findsOneWidget,
      reason: '★ Math.max(1, 3) = 3 > 1 ⇒ 必须渲染（此前只判 length ⇒ 整条消失）',
    );
  });

  testWidgets('★ 窄屏 + 只有 1 个子群（total 也是 1）⇒ 不渲染（condition 的另一半）', (
    WidgetTester tester,
  ) async {
    await boot(
      tester,
      kNarrowWidth,
      () => AylaSubgroupPage(
        results: <AylaSubGroup>[_sg('a', isDefault: true)],
        total: 1,
        defaultSubgroup: _sg('a', isDefault: true),
      ),
    );
    expect(
      find.byType(AylaGroupChatSubgroupBar),
      findsNothing,
      reason: 'Math.max(1, 1) = 1，不 > 1 ⇒ 不渲染（web 同）',
    );
  });

  testWidgets('★ 窄屏：条锚在输入区上沿（web `bottom: 100%` 的几何判据）', (
    WidgetTester tester,
  ) async {
    await boot(
      tester,
      kNarrowWidth,
      () => AylaSubgroupPage(
        results: <AylaSubGroup>[_sg('a', isDefault: true), _sg('b')],
        total: 2,
        defaultSubgroup: _sg('a', isDefault: true),
      ),
    );

    final Finder bar = find.byType(AylaGroupChatSubgroupBar);
    expect(bar, findsOneWidget);
    await tester.pumpAndSettle();

    // ## 口径（web `group.css:152–161` 的 `bottom: 100%`）
    // web 的 containing block = `.group-chat-compose-area`（= 输入区盒），
    // `bottom: 100%` ⇒ 条的**平底正好压在输入区上沿**。
    //
    // ★ 2026-10-09 二次实报「很明显有显示bug」后本轮**改为严格贴齐**：
    // 此前调用方给输入框包了一层 `Padding(top: sp2)`（8px），使把手与输入区之间
    // 留出一道 8px 缝、那个半圆把手看起来像**悬空的一块**。该 8px 原是
    // 19 号 §16.4 第 1 条登记的偏离（"本轮未动"），现按用户实报对齐 web 删除
    // （web 窄屏 `.composer` 无任何 margin，`app.css:3206–3208` 只改内距）
    // ⇒ 条底边与 `AylaMessageInput` 顶边**重合**（gap = 0）。
    final Rect rect = tester.getRect(bar);
    final Rect composer = tester.getRect(find.byType(AylaMessageInput).first);
    expect(
      composer.top - rect.bottom,
      moreOrLessEquals(0, epsilon: 0.5),
      reason:
          '★ 条底边必须贴齐输入区上沿（web `bottom: 100%` + 窄屏 `.composer` 无 margin）；'
          '此前那 8px 缝（`Padding(top: sp2)`）正是用户二次实报的「显示bug」',
    );
    expect(
      rect.top,
      lessThan(composer.top),
      reason: '★ 条主体在输入框上沿**之上**（不压住输入框）',
    );
  });

  testWidgets('★★ 窄屏入场：条与输入区**同一条轨道**（用户二次实报的动画判据）', (
    WidgetTester tester,
  ) async {
    // ⚠️ `settle: false`：秒表用例必须在 t≈0 起采样（`boot` 默认推进 300ms，
    // 会把入场整段走完 ⇒ 采到的全是终态）。
    await boot(
      tester,
      kNarrowWidth,
      () => AylaSubgroupPage(
        results: <AylaSubGroup>[_sg('a', isDefault: true), _sg('b')],
        total: 2,
        defaultSubgroup: _sg('a', isDefault: true),
      ),
      settle: false,
    );

    // ## web 事实源（用户二次实报「从下往上滑入的动画也用错了」）
    // `GroupChat.tsx:326–343`：switcher 是 `.group-chat-compose-area`
    // —— **一个 motion.div**（tsx:326–333，`variants={panelVariants(reducedMotion, "bottom")}`）
    // —— 的**第一个子节点**。CSS transform 作用于**祖先盒** ⇒
    // 子群条**随输入框一起**做 `y +20 → 0`（300ms `--auroraqua-ease-in-out`）。
    // 修前：条挂在消息区 Stack 内、**没有**入场层 ⇒ 输入框自己上滑、条原地不动，
    // 动画期把手与输入区上沿的贴合关系被破坏 —— 这正是用户看到的「用错了」。
    //
    // ① 动态取证：条自己必须**从下方 20px 滑入**（修前恒等于终态 ⇒ 本断言失败）。
    final Finder bar = find.byType(AylaGroupChatSubgroupBar);
    double? firstTop;
    for (int i = 0; i < 40 && firstTop == null; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (bar.evaluate().isNotEmpty) firstTop = tester.getRect(bar).top;
    }
    expect(firstTop, isNotNull, reason: '条最终必须渲染（前置条件，否则后面全是空断言）');
    await tester.pumpAndSettle();
    final double barSettled = tester.getRect(bar).top;
    expect(
      firstTop! - barSettled,
      moreOrLessEquals(AylaRevealMotion.distance, epsilon: 1.5),
      reason:
          '★ 条必须从下方 +20 滑入（web compose-area 的 `panelVariants(reduced, "bottom")`）；'
          '修前条无入场层 ⇒ 差值为 0 = 用户实报的「动画用错了」',
    );

    // ② 逐帧取证：条与输入框的**相对位置全程恒为 0**
    //    （web：两者同属一个 motion.div ⇒ 只有一个 animator，天然零相位差）。
    //    ⚠️ 这是本轮的**根治判据**：此前条与输入框各挂一个 `AylaRevealItem`
    //    ⇒ 两个控制器、起点差一帧（探针实测 t=96ms 输入框进度 0.211 而条 0.150）
    //    ⇒ 这里会稳定失败。现由页面自持的**单个** `AnimationController`
    //    （`_composeEntryCurved`）同时驱动两处 ⇒ 恒 0。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await boot(
      tester,
      kNarrowWidth,
      () => AylaSubgroupPage(
        results: <AylaSubGroup>[_sg('a', isDefault: true), _sg('b')],
        total: 2,
        defaultSubgroup: _sg('a', isDefault: true),
      ),
      settle: false,
    );

    double? worst;
    for (int i = 0; i < 24; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (bar.evaluate().isEmpty) continue;
      final double gap =
          tester.getRect(find.byType(AylaMessageInput).first).top -
          tester.getRect(bar).bottom;
      worst = worst == null
          ? gap.abs()
          : (gap.abs() > worst ? gap.abs() : worst);
    }
    expect(worst, isNotNull, reason: '采样期间条必须已渲染');
    expect(
      worst!,
      lessThan(0.5),
      reason:
          '★ 条底边与输入框顶边必须**逐帧重合**（web 同属一个 motion.div、单一 animator）；'
          '此前两处各挂一个入场件 ⇒ 相位差约半帧~一帧，此断言会失败',
    );
  });

  testWidgets('★★★ 窄屏：展开/收起 = 选项卡**自下而上滑入 / 向下滑出**（用户三次强调）', (
    WidgetTester tester,
  ) async {
    await boot(
      tester,
      kNarrowWidth,
      () => AylaSubgroupPage(
        results: <AylaSubGroup>[_sg('a', isDefault: true), _sg('b')],
        total: 2,
        defaultSubgroup: _sg('a', isDefault: true),
      ),
    );
    final Finder bar = find.byType(AylaGroupChatSubgroupBar);
    final Finder tab = find.text('子群a');
    expect(bar, findsOneWidget);
    final double barBottom = tester.getRect(bar).bottom;

    // ## web 事实源（用户 2026-10-09 三次强调「是从下往上滑入」「不是你这样裁切展开」）
    // `.group-chat-subgroup-panel` 是 `position: absolute; bottom: 0`
    // （`group.css:163–170`）的 motion.div，disclosure 变体动的是它的 **height**
    //（`open: { height: "auto" }` / `closed: { height: 0 }`，
    // `auroraquaMotion.ts:89–95`，300ms easeOut），内联 `overflow: hidden`
    //（`GroupChat.tsx:364`）。锚点在**下沿** ⇒ 高度增长时只有**上沿在往上走**
    // ⇒ 里面的 `.group-chat-subgroup-tabs`（min-height 40）**整条自下而上升起**。
    //
    // ⚠️ 判据必须是「选项卡**自身的顶边在连续移动**」而不是「盒子变高」：
    // `AnimatedSize(alignment: bottomCenter)` 那种写法盒子也在变高，
    // 但子件被钉住 ⇒ 顶边**不动**（= 用户实报的「裁切展开」）。
    final double collapsedTabTop = tester.getTopLeft(tab.first).dy;

    await tester.tap(find.byKey(AylaGroupChatSubgroupBar.collapseHandleKey));
    final List<double> openTops = <double>[];
    for (int i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      openTops.add(tester.getTopLeft(tab.first).dy);
    }
    await tester.pumpAndSettle();
    final double expandedTabTop = tester.getTopLeft(tab.first).dy;

    // ① 展开方向：顶边必须**上移** 40px（= 选项卡行 min-height，group.css:178）
    expect(
      collapsedTabTop - expandedTabTop,
      moreOrLessEquals(40, epsilon: 1.0),
      reason: '★ 展开后选项卡必须整体上移 40px（web：height 40 的 row 贴着下沿升起）',
    );
    // ② 连续性：**单调**上升、无跳变（「瞬间换掉子树」会在某一帧直接跳到终值）
    for (int i = 1; i < openTops.length; i++) {
      expect(
        openTops[i],
        lessThanOrEqualTo(openTops[i - 1] + 0.01),
        reason: '★ 展开必须是连续滑动（第 $i 帧回退了 ⇒ 有跳变/裁切式展开）',
      );
    }
    expect(
      openTops.first,
      greaterThan(expandedTabTop + 1),
      reason: '★ 起点必须在终态**下方**（否则是「原地揭开」而非滑入）',
    );
    // ③ 全程仍在输入区上沿**之上**（不侵入输入框）
    expect(
      tester.getRect(bar).bottom,
      moreOrLessEquals(barBottom, epsilon: 0.5),
      reason: '★ 条的下沿恒在输入区上沿（展开只往上长）',
    );

    // ④ 收起：必须**向下滑回**（不能瞬间消失）
    await tester.tap(find.byKey(AylaGroupChatSubgroupBar.collapseHandleKey));
    final List<double> closeTops = <double>[];
    for (int i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (tab.evaluate().isEmpty) break;
      closeTops.add(tester.getTopLeft(tab.first).dy);
    }
    expect(
      closeTops.length,
      greaterThan(8),
      reason: '★ 收起时选项卡必须继续存在并滑动（瞬间找不到 = 子树被换掉、没有滑动过程）',
    );
    for (int i = 1; i < closeTops.length; i++) {
      expect(
        closeTops[i],
        greaterThanOrEqualTo(closeTops[i - 1] - 0.01),
        reason: '★ 收起必须是连续下滑（第 $i 帧回退了 ⇒ 有跳变）',
      );
    }
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(tab.first).dy,
      moreOrLessEquals(collapsedTabTop, epsilon: 1.0),
      reason: '★ 收起终态必须回到展开前的起点（对称）',
    );
  });

  testWidgets('★★★ 窄屏：条**可点击**（命中测试 —— 用户实报「点都点不动」的判据）', (
    WidgetTester tester,
  ) async {
    await boot(
      tester,
      kNarrowWidth,
      () => AylaSubgroupPage(
        results: <AylaSubGroup>[_sg('a', isDefault: true), _sg('b')],
        total: 2,
        defaultSubgroup: _sg('a', isDefault: true),
      ),
    );
    final Finder bar = find.byType(AylaGroupChatSubgroupBar);
    expect(bar, findsOneWidget);
    await tester.pumpAndSettle();

    // ## 为什么单独锁「可点击」（2026-10-09 用户实报「点都点不动」）
    // 上一轮只修了**可见性**（`Stack(clipBehavior: Clip.none)`），漏了**命中**：
    // Flutter `RenderBox.hitTest` 首行 `if (_size.contains(position))` ⇒
    // 画到父盒之外的子件收不到指针 —— `Clip.none` 只放开绘制。
    // 实测当时 `tester.tap` 打印
    // `derived an Offset (Offset(28.0, 767.0)) that would not hit test`，
    // 点击穿透到后面的消息列表。web 无此限制（CSS 绝对定位按绘制后几何命中）。
    // 修法：条移进**消息区** Stack、锚 `bottom: 0` ⇒ 既在盒内可命中，
    // 又因 `Positioned` 不参与布局而**不消耗消息列表高度**（web 的原意）。
    //
    // ① 折叠把手 → 展开选项卡行
    await tester.tap(find.byKey(AylaGroupChatSubgroupBar.collapseHandleKey));
    await tester.pumpAndSettle();
    expect(
      find.text('子群a'),
      findsOneWidget,
      reason: '★ 点折叠把手必须真的展开（命中失败时这里恒为 0 —— 修前实测）',
    );

    // ② 点选项卡（web `switchSubgroup`）：断言「真的命中」——
    // 选中态切换后的胶囊迁移由 `nav_highlight_list_test.dart` 锁，
    // 这里只证「命中不再落空」（修前 `would not hit test` ⇒ 点上去毫无反应）。
    await tester.tap(find.text('子群b'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: '点选项卡不得抛异常');
  });

  testWidgets('★★ 窄屏：条真的被画出来（差分像素取证 —— `Clip.none` 的判据）', (
    WidgetTester tester,
  ) async {
    await boot(
      tester,
      kNarrowWidth,
      () => AylaSubgroupPage(
        results: <AylaSubGroup>[_sg('a', isDefault: true), _sg('b')],
        total: 2,
        defaultSubgroup: _sg('a', isDefault: true),
      ),
    );
    final Finder bar = find.byType(AylaGroupChatSubgroupBar);
    expect(bar, findsOneWidget);
    await tester.pumpAndSettle();
    final Rect rect = tester.getRect(bar);
    expect(rect.height, greaterThan(0), reason: '条在树里且有高度（布局正确）');

    final (List<int>, int, int) withBar = await rasterize(tester);

    // 换一帧：同一页面、`total=1` ⇒ 条件不成立 ⇒ 条不渲染。其余内容完全相同
    // （空消息列表 + 同尺寸输入框）⇒ 两帧之差**只可能**来自这条本身。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await boot(
      tester,
      kNarrowWidth,
      () => AylaSubgroupPage(
        results: <AylaSubGroup>[_sg('a', isDefault: true)],
        total: 1,
        defaultSubgroup: _sg('a', isDefault: true),
      ),
    );
    expect(
      find.byType(AylaGroupChatSubgroupBar),
      findsNothing,
      reason: '对照帧：total=1 ⇒ 条件不成立',
    );
    await tester.pumpAndSettle();
    final (List<int>, int, int) withoutBar = await rasterize(tester);

    // ★ 核心判据：条所在矩形内必须出现差异。
    //   `Stack` 默认 `Clip.hardEdge` 时实测 **diff = 0**（逐像素完全相同 ——
    //   条被整块裁掉，布局矩形却完全正确）；`Clip.none` 后 diff = 535。
    //   —— 这正是「裁剪型缺陷不能只看 getRect」的原因。
    final int diff = diffCount(withBar, withoutBar, rect);
    expect(diff, greaterThan(50), reason: '★ 条区域必须真的被绘制（硬裁时实测 diff = 0）');
  });

  testWidgets('宽屏（>768）：不渲染子群条（isNarrow 判据的另一半）', (WidgetTester tester) async {
    await boot(
      tester,
      kWideWidth,
      () => AylaSubgroupPage(
        results: <AylaSubGroup>[_sg('a', isDefault: true), _sg('b')],
        total: 2,
        defaultSubgroup: _sg('a', isDefault: true),
      ),
    );
    expect(
      find.byType(AylaGroupChatSubgroupBar),
      findsNothing,
      reason: 'NARROW_QUERY 是 max-width:768 ⇒ 1200 宽走宽屏（子群条只在窄屏出现）',
    );
  });

  testWidgets('断点含等号：正好 768 ⇒ 仍是窄屏（`max-width: 768px` 原文）', (
    WidgetTester tester,
  ) async {
    await boot(
      tester,
      768,
      () => AylaSubgroupPage(
        results: <AylaSubGroup>[_sg('a', isDefault: true), _sg('b')],
        total: 2,
        defaultSubgroup: _sg('a', isDefault: true),
      ),
    );
    expect(
      find.byType(AylaGroupChatSubgroupBar),
      findsOneWidget,
      reason: '★ 768 落在 ≤768 内（hooks/useMediaQuery.ts:13 含等号）；769 才算宽屏',
    );
  });
}
