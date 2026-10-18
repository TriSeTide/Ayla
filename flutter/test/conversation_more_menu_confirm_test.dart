/// ⋯ 菜单的**删除二次确认** —— P0-2 的 UI 契约。
///
/// ## 事实源
/// web `ConversationMoreMenu.tsx`：
/// - `handleDelete`（105–108）：只 `closeMenu()` + `setConfirmDeleteOpen(true)`，
///   **不直接删除**；
/// - `doDelete`（110–120）：确认后才 `hideConversation(id).then(() => removeConversation(id))`；
/// - 确认弹层文案（206–213）：
///   `删除会话` / `删除会话「<title>」？\n消息记录会保留，对方再发消息时会话将重新出现。`
///
/// 菜单项（tsx 214–221）：置顶文案 `is_pinned ? "取消置顶" : "置顶"`，
/// 点击传 `!is_pinned`（`handleTogglePin` 96）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/preview_theme.dart';
import '../lib/widgets/chat/conversation_more_menu.dart';

/// 宿主：本件在会话行里是 `Positioned` ⇒ 必须有 `Stack` 祖先
/// （否则抛 `Incorrect use of ParentDataWidget`，见 `cursor_pointer_test.dart:552`）。
Widget _host(AylaConversationMoreMenu menu) => MaterialApp(
      home: previewTheme(
        Scaffold(body: Stack(children: <Widget>[menu])),
      ),
    );

/// 点开 ⋯ 按钮（aria-label「更多操作」= `_MoreButton` 的 Semantics label）。
///
/// 用语义 label 而不是坐标：本件外壳是 `Positioned(top:0,bottom:0,right:6)`，
/// 其 `Center` 在松约束下会撑满可用宽度 ⇒ 「组件几何中心」**不在按钮上**
/// （实测 tap 落空）。语义命中才是与 web `aria-label` 同口径的判据。
Future<void> _openMenu(WidgetTester tester) async {
  final SemanticsHandle handle = tester.ensureSemantics();
  await tester.tap(find.bySemanticsLabel('更多操作'));
  // 面板插进 Overlay 后要**下一帧**才测量出位置（`_MenuOverlayState._measure`）。
  await tester.pumpAndSettle();
  handle.dispose();
}

void main() {
  // ⚠️ 回归锁（2026-10-15 修复的真实缺陷）：面板曾被 `if (_pos != null)` 门控，
  // 而 `_pos` 只能靠**面板自身尺寸**算出 ⇒ 面板永不渲染、菜单项一个都不出现。
  // 用户侧症状就是 P0-1 / P0-2「点 ⋯ 没反应」。这里锁死「点开就能看到两项」。
  testWidgets('点开 ⋯ ⇒ 面板真的渲染出「置顶 / 删除会话」两项', (WidgetTester tester) async {
    await tester.pumpWidget(_host(const AylaConversationMoreMenu(
      conversation: AylaConversation(id: 'c1', title: '小樱'),
    )));
    await _openMenu(tester);

    expect(find.text('置顶'), findsOneWidget,
        reason: '面板必须可见（`_pos` 门控缺陷会让整块面板不渲染）');
    expect(find.text('删除会话'), findsOneWidget);

    // 面板几何：夹在视口内（tsx positionMenu 的 `edge = 8` 夹取）。
    // 默认测试视口 800×600（`TestWidgetsFlutterBinding` 的既定值）。
    final Size vp = tester.view.physicalSize / tester.view.devicePixelRatio;
    final Rect panel = tester.getRect(find.byType(AylaConversationMoreMenu).last);
    expect(panel.left, greaterThanOrEqualTo(0));
    expect(panel.top, greaterThanOrEqualTo(0));
    expect(panel.right, lessThanOrEqualTo(vp.width));
    expect(panel.bottom, lessThanOrEqualTo(vp.height));
  });

  testWidgets('点「删除会话」⇒ 弹确认框，**不直接回调** onDelete', (WidgetTester tester) async {
    int deletes = 0;
    await tester.pumpWidget(_host(AylaConversationMoreMenu(
      conversation: const AylaConversation(id: 'c1', title: '小樱'),
      onDelete: () => deletes++,
    )));
    await _openMenu(tester);

    await tester.tap(find.text('删除会话'));
    await tester.pumpAndSettle();

    expect(deletes, 0,
        reason: 'web handleDelete 只开确认，doDelete 才发请求（tsx 105–120）');
    expect(
      find.textContaining('消息记录会保留，对方再发消息时会话将重新出现。'),
      findsOneWidget,
      reason: 'ConversationMoreMenu.tsx:210 的确认文案原文',
    );
  });

  testWidgets('确认 ⇒ onDelete 回调一次', (WidgetTester tester) async {
    int deletes = 0;
    await tester.pumpWidget(_host(AylaConversationMoreMenu(
      conversation: const AylaConversation(id: 'c1', title: '小樱'),
      onDelete: () => deletes++,
    )));
    await _openMenu(tester);
    await tester.tap(find.text('删除会话'));
    await tester.pumpAndSettle();

    // AylaConfirmDialog 的确认键 = AylaGlassButton(label: confirmLabel 默认「删除」)
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(deletes, 1, reason: 'ConfirmDialog 确认 ⇒ doDelete 一次');
  });

  testWidgets('取消 ⇒ onDelete 一次都不调', (WidgetTester tester) async {
    int deletes = 0;
    await tester.pumpWidget(_host(AylaConversationMoreMenu(
      conversation: const AylaConversation(id: 'c1', title: '小樱'),
      onDelete: () => deletes++,
    )));
    await _openMenu(tester);
    await tester.tap(find.text('删除会话'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(deletes, 0, reason: 'ConfirmDialog 取消 ⇒ 不删');
  });

  testWidgets('未注入 onDelete ⇒ 菜单项仍渲染、确认后不崩', (WidgetTester tester) async {
    await tester.pumpWidget(_host(const AylaConversationMoreMenu(
      conversation: AylaConversation(id: 'c1', title: '小樱'),
    )));
    await _openMenu(tester);
    expect(find.text('删除会话'), findsOneWidget,
        reason: 'showDelete 默认 true，与 ConversationList.tsx:158 同口径');

    await tester.tap(find.text('删除会话'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: '回调为 null 时安全空转');
  });

  testWidgets('群聊档（showDelete=false）⇒ 没有「删除会话」项', (WidgetTester tester) async {
    await tester.pumpWidget(_host(const AylaConversationMoreMenu(
      conversation: AylaConversation(id: 'g1', title: '技术群'),
      showDelete: false,
    )));
    await _openMenu(tester);
    expect(find.text('删除会话'), findsNothing,
        reason: 'GroupCard.tsx:69 / GroupListItem.tsx:66 的 showDelete={false}');
    expect(find.text('置顶'), findsOneWidget);
  });

  testWidgets('置顶项文案随 isPinned 切换，点击回调收到取反值', (WidgetTester tester) async {
    bool? received;
    await tester.pumpWidget(_host(AylaConversationMoreMenu(
      conversation:
          const AylaConversation(id: 'c1', title: '小樱', isPinned: true),
      onTogglePin: (bool v) => received = v,
    )));
    await _openMenu(tester);

    expect(find.text('取消置顶'), findsOneWidget,
        reason: 'tsx 190 `conversation.is_pinned ? "取消置顶" : "置顶"`');
    await tester.tap(find.text('取消置顶'));
    await tester.pumpAndSettle();
    expect(received, isFalse, reason: 'handleTogglePin 的 next = !is_pinned');
  });

  testWidgets('未置顶 ⇒ 文案「置顶」，点击回调收到 true', (WidgetTester tester) async {
    bool? received;
    await tester.pumpWidget(_host(AylaConversationMoreMenu(
      conversation: const AylaConversation(id: 'c1', title: '小樱'),
      onTogglePin: (bool v) => received = v,
    )));
    await _openMenu(tester);
    expect(find.text('置顶'), findsOneWidget);
    await tester.tap(find.text('置顶'));
    await tester.pumpAndSettle();
    expect(received, isTrue);
  });
}
