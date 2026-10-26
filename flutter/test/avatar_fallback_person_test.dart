/// 无名头像 = 人形图标（不是「?」）回归锁（2026-10-26 用户裁决）。
///
/// 用户要求：群成员退出后**不要显示问号头像**，要正常显示普通头像，
/// 且**在线光环照常**。
///
/// 实现：无名字时头像本体渲染 `Icons.person`（正常默认头像观感），
/// 光环由 `_computeOnline` 独立决定，与有没有名字**无关**。
///
/// 注：这是**有意偏离 web** 的一处（web `Avatar.tsx:37` 是 `label?.trim() || "?"`）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/user_public.dart' show AylaUserPublic;
import '../lib/state/presence_providers.dart' show presenceStateProvider;
import '../lib/widgets/base/avatar_halo.dart';

void main() {
  testWidgets('★ 无名 + 无图 ⇒ 人形图标，不出现「?」', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: AylaAvatarHalo(label: '', size: 40)),
      ),
    );
    await tester.pump();
    expect(find.byIcon(Icons.person), findsOneWidget,
        reason: '无名时必须是正常默认头像（人形）');
    expect(find.text('?'), findsNothing, reason: '★ 用户明确要求不要问号头像');
  });

  testWidgets('★ 有名字 ⇒ 仍取首字（不回归）', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: AylaAvatarHalo(label: '小樱', size: 40)),
      ),
    );
    await tester.pump();
    expect(find.text('小'), findsOneWidget);
    expect(find.byIcon(Icons.person), findsNothing);
  });

  testWidgets('★ 无名时在线光环**照常**显示（用户要求）', (WidgetTester tester) async {
    final ProviderContainer c = ProviderContainer();
    addTearDown(c.dispose);
    // 无名但知道 userId，且 presence 说他在线
    c.read(presenceStateProvider).setUser('u9', 'online');
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(
          home: Scaffold(body: AylaAvatarHalo(label: '', size: 40, userId: 'u9')),
        ),
      ),
    );
    await tester.pump();
    expect(find.byIcon(Icons.person), findsOneWidget);
    // 光环在线：语义标签为「在线」（avatar_halo 的双通道之一）
    bool online = false;
    for (final Semantics s in tester.widgetList<Semantics>(find.byType(Semantics))) {
      final String? l = s.properties.label;
      if (l != null && l.contains('在线') && !l.contains('离线')) online = true;
    }
    expect(online, isTrue, reason: '★ 无名不影响在线光环');
  });
}
