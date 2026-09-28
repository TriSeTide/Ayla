/// `AylaProfilePresence`（`.profile-presence`，`profile.css:558–570`）回归。
///
/// 2026-09-28 由 `user_profile_page.dart` 的私有 `_PresenceChip` 提升为公共件。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/profile/profile_presence.dart';

void main() {
  Widget host(Widget child) => MaterialApp(home: previewScope(Center(child: child)));

  testWidgets('静息档：padding 2×sp3 + pill + ice-100 底 / secondary 字（12/w600）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(const AylaProfilePresence(label: '离线')));
    await tester.pump();

    final Container box = tester.widget<Container>(find.byType(Container));
    expect(
      box.padding,
      const EdgeInsets.symmetric(horizontal: AylaSpacing.sp3, vertical: 2),
    );
    final BoxDecoration deco = box.decoration! as BoxDecoration;
    expect(deco.color, AylaColors.ice100);
    expect(deco.borderRadius, AylaRadii.pill);

    final Text text = tester.widget<Text>(find.text('离线'));
    expect(text.style!.fontSize, 12);
    expect(text.style!.fontWeight, FontWeight.w600);
    expect(text.style!.color, AylaColors.textSecondary);
  });

  testWidgets('在线档（.is-online）：sakura-300 底 + grape-700 字', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(const AylaProfilePresence(label: '在线', online: true)),
    );
    await tester.pump();

    final Container box = tester.widget<Container>(find.byType(Container));
    expect((box.decoration! as BoxDecoration).color, AylaColors.sakura300);
    expect(
      tester.widget<Text>(find.text('在线')).style!.color,
      AylaColors.grape700,
    );
  });

  testWidgets('文案完全由调用方注入（本件不造默认值）', (WidgetTester tester) async {
    await tester.pumpWidget(host(const AylaProfilePresence(label: '勿扰')));
    await tester.pump();
    expect(find.text('勿扰'), findsOneWidget);
    // 未传文案的调用点会直接编译不过（required），此处锁「不出现任何内置文案」
    for (final String builtin in <String>['在线', '离线', '离开']) {
      expect(find.text(builtin), findsNothing, reason: builtin);
    }
  });
}