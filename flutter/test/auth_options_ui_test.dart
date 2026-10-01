/// 登录页「记住密码 / 自动登录」定向测试。
///
/// 事实源：**新增功能** —— `web/src/pages/LoginPage.tsx` 全 95 行已核，web 侧没有这两个控件。
/// 视觉/交互全部沿用既有规范（复用件 [AylaCheckbox] + [AylaTextStyles.label] + web `app.css:161–167 /
/// 117–133`、`auth.css:63–72` 的规格），细节见 `lib/pages/login_page.dart` 的 [AylaAuthOptions] 库头。
///
/// ## 纪律（skill 固化）
/// - **一态一用例**：同一个 `testWidgets` 里换 props 再 pump 读到的是旧态 ⇒ 每条用例只验一档；
/// - **几何断言必须先钉真实表面**：默认 800×600 会把登录页宽屏分栏挤爆（`RenderFlex overflowed`）——
///   窄屏用例用 375×1400（够高，避免行落在视口外点不到），宽屏用例用 1440×900 并复位；
/// - 语义断言要 `tester.ensureSemantics()` 并 `dispose`（否则 `getSemantics` 拿到的是空节点）。
library;

import 'dart:ui' show CheckedState;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';

import '../lib/pages/login_page.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/base/checkbox.dart';

void main() {
  /// 窄屏表面（够高 ⇒ 卡内所有行都在视口内，`tap` 不会因为越界而失手）。
  const Size narrowSurface = Size(375, 1400);
  const Size narrowViewport = Size(375, 812);

  Future<void> useSurface(WidgetTester tester, Size size) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  /// 真实宿主：`previewScope` 提供主题/极光/Overlay/Localizations（缺一 TextField 崩）。
  Widget host(Widget child, {Size viewport = narrowViewport}) {
    return MaterialApp(
      home: Builder(
        builder: (BuildContext context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(size: viewport),
          child: previewScope(child),
        ),
      ),
    );
  }

  Finder rememberRow() => find.byKey(kAylaAuthRememberRowKey);
  Finder autoRow() => find.byKey(kAylaAuthAutoRowKey);
  Finder rememberBox() =>
      find.descendant(of: rememberRow(), matching: find.byType(AylaCheckbox));
  Finder autoBox() =>
      find.descendant(of: autoRow(), matching: find.byType(AylaCheckbox));

  /// 复选框**视觉**态（读 widget 的 checked，不是猜像素）。
  bool visualChecked(WidgetTester tester, Finder box) =>
      tester.widget<AylaCheckbox>(box).checked;

  group('AylaAuthOptions · 登录页内的两个开关', () {
    testWidgets('① 默认两行都不勾，文案逐字「记住密码」「自动登录」', (WidgetTester tester) async {
      await useSurface(tester, narrowSurface);
      await tester.pumpWidget(host(const LoginPage()));
      await tester.pump();

      expect(find.text('记住密码'), findsOneWidget);
      expect(find.text('自动登录'), findsOneWidget);
      expect(visualChecked(tester, rememberBox()), isFalse);
      expect(visualChecked(tester, autoBox()), isFalse);
    });

    testWidgets('①b 记住密码未勾 ⇒ 自动登录行禁用视觉（灰文案）、复选框未勾，仍可点', (WidgetTester tester) async {
      await useSurface(tester, narrowSurface);
      await tester.pumpWidget(host(const LoginPage()));
      await tester.pump();

      final Text autoLabel = tester.widget<Text>(find.text('自动登录'));
      final Text rememberLabel = tester.widget<Text>(find.text('记住密码'));
      expect(autoLabel.style?.color, AylaColors.textSecondary, reason: '禁用视觉 = 次要色');
      expect(rememberLabel.style?.color, AylaColors.textPrimary, reason: '记住密码行不禁用');
    });

    testWidgets('② 点「自动登录」（记住密码未勾）⇒ 两个同时变勾 + 回调 (true, true)', (
      WidgetTester tester,
    ) async {
      await useSurface(tester, narrowSurface);
      final List<List<bool>> calls = <List<bool>>[];
      await tester.pumpWidget(
        host(LoginPage(onRememberChanged: (bool r, bool a) => calls.add(<bool>[r, a]))),
      );
      await tester.pump();

      await tester.tap(autoRow());
      await tester.pump();

      expect(visualChecked(tester, rememberBox()), isTrue, reason: '自动登录 ⇒ 记住密码同时开');
      expect(visualChecked(tester, autoBox()), isTrue);
      expect(calls, <List<bool>>[
        <bool>[true, true],
      ]);
    });

    testWidgets('③ 取消「记住密码」⇒ 自动登录随之取消（视觉 + 语义两处）', (WidgetTester tester) async {
      await useSurface(tester, narrowSurface);
      final SemanticsHandle handle = tester.ensureSemantics();
      final List<List<bool>> calls = <List<bool>>[];
      await tester.pumpWidget(
        host(
          LoginPage(
            rememberPassword: true,
            autoLogin: true,
            onRememberChanged: (bool r, bool a) => calls.add(<bool>[r, a]),
          ),
        ),
      );
      await tester.pump();

      // 前置：两行都是勾上的（受控初值生效）
      expect(visualChecked(tester, rememberBox()), isTrue);
      expect(visualChecked(tester, autoBox()), isTrue);
      expect(
        tester.getSemantics(autoRow()).flagsCollection.isChecked,
        CheckedState.isTrue,
        reason: '语义前置：自动登录行 checked',
      );

      await tester.tap(rememberRow());
      await tester.pump();

      // 视觉两处
      expect(visualChecked(tester, rememberBox()), isFalse);
      expect(visualChecked(tester, autoBox()), isFalse, reason: '自动登录必须同时取消');
      // 语义两处
      expect(
        tester.getSemantics(rememberRow()).flagsCollection.isChecked,
        CheckedState.isFalse,
      );
      expect(
        tester.getSemantics(autoRow()).flagsCollection.isChecked,
        CheckedState.isFalse,
      );
      expect(calls, <List<bool>>[
        <bool>[false, false],
      ]);
      handle.dispose();
    });

    testWidgets('④ 点「记住密码」勾上 ⇒ 自动登录仍不勾 + 回调 (true, false)', (WidgetTester tester) async {
      await useSurface(tester, narrowSurface);
      final List<List<bool>> calls = <List<bool>>[];
      await tester.pumpWidget(
        host(LoginPage(onRememberChanged: (bool r, bool a) => calls.add(<bool>[r, a]))),
      );
      await tester.pump();

      await tester.tap(rememberRow());
      await tester.pump();

      expect(visualChecked(tester, rememberBox()), isTrue);
      expect(visualChecked(tester, autoBox()), isFalse, reason: '只勾记住密码不带动自动登录');
      expect(calls, <List<bool>>[
        <bool>[true, false],
      ]);
    });

    testWidgets('⑤ 已勾自动登录后单独取消它 ⇒ 记住密码保持勾选 + 回调 (true, false)', (
      WidgetTester tester,
    ) async {
      await useSurface(tester, narrowSurface);
      final List<List<bool>> calls = <List<bool>>[];
      await tester.pumpWidget(
        host(
          LoginPage(
            rememberPassword: true,
            autoLogin: true,
            onRememberChanged: (bool r, bool a) => calls.add(<bool>[r, a]),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(autoRow());
      await tester.pump();

      expect(visualChecked(tester, rememberBox()), isTrue, reason: '取消自动登录不撤销记住密码');
      expect(visualChecked(tester, autoBox()), isFalse);
      expect(calls, <List<bool>>[
        <bool>[true, false],
      ]);
    });

    testWidgets('⑥ 点复选框本体只切一次（整行一次手势，本体不挂手势）', (WidgetTester tester) async {
      await useSurface(tester, narrowSurface);
      final List<List<bool>> calls = <List<bool>>[];
      await tester.pumpWidget(
        host(LoginPage(onRememberChanged: (bool r, bool a) => calls.add(<bool>[r, a]))),
      );
      await tester.pump();

      await tester.tap(rememberBox()); // 点在复选框本体上
      await tester.pump();

      expect(calls.length, 1, reason: '双侧挂手势会翻两次（净效果 = 回到原位）');
      expect(visualChecked(tester, rememberBox()), isTrue);
    });

    testWidgets('⑦ 键盘：焦点在「记住密码」行上按 Enter ⇒ 切换一次', (WidgetTester tester) async {
      await useSurface(tester, narrowSurface);
      final List<List<bool>> calls = <List<bool>>[];
      await tester.pumpWidget(
        host(LoginPage(onRememberChanged: (bool r, bool a) => calls.add(<bool>[r, a]))),
      );
      await tester.pump();

      // 焦点顺序：用户名输入框（autofocus）→ 密码 → 记住密码行 → 自动登录行。
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(calls, <List<bool>>[
        <bool>[true, false],
      ]);
    });

    testWidgets('⑧ focus 环：行获得焦点时出现（--focus-ring offset 2）', (WidgetTester tester) async {
      await useSurface(tester, narrowSurface);
      await tester.pumpWidget(host(const LoginPage()));
      await tester.pump();

      expect(find.byKey(kAylaAuthRememberFocusRingKey), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(find.byKey(kAylaAuthRememberFocusRingKey), findsOneWidget);
    });

    testWidgets('⑨ onChanged: null ⇒ 两个选项都不可点（直接渲染 AylaAuthOptions）', (WidgetTester tester) async {
      await useSurface(tester, narrowSurface);
      await tester.pumpWidget(
        host(
          const AylaAuthOptions(remember: false, auto: false, onChanged: null),
        ),
      );
      await tester.pump();

      await tester.tap(rememberRow());
      await tester.pump();
      expect(visualChecked(tester, rememberBox()), isFalse); // 无异常即通过（无回调可触发）
    });
  });

  group('布局与提交路径', () {
    testWidgets('宽屏：两个开关**同一行**，整体位于密码字段与「登录」按钮之间', (WidgetTester tester) async {
      await useSurface(tester, const Size(1440, 900));
      await tester.pumpWidget(host(const LoginPage(), viewport: const Size(1440, 900)));
      await tester.pump();

      final Rect password = tester.getRect(find.byType(TextField).at(1)); // 0=用户名 1=密码
      final Rect remember = tester.getRect(rememberRow());
      final Rect auto = tester.getRect(autoRow());
      final Rect login = tester.getRect(find.text('登录'));

      expect(remember.top, greaterThanOrEqualTo(password.bottom), reason: '在密码框之下');
      expect(login.top, greaterThanOrEqualTo(remember.bottom), reason: '在「登录」按钮之上');
      expect(login.top, greaterThanOrEqualTo(auto.bottom), reason: '在「登录」按钮之上');
      // 选项 min-height 40（`app.css:117–133`）
      expect(remember.height, greaterThanOrEqualTo(40));
      expect(auto.height, greaterThanOrEqualTo(40));
      // ---- 同一行（2026-10-01 用户要求）----
      expect(
        (auto.center.dy - remember.center.dy).abs(),
        lessThanOrEqualTo(1.0),
        reason: '两个开关必须竖直居中对齐（同一行）',
      );
      expect(auto.left, greaterThanOrEqualTo(remember.right), reason: '记住密码在左、自动登录在右');
      expect(
        auto.left - remember.right,
        AylaAuthOptions.optionGap,
        reason: '同一行内间距 = .visibility-selector-options 的 gap: var(--sp-2)（app.css:111–115）',
      );
    });

    testWidgets('窄卡（375 档）里两个开关仍同一行（放得下就不折行）', (WidgetTester tester) async {
      await useSurface(tester, const Size(375, 1400));
      await tester.pumpWidget(host(const LoginPage(), viewport: const Size(375, 812)));
      await tester.pump();

      final Rect remember = tester.getRect(rememberRow());
      final Rect auto = tester.getRect(autoRow());
      expect((auto.center.dy - remember.center.dy).abs(), lessThanOrEqualTo(1.0));
      expect(auto.left, greaterThanOrEqualTo(remember.right));
      expect(auto.right, lessThanOrEqualTo(375), reason: '不得溢出视口');
    });

    testWidgets('⑩ 密码框回车仍触发 onSubmit，且 username/password 正确（不受勾选影响）', (
      WidgetTester tester,
    ) async {
      await useSurface(tester, narrowSurface);
      final List<String> submitted = <String>[];
      await tester.pumpWidget(
        host(
          LoginPage(
            initialUsername: 'alice',
            initialPassword: 'pw123456',
            onSubmit: (String u, String p) => submitted.add('$u|$p'),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(autoRow()); // 勾选动作不触发提交
      await tester.pump();
      expect(submitted, isEmpty, reason: '点开关不触发登录提交');

      // `receiveAction` 只发给**当前持有输入连接**的字段（0=用户名 / 1=密码）
      // ⇒ 先点密码框让它接管连接，再发回车，才是在测「密码框回车」这条既有路径。
      await tester.tap(find.byType(TextField).at(1));
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(submitted, <String>['alice|pw123456']);
    });
  });

  group('凭据回填（异步读盘后到达的初值）', () {
    testWidgets('⑪ 初值后到 ⇒ 两个输入框被回填', (WidgetTester tester) async {
      await useSurface(tester, narrowSurface);
      // ⚠️ 宿主本身必须**保持不变**：`host()` 每次都会新建 MaterialApp/Overlay ⇒ 整棵树被重建、
      // LoginPage 走 initState 而不是 didUpdateWidget（见 skill「换 MaterialApp.home 不重建子树」的反面）。
      // 这里用 StatefulBuilder 让 rebuild 只发生在 LoginPage 之上、宿主不动。
      late StateSetter drop;
      String user = '';
      String pass = '';
      await tester.pumpWidget(
        host(
          StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) {
              drop = setState;
              return LoginPage(initialUsername: user, initialPassword: pass);
            },
          ),
        ),
      );
      await tester.pump();
      expect(tester.widget<TextField>(find.byType(TextField).first).controller!.text, '');

      drop(() {
        user = 'alice';
        pass = 'pw';
      });
      await tester.pump();

      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        'alice',
      );
      expect(
        tester.widget<TextField>(find.byType(TextField).at(1)).controller!.text,
        'pw',
      );
    });

    testWidgets('⑫ 用户已输入 ⇒ 后到的初值不覆盖用户输入', (WidgetTester tester) async {
      await useSurface(tester, narrowSurface);
      late StateSetter drop;
      String user = '';
      String pass = '';
      await tester.pumpWidget(
        host(
          StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) {
              drop = setState;
              return LoginPage(initialUsername: user, initialPassword: pass);
            },
          ),
        ),
      );
      await tester.pump();

      await tester.enterText(find.byType(TextField).first, 'typed-by-user');
      await tester.enterText(find.byType(TextField).at(1), 'user-pw');
      await tester.pump();

      drop(() {
        user = 'alice';
        pass = 'pw';
      });
      await tester.pump();

      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        'typed-by-user',
      );
      expect(
        tester.widget<TextField>(find.byType(TextField).at(1)).controller!.text,
        'user-pw',
      );
    });
  });

  group('画布样张入口', () {
    testWidgets('aylaAuthOptionsSamples() 渲染五档（四静态 + 一可点 + 一禁用）', (WidgetTester tester) async {
      await useSurface(tester, const Size(1200, 1600));
      await tester.pumpWidget(host(aylaAuthOptionsSamples(), viewport: const Size(1200, 1600)));
      await tester.pump();

      expect(find.byType(AylaAuthOptions), findsNWidgets(5));
      expect(find.text('记住密码'), findsNWidgets(5));
      expect(find.text('自动登录'), findsNWidgets(5));
      // 档 ③（都勾）与 ①/②/⑤（自动登录未勾）并存 ⇒ 至少各有一个勾/未勾的复选框
      expect(find.byType(AylaCheckbox), findsNWidgets(10));
    });
  });
}
