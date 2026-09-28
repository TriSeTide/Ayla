/// `AylaPageState`（`.home-state` + placeholder 标题族）定向测试 —— 对照
/// `home.css:620–629` + `shell.css:595–629` + `directory-filters.css:185–187`。
///
/// 覆盖：容器几何（gap sp4 / padding sp12 sp6 / align-items center）· 宽度随父级（web 块级）·
/// title 28/600/display/text-primary · desc 14/body/text-secondary · children 顺序与间距 ·
/// 收藏页覆盖档（padding-top sp3）· 错态 liveRegion（web `role="alert"`）· title 缺省 ·
/// `search-empty` 的 20px 变体（`search.css:55–57`）。
///
/// ⚠️ 一态一用例（同用例二次 pumpWidget 换 props 不生效）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/base/page_state.dart';

void main() {
  Widget host(Widget child, {double width = 300}) => MaterialApp(
    home: previewScope(
      Builder(
        builder: (BuildContext context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(size: const Size(800, 600)),
          child: Center(child: SizedBox(width: width, child: child)),
        ),
      ),
    ),
  );

  testWidgets('容器几何：gap sp4 + padding sp12 sp6 + 居中', (WidgetTester tester) async {
    await tester.pumpWidget(host(const AylaPageState(
      title: '这个分类还没有收藏',
      description: '在对应场景点收藏，内容会出现在这里',
    )));

    final Rect box = tester.getRect(find.byType(AylaPageState));
    final Rect title = tester.getRect(find.text('这个分类还没有收藏'));
    final Rect desc = tester.getRect(find.text('在对应场景点收藏，内容会出现在这里'));

    // padding: var(--sp-12) var(--sp-6)（home.css:627）
    expect(title.top - box.top, AylaSpacing.sp12); // 48
    expect(box.bottom - desc.bottom, AylaSpacing.sp12);
    // gap: var(--sp-4)（626）
    expect(desc.top - title.bottom, AylaSpacing.sp4); // 16

    // align-items/ text-align center：两段文案水平居中于容器
    expect(title.center.dx, moreOrLessEquals(box.center.dx, epsilon: 0.5));
    expect(desc.center.dx, moreOrLessEquals(box.center.dx, epsilon: 0.5));
    // 宽度随父级（web 块级撑满）
    expect(box.width, 300);
  });

  testWidgets('title 28/600/display/text-primary · desc 14/body/text-secondary', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(const AylaPageState(
      title: '还没有帖子',
      description: '点右下角 + 发布第一条帖子',
    )));

    final Text title = tester.widget<Text>(find.text('还没有帖子')); // shell.css 619–624
    expect(title.style!.fontFamily, AylaFonts.display);
    expect(title.style!.fontSize, 28);
    expect(title.style!.fontWeight, FontWeight.w600);
    expect(title.style!.color, AylaColors.textPrimary);

    final Text desc = tester.widget<Text>(find.text('点右下角 + 发布第一条帖子')); // 626–629
    expect(desc.style!.fontFamily, AylaFonts.body); // 未声明 font-family ⇒ 继承 body
    expect(desc.style!.fontSize, 14);
    expect(desc.style!.color, AylaColors.textSecondary);
  });

  testWidgets('children 排在 description 之后、共用 gap sp4', (WidgetTester tester) async {
    await tester.pumpWidget(host(AylaPageState(
      title: '创建你的第一个群',
      description: '和朋友们聚在一起，从这里开始',
      children: <Widget>[const SizedBox(key: ValueKey<String>('action'), height: 30)],
    )));

    final Rect desc = tester.getRect(find.text('和朋友们聚在一起，从这里开始'));
    final Rect action = tester.getRect(find.byKey(const ValueKey<String>('action')));
    expect(action.top - desc.bottom, AylaSpacing.sp4);
  });

  testWidgets('收藏页覆盖档：padding-top sp3（directory-filters.css 185–187）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(const AylaPageState(
      title: '这个分类还没有收藏',
      description: '在对应场景点收藏，内容会出现在这里',
      padding: EdgeInsets.fromLTRB(
        AylaSpacing.sp6,
        AylaSpacing.sp3,
        AylaSpacing.sp6,
        AylaSpacing.sp12,
      ),
    )));

    final Rect box = tester.getRect(find.byType(AylaPageState));
    final Rect title = tester.getRect(find.text('这个分类还没有收藏'));
    expect(title.top - box.top, AylaSpacing.sp3); // 12，而非 48
  });

  testWidgets('错态：无 title 时不渲染 · liveRegion（web role=alert）· children 保留动作', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle handle = tester.ensureSemantics(); // 必须在测试体内 dispose
    try {
      await tester.pumpWidget(host(AylaPageState(
        description: '保存失败，请稍后重试',
        liveRegion: true,
        children: <Widget>[const SizedBox(key: ValueKey<String>('retry'), height: 30)],
      )));

      expect(find.byType(AylaPlaceholderTitle), findsNothing);
      final SemanticsNode node = tester.getSemantics(find.text('保存失败，请稍后重试'));
      expect(node.flagsCollection.isLiveRegion, isTrue);
      expect(find.byKey(const ValueKey<String>('retry')), findsOneWidget);
    } finally {
      handle.dispose();
    }
  });

  testWidgets('非 liveRegion 档不挂实时区域（空态无 role）', (WidgetTester tester) async {
    final SemanticsHandle handle = tester.ensureSemantics(); // 必须在测试体内 dispose
    try {
      await tester.pumpWidget(host(const AylaPageState(description: '换个分类看看')));

      final SemanticsNode node = tester.getSemantics(find.text('换个分类看看'));
      expect(node.flagsCollection.isLiveRegion, isFalse);
    } finally {
      handle.dispose();
    }
  });

  testWidgets('title 20px 变体（search.css 55–57 的 .search-empty 档）', (WidgetTester tester) async {
    await tester.pumpWidget(host(
      const AylaPlaceholderTitle('未找到「冰樱」相关结果', fontSize: 20),
    ));
    final Text title = tester.widget<Text>(find.text('未找到「冰樱」相关结果'));
    expect(title.style!.fontSize, 20);
    expect(title.style!.fontFamily, AylaFonts.display);
  });
}
