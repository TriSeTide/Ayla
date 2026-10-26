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
///
/// ## 2026-10-26 扩展：资料（头像图 / 昵称）热更新锁
/// 用户第三次实报「换头像不热更新」。当时 `user.updated` 帧 → `presence_ws` →
/// `AylaPresenceState.applyUserProfile` 全都通了，**但全仓零处读 `profileOf()`**
/// ⇒ 头像图片始终是构造参数 `resourceUrl` 的那一份（永不更新）。
/// 现由 `AylaAvatarHalo` 在给了身份（`user` / `userId`）时读覆盖层，
/// 本文件新增断言锁住「**帧到达后渲染出的图 URL 真的换**」。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/user_public.dart' show AylaUserPublic;
import '../lib/state/presence_providers.dart' show presenceStateProvider;
import '../lib/widgets/base/avatar_halo.dart';
import '../lib/widgets/base/resource_image.dart' show AylaResourceImage;

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

  // ============ 2026-10-26 新增：资料（头像图片）热更新锁 ============

  /// 读「渲染出的头像图 URL」（null = 走文字首字档，即没有图）。
  String? renderedAvatarSrc(WidgetTester tester) {
    final Iterable<AylaResourceImage> imgs =
        tester.widgetList<AylaResourceImage>(find.byType(AylaResourceImage));
    return imgs.isEmpty ? null : imgs.first.src;
  }

  /// 包一层带 scope 的宿主（资料帧测试专用）。
  Widget scoped(ProviderContainer c, Widget child) => UncontrolledProviderScope(
        container: c,
        child: MaterialApp(home: Scaffold(body: child)),
      );

  testWidgets('★ user.updated ⇒ 头像**图片 URL** 真的换（user 形态）', (
    WidgetTester tester,
  ) async {
    final ProviderContainer c = ProviderContainer();
    addTearDown(c.dispose);
    const AylaUserPublic user = AylaUserPublic(
      id: 'u2',
      username: 'xixi',
      nickname: '汐汐',
      avatar: 'https://old/avatar.png',
      online: true,
    );
    await tester.pumpWidget(
      scoped(
        c,
        const AylaAvatarHalo(
          label: '汐汐',
          size: 40,
          user: user,
          resourceUrl: 'https://old/avatar.png',
        ),
      ),
    );
    await tester.pump();
    expect(renderedAvatarSrc(tester), 'https://old/avatar.png',
        reason: '前置：渲染的是构造参数那份旧 URL');

    // ★ 模拟后端 `user.updated` 帧（WS 落 store 的正是这条路径）
    c.read(presenceStateProvider).applyUserProfile(
      'u2',
      nickname: '汐汐',
      avatar: 'https://new/avatar.png',
      signature: '',
    );
    await tester.pump();

    expect(
      renderedAvatarSrc(tester),
      'https://new/avatar.png',
      reason: '★ 换头像帧到达后，渲染出的图 URL 必须真的换 —— '
          '这条断言正是过去缺失的那条（零处读 profileOf 时这里会红）',
    );
  });

  testWidgets('★ user.updated ⇒ 头像图片真的换（userId 形态）', (
    WidgetTester tester,
  ) async {
    final ProviderContainer c = ProviderContainer();
    addTearDown(c.dispose);
    await tester.pumpWidget(
      scoped(
        c,
        const AylaAvatarHalo(
          label: '汐汐',
          size: 40,
          userId: 'u2',
          resourceUrl: 'https://old/avatar.png',
        ),
      ),
    );
    await tester.pump();
    expect(renderedAvatarSrc(tester), 'https://old/avatar.png');

    c.read(presenceStateProvider).applyUserProfile('u2', avatar: 'https://new2/a.png');
    await tester.pump();
    expect(renderedAvatarSrc(tester), 'https://new2/a.png',
        reason: '只有 id 的头像（列表条目）也必须跟手');
  });

  testWidgets('★ user.updated 换昵称 ⇒ 文字首字/语义标签跟着变', (
    WidgetTester tester,
  ) async {
    final ProviderContainer c = ProviderContainer();
    addTearDown(c.dispose);
    // 无头像图 ⇒ 走文字首字档，可直接断言昵称变化
    await tester.pumpWidget(
      scoped(c, const AylaAvatarHalo(label: '旧名', size: 40, userId: 'u2')),
    );
    await tester.pump();
    expect(find.text('旧'), findsOneWidget, reason: '前置：首字来自构造参数 label');

    c.read(presenceStateProvider).applyUserProfile('u2', nickname: '新名');
    await tester.pump();
    expect(find.text('新'), findsOneWidget, reason: '换昵称帧到达后首字也要换');
  });

  testWidgets('★ 清空头像（空串）⇒ 以空串为权威，不回落旧 URL', (
    WidgetTester tester,
  ) async {
    final ProviderContainer c = ProviderContainer();
    addTearDown(c.dispose);
    await tester.pumpWidget(
      scoped(
        c,
        const AylaAvatarHalo(
          label: '汐汐',
          size: 40,
          userId: 'u2',
          resourceUrl: 'https://old/a.png',
        ),
      ),
    );
    await tester.pump();
    expect(renderedAvatarSrc(tester), 'https://old/a.png');

    // 后端「删除头像」广播空串
    c.read(presenceStateProvider).applyUserProfile('u2', avatar: '');
    await tester.pump();
    expect(renderedAvatarSrc(tester), isNull,
        reason: '空串 = 真的没头像 ⇒ 走首字档，不能回退旧图（否则删头像对别人无效）');
  });

  testWidgets('★ 静态档不回归：群头像（无身份）不受 user.updated 影响', (
    WidgetTester tester,
  ) async {
    final ProviderContainer c = ProviderContainer();
    addTearDown(c.dispose);
    await tester.pumpWidget(
      scoped(
        c,
        const AylaAvatarHalo(
          label: '群',
          size: 40,
          resourceUrl: 'https://group/avatar.png',
        ),
      ),
    );
    await tester.pump();
    c.read(presenceStateProvider).applyUserProfile('u2', avatar: 'https://new/a.png');
    await tester.pump();
    expect(renderedAvatarSrc(tester), 'https://group/avatar.png',
        reason: '群头像不是「某个人」，不能被用户资料帧改掉');
  });
}
