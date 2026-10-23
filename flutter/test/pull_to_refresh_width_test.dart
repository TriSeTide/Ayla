/// 回归锁：`AylaPullToRefresh` 的内容必须**块级撑满父可用宽**。
///
/// ## 症状（用户实报 2026-10-20）
/// 群内帖子页的空态「群内还没有帖子 / 在下方输入框发第一条帖子」**左右不居中**：
/// 400 宽视口下占位壳只有 245.8 宽并贴左，标题中心 x=138.875，而屏幕中心是 200。
///
/// ## 事实源（web，禁自由发挥）
/// `Ayla/web/src/components/motion/PullToRefresh.tsx`（JSX 253–279）+
/// `Ayla/web/src/styles/app.css:4008–4035`：
/// - `.pull-to-refresh { position: relative; min-height: 0 }`（4010–4013）—— 容器在流内；
/// - `.pull-refresh-content { position: relative }`（4015–4017）—— 内容在流内；
///   **块级 div 的 `width: auto` 在块级格式化上下文里用掉父宽**（CSS 2.1 §10.3.3）
///   ⇒ 内容盒宽 == 容器盒宽，其内部的居中才落回屏幕中心；
/// - `.pull-refresh-indicator`（4022–4035）是 `position: absolute`，不参与尺寸。
///
/// ## 根因（Flutter 侧）
/// 内容只被 `Align(alignment: topLeft, heightFactor: 1.0)` 包了一层。
/// `RenderPositionedBox._layoutChild` 只把约束 **`loosen()` 后透传**给子级
/// （`flutter/lib/src/rendering/shifted_box.dart:461–473`）⇒ 子级 `minWidth: 0`，
/// 自身不撑宽就只占内容宽 ⇒ 贴左。
/// 修法 = 内容外包 `AylaInlineNaturalSize`（`widgets/base/fit_content.dart`，
/// 块级 `width:auto` / `flex:1` 的两趟语义）：
/// 宽有界 ⇒ tight = `constraints.maxWidth`；宽无界 ⇒ 取子级自然宽。
/// 外层 `Align(heightFactor: 1.0)` **保留**（高度由内容决定，2026-09-29 P0 的修复）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/glass.dart' show AylaGlassButton;
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart' show AylaSpacing;
import '../lib/widgets/base/media_interaction.dart';
import '../lib/widgets/group/group_scene.dart'
    show
        AylaGroupSceneHead,
        AylaGroupScenePlaceholder,
        AylaGroupSceneStickyHead;

void main() {
  group('AylaPullToRefresh 内容宽度（块级撑满，web app.css:4015–4017）', () {
    // ======================= ① 有界宽度 =======================

    testWidgets('① 有界宽度：内容子级宽 == AylaPullToRefresh 自身宽', (WidgetTester tester) async {
      final GlobalKey pullKey = GlobalKey();
      final GlobalKey contentKey = GlobalKey();
      await tester.pumpWidget(
        previewTheme(
          SizedBox(
            width: 400,
            height: 600,
            // 探针用裸 Text：它在 **loose** 约束下只取自身文字宽
            // （RenderParagraph: size = constraints.constrain(textSize)），
            // 在 **tight** 约束下取满宽 ⇒ 能区分「loosen() 透传」(错) 与
            // 「块级 fill-available」(对) 两种语义。
            child: AylaPullToRefresh(
              key: pullKey,
              isAtTop: () => true,
              onRefresh: () async {},
              child: Text('窄内容', key: contentKey),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);

      final Rect pull = tester.getRect(find.byKey(pullKey));
      final Rect text = tester.getRect(find.byKey(contentKey));

      expect(pull.width, 400, reason: '容器本身撑满父宽（此前即已正确）');
      expect(
        text.width,
        pull.width,
        reason: '内容盒宽必须 == 容器盒宽（web .pull-refresh-content 是块级 div，'
            'width:auto 吃掉父宽）；修复前这里只有文字自然宽 ⇒ 内部居中失效',
      );
      expect(
        text.left,
        pull.left,
        reason: '块级左对齐（内容左沿与容器左沿重合）',
      );
    });

    testWidgets('①-b 有界宽度 + 内容自身塌陷：仍撑满（不是"跟着内容缩"）',
        (WidgetTester tester) async {
      final GlobalKey pullKey = GlobalKey();
      final GlobalKey contentKey = GlobalKey();
      await tester.pumpWidget(
        previewTheme(
          SizedBox(
            width: 400,
            height: 600,
            child: AylaPullToRefresh(
              key: pullKey,
              isAtTop: () => true,
              onRefresh: () async {},
              child: Align(
                key: contentKey,
                alignment: Alignment.topLeft,
                heightFactor: 1.0,
                child: const Text('左上角一小块'),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);

      final Rect pull = tester.getRect(find.byKey(pullKey));
      final Rect box = tester.getRect(find.byKey(contentKey));
      expect(box.width, pull.width,
          reason: '内容即使内部只占一小块，盒子本身也必须占满父宽');
    });

    // ======================= ② 真实调用点 =======================

    testWidgets('② 真实调用点（群内帖子空态）：标题/描述/按钮中心 x == 屏幕中心 x',
        (WidgetTester tester) async {
      // 400 宽视口 ⇒ 屏幕中心 x = 200.0（用户实报的取样条件）
      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      // 结构逐条复刻 `pages/group_posts_page.dart:1134–1163`：
      // AylaGroupSceneStickyHead(padding: all(sp4), gap: sp4)
      //   └ AylaPullToRefresh(child: AylaGroupScenePlaceholder(...))
      // 文案逐字取自同文件 957–964（web GroupPosts.tsx:406–412）。
      await tester.pumpWidget(
        previewTheme(
          SizedBox(
            width: 400,
            height: 800,
            child: AylaGroupSceneStickyHead(
              padding: const EdgeInsets.all(AylaSpacing.sp4),
              gap: AylaSpacing.sp4,
              head: const AylaGroupSceneHead(
                title: '群内帖子',
                description: '浏览本群的最新动态',
              ),
              child: AylaPullToRefresh(
                isAtTop: () => true,
                onRefresh: () async {},
                child: AylaGroupScenePlaceholder(
                  title: '群内还没有帖子',
                  description: '在下方输入框发第一条帖子',
                  actions: <Widget>[
                    AylaGlassButton(label: '返回聊天', onPressed: () {}),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400)); // 头部入场动画走完
      expect(tester.takeException(), isNull);

      const double screenCenterX = 200.0; // 400 / 2

      final Rect title = tester.getRect(find.text('群内还没有帖子'));
      final Rect desc = tester.getRect(find.text('在下方输入框发第一条帖子'));
      final Rect button = tester.getRect(find.text('返回聊天'));

      expect(title.center.dx, closeTo(screenCenterX, 0.01),
          reason: '标题中心必须落在屏幕中心（修复前 138.875）');
      expect(desc.center.dx, closeTo(screenCenterX, 0.01),
          reason: '描述中心必须落在屏幕中心');
      expect(button.center.dx, closeTo(screenCenterX, 0.01),
          reason: '操作键中心必须落在屏幕中心');

      // 占位壳自身也要满宽（16 + 368 + 16 = 400）
      final Rect pull = tester.getRect(find.byType(AylaPullToRefresh));
      expect(pull.width, 400 - AylaSpacing.sp4 * 2,
          reason: '滚动口左右各 sp4 留白 ⇒ 容器宽 368');
      final Rect shell = tester.getRect(find.byType(AylaGroupScenePlaceholder));
      expect(shell.width, pull.width,
          reason: '占位壳（内容盒）宽必须 == 容器宽（修复前 245.8）');
      expect(shell.center.dx, closeTo(screenCenterX, 0.01));
    });

    testWidgets('②-b 空态仍可下拉刷新（居中修好不影响命中面）', (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      int refreshes = 0;
      await tester.pumpWidget(
        previewTheme(
          SizedBox(
            width: 400,
            height: 800,
            child: AylaGroupSceneStickyHead(
              padding: const EdgeInsets.all(AylaSpacing.sp4),
              gap: AylaSpacing.sp4,
              head: const AylaGroupSceneHead(title: '群内帖子'),
              child: AylaPullToRefresh(
                isAtTop: () => true,
                onRefresh: () async => refreshes++,
                child: const AylaGroupScenePlaceholder(
                  title: '群内还没有帖子',
                  description: '在下方输入框发第一条帖子',
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final Rect pull = tester.getRect(find.byType(AylaPullToRefresh));
      final TestGesture g =
          await tester.startGesture(Offset(pull.center.dx, pull.top + 40));
      await tester.pump();
      await g.moveTo(Offset(pull.center.dx, pull.top + 150)); // dy = 110 > 64
      await tester.pump();
      await g.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));

      expect(refreshes, 1, reason: '空态下拉必须触发刷新（web 三态都在 PullToRefresh 内）');
      expect(tester.takeException(), isNull);
    });

    // ======================= ③ 宽度无界 =======================

    testWidgets('③ 宽度无界（横向滚动容器内）：不炸、内容取自然宽',
        (WidgetTester tester) async {
      final GlobalKey pullKey = GlobalKey();
      final GlobalKey contentKey = GlobalKey();

      await tester.pumpWidget(
        previewTheme(
          // 横向 SingleChildScrollView ⇒ 子级拿到 `heightConstraints()`：
          // 宽 0..∞（本用例要验的「无界宽」）、高 tight。
          SizedBox(
            width: 400,
            height: 300,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: AylaPullToRefresh(
                key: pullKey,
                isAtTop: () => true,
                onRefresh: () async {},
                child: SizedBox(
                  key: contentKey,
                  width: 900, // 自然宽 > 视口 ⇒ 真能横向滚
                  height: 120,
                  child: const Text('横向内容'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull,
          reason: "无界宽下不得出现 Stack 的 'size.isFinite' 断言"
              '（此前把 infinity 透传给子级会崩）');

      final Size pull = tester.getSize(find.byKey(pullKey));
      expect(pull.width.isFinite, isTrue, reason: '容器宽必须有限（取内容自然宽 900）');
      expect(pull.width, 900,
          reason: '无界宽 ⇒ 用无界主轴布局一次、取子级自然宽（CSS intrinsic 趟 max-content）');

      final Size contentSize = tester.getSize(find.byKey(contentKey));
      expect(contentSize.width, 900);
      expect(contentSize.width, pull.width,
          reason: '无界宽下内容盒宽 == 容器宽（自然宽）');
    });

    testWidgets('③-b 宽度无界 + 高度无界（两个方向都无界也不崩）', (WidgetTester tester) async {
      await tester.pumpWidget(
        previewTheme(
          SingleChildScrollView(
            scrollDirection: Axis.vertical,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: AylaPullToRefresh(
                isAtTop: () => true,
                onRefresh: () async {},
                child: const SizedBox(
                  width: 700,
                  height: 200,
                  child: Text('双向自然尺寸'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('双向自然尺寸'), findsOneWidget);
    });
  });
}
