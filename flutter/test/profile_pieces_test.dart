/// 个人主页域三件定向测试 —— 逐条对照 `ProfilePage.tsx:154–180` / `FavoritesPage.tsx:268–271` +
/// `app.css 241–248/2657–2695` + `profile.css 14–16/44–52/142–171/584–591/623–625/452–456`。
///
/// 覆盖：资料卡两档 padding/gap · identity 的结构（返回 40 / 头像 64 / `@用户名` / 分享槽位）与窄宽不溢出 ·
/// avatar-actions 的左内距 48 与等宽按钮 + hint/error 两行 · 收藏骨架两条 64 高 + 语义 label。
/// ⚠️ 纪律：一态一用例（同一用例二次 `pumpWidget` 换 props 不生效，库内既有结论）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/buttons.dart';
import '../lib/theme/glass.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/base/avatar_halo.dart';
import '../lib/widgets/base/loading.dart';
import '../lib/widgets/profile/favorites_skeleton.dart';
import '../lib/widgets/profile/profile_card.dart';

void main() {
  Widget host(Widget child, {double width = 420}) => MaterialApp(
    home: previewScope(
      Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: width, child: child),
      ),
    ),
  );

  Widget ghostButton(String label) => AylaGlassButton(
    label: label,
    variant: AylaGlassButtonVariant.ghost,
    fontSize: 12,
    minHeight: 28,
    padding: const EdgeInsets.symmetric(
      horizontal: AylaSpacing.sp2,
      vertical: AylaSpacing.sp1,
    ),
    onPressed: () {},
  );

  group('AylaProfileCard（.solid-card .profile-card，app.css 2657 / profile.css 48）', () {
    testWidgets('宽档：padding sp8 / gap sp6，且容器走玻璃卡', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          const AylaProfileCard(children: <Widget>[Text('a'), Text('b')]),
        ),
      );
      final AylaGlassCard card = tester.widget<AylaGlassCard>(
        find.byType(AylaGlassCard),
      );
      expect(card.padding, const EdgeInsets.all(AylaSpacing.sp8));
      final Column col = tester.widget<Column>(
        find.descendant(
          of: find.byType(AylaGlassCard),
          matching: find.byType(Column),
        ),
      );
      expect(col.spacing, AylaSpacing.sp6);
    });

    testWidgets('紧凑档（≥769 双栏）：padding sp4 / gap sp4', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          const AylaProfileCard(
            compact: true,
            children: <Widget>[Text('a'), Text('b')],
          ),
        ),
      );
      final AylaGlassCard card = tester.widget<AylaGlassCard>(
        find.byType(AylaGlassCard),
      );
      expect(card.padding, const EdgeInsets.all(AylaSpacing.sp4));
      final Column col = tester.widget<Column>(
        find.descendant(
          of: find.byType(AylaGlassCard),
          matching: find.byType(Column),
        ),
      );
      expect(col.spacing, AylaSpacing.sp4);
    });
  });

  group('AylaProfileIdentity（ProfilePage.tsx 154–177）', () {
    testWidgets('结构：返回 40 + 头像 64 + 昵称 + `@用户名` + 分享槽位', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          AylaProfileIdentity(
            displayName: '爱莉',
            username: 'elysia',
            online: true,
            onBack: () {},
            share: const SizedBox(key: ValueKey<String>('share'), width: 40),
          ),
        ),
      );
      expect(find.text('爱莉'), findsOneWidget);
      expect(find.text('@elysia'), findsOneWidget);
      expect(tester.widget<AylaAvatarHalo>(find.byType(AylaAvatarHalo)).size, 64);
      expect(tester.getSize(find.byType(AylaIconButton)).width, 40); // icon-btn-40
      expect(find.byKey(const ValueKey<String>('share')), findsOneWidget);
    });

    testWidgets('无 onBack ⇒ 不渲染返回键（UserProfilePage 的窄档）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(const AylaProfileIdentity(displayName: '小樱', username: 'sakura')),
      );
      expect(find.byType(AylaIconButton), findsNothing);
      expect(find.text('@sakura'), findsOneWidget);
    });

    testWidgets('窄宿主不溢出（昵称/用户名收缩为省略号）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          AylaProfileIdentity(
            displayName: '一个特别特别长的昵称用来撑爆这一行',
            username: 'a_very_long_username_here',
            onBack: () {},
            share: const SizedBox(width: 40),
          ),
          width: 300,
        ),
      );
      expect(tester.takeException(), isNull); // 无 RenderFlex overflow
    });
  });

  group('AylaProfileAvatarActions（profile.css 150–171 / 584–591）', () {
    testWidgets('左内距 48（40 + sp4）+ 三键等宽', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          AylaProfileAvatarActions(
            actions: <Widget>[
              ghostButton('更换头像'),
              ghostButton('收藏'),
              ghostButton('隐私设置'),
            ],
          ),
        ),
      );
      final Rect first = tester.getRect(find.text('更换头像'));
      // 左内距 = 40 + sp4 ⇒ 按钮文字左缘 ≥ 48
      expect(first.left, greaterThanOrEqualTo(AylaProfileAvatarActions.indent));
      final double w0 = tester.getSize(find.byType(AylaGlassButton).at(0)).width;
      final double w1 = tester.getSize(find.byType(AylaGlassButton).at(1)).width;
      final double w2 = tester.getSize(find.byType(AylaGlassButton).at(2)).width;
      expect(w1, closeTo(w0, 0.5));
      expect(w2, closeTo(w0, 0.5));
    });

    testWidgets('hint 与 error 两行（error 走 destructive）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          AylaProfileAvatarActions(
            actions: <Widget>[ghostButton('更换头像')],
            hint: '新头像将在保存后生效',
            error: '图片过大',
          ),
        ),
      );
      expect(find.text('新头像将在保存后生效'), findsOneWidget); // web 原文（仅选定新图时显示）
      expect(find.text('图片过大'), findsOneWidget);
      final Text err = tester.widget<Text>(find.text('图片过大'));
      expect(err.style!.color, AylaColors.destructive);
    });

    testWidgets('无 actions ⇒ 只有提示行，不渲染按钮行', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(const AylaProfileAvatarActions(actions: <Widget>[], hint: '仅提示')),
      );
      expect(find.byType(AylaGlassButton), findsNothing);
      expect(find.text('仅提示'), findsOneWidget);
    });
  });

  group('AylaFavoritesSkeleton（FavoritesPage.tsx 268–271 / profile.css 452–456）', () {
    testWidgets('两条骨架条：高 64、首条下方留 8；语义 label = 正在加载收藏', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(host(const AylaFavoritesSkeleton()));
      final Finder bars = find.byType(AylaSkeleton);
      expect(bars, findsNWidgets(2));
      expect(tester.getSize(bars.at(0)).height, 64);
      expect(tester.getSize(bars.at(1)).height, 64);
      final Rect b0 = tester.getRect(bars.at(0));
      final Rect b1 = tester.getRect(bars.at(1));
      expect(b1.top - b0.bottom, AylaFavoritesSkeleton.barGap);

      final Semantics sem = tester.widget<Semantics>(
        find.descendant(
          of: find.byType(AylaFavoritesSkeleton),
          matching: find.byType(Semantics),
        ),
      );
      expect(sem.properties.label, '正在加载收藏');
      expect(sem.properties.liveRegion, isTrue); // 等价 role=status
    });
  });
}
