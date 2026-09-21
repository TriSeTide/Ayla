/// A3：CreateSheet 定向测试 —— 逐条对照 `layout/CreateSheet.tsx` 1–61 与
/// `styles/private.css` 185–275。
///
/// 另含本轮同批修正的既存偏差回归：`ConfirmDialog.tsx:82–89` /
/// `PrivacySheet.tsx:188–190` 的关闭钮都是 `button.icon-btn-40` + `<IconClose />`，
/// Flutter 侧此前是手搓 40 盒 + Material `Icons.close`。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/app_icons.dart' show AylaIcon;
import '../lib/theme/buttons.dart' show AylaIconButton;
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart' show AylaColors, AylaFonts, AylaSpacing;
import '../lib/widgets/create_sheet.dart';
import '../lib/widgets/dialogs.dart'
    show AylaModalCard, AylaModalOverlay, AylaSheetHead, ConfirmDialog;
import '../lib/widgets/privacy_sheet.dart' show PrivacySheet;

/// 弹层内容（宽度撑满，模拟 web 里 width:100% 的表单）。
const Key kSheetBody = ValueKey<String>('create-sheet-body');

Widget sheetBody() => const SizedBox(
      key: kSheetBody,
      width: double.infinity,
      height: 120,
    );

void main() {
  Widget host(Widget child) => MaterialApp(home: previewScope(child));

  void setViewport(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  /// 宽屏无入场、窄屏有 250ms 上滑（`create-sheet-slide-in`）→ 统一推完。
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Widget sheet({String title = '发帖', VoidCallback? onClose, Widget? child}) {
    return AylaCreateSheet(
      title: title,
      onClose: onClose ?? () {},
      child: child ?? sheetBody(),
    );
  }

  // ==================== 结构 ====================

  group('AylaCreateSheet 结构（tsx 39–59）', () {
    testWidgets('head 标题 + 关闭钮 + children 直挂卡片（无额外容器）', (WidgetTester tester) async {
      setViewport(tester, const Size(1440, 900));
      await tester.pumpWidget(host(sheet()));
      await settle(tester);

      // `.create-sheet-head`（tsx:50）+ `.create-sheet-title`（tsx:51）
      expect(find.byType(AylaSheetHead), findsOneWidget);
      expect(find.byType(AylaModalCard), findsOneWidget);
      expect(find.byType(AylaModalOverlay), findsOneWidget);
      expect(find.text('发帖'), findsOneWidget);
      // tsx:56 `{children}` 直接跟在 head 之后
      expect(find.byKey(kSheetBody), findsOneWidget);
    });

    testWidgets('关闭钮 = AylaIconButton（.icon-btn-40）+ iconClose 20，不是 Material 图标', (
      WidgetTester tester,
    ) async {
      setViewport(tester, const Size(1440, 900));
      await tester.pumpWidget(host(sheet()));
      await settle(tester);

      final AylaSheetHead head =
          tester.widget<AylaSheetHead>(find.byType(AylaSheetHead));
      expect(head.title, '发帖');
      // `CreateSheet.tsx:53`：`<IconClose width={20} height={20} />`
      expect(head.closeIconSize, 20, reason: 'CreateSheet.tsx:53 = 20（ConfirmDialog 是 18）');
      expect(head.disabled, isFalse);

      final AylaIconButton close =
          tester.widget<AylaIconButton>(find.byType(AylaIconButton));
      expect(close.icon, isA<AylaIcon>());
      expect((close.icon as AylaIcon).icon.name, 'iconClose');
      expect((close.icon as AylaIcon).size, 20);
      // `.icon-btn-40`（home.css:121–134）= 40×40 pill
      expect(close.size, 40);
      expect(close.square, isFalse);
      expect(close.semanticLabel, '关闭'); // aria-label="关闭"
      // 扫光只给 `.narrow-topbar-more > .icon-btn-40` / `.top-nav-more > ...`
      // （auroraqua.css:142）→ 弹层头里的关闭钮无扫光
      expect(close.sweep, isFalse);
      // 防回退：web 用 lucide 同族 IconClose，不是 Material Icons.close
      expect(find.byIcon(Icons.close), findsNothing);
    });

    testWidgets('标题样式 .create-sheet-title = Fredoka 18/600/textPrimary；head 下间距 sp3', (
      WidgetTester tester,
    ) async {
      setViewport(tester, const Size(1440, 900));
      await tester.pumpWidget(host(sheet()));
      await settle(tester);

      final Text title = tester.widget<Text>(find.text('发帖'));
      expect(title.style?.fontFamily, AylaFonts.display); // --font-display
      expect(title.style?.fontSize, 18); // font-size: 18px
      expect(title.style?.fontWeight, FontWeight.w600); // font-weight: 600
      expect(title.style?.color, AylaColors.textPrimary); // --text-primary

      // `.create-sheet-head { margin-bottom: var(--sp-3) }`
      final Padding pad = tester.widget<Padding>(
        find
            .descendant(
              of: find.byType(AylaSheetHead),
              matching: find.byType(Padding),
            )
            .first,
      );
      expect(pad.padding, const EdgeInsets.only(bottom: AylaSpacing.sp3));
    });

    testWidgets('卡片材质 = AylaModalCard（strong 玻璃 + radius-panel + modal 阴影）', (
      WidgetTester tester,
    ) async {
      setViewport(tester, const Size(1440, 900));
      await tester.pumpWidget(host(sheet()));
      await settle(tester);

      final AylaModalCard card =
          tester.widget<AylaModalCard>(find.byType(AylaModalCard));
      expect(AylaModalCard.panelRadius, 20, reason: '--radius-panel');
      expect(AylaModalCard.maxWidth, 480, reason: 'width: min(480px, 100%)');
      // `.create-sheet-card { overflow-y: auto }`（整卡滚动，含 head）
      expect(card.scrollable, isTrue);
      // `.create-sheet-card { padding: var(--sp-4) }`
      expect(card.padding?.left, AylaSpacing.sp4);
      expect(card.padding?.top, AylaSpacing.sp4);
      expect(card.padding?.right, AylaSpacing.sp4);
    });
  });

  // ==================== 尺寸与两形态 ====================

  group('AylaCreateSheet 两形态（private.css 187–258）', () {
    testWidgets('宽屏：overlay padding sp4=16 + 卡片 480 居中', (WidgetTester tester) async {
      setViewport(tester, const Size(1440, 900));
      await tester.pumpWidget(host(sheet()));
      await settle(tester);

      final AylaModalOverlay overlay =
          tester.widget<AylaModalOverlay>(find.byType(AylaModalOverlay));
      // ⚠️ 必须显式传 16：AylaModalOverlay 默认 24 是 privacy 那一档
      expect(overlay.padding, AylaSpacing.sp4);

      final Rect card = tester.getRect(find.byType(AylaModalCard));
      expect(card.width, 480);
      expect(card.center.dx, closeTo(720, 0.5), reason: 'justify-content: center');
    });

    testWidgets('窄屏：卡片 100% 宽、贴底、top radius 24、padding-bottom = sp4 + safe-area', (
      WidgetTester tester,
    ) async {
      setViewport(tester, const Size(375, 812));
      tester.view.padding = const FakeViewPadding(bottom: 34);
      await tester.pumpWidget(host(sheet()));
      await settle(tester);

      final Rect card = tester.getRect(find.byType(AylaModalCard));
      expect(card.width, 375, reason: '窄屏 width: 100%');
      expect(card.bottom, 812, reason: 'overlay align-items:flex-end + padding 0');

      final AylaModalCard w =
          tester.widget<AylaModalCard>(find.byType(AylaModalCard));
      expect(w.narrowRadius, 24, reason: '窄屏 radius 24px 24px 0 0');

      // `padding-bottom: calc(var(--sp-4) + env(safe-area-inset-bottom))`
      final double gap =
          card.bottom - tester.getRect(find.byKey(kSheetBody)).bottom;
      expect(gap, AylaSpacing.sp4 + 34);
    });

    testWidgets('className 等价档：narrowHeightFactor / scrollable 透传到 AylaModalCard', (
      WidgetTester tester,
    ) async {
      setViewport(tester, const Size(375, 812));
      await tester.pumpWidget(host(
        AylaCreateSheet(
          title: '群内开播',
          onClose: () {},
          narrowHeightFactor: 0.6,
          scrollable: false,
          child: sheetBody(),
        ),
      ));
      await settle(tester);

      final AylaModalCard card =
          tester.widget<AylaModalCard>(find.byType(AylaModalCard));
      expect(card.narrowHeightFactor, 0.6);
      expect(card.scrollable, isFalse);
      expect(tester.getRect(find.byType(AylaModalCard)).height, closeTo(812 * 0.6, 0.5));
    });
  });

  // ==================== 关闭语义 ====================

  group('AylaCreateSheet 关闭路径（tsx 30–36 / 41–43 / 52）', () {
    testWidgets('ESC → onClose（一次）', (WidgetTester tester) async {
      setViewport(tester, const Size(1440, 900));
      int closed = 0;
      await tester.pumpWidget(host(sheet(onClose: () => closed++)));
      await settle(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(closed, 1);
    });

    testWidgets('点遮罩 → onClose；点卡内不关（e.target === e.currentTarget）', (
      WidgetTester tester,
    ) async {
      setViewport(tester, const Size(1440, 900));
      int closed = 0;
      await tester.pumpWidget(host(sheet(onClose: () => closed++)));
      await settle(tester);

      // 卡内（标题行）
      await tester.tapAt(tester.getCenter(find.byType(AylaModalCard)));
      await tester.pump();
      expect(closed, 0, reason: 'tsx:41–43 只在点遮罩本体时关闭');

      // 遮罩（宽屏卡片居中，左上角必在卡外）
      await tester.tapAt(const Offset(20, 20));
      await tester.pump();
      expect(closed, 1);
    });

    testWidgets('关闭钮 → onClose', (WidgetTester tester) async {
      setViewport(tester, const Size(1440, 900));
      int closed = 0;
      await tester.pumpWidget(host(sheet(onClose: () => closed++)));
      await settle(tester);

      await tester.tap(find.byType(AylaIconButton));
      await tester.pump();
      expect(closed, 1);
    });

    testWidgets('route 语义：scopesRoute + label = title（tsx:47–48 aria-label）', (
      WidgetTester tester,
    ) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      setViewport(tester, const Size(1440, 900));
      await tester.pumpWidget(host(sheet()));
      await settle(tester);

      expect(find.bySemanticsLabel('发帖'), findsWidgets);
      handle.dispose();
    });
  });

  // ==================== 同批既存偏差回归 ====================

  group('同批修正：ConfirmDialog / PrivacySheet 的关闭钮（web = icon-btn-40 + IconClose）', () {
    testWidgets('ConfirmDialog 关闭钮 = AylaIconButton/iconClose 18；busy 时禁用', (
      WidgetTester tester,
    ) async {
      setViewport(tester, const Size(1440, 900));
      int closed = 0;
      await tester.pumpWidget(host(ConfirmDialog(
        title: '删除会话',
        message: '删除会话「小樱」？',
        onConfirm: () {},
        onClose: () => closed++,
      )));
      await tester.pump();

      expect(find.byType(AylaSheetHead), findsOneWidget);
      final AylaSheetHead head =
          tester.widget<AylaSheetHead>(find.byType(AylaSheetHead));
      expect(head.closeIconSize, 18, reason: 'ConfirmDialog.tsx:85 = 18');
      expect(head.disabled, isFalse);

      final AylaIconButton close =
          tester.widget<AylaIconButton>(find.byType(AylaIconButton));
      expect((close.icon as AylaIcon).icon.name, 'iconClose');
      expect((close.icon as AylaIcon).size, 18);
      expect(find.byIcon(Icons.close), findsNothing);

      await tester.tap(find.byType(AylaIconButton));
      await tester.pump();
      expect(closed, 1);
    });

    testWidgets('ConfirmDialog busy → 关闭钮禁用（disabled={busy}）', (WidgetTester tester) async {
      setViewport(tester, const Size(1440, 900));
      int closed = 0;
      await tester.pumpWidget(host(ConfirmDialog(
        title: 'T',
        message: 'M',
        busy: true,
        onConfirm: () {},
        onClose: () => closed++,
      )));
      await tester.pump();

      expect(
        tester.widget<AylaSheetHead>(find.byType(AylaSheetHead)).disabled,
        isTrue,
      );
      expect(
        tester.widget<AylaIconButton>(find.byType(AylaIconButton)).onPressed,
        isNull,
      );
      await tester.tap(find.byType(AylaIconButton));
      await tester.pump();
      expect(closed, 0);
    });

    testWidgets('PrivacySheet 关闭钮 = AylaIconButton/iconClose 18', (WidgetTester tester) async {
      setViewport(tester, const Size(1440, 900));
      int closed = 0;
      await tester.pumpWidget(host(PrivacySheet(onClose: () => closed++)));
      await tester.pump();

      final AylaIconButton close =
          tester.widget<AylaIconButton>(find.byType(AylaIconButton));
      expect((close.icon as AylaIcon).icon.name, 'iconClose');
      expect((close.icon as AylaIcon).size, 18, reason: 'PrivacySheet.tsx:189 = 18');
      expect(close.semanticLabel, '关闭');
      expect(find.byIcon(Icons.close), findsNothing);

      await tester.tap(find.byType(AylaIconButton));
      await tester.pump();
      expect(closed, 1);
    });
  });
}
