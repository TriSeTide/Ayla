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
import '../lib/widgets/base/dialogs.dart' show AylaModalOverlay;
import '../lib/widgets/base/favorite_item.dart';
import '../lib/widgets/base/profile_and_filters.dart' show AylaDirectoryFilters;
import '../lib/widgets/base/switch.dart';
import '../lib/widgets/base/visibility_selector.dart';
import '../lib/widgets/chat/conversation_list.dart';
import '../lib/widgets/chat/conversation_more_menu.dart';
import '../lib/widgets/group/group_card.dart';
import '../lib/widgets/group/group_info_settings.dart';
import '../lib/widgets/posts/post_card.dart';
import '../lib/widgets/search/search_history_chips.dart';

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
      final List<MouseRegion> regions = regionsIn(
        tester,
        find.byType(AylaPostCard),
      );
      // 卡内存在 pointer 区（.post-card-main 主区 + .post-card-open 键）；
      // 尾部分享键同理（`PostCard.tsx:146–153` 的 `<ShareButton>` 是
      // `.icon-btn-40.post-card-share` ⇒ `base.css:340` 全局 pointer）。
      //
      // ⚠️ **2026-10-09 订正**：本条此前断言「未传 `onShare` 的分享键按 disabled 档给
      // not-allowed」。那只在分享键的**注入档**成立；共享件自 2026-10-09 起具备
      // **自给自足档**（`share.dart` 的 `_canSelfServe`：`AylaPostCard` 恒传
      // `payloadBuilder`，对齐 web 的 `<ShareButton payload={…}/>` **无条件可点**）
      // ⇒ 本卡不再出现 forbidden 声明。原断言是**旧行为的锁**，会与 web 冲突，
      // 故改为断言「分享键声明 click」（与 web 一致，且更严格：主区 + 尾键都在）。
      expect(
        regions.where((MouseRegion r) => r.cursor == SystemMouseCursors.click),
        isNotEmpty,
        reason: '帖子卡主区/「查看帖子」/分享键应声明 cursor: click',
      );
      expect(
        regions.where(
          (MouseRegion r) => r.cursor == SystemMouseCursors.forbidden,
        ),
        isEmpty,
        reason: 'web 的转发键 unconditional（PostCard.tsx:146–153）⇒ 不应有禁用指针',
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

  // ==================================================================
  // 2026-10-09 全库普查后新补的件（逐件锁定，防回退）
  // ==================================================================
  group('抽查 ②：2026-10-09 普查补过指针的件', () {
    testWidgets('目录页分类选项卡（.directory-filter 是 <button role=tab>）→ click', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          SizedBox(
            width: 300,
            child: AylaDirectoryFilters(
              label: '收藏分类',
              options: const <({String key, String label})>[
                (key: 'all', label: '全部'),
              ],
              value: 'all',
              narrow: false,
              onChange: (String _) {},
            ),
          ),
        ),
      );
      await tester.pump();
      // `DirectoryFilters.tsx:73–83` = <button type="button" role="tab">
      // ⇒ base.css:340 全局 pointer；directory-filters.css:117 另有同值声明。
      final List<MouseRegion> regions = regionsIn(
        tester,
        find.byType(AylaDirectoryFilters),
      );
      expect(
        regions.where((MouseRegion r) => r.cursor == SystemMouseCursors.click),
        isNotEmpty,
        reason: '分类选项卡应声明 cursor: click（此前漏挂 ⇒ 用户实报不变手指）',
      );
    });

    testWidgets('可见性群选项（.visibility-group-option）：可点 → click / 锁定 → not-allowed', (
      WidgetTester tester,
    ) async {
      // `VisibilitySelector.tsx:96` = <label> 包 <input type=checkbox disabled={isLockedGroup}>；
      // app.css:200 `cursor: pointer`、app.css:217–219 `.is-locked { cursor: not-allowed }`。
      await tester.pumpWidget(
        host(
          SizedBox(
            width: 320,
            child: AylaVisibilitySelector(
              value: const AylaVisibilitySelection(group: true),
              onChange: (AylaVisibilitySelection _) {},
              // 锁定的本群 + 一个可选群（`lockGroup && initialGroupId == id` ⇒ is-locked）
              groups: const <({String id, String title})>[
                (id: 'g1', title: '本群（锁定）'),
                (id: 'g2', title: '公开群'),
              ],
              selectedGroupIds: const <String>['g1'],
              onSelectedGroupIdsChange: (List<String> _) {},
              initialGroupId: 'g1',
              lockGroup: true,
            ),
          ),
        ),
      );
      await tester.pump();
      final List<MouseRegion> regions = regionsIn(
        tester,
        find.byType(AylaVisibilitySelector),
      );
      expect(
        regions.where((MouseRegion r) => r.cursor == SystemMouseCursors.click),
        isNotEmpty,
        reason: '可点群选项应声明 cursor: click（app.css:200）',
      );
      expect(
        regions.where(
          (MouseRegion r) => r.cursor == SystemMouseCursors.forbidden,
        ),
        isNotEmpty,
        reason: '锁定群选项应声明 cursor: not-allowed（app.css:217–219）',
      );
    });

    testWidgets('行装配开关（AylaSwitch ownTap:false）本体仍声明 click', (
      WidgetTester tester,
    ) async {
      // web 两处开关都是 <button role=switch>（ProfilePage.tsx:266）/ <label> 包 input
      // ⇒ base.css:340 pointer。行装配档（ownTap:false）此前整件不挂指针层 ⇒ defer。
      await tester.pumpWidget(
        host(
          SizedBox(
            width: 300,
            child: AylaSwitch(
              value: false,
              variant: AylaSwitchVariant.regular,
              ownTap: false,
              semanticLabel: '行装配开关',
              onChanged: (bool _) {},
            ),
          ),
        ),
      );
      await tester.pump();
      expect(
        cursorOf(tester, find.byType(AylaSwitch)),
        SystemMouseCursors.click,
      );
    });

    testWidgets('行装配开关禁用（onChanged == null）→ not-allowed', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          const SizedBox(
            width: 300,
            child: AylaSwitch(
              value: true,
              variant: AylaSwitchVariant.compact,
              ownTap: false,
              semanticLabel: '行装配开关禁用',
              onChanged: null,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(
        cursorOf(tester, find.byType(AylaSwitch)),
        SystemMouseCursors.forbidden,
      );
    });

    testWidgets('弹层遮罩（AylaModalOverlay）→ 不是 click（web 遮罩无 cursor 声明）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          AylaModalOverlay(
            onDismiss: () {},
            child: const SizedBox(width: 200, height: 120, child: Text('弹卡')),
          ),
        ),
      );
      await tester.pump();
      final MouseCursor cursor = cursorOf(tester, find.byType(AylaModalOverlay));
      expect(cursor, SystemMouseCursors.basic,
          reason: '遮罩选择器（profile.css:626 等）无 cursor 声明 ⇒ 默认箭头');
    });

    testWidgets('群信息开关：本体（AylaSwitch ownTap:false）声明 click；整行缺口已登记', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          SizedBox(
            width: 320,
            child: AylaGroupInfoSwitch(
              label: '允许成员邀请',
              value: false,
              onChanged: (bool _) {},
            ),
          ),
        ),
      );
      await tester.pump();
      // ⚠️ **整行的指针缺口已登记为跨域移交**（2026-10-09）：web 的
      // `<label class="group-info-switch">`（`GroupInfo.tsx:585`）命中
      // `group.css:1930–1937` 的 `cursor: pointer`，而 Flutter 侧整行**无指针层**
      // ⇒ `defer` 会沿命中链继续往外找。该文件属并行 agent 的禁改范围，
      // 本轮只登记未改（见 13 号 §10.1 的移交清单）。
      // 本用例锁定**已生效的那一半**：开关本体（`AylaSwitch ownTap:false`）
      // 由公共件声明 click，保证「悬停开关圆盘」是手型。
      expect(
        cursorOf(tester, find.byType(AylaSwitch)),
        SystemMouseCursors.click,
        reason: '开关本体是 <button role=switch> ⇒ click（已生效）',
      );
    });

    testWidgets('搜索历史 chip（AylaPressScale 壳）→ click', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          const AylaSearchHistoryChips(
            history: <String>['爱莉'],
            // ⚠️ 必须传 onClear：不传时「清空」键落 disabled 档（forbidden），
            // 而本件同时含两个 AylaPressScale ⇒ `cursorOf`（取树里最后一个）会读到它。
            onClear: _noop,
          ),
        ),
      );
      await tester.pump();
      // `.search-chip` 是 `<button class="search-chip">`（SearchPage.tsx:365）
      // ⇒ base.css:340 pointer。本件断言「存在 click 声明」而不是取单点最内层
      //（两个子键共存，单点解析值取决于鼠标实际悬停位置）。
      final List<MouseRegion> regions = regionsIn(
        tester,
        find.byType(AylaSearchHistoryChips),
      );
      expect(
        regions.where((MouseRegion r) => r.cursor == SystemMouseCursors.click),
        isNotEmpty,
        reason: '历史 chip / 清空键应声明 cursor: click',
      );
    });

    testWidgets('会话「⋯」更多键（.conv-more-btn 是 <button>）→ click', (
      WidgetTester tester,
    ) async {
      // ⚠️ 本件返回 `Positioned`（消费 Stack 的 parent data）⇒ 必须放进 Stack，
      // 否则抛 `Incorrect use of ParentDataWidget`（实测）。
      await tester.pumpWidget(
        host(
          Stack(
            children: <Widget>[
              AylaConversationMoreMenu(
                conversation: const AylaConversation(id: 'c1', title: '小樱'),
                showDelete: true,
              ),
            ],
          ),
        ),
      );
      await tester.pump();
      expect(
        cursorOf(tester, find.byType(AylaConversationMoreMenu)),
        SystemMouseCursors.click,
      );
    });

    testWidgets('会话「⋯」更多键 busy ⇒ not-allowed（disabled={busy}）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          Stack(
            children: <Widget>[
              AylaConversationMoreMenu(
                conversation: const AylaConversation(id: 'c1', title: '小樱'),
                showDelete: true,
                busy: true,
              ),
            ],
          ),
        ),
      );
      await tester.pump();
      expect(
        cursorOf(tester, find.byType(AylaConversationMoreMenu)),
        SystemMouseCursors.forbidden,
      );
    });

    testWidgets('收藏项（.favorite-item → 内含可点卡）→ click', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          const SizedBox(
            width: 360,
            child: AylaFavoriteItem(child: Text('收藏内容')),
          ),
        ),
      );
      await tester.pump();
      // .favorite-item 自身是 <div>（FavoritesPage.tsx:95），web 的 click 来自
      // 内部 .post-card-main / typed 卡（typed-result-cards.css:4/6）与「取消收藏」<button>。
      // 本件只放静态子件 ⇒ 不断言整件，改断言「不含 forbidden 声明」。
      final List<MouseRegion> regions = regionsIn(
        tester,
        find.byType(AylaFavoriteItem),
      );
      expect(
        regions.where(
          (MouseRegion r) => r.cursor == SystemMouseCursors.forbidden,
        ),
        isEmpty,
      );
    });
  });
}

/// 空回调（const 上下文里不能写闭包字面量）。
void _noop() {}
