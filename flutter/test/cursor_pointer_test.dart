/// 指针（cursor）覆盖回归 —— 问题 15「很多按钮鼠标悬停时没有变成选中的手指指针」。
///
/// ## web 事实源
/// - **全局兜底**：`base.css:333–341` \`button { … cursor: pointer }` —— web 上**凡是
///   `<button>`** 都是手型，无需逐条声明；`base.css:343–346`
///   \`button:disabled { cursor: not-allowed; opacity: .55 }` ⇒ 禁用态**不是**手型。
/// - **组件级**：另有 56 处逐选择器声明（`typed-result-cards.css:4/6` 的 `.post-card-main`、
///   `app.css:3300` 的 `.live-card`、`voice.css:538/709` 的 `.voice-channel-card` 等）；
///   且**反向**也有声明（`typed-result-cards.css:43`、`voice.css:553/724` 的
///   `[aria-disabled="true"]`、`live.css:1266` 的骨架行 ⇒ `cursor: default`）。
///
/// ## Flutter 侧结构差异（本任务调研结论）
/// Flutter **没有 CSS 级联等价物**：
/// - `mouse_cursor.dart:261–264` 的 `_DeferringMouseCursor.resolve` 语义 = 「取命中链里
///   **第一个非 defer** 的候选」；`MouseTracker._handleDeviceUpdate`
///   （`mouse_tracker.dart:277–281`）把 `details.nextAnnotations.keys` 的 cursor 交给
///   `MouseCursorManager`。命中链自内向外 ⇒ **内层 MouseRegion 一定遮蔽外层**，
///   父级包一层无法「继承」到子按钮。
/// - 因此 web 的「全局 button 兜底」在 Flutter 只能落到**按钮族公共壳**
///   （`AylaPressScale` / `AylaCardInteraction`）上，其余按 web 逐选择器声明补。
///
/// 本文件断言的是**组件声明的 cursor**（渲染层坐标无关）；
/// 测试环境没有原生指针设备，`debugDeviceActiveCursor` 恒为 null，
/// 无法断言平台最终光标，故按 widget 声明面断言。
///
/// 覆盖：① `AylaCardInteraction` 的 cursor 推导；② `AylaPressScale` 禁用/可用两档；
/// ③ 抽查 4 个补过指针的件；④ 反向档（不可点 → 不是 click）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/conversation.dart';
import '../lib/core/models/post.dart';
import '../lib/theme/buttons.dart';
import '../lib/theme/glass.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/widgets/chat/conversation_list.dart';
import '../lib/widgets/group/group_card.dart';
import '../lib/widgets/posts/post_card.dart';

void main() {
  Widget host(Widget child) => MaterialApp(
    home: previewTheme(
      Builder(
        builder: (BuildContext context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(size: const Size(420, 900)),
          child: Center(child: child),
        ),
      ),
    ),
  );

  /// [root] 子树里**由该件自己声明**的 MouseRegion 列表（不含宿主主题的）。
  List<MouseRegion> regionsIn(WidgetTester tester, Finder root) => tester
      .widgetList<MouseRegion>(
        find.descendant(of: root, matching: find.byType(MouseRegion)),
      )
      .toList();

  /// 该件**实际生效**的 cursor —— 复刻 Flutter 的解析语义：
  /// 命中链自内向外，取**最内层的非 defer** 候选
  /// （`mouse_cursor.dart:261–264` `_DeferringMouseCursor.resolve`）。
  MouseCursor cursorOf(WidgetTester tester, Finder root) {
    final List<MouseRegion> regions = regionsIn(tester, root);
    expect(regions, isNotEmpty, reason: 'root 子树里应至少有一个 MouseRegion');
    for (final MouseRegion r in regions.reversed) {
      if (r.cursor != MouseCursor.defer) return r.cursor;
    }
    return MouseCursor.defer;
  }

  group('AylaCardInteraction 的 cursor 推导（web 卡片族逐域声明 pointer）', () {
    testWidgets('onTap != null → click', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          AylaCardInteraction(
            onTap: () {},
            builder: (BuildContext c, bool hovered) =>
                const SizedBox(width: 200, height: 80, child: Text('可点卡')),
          ),
        ),
      );
      expect(
        cursorOf(tester, find.byType(AylaCardInteraction)),
        SystemMouseCursors.click,
      );
    });

    testWidgets('onTap == null → 不是 click（basic）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          AylaCardInteraction(
            builder: (BuildContext c, bool hovered) =>
                const SizedBox(width: 200, height: 80, child: Text('静态卡')),
          ),
        ),
      );
      final MouseCursor cursor = cursorOf(tester, find.byType(AylaCardInteraction));
      expect(cursor, isNot(SystemMouseCursors.click));
      expect(cursor, SystemMouseCursors.basic);
    });

    testWidgets('显式 cursor 覆盖推导（web 的 cursor: default 反向档）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          AylaCardInteraction(
            onTap: () {},
            cursor: SystemMouseCursors.basic, // 如 voice.css:553 [aria-disabled]
            builder: (BuildContext c, bool hovered) =>
                const SizedBox(width: 200, height: 80, child: Text('禁用卡')),
          ),
        ),
      );
      expect(
        cursorOf(tester, find.byType(AylaCardInteraction)),
        SystemMouseCursors.basic,
      );
    });

    testWidgets('interactive:false 且 onTap:null → 不挂指针层（既有行为不回退）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          AylaCardInteraction(
            interactive: false,
            builder: (BuildContext c, bool hovered) =>
                const SizedBox(width: 200, height: 80, child: Text('静态')),
          ),
        ),
      );
      expect(regionsIn(tester, find.byType(AylaCardInteraction)), isEmpty);
    });

    testWidgets('interactive:false 但有 onTap → 仍给 click（web .live-viewer-strip 档）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          AylaCardInteraction(
            interactive: false,
            onTap: () {},
            builder: (BuildContext c, bool hovered) =>
                const SizedBox(width: 200, height: 80, child: Text('观看条')),
          ),
        ),
      );
      expect(
        cursorOf(tester, find.byType(AylaCardInteraction)),
        SystemMouseCursors.click,
      );
    });
  });

  group('AylaPressScale 按钮族公共壳（base.css:340 全局 button: pointer 的等价物）', () {
    testWidgets('可点 → click', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          AylaPressScale(
            onTap: () {},
            child: const SizedBox(width: 120, height: 40, child: Text('按钮')),
          ),
        ),
      );
      expect(
        cursorOf(tester, find.byType(AylaPressScale)),
        SystemMouseCursors.click,
      );
    });

    testWidgets('onTap == null → not-allowed（disabled 档，base.css:343）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          const AylaPressScale(
            child: SizedBox(width: 120, height: 40, child: Text('禁用')),
          ),
        ),
      );
      expect(
        cursorOf(tester, find.byType(AylaPressScale)),
        SystemMouseCursors.forbidden,
      );
    });

    testWidgets('enabled:false → not-allowed', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          AylaPressScale(
            enabled: false,
            onTap: () {},
            child: const SizedBox(width: 120, height: 40, child: Text('禁用')),
          ),
        ),
      );
      expect(
        cursorOf(tester, find.byType(AylaPressScale)),
        SystemMouseCursors.forbidden,
      );
    });
  });

  group('抽查：补过指针的件', () {
    testWidgets('群卡整卡 → click（.group-card-main 轮播 + 底排 <button>）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          // 群卡依赖外层网格给宽高等约束（web 同：卡片由 .home-grid 列宽决定高）
          SizedBox(
            width: 360,
            height: 420,
            child: AylaGroupCard(
            groupId: 'g1',
            title: '测试群',
            slides: <AylaGroupCarouselSlide>[
              const AylaGroupCarouselSlide.messageVoice(
                newMessageCount: 3,
                voiceRooms: <AylaGroupSlideVoiceRoom>[],
              ),
            ],
            onOpen: () {},
          ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        cursorOf(tester, find.byType(AylaCardInteraction)),
        SystemMouseCursors.click,
      );
    });

    testWidgets('群列表行 → click', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          AylaGroupListItem(
            groupId: 'g1',
            title: '测试群',
            preview: '你好',
            onOpen: () {},
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        cursorOf(tester, find.byType(AylaCardInteraction)),
        SystemMouseCursors.click,
      );
    });

    testWidgets('帖子卡「查看帖子」为 <button> → click（PostCard.tsx:136）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          SizedBox(
            width: 360,
            child: AylaPostCard(
              post: const AylaPost(id: 1, title: '标题', body: '正文'),
              onOpen: () {},
            ),
          ),
        ),
      );
      await tester.pump();
      // 「查看帖子」自身的 MouseRegion（最内层那个祖先）
      final Finder openRegion = find
          .ancestor(
            of: find.text('查看帖子'),
            matching: find.byType(MouseRegion),
          )
          .first;
      // openRegion 自身即那个 MouseRegion ⇒ 直接读其声明（descendant 不含自身）
      expect(
        tester.widget<MouseRegion>(openRegion).cursor,
        SystemMouseCursors.click,
      );
      // 卡内存在 pointer 区（.post-card-main 主区 + .post-card-open 键）；
      // 尾部未传 onShare 的分享键按 disabled 档给 not-allowed（base.css:343）——
      // 整卡最终解析值取决于鼠标实际悬停位置，故这里只断言「主区确实声明了 click」。
      final List<MouseRegion> regions = regionsIn(
        tester,
        find.byType(AylaPostCard),
      );
      expect(
        regions.where((MouseRegion r) => r.cursor == SystemMouseCursors.click),
        isNotEmpty,
        reason: '帖子卡主区/「查看帖子」应声明 cursor: click',
      );
      expect(
        regions.where(
          (MouseRegion r) => r.cursor == SystemMouseCursors.forbidden,
        ),
        isNotEmpty,
        reason: '未传 onShare 的分享键应按 disabled 档给 not-allowed',
      );
    });

    testWidgets('会话列表行 → click（.conv-item 是 <button>）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          SizedBox(
            width: 360,
            child: AylaConversationList(
              conversations: <AylaConversationSummary>[
                const AylaConversationSummary(
                  id: 'c1',
                  type: AylaConversationType.private,
                  title: '小樱',
                ),
              ],
              activeId: null,
              onSelect: (String id) {},
            ),
          ),
        ),
      );
      await tester.pump();
      expect(
        cursorOf(tester, find.byType(AylaConversationList)),
        SystemMouseCursors.click,
      );
    });
  });
}
