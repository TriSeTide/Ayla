/// 个人页回归（`web/src/pages/ProfilePage.tsx` 317 行 + `profile.css` 两档布局）。
///
/// 覆盖：加载态 / 身份行 / 操作三键 / `dirty` 门控 / 窄屏单列 / 草稿重置语义。
/// 保存与头像上传的网络路径不发请求（无 mock `DioClient`），由后端契约与能力层测试覆盖。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/media/media_picker.dart';
import '../lib/pages/profile_page.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/base/avatar_halo.dart';
import '../lib/widgets/base/reveal.dart';
import '../lib/widgets/profile/profile_card.dart';
import '../lib/widgets/profile/profile_edit.dart'
    show AylaProfileForm, AylaProfileFormRow;
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

  testWidgets('宽屏两列各有面板入场（web auroraqua.css:323–332）', (WidgetTester tester) async {
    await useViewport(tester, const Size(1440, 1000));
    await tester.pumpWidget(host(const ProfilePage()));
    await tester.pump();
    await signIn(tester, user);

    final List<AylaRevealItem> items =
        tester.widgetList<AylaRevealItem>(find.byType(AylaRevealItem)).toList();
    expect(items.length, 2, reason: 'profile-side + profile-main 各一条');
    // `.profile-side` = auroraqua-sidebar-in（左入 −20）
    expect(items.any((AylaRevealItem i) => i.offset == const Offset(-20, 0)), isTrue);
    // `.profile-main` = auroraqua-panel-from-right（右入 +20）
    expect(items.any((AylaRevealItem i) => i.offset == const Offset(20, 0)), isTrue);
    expect(
      items.every((AylaRevealItem i) => i.duration == AylaDurations.auroraqua),
      isTrue,
    );
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

  testWidgets('头像即时预览：未选 ⇒ avatarOverride 为 null（走真实 URL，默认档行为不变）', (
    WidgetTester tester,
  ) async {
    await useViewport(tester, const Size(1440, 1000));
    await tester.pumpWidget(host(const ProfilePage()));
    await tester.pump();
    await signIn(tester, user);

    final AylaProfileIdentity identity = tester.widget<AylaProfileIdentity>(
      find.byType(AylaProfileIdentity),
    );
    expect(identity.avatarOverride, isNull);
    expect(
      tester.widget<AylaAvatarHalo>(find.byType(AylaAvatarHalo)).previewImage,
      isNull,
    );
  });

  testWidgets('头像即时预览：选文件后 avatarOverride = MemoryImage（web objectURL 等价物）', (
    WidgetTester tester,
  ) async {
    await useViewport(tester, const Size(1440, 1000));
    // 1×1 透明 PNG：让 AylaResourceImage 真能解码（否则预览路径会抛解码异常）
    final Uint8List png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
    );
    AylaMediaPicker.backend = _FakePicker(
      AylaPickedFile(
        name: 'avatar.png',
        size: png.length,
        mimeType: 'image/png',
        readBytes: () async => png,
      ),
    );
    addTearDown(() => AylaMediaPicker.backend = const AylaFilePickerBackend());

    await tester.pumpWidget(host(const ProfilePage()));
    await tester.pump();
    await signIn(tester, user);

    await tester.tap(find.text('更换头像'));
    await tester.pumpAndSettle();

    // 组件层：override 已透传到 AylaAvatarHalo.previewImage
    expect(
      tester
          .widget<AylaProfileIdentity>(find.byType(AylaProfileIdentity))
          .avatarOverride,
      isA<MemoryImage>(),
    );
    expect(
      tester.widget<AylaAvatarHalo>(find.byType(AylaAvatarHalo)).previewImage,
      isA<MemoryImage>(),
    );
    // 与 web 的 hint 并存（tsx 202–204：选了新头像才出现该提示）
    expect(find.text('新头像将在保存后生效'), findsOneWidget);
  });
  // ==================== 侧栏模式（web profile.css:57–127） ====================

  testWidgets('侧栏模式：资料卡铺满侧栏高度（flex: 1 0 auto + align-self: stretch）', (
    WidgetTester tester,
  ) async {
    await useViewport(tester, const Size(1440, 1000));
    await tester.pumpWidget(host(const ProfilePage()));
    await tester.pump();
    await signIn(tester, user);

    final Rect card = tester.getRect(find.byType(AylaProfileCard));
    final Size colSize = tester.getSize(find.descendant(of: find.byType(AylaProfileCard), matching: find.byType(Column)).first);
    final Rect identity = tester.getRect(find.byType(AylaProfileIdentity));
    debugPrint('SIDEBAR card=' + card.toString() + ' col=' + colSize.toString() + ' identityTop=' + identity.top.toString());
    // 铺满：卡片高度 ≈ 视口高 − 页面 padding-top sp3 − 侧栏底部呼吸 sp3
    expect(
      card.height,
      greaterThan(900),
      reason: '卡片应被撑到侧栏高（≈1000−12−12），而不是内容高',
    );
    expect(card.top, closeTo(AylaSpacing.sp3, 1));
    expect(card.bottom, greaterThan(970));
  });

  testWidgets('侧栏模式：卡片 gap = sp6 + fillHeight + compact（profile.css:115–119）', (
    WidgetTester tester,
  ) async {
    await useViewport(tester, const Size(1440, 1000));
    await tester.pumpWidget(host(const ProfilePage()));
    await tester.pump();
    await signIn(tester, user);

    final AylaProfileCard card =
        tester.widget<AylaProfileCard>(find.byType(AylaProfileCard));
    expect(card.compact, isTrue); // .profile-card { padding: sp4 }
    expect(card.gap, AylaSpacing.sp6); // .profile-side .profile-card { gap: sp6 }
    expect(card.fillHeight, isTrue); // flex: 1 0 auto ⇒ 间隙自适应
  });

  testWidgets('侧栏模式：间隙自适应 —— 操作区沉到卡底（.profile-actions { margin-top: auto }）', (
    WidgetTester tester,
  ) async {
    await useViewport(tester, const Size(1440, 1000));
    await tester.pumpWidget(host(const ProfilePage()));
    await tester.pump();
    await signIn(tester, user);

    final Rect card = tester.getRect(find.byType(AylaProfileCard));
    final Rect logout = tester.getRect(
      find.widgetWithText(AylaGlassButton, '退出登录'),
    );
    // 卡片被撑高后，多余空间落在「上半区（identity + 头像操作）」与表单之间
    // ⇒ 表单（含操作区）贴着卡片底部（差距 = 卡片 padding sp4 = 16）
    final double bottomGap = card.bottom - logout.bottom;
    debugPrint('SIDEBAR bottomGap=' + bottomGap.toString());
    expect(
      bottomGap,
      lessThanOrEqualTo(AylaSpacing.sp4 + 4), // 实测 18 = 卡片 padding sp4 + 2
      reason: '操作区应沉到卡底（只剩卡片 padding sp4），不该被空隙顶开',
    );
    // 且上方确实有被拉开的空隙（间隙自适应）：头像操作区底边到表单顶边 > sp6
    final Rect identity = tester.getRect(find.byType(AylaProfileIdentity));
    final Rect avatarActions = tester.getRect(find.byType(AylaProfileAvatarActions));
    final Rect form = tester.getRect(find.byType(AylaProfileForm));
    final double stretched = form.top - avatarActions.bottom;
    final double upperGap = avatarActions.top - identity.bottom;
    debugPrint(
      'SIDEBAR gaps upper=' +
          upperGap.toString() +
          ' lower=' +
          stretched.toString(),
    );
    // **均匀分布**：两个相邻间隙必须近似相等（2026-09-28 用户实报「要均匀分布一些」）。
    // 若把若干区块先打包成一组的写法回潮，这里会立刻红（空隙会集中成一处）。
    expect((upperGap - stretched).abs(), lessThan(2));

    // **整块上下均匀**（用户第三轮反馈）：表单（AylaProfileForm）也是「可伸展子项」，
    // 它内部的 4 个间隙与卡片级间隙由同一份多余高度均分 ⇒ 两者应当接近。
    // 基准间隙不同（卡片级 sp6 = 24 / 表单内 sp4 = 16）⇒ 容忍 8px + 取整误差。
    final Rect statusRow = tester.getRect(
      find.widgetWithText(AylaProfileFormRow, '在线状态'),
    );
    final Rect nicknameRow = tester.getRect(
      find.widgetWithText(AylaProfileFormRow, '昵称'),
    );
    final double innerGap = nicknameRow.top - statusRow.bottom;
    debugPrint('SIDEBAR innerGap=' + innerGap.toString());
    expect(
      (innerGap - stretched).abs(),
      lessThan(12),
      reason: '表单内部间隙应与卡片级间隙同值（整块均匀）',
    );
    debugPrint('SIDEBAR stretchedGap=' + stretched.toString());
    expect(
      stretched,
      greaterThan(50),
      reason: '卡片铺满后多余空间应分配到相邻区块之间（用户：整块上下均匀）',
    );
  });

  testWidgets('窄屏单列档：卡片不铺满（内容高），且无 fillHeight 档', (WidgetTester tester) async {
    await useViewport(tester, const Size(375, 812));
    await tester.pumpWidget(
      host(const ProfilePage(), viewport: const Size(375, 812)),
    );
    await tester.pump();
    await signIn(tester, user);

    final AylaProfileCard card =
        tester.widget<AylaProfileCard>(find.byType(AylaProfileCard));
    expect(card.fillHeight, isFalse); // 单列自然流
    expect(card.gap, isNull); // 走 compact 推导
  });

}

/// 选文件替身（避免平台通道）：直接返回构造好的文件。
class _FakePicker implements AylaPickerBackend {
  _FakePicker(this.file);

  final AylaPickedFile file;

  @override
  Future<List<AylaPickedFile>> pick({
    required AylaPickKind kind,
    bool multiple = false,
  }) async => <AylaPickedFile>[file];
}
