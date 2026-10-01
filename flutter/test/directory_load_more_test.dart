/// AylaDirectoryLoadMore 定向测试（触底自动加载 + autoLoadMore 开关）。
///
/// 事实源：`web/src/components/DirectoryLoadMore.tsx:21–28`——`IntersectionObserver`
/// 的 `rootMargin: "240px 0px"`（**提前 240px 触发**）与 `:22` 的四项短路守卫。
///
/// ## 本文件锁的缺陷（修复前**必红**）
/// 修复前触底判定挂在**页脚自己**的 `NotificationListener<ScrollNotification>` 上，
/// 而 Flutter 的 `Notification` **只向祖先冒泡**（`framework.dart` 的
/// `_NotificationNode.dispatchNotification` 只走 `parent`），页脚是 `Scrollable`
/// 视图的**后代** ⇒ 那条路径是死代码。Lead 实测两个独立探针：
/// 1. 最简复现：滚动容器**内部**的监听器命中 **0** 次，同一容器**外部**命中 **6** 次；
/// 2. 真实本件（`hasMore: true` 已渲染出「加载更多」按钮）放进
///    `SingleChildScrollView` 拖到底后打印
///    `calls=0  pixels=380.0  max=380.0  extentAfter=0.0` —— 触底了但一次都没触发。
///
/// ⇒ 组①/组⑤是本文件的判别性用例（修复前 `calls` 恒为 0）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/preview_theme.dart';
import '../lib/widgets/base/directory_controls.dart'
    show AylaDirectoryLoadMore, AylaPaginationLoadingDots;

void main() {
  // ======================= 工具 =======================

  /// 长列表宿主：`SizedBox(height: 4000)` + 页脚（页脚**在滚动内容内部**，
  /// 与所有真实调用点一致）。视口 800×600 ⇒ 内容远高于一屏。
  ///
  /// 作者注：`SingleChildScrollView` 的 `child` 不得用 `Column(mainAxisSize:min)`
  /// 之外的东西——`AylaStablePaginationFooter` 用 `UnconstrainedBox` 让内容按自然
  /// 高度布局，套 `Expanded` 会直接断言失败。
  Widget hostLong({
    required Future<void> Function() loadMore,
    required Future<void> Function() refresh,
    bool loading = false,
    String? error,
    bool hasMore = true,
    bool invalidated = false,
    bool retainCompletedSpace = true,
    bool autoLoadMore = true,
  }) {
    return previewTheme(
      SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const SizedBox(height: 4000),
            AylaDirectoryLoadMore(
              loading: loading,
              error: error,
              hasMore: hasMore,
              invalidated: invalidated,
              loadMore: loadMore,
              refresh: refresh,
              retainCompletedSpace: retainCompletedSpace,
              autoLoadMore: autoLoadMore,
            ),
          ],
        ),
      ),
    );
  }

  /// 短列表宿主（**内容不足一屏**）：`80 + 页脚 ≈ 170 < 600` ⇒
  /// 首帧 `extentAfter` 就已是 0（组⑤用）。
  Widget hostShort({
    required Future<void> Function() loadMore,
    required Future<void> Function() refresh,
    bool hasMore = true,
    bool autoLoadMore = true,
  }) {
    return previewTheme(
      SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const SizedBox(height: 80),
            AylaDirectoryLoadMore(
              loading: false,
              error: null,
              hasMore: hasMore,
              invalidated: false,
              loadMore: loadMore,
              refresh: refresh,
              autoLoadMore: autoLoadMore,
            ),
          ],
        ),
      ),
    );
  }

  ScrollPosition position(WidgetTester tester) =>
      tester.state<ScrollableState>(find.byType(Scrollable)).position;

  /// 真实交互路径：`jumpTo` 到底（不是只改 widget 参数）。
  Future<void> scrollToBottom(WidgetTester tester) async {
    final ScrollPosition p = position(tester);
    p.jumpTo(p.maxScrollExtent);
    await tester.pumpAndSettle();
  }

  /// 排两帧（`_scheduleCheck` 的 post-frame 回调 + 其可能触发的重建）。
  Future<void> settleFrames(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
  }

  group('AylaDirectoryLoadMore 触底自动加载', () {
    testWidgets('① 真实滚动到底 ⇒ loadMore 恰好触发一次（修复前必红）', (
      WidgetTester tester,
    ) async {
      int calls = 0;
      await tester.pumpWidget(hostLong(
        loadMore: () async => calls++,
        refresh: () async {},
      ));
      await settleFrames(tester);

      // 起点：距底远大于 240 ⇒ 一次都不该触发（否则「到底才触发」这句没被验到）。
      expect(
        position(tester).extentAfter,
        greaterThan(AylaDirectoryLoadMore.rootMargin),
      );
      expect(calls, 0, reason: '未进入 240px 触发区 ⇒ 不追加');

      await scrollToBottom(tester);

      expect(
        position(tester).extentAfter,
        0.0,
        reason: '确实滚到底了（探针②的 pixels==max==380 等价形态）',
      );
      expect(calls, 1, reason: '进入触发区 ⇒ 恰好一次（修复前恒为 0）');
    });

    testWidgets('①b 离底后再次到底 ⇒ 再触发一次（判定持续有效，非一次性）', (
      WidgetTester tester,
    ) async {
      int calls = 0;
      await tester.pumpWidget(hostLong(
        loadMore: () async => calls++,
        refresh: () async {},
      ));
      await settleFrames(tester);

      await scrollToBottom(tester);
      expect(calls, 1);

      // 回到顶部（离底 > 240）再到底：web 的观察器在元素离开后重新变得可相交，
      // 这里等价于「新的滚动位置再次满足距底 < 240」。
      position(tester).jumpTo(0);
      await tester.pumpAndSettle();
      expect(calls, 1, reason: '离底期间不追加');

      await scrollToBottom(tester);
      expect(calls, 2, reason: '再次到底 ⇒ 再追加一次');
    });

    testWidgets('② loading / !hasMore / error / invalidated 四态短路（tsx 22）', (
      WidgetTester tester,
    ) async {
      // 四态各用一个独立宿主，避免状态互相污染。
      Future<int> run({
        bool loading = false,
        String? error,
        bool hasMore = true,
        bool invalidated = false,
      }) async {
        int calls = 0;
        await tester.pumpWidget(hostLong(
          loadMore: () async => calls++,
          refresh: () async {},
          loading: loading,
          error: error,
          hasMore: hasMore,
          invalidated: invalidated,
        ));
        await settleFrames(tester);
        await scrollToBottom(tester);
        return calls;
      }

      expect(await run(loading: true), 0, reason: 'loading ⇒ 不触发');
      expect(await run(hasMore: false), 0, reason: '!hasMore ⇒ 不触发');
      expect(await run(error: '网络错误'), 0, reason: 'error ⇒ 不触发');
      expect(await run(invalidated: true), 0, reason: 'invalidated ⇒ 不触发');
    });

    testWidgets('③ 未到底（extentAfter ≥ 240）⇒ 不触发', (WidgetTester tester) async {
      int calls = 0;
      await tester.pumpWidget(hostLong(
        loadMore: () async => calls++,
        refresh: () async {},
      ));
      await settleFrames(tester);

      final ScrollPosition p = position(tester);
      // 停在「距底恰好 240」处：tsx 的判定是「进入 240px 外扩区」，
      // 边界等于 240 时**不**触发 ⇒ 断言必须 ≥ 240 而非 > 240。
      p.jumpTo(p.maxScrollExtent - 240);
      await tester.pumpAndSettle();

      expect(
        p.extentAfter,
        240.0,
        reason: '构造的正是边界点（不凑够就退化成测别的东西）',
      );
      expect(calls, 0, reason: 'extentAfter == 240 ⇒ 未进入触发区');
    });

    testWidgets('④ autoLoadMore: false ⇒ 到底也不触发，但按钮与三态渲染不变', (
      WidgetTester tester,
    ) async {
      int calls = 0;
      await tester.pumpWidget(hostLong(
        loadMore: () async => calls++,
        refresh: () async {},
        autoLoadMore: false,
      ));
      await settleFrames(tester);

      // 视觉与契约不得变（开关只关触发、不改渲染）。
      final AylaDirectoryLoadMore widget =
          tester.widget<AylaDirectoryLoadMore>(find.byType(AylaDirectoryLoadMore));
      expect(widget.autoLoadMore, isFalse);
      expect(find.text('加载更多'), findsOneWidget, reason: '关掉自动触发不改渲染');
      expect(find.byType(AylaPaginationLoadingDots), findsNothing);

      await scrollToBottom(tester);
      expect(calls, 0, reason: '开关关闭 ⇒ 本件不做触底触发（owner 在宿主容器）');

      // 手动路径必须仍然可用。
      await tester.tap(find.text('加载更多'));
      await tester.pump();
      expect(calls, 1, reason: '按钮路径不受开关影响');
    });

    // ⚠️ 与 ④ 分开是因为 `previewTheme` 内含 `Overlay(initialEntries:)`——
    // `OverlayState.initState` 只 `insertAll(widget.initialEntries)`（`overlay.dart:657`）
    // 且**没有** `didUpdateWidget` 更新入口 ⇒ 同一 `testWidgets` 内二次 `pumpWidget`
    // 仍是**旧** builder 子树（本仓既有教训，见 `channel_sidebar_test.dart:9–11`）。
    testWidgets('④b autoLoadMore: false 时 invalidated 仍自动 refresh（两条路径正交）', (
      WidgetTester tester,
    ) async {
      int calls = 0;
      int refreshed = 0;
      await tester.pumpWidget(hostLong(
        loadMore: () async => calls++,
        refresh: () async => refreshed++,
        invalidated: true,
        autoLoadMore: false,
      ));
      await settleFrames(tester);

      // tsx 18–20 的自动 refresh 是**另一个** useEffect，与触底观察器无关。
      expect(refreshed, 1, reason: 'autoLoadMore:false 不改 invalidated 自动 refresh');
      expect(find.byType(AylaPaginationLoadingDots), findsOneWidget);
      expect(calls, 0, reason: 'invalidated ⇒ 触底短路（tsx 22）');
    });

    testWidgets('⑤ 短列表（内容不足一屏）首帧即触底 ⇒ 拿到一次机会（锁排帧判定）', (
      WidgetTester tester,
    ) async {
      int calls = 0;
      await tester.pumpWidget(hostShort(
        loadMore: () async => calls++,
        refresh: () async {},
      ));
      await settleFrames(tester);

      expect(
        position(tester).maxScrollExtent,
        0.0,
        reason: '短列表本就无滚动空间（extentAfter 恒 0）',
      );
      expect(
        calls,
        1,
        reason: '首帧后必须补判一次；否则「内容不足一屏」的列表永远拿不到追加机会',
      );
    });

    /// **反例锁**：修复前的形态——`NotificationListener` 挂在**滚动内容内部**
    /// （与页脚同层），收不到滚动通知 ⇒ `calls` 恒为 0。这条把「为什么不能那样写」
    /// 变成永久可执行的证据（Lead 探针：内容内 0 次 / 容器外 6 次）。
    testWidgets('⑥ 反例：内容内部的 NotificationListener 收不到通知', (
      WidgetTester tester,
    ) async {
      int insideCalls = 0;
      int outsideCalls = 0;
      // 「容器外」= 包住 `Scrollable` 自身（在它**上面**）；「容器内」= 滚动内容里。
      // 注意连「与页脚同层的兄弟」也在内——滚动通知的起点
      // `notificationContext`（`scrollable.dart:604` 的 `_gestureDetectorKey`）
      // 比用户内容更靠上，故内容里**任何**位置都收不到。
      await tester.pumpWidget(previewTheme(
        NotificationListener<ScrollNotification>(
          onNotification: (ScrollNotification n) {
            outsideCalls++;
            return false;
          },
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const SizedBox(height: 4000),
                NotificationListener<ScrollNotification>(
                  onNotification: (ScrollNotification n) {
                    insideCalls++;
                    return false;
                  },
                  child: const SizedBox(height: 80),
                ),
              ],
            ),
          ),
        ),
      ));
      await settleFrames(tester);

      final ScrollPosition p = position(tester);
      p.jumpTo(p.maxScrollExtent);
      await tester.pumpAndSettle();

      expect(outsideCalls, greaterThan(0), reason: '容器外（祖先）能收到滚动通知');
      expect(
        insideCalls,
        0,
        reason: '容器内（滚动视图的后代）收不到 ⇒ 修复前那条路径是死代码',
      );
    });

    testWidgets('⑤b 无祖先 Scrollable ⇒ 不触发、不崩（防御性）', (WidgetTester tester) async {
      int calls = 0;
      await tester.pumpWidget(previewTheme(
        AylaDirectoryLoadMore(
          loading: false,
          error: null,
          hasMore: true,
          invalidated: false,
          loadMore: () async => calls++,
          refresh: () async {},
        ),
      ));
      await settleFrames(tester);
      expect(tester.takeException(), isNull);
      expect(calls, 0, reason: '没有可绑定的 ScrollPosition ⇒ 无判定数据源');
    });
  });
}
