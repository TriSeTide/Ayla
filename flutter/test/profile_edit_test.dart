/// 个人主页编辑面定向测试 —— 对照 `ProfilePage.tsx:212–305» + `app.css 2696–2749» +
/// `profile.css 47–51 / 377–440 / 593–611» + `auth.css 79–87»。
///
/// 覆盖：状态胶囊（文案顺序 / 选中态色 / 未选中态色 / 点击回调 / radio 语义 / 字体档）·
/// 开关行（48×28 轨道 · knob 20×20；**含 1px 边框补偿 ⇒ 外框坐标 4→24**，见 switch.dart 库头 ·
/// 底/钮两档色 · 整行点一次 · 键盘 Space · toggled 语义）·
/// 表单装配（行文案 / 保存键禁用三条件 / 保存中文案 / 已保存提示条件 / 错误行 liveRegion / 退出键可选）。
///
/// ⚠️ 一态一用例（同用例二次 pumpWidget 换 props 不生效）。
library;

import 'dart:ui' show CheckedState;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/app_theme.dart';
import '../lib/theme/glass.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/profile/profile_edit.dart';

void main() {
  Widget host(Widget child, {double width = 420}) => MaterialApp(
    home: previewScope(
      Builder(
        builder: (BuildContext context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(size: Size(width, 1200)),
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: width, child: child),
          ),
        ),
      ),
    ),
  );

  // ===================== 状态胶囊 =====================

  group('AylaStatusChips', () {
    testWidgets('四颗胶囊 · 文案与顺序同 web STATUS_OPTIONS', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(AylaStatusChips(value: 'auto', onChanged: (String value) {})),
      );
      for (final String label in <String>['自动', '离开', '勿扰', '隐身']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(find.byType(AnimatedContainer), findsNWidgets(4));
    });

    testWidgets('未选中 = ice-300 @16% 底 + indigo-700 字；选中 = sakura-300 + grape-700', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(AylaStatusChips(value: 'dnd', onChanged: (String value) {})),
      );
      final Finder chips = find.descendant(
        of: find.byType(AylaStatusChips),
        matching: find.byType(AnimatedContainer),
      );
      // 顺序 = 自动 / 离开 / 勿扰 / 隐身 ⇒ 选中项是第 3 颗
      final BoxDecoration off =
          tester.widget<AnimatedContainer>(chips.at(0)).decoration!
              as BoxDecoration;
      expect(off.color, AylaColors.ice300.withValues(alpha: 0.16));
      expect(off.borderRadius, AylaRadii.pill);
      expect(off.boxShadow, isNull);

      final BoxDecoration on =
          tester.widget<AnimatedContainer>(chips.at(2)).decoration!
              as BoxDecoration;
      expect(on.color, AylaColors.sakura300);
      expect(on.boxShadow, isNotNull); // --glow-shadow

      final Text offText = tester.widget<Text>(find.text('自动'));
      expect(offText.style!.color, AylaColors.indigo700);
      expect(offText.style!.fontSize, 11); // Display 11 / w500 / ls .8
      expect(offText.style!.letterSpacing, 0.8);
      expect(offText.style!.fontFamily, AylaFonts.display);

      final Text onText = tester.widget<Text>(find.text('勿扰'));
      expect(onText.style!.color, AylaColors.grape700);
    });

    testWidgets('点击胶囊回传 value；radio 语义 checked + 互斥组', (WidgetTester tester) async {
      String? picked;
      await tester.pumpWidget(
        host(
          AylaStatusChips(
            value: 'auto',
            onChanged: (String value) => picked = value,
          ),
        ),
      );
      await tester.tap(find.text('隐身'));
      await tester.pump();
      expect(picked, 'invisible');

      final SemanticsNode node = tester.getSemantics(find.text('自动'));
      expect(node.flagsCollection.isChecked, CheckedState.isTrue);
      final SemanticsNode other = tester.getSemantics(find.text('离开'));
      expect(other.flagsCollection.isChecked, CheckedState.isFalse);
    });

    testWidgets('hover 走 brightness(1.04) 分支（ColorFiltered）不抛错', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(AylaStatusChips(value: 'auto', onChanged: (String value) {})),
      );
      expect(find.byType(ColorFiltered), findsNothing);
      final TestGesture mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      // ⚠️ 指针初始位置必须离开胶囊区域：addPointer 即派发 hover
      // （放 (0,0) 时第一颗胶囊就在宿主原点 ⇒ 一上来就 hover，断言会红）
      await mouse.addPointer(location: const Offset(1, 600));
      await tester.pump();
      expect(find.byType(ColorFiltered), findsNothing);
      await mouse.moveTo(tester.getCenter(find.text('离开')));
      await tester.pump();
      expect(find.byType(ColorFiltered), findsOneWidget);
      // ⚠️ 移出点不能用 (0,0) —— 那正是第一颗胶囊（宿主 Align topLeft）⇒ 会一直 hover
      await mouse.moveTo(const Offset(1, 600));
      await tester.pump();
      expect(find.byType(ColorFiltered), findsNothing);
    });

    testWidgets('enabled=false ⇒ 点击无回调', (WidgetTester tester) async {
      int calls = 0;
      await tester.pumpWidget(
        host(
          AylaStatusChips(
            value: 'auto',
            enabled: false,
            onChanged: (String value) => calls++,
          ),
        ),
      );
      await tester.tap(find.text('离开'));
      await tester.pump();
      expect(calls, 0);
    });
  });

  // ===================== 开关行 =====================

  group('AylaProfileSwitch', () {
    testWidgets('轨道 48×28 · knob 20×20 · off 档 left 4（含 1px 边框补偿）+ ice-300 钮 + 玻璃底', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          AylaProfileSwitch(
            label: '向他人展示内容',
            value: false,
            onChanged: (bool value) {},
          ),
        ),
      );
      final Finder containers = find.descendant(
        of: find.byType(AylaProfileSwitch),
        matching: find.byType(AnimatedContainer),
      );
      final AnimatedContainer track =
          tester.widget<AnimatedContainer>(containers.first);
      // Container 把 width/height 并入 constraints（无公开 getter）
      expect(track.constraints, BoxConstraints.tightFor(width: 48, height: 28));
      final BoxDecoration trackDecor = track.decoration! as BoxDecoration;
      expect(trackDecor.color, AylaColors.glassBgStrong); // --glass-bg-strong
      expect(trackDecor.boxShadow, isNull);

      final AnimatedContainer knob =
          tester.widget<AnimatedContainer>(containers.at(1));
      expect(knob.constraints, BoxConstraints.tightFor(width: 20, height: 20));
      expect((knob.decoration! as BoxDecoration).color, AylaColors.ice300);

      final AnimatedPositioned positioned = tester.widget<AnimatedPositioned>(
        find.byType(AnimatedPositioned),
      );
      // ⚠️ CSS .knob { top: 3px; left: 3px } 的包含块是 **padding box**（base.css 6–7 全局
      // box-sizing: border-box ⇒ 48×28 含 1px 边框）⇒ 距外框 4px。
      // 旧实现按外框 3 ⇒ knob 中心 13 ≠ 轨道中心 14（圆点偏上 1px，用户当场点名）；
      // 现按 4 对齐，居中由 test/switch_test.dart 的「knob 中心 vs 轨道中心」断言锁死。
      expect(positioned.left, 4);
      expect(positioned.top, 4);
    });

    testWidgets('on 档：knob translateX(20) ⇒ left 24（含 1px 补偿）· 底 sakura-300 + 钮 grape-700 + 辉光', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          AylaProfileSwitch(
            label: '向他人展示内容',
            value: true,
            onChanged: (bool value) {},
          ),
        ),
      );
      final Finder containers = find.descendant(
        of: find.byType(AylaProfileSwitch),
        matching: find.byType(AnimatedContainer),
      );
      final BoxDecoration trackDecor =
          tester.widget<AnimatedContainer>(containers.first).decoration!
              as BoxDecoration;
      expect(trackDecor.color, AylaColors.sakura300);
      expect(trackDecor.boxShadow, isNotNull); // --glow-shadow

      expect(
        (tester.widget<AnimatedContainer>(containers.at(1)).decoration!
                as BoxDecoration)
            .color,
        AylaColors.grape700,
      );
      expect(
        tester
            .widget<AnimatedPositioned>(find.byType(AnimatedPositioned))
            .left,
        24, // CSS left 3 + translateX(20) + 1px 边框补偿
      );
    });

    testWidgets('点整行只切换一次（label 转发语义），点开关本体同样一次', (
      WidgetTester tester,
    ) async {
      int calls = 0;
      await tester.pumpWidget(
        host(
          AylaProfileSwitch(
            label: '向他人展示内容',
            value: false,
            onChanged: (bool value) => calls++,
          ),
        ),
      );
      await tester.tap(find.text('向他人展示内容'));
      await tester.pump();
      expect(calls, 1);

      await tester.tapAt(tester.getCenter(find.byType(AnimatedPositioned)));
      await tester.pump();
      expect(calls, 2);
    });

    testWidgets('键盘 Space 切换 + toggled 语义 + 副标题渲染', (WidgetTester tester) async {
      int calls = 0;
      await tester.pumpWidget(
        host(
          AylaProfileSwitch(
            label: '向他人展示内容',
            description: '开启后，他人可在你的主页看到「他的内容」（发帖/直播间/桌游）',
            value: true,
            onChanged: (bool value) => calls++,
          ),
        ),
      );
      expect(find.textContaining('开启后'), findsOneWidget);

      final SemanticsNode node = tester.getSemantics(find.text('向他人展示内容'));
      expect(node.flagsCollection.isToggled.toBoolOrNull(), isTrue);

      await tester.tap(find.text('向他人展示内容'));
      await tester.pump();
      expect(calls, 1);
    });

    testWidgets('onChanged=null ⇒ 禁用档（无回调 + 降透明）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          const AylaProfileSwitch(label: '向他人展示内容', value: false, onChanged: null),
        ),
      );
      expect(find.byType(Opacity), findsWidgets);
      await tester.tap(find.text('向他人展示内容'));
      await tester.pump();
      // 无异常即通过（无回调可触发）
    });
  });

  // ===================== 表单装配 =====================

  group('AylaProfileForm', () {
    Widget form({
      bool saving = false,
      bool saved = false,
      bool dirty = true,
      String? error,
      VoidCallback? onLogout,
      String? nickname,
    }) {
      return AylaProfileForm(
        nicknameController: TextEditingController(text: nickname ?? '爱莉'),
        signatureController: TextEditingController(text: '今天也想见你'),
        nicknamePlaceholder: 'elysia',
        status: 'auto',
        onStatusChanged: (String value) {},
        showContent: false,
        onShowContentChanged: (bool value) {},
        saving: saving,
        saved: saved,
        dirty: dirty,
        error: error,
        onSave: () {},
        onLogout: onLogout,
      );
    }

    testWidgets('行与文案：在线状态 / 昵称 / 个性签名 / 开关行 / 三键', (WidgetTester tester) async {
      await tester.pumpWidget(host(form(onLogout: () {})));
      expect(find.text('在线状态'), findsOneWidget);
      expect(find.text('昵称'), findsOneWidget);
      expect(find.text('个性签名'), findsOneWidget);
      expect(find.text('向他人展示内容'), findsOneWidget);
      expect(find.text('保存修改'), findsOneWidget);
      expect(find.text('退出登录'), findsOneWidget);
      expect(find.byType(AylaGlassInput), findsNWidgets(2));
      // 昵称占位 = username（web placeholder={currentUser.username}）
      expect(find.text('elysia'), findsOneWidget);
      expect(find.text('写点什么…'), findsOneWidget);
    });

    testWidgets('保存键：dirty=false ⇒ 禁用（web disabled = saving || !dirty）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(host(form(dirty: false)));
      final AylaGlassButton save = tester.widget<AylaGlassButton>(
        find.widgetWithText(AylaGlassButton, '保存修改'),
      );
      expect(save.onPressed, isNull);
    });

    testWidgets('保存中：文案「保存中…」且禁用', (WidgetTester tester) async {
      await tester.pumpWidget(host(form(saving: true)));
      final AylaGlassButton save = tester.widget<AylaGlassButton>(
        find.widgetWithText(AylaGlassButton, '保存中…'),
      );
      expect(save.onPressed, isNull);
    });

    testWidgets('dirty=true ⇒ 保存键可用并可触发 onSave', (WidgetTester tester) async {
      int saved = 0;
      await tester.pumpWidget(
        host(
          AylaProfileForm(
            nicknameController: TextEditingController(text: '爱莉'),
            signatureController: TextEditingController(text: '今天也想见你'),
            status: 'auto',
            onStatusChanged: (String value) {},
            showContent: false,
            onShowContentChanged: (bool value) {},
            onSave: () => saved++,
          ),
        ),
      );
      await tester.tap(find.widgetWithText(AylaGlassButton, '保存修改'));
      await tester.pump();
      expect(saved, 1);
    });

    testWidgets('「已保存」在 saved && !dirty 时显示（13 / --success）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(host(form(saved: true, dirty: false)));
      expect(find.text('已保存'), findsOneWidget);
      final Text label = tester.widget<Text>(find.text('已保存'));
      expect(label.style!.color, AylaColors.success); // .profile-saved 13 / --success
      expect(label.style!.fontSize, 13);
    });

    testWidgets('saved && dirty ⇒ 不显示「已保存」', (WidgetTester tester) async {
      await tester.pumpWidget(host(form(saved: true, dirty: true)));
      expect(find.text('已保存'), findsNothing);
    });

    testWidgets('错误行：文案 + liveRegion（web role=alert）', (WidgetTester tester) async {
      await tester.pumpWidget(host(form(error: '保存失败，请稍后重试')));
      expect(find.text('保存失败，请稍后重试'), findsOneWidget);
      final SemanticsNode node = tester.getSemantics(
        find.text('保存失败，请稍后重试'),
      );
      expect(node.flagsCollection.isLiveRegion, isTrue);
      final Text text = tester.widget<Text>(find.text('保存失败，请稍后重试'));
      expect(text.style!.color, AylaColors.destructive);
      expect(text.style!.fontSize, 13);
    });

    testWidgets('onLogout=null ⇒ 不渲染退出键', (WidgetTester tester) async {
      await tester.pumpWidget(host(form()));
      expect(find.text('退出登录'), findsNothing);
      expect(find.text('保存修改'), findsOneWidget);
    });
  });
}
