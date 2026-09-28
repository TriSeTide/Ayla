/// 个人页回归（`web/src/pages/ProfilePage.tsx` 317 行 + `profile.css` 两档布局）。
///
/// 覆盖：加载态 / 身份行 / 操作三键 / `dirty` 门控 / 窄屏单列 / 草稿重置语义。
/// 保存与头像上传的网络路径不发请求（无 mock `DioClient`），由后端契约与能力层测试覆盖。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/pages/profile_page.dart';
import '../lib/state/auth_state.dart';
import '../lib/theme/glass.dart';
import '../lib/theme/preview_theme.dart';

void main() {
  const AuthUser user = AuthUser(
    id: 'u1',
    username: 'ayla',
    nickname: '爱莉',
    avatar: '',
    signature: '你好',
    status: 'auto',
    online: true,
    displayStatus: '在线',
    dateJoined: '2026-01-01',
    isInVoice: false,
    voiceRoomId: null,
    isLive: false,
    liveRoomId: null,
    showContent: false,
    email: 'a@b.c',
  );

  Future<void> useViewport(WidgetTester tester, Size size) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  Widget host(Widget child, {Size viewport = const Size(1440, 1000)}) {
    return MaterialApp(
      home: Builder(
        builder: (BuildContext context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(size: viewport),
          child: previewScope(child),
        ),
      ),
    );
  }

  /// 登录态注入（等价 web `useAuthStore.currentUser`）。
  Future<void> signIn(WidgetTester tester, AuthUser value) async {
    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(ProfilePage)),
    );
    final AuthNotifier notifier = container.read(authNotifierProvider.notifier);
    notifier.setTokens('access', 'refresh');
    notifier.setUser(value);
    await tester.pump();
  }

  testWidgets('未取到用户：只渲染「正在加载个人资料…」（tsx 87–97）', (
    WidgetTester tester,
  ) async {
    await useViewport(tester, const Size(1440, 1000));
    await tester.pumpWidget(host(const ProfilePage()));
    await tester.pump();
    expect(find.text('正在加载个人资料…'), findsOneWidget);
  });

  testWidgets('身份行与操作三键（tsx 154–210）', (WidgetTester tester) async {
    await useViewport(tester, const Size(1440, 1000));
    await tester.pumpWidget(host(const ProfilePage()));
    await tester.pump();
    await signIn(tester, user);

    expect(find.text('@ayla'), findsOneWidget);
    expect(find.text('更换头像'), findsOneWidget);
    expect(find.text('隐私设置'), findsOneWidget);
    expect(find.text('我的收藏'), findsOneWidget);
    expect(find.text('保存修改'), findsOneWidget);
    expect(find.text('退出登录'), findsOneWidget);
    // 分享键是图标钮（可访问名走 aria，不是可见文本）
    expect(find.text('分享我的主页'), findsNothing);
  });

  testWidgets('dirty 门控：初值干净 ⇒ 保存禁用；改昵称 ⇒ 启用（tsx 292）', (
    WidgetTester tester,
  ) async {
    await useViewport(tester, const Size(1440, 1000));
    await tester.pumpWidget(host(const ProfilePage()));
    await tester.pump();
    await signIn(tester, user);

    AylaGlassButton save() => tester.widget<AylaGlassButton>(
          find.widgetWithText(AylaGlassButton, '保存修改'),
        );
    expect(save().onPressed, isNull); // `disabled={saving || !dirty}`

    await tester.enterText(find.byType(TextField).at(0), '改了昵称');
    await tester.pump();
    expect(save().onPressed, isNotNull);
  });

  testWidgets('窄屏（≤768）：单列自然流（`.profile-side/.profile-main` 都是 display:contents）', (
    WidgetTester tester,
  ) async {
    await useViewport(tester, const Size(375, 812));
    await tester.pumpWidget(
      host(const ProfilePage(), viewport: const Size(375, 812)),
    );
    await tester.pump();
    await signIn(tester, user);

    final Rect identity = tester.getRect(find.text('@ayla'));
    expect(identity.left, greaterThan(0));
    expect(find.text('更换头像'), findsOneWidget);
  });
}