/// 头像 presence 实时订阅回归锁（2026-10-20）。
///
/// ## 为什么必须有这条锁
/// 普查 D（`docs/flutter/30-普查-头像在线状态.md` §8.2）实测并当场推翻了
/// 一版**看起来正确、实际零效果**的实现：用
/// `ProviderScope.containerOf(context, listen: true).read(presenceStateProvider)`
/// 求值。那条路径：
/// - `container.read()` **不建立 provider 监听**（riverpod `container.dart:238–242`）；
/// - `containerOf` 只依赖 `UncontrolledProviderScope` 这个 InheritedWidget，
///   其 `updateShouldNotify` 是 `container != oldWidget.container`
///   （`framework.dart:287–289`），而 container 是长生命周期单例
///   ⇒ **永不重建** ⇒ 参数传了、光环照旧冻。
///
/// 这正是「遗漏能长期存在」的根因：**没有任何测试断言「presence 帧到达后
/// 头像光环真的变了」**。本文件补上这条断言。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/user_public.dart' show AylaUserPublic;
import '../lib/state/presence_providers.dart' show presenceStateProvider;
import '../lib/widgets/base/avatar_halo.dart';

const AylaUserPublic _user = AylaUserPublic(
  id: 'u2',
  username: 'xixi',
  nickname: '汐汐',
  online: false,
);

/// 从渲染出的光环上读出「是否在线」。
///
/// 实现口径：在线时环使用 **online 渐变**（4 色 sweep，含 glow500/sakura300），
/// 离线时是 **ice100 单色**。这里直接比对 `AylaAvatarHalo` 的语义状态 ——
/// 通过 `Tooltip`/语义标签更稳定：组件内部 stateLabel = 在线/离线。
bool _haloOnline(WidgetTester tester) {
  final Iterable<Semantics> semantics =
      tester.widgetList<Semantics>(find.byType(Semantics));
  for (final Semantics s in semantics) {
    final String? label = s.properties.label;
    if (label == null) continue;
    if (label.contains('在线') && !label.contains('离线')) return true;
  }
  return false;
}

void main() {
  testWidgets('presence 帧到达 ⇒ 头像在线态**真的**变（不是只传参）', (
    WidgetTester tester,
  ) async {
    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: AylaAvatarHalo(
              label: '汐汐',
              size: 40,
              user: _user,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(
      _haloOnline(tester),
      isFalse,
      reason: '前置：REST 快照 online=false 且 store 无记录 ⇒ 离线',
    );

    // ★ 模拟 presence.update 帧到达（WS 层写的就是这个 store）。
    container.read(presenceStateProvider).setUser('u2', 'online');
    await tester.pump();

    expect(
      _haloOnline(tester),
      isTrue,
      reason: '★ presence 帧到达后头像必须**真的**变在线 —— '
          '这条断言正是过去缺失的那条（用 containerOf().read() 的写法会在这里红）',
    );

    // 再模拟离线帧
    container.read(presenceStateProvider).setUser('u2', 'offline');
    await tester.pump();
    expect(_haloOnline(tester), isFalse, reason: '离线帧同理');
  });

  testWidgets('userId 形态同样生效（无完整用户对象时）', (
    WidgetTester tester,
  ) async {
    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: AylaAvatarHalo(label: '汐汐', size: 40, userId: 'u2'),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(_haloOnline(tester), isFalse);

    container.read(presenceStateProvider).setUser('u2', 'online');
    await tester.pump();
    expect(_haloOnline(tester), isTrue, reason: 'userId 形态也必须真订阅');
  });

  testWidgets('无 ProviderScope 时不得崩（画布/纯 widget 测试）', (
    WidgetTester tester,
  ) async {
    // 挂一个**不带** ProviderScope 的头像：必须安全降级为静态 online。
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AylaAvatarHalo(label: '汐汐', size: 40, online: true),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull, reason: '无 scope 必须降级而不是抛异常');
  });
}
