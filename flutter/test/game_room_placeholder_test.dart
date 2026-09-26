/// B4 boardgame 域第一批（3/3）：桌游室占位整页壳定向测试 —— 逐条对照
/// GameRoomPlaceholder.tsx 132–187 与 boardgame.css 136–219、auroraqua.css 335/402–408/418、
/// posts.css 373–376。
///
/// 覆盖：head 结构（返回 40 / 名字 18 / 分享 / 收藏 compact）/ **head 两档（窄屏通栏 vs
/// 宽屏卡片化 margin 12）且高度恒 64** / 正文文案 / 加入↔离开两态 / busy 文案与禁用 /
/// 房主控制（排除自己 + 移出/转让 + 删除房间全宽）/ 非房主不渲染控制区 /
/// 成员操作禁用（actionBusyUserId）/ 删除确认弹窗（打开 → 确认 → 关闭）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/game_room.dart';
import '../lib/core/models/user_public.dart';
import '../lib/core/models/visibility.dart';
import '../lib/theme/buttons.dart' show AylaIconButton;
import '../lib/theme/glass.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/base/dialogs.dart';
import '../lib/widgets/base/directory_controls.dart';
import '../lib/widgets/game/game_room_placeholder.dart';
import '../lib/widgets/base/share.dart';

void main() {
  const AylaUserPublic alice = AylaUserPublic(
    id: 'u1',
    nickname: '爱莉',
    username: 'elysia',
  );
  const AylaUserPublic bob = AylaUserPublic(id: 'u2', username: 'bob');
  const AylaUserPublic carol = AylaUserPublic(id: 'u3', nickname: '卡罗尔');

  const List<AylaGameRoomMember> members = <AylaGameRoomMember>[
    AylaGameRoomMember(id: 1, userId: 'u1', user: alice),
    AylaGameRoomMember(id: 2, userId: 'u2', user: bob),
    AylaGameRoomMember(id: 3, userId: 'u3', user: carol),
  ];

  const AylaGameRoom room = AylaGameRoom(
    id: 7,
    name: '爱莉的桌游室',
    owner: alice,
    ownerId: 'u1',
    status: AylaGameRoomStatus.waiting,
    visibility: AylaPostVisibility.public,
    memberCount: 3,
  );

  Widget host(
    Widget child, {
    Size viewport = const Size(900, 640),
  }) {
    return MaterialApp(
      home: previewScope(
        Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(size: viewport),
            child: SizedBox.fromSize(size: viewport, child: child),
          ),
        ),
      ),
    );
  }

  AylaGameRoomPlaceholder pane({
    AylaGameRoom value = room,
    String? currentUserId = 'u2',
    VoidCallback? onBack,
    VoidCallback? onShare,
    VoidCallback? onJoin,
    VoidCallback? onLeave,
    ValueChanged<String>? onKickMember,
    ValueChanged<String>? onTransferOwner,
    VoidCallback? onDeleteRoom,
    bool busy = false,
    String? error,
    bool? isMember,
    bool? isOwner,
    List<AylaGameRoomMember> memberList = const <AylaGameRoomMember>[],
    bool membersHasMore = false,
    String? actionBusyUserId,
  }) {
    return AylaGameRoomPlaceholder(
      room: value,
      onBack: onBack ?? () {},
      onShare: onShare,
      onJoin: onJoin,
      onLeave: onLeave,
      onKickMember: onKickMember,
      onTransferOwner: onTransferOwner,
      onDeleteRoom: onDeleteRoom,
      busy: busy,
      error: error,
      currentUserId: currentUserId,
      isMember: isMember,
      isOwner: isOwner,
      members: memberList,
      membersHasMore: membersHasMore,
      actionBusyUserId: actionBusyUserId,
    );
  }

  testWidgets('head 结构：返回 40 / 名字 18 / 分享（分享桌游室）/ 收藏 compact', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(pane()));
    await tester.pump();

    expect(find.text('爱莉的桌游室'), findsOneWidget); // tsx 138
    // 返回键 = .icon-btn-40（40×40、IconBack 20）
    final AylaIconButton back = tester.widget<AylaIconButton>(
      find.byWidgetPredicate((Widget w) => w is AylaIconButton && w.size == 40),
    );
    expect(back.semanticLabel, '返回');
    // 分享键（tsx 139–142：label 分享桌游室）
    final AylaShareButton share = tester.widget<AylaShareButton>(
      find.byType(AylaShareButton),
    );
    expect(share.label, '分享桌游室');
    // 收藏键 compact（tsx 143）
    expect(find.byType(AylaFavoriteButton), findsOneWidget);
    final Size fav = tester.getSize(find.byType(AylaFavoriteButton));
    expect(fav.width, 32);
    expect(fav.height, 32);

    // 名字字号 18 / display（boardgame.css 155–163）
    final Text name = tester.widget<Text>(find.text('爱莉的桌游室'));
    expect(name.style?.fontSize, 18);
    expect(name.style?.fontFamily, 'Fredoka');
  });

  testWidgets('head 宽屏档（≥769）：卡片化 margin 12 + 高度恒 64', (WidgetTester tester) async {
    // 视口必须 pin 到与舞台同尺寸：默认测试窗口 800×600 会把 SizedBox 夹窄
    tester.view.physicalSize = const Size(900, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host(pane(), viewport: const Size(900, 640)));
    await tester.pump();
    final Size wide = tester.getSize(find.byType(AylaGlassSurface).first);
    expect(wide.width, 900 - 2 * AylaSpacing.sidebarGutter); // 卡片化 = 四周 12 留白
    expect(wide.height, 64); // padding sp3×2 + 内容 40（两档恒定）
  });

  testWidgets('head 窄屏档（≤768）：通栏无 margin + 高度同为 64', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(375, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host(pane(), viewport: const Size(375, 700)));
    await tester.pump();
    final Size narrow = tester.getSize(find.byType(AylaGlassSurface).first);
    expect(narrow.width, 375); // 通栏：无 margin
    expect(narrow.height, 64);
  });

  testWidgets('正文：占位说明 + 「N 人 · 房主 展示名」+ 错误行', (WidgetTester tester) async {
    await tester.pumpWidget(host(pane(error: '加入失败')));
    await tester.pump();

    expect(find.text('桌游玩法后续上线，当前为房间框架占位'), findsOneWidget); // tsx 146–148
    expect(find.text('3 人 · 房主 爱莉'), findsOneWidget); // tsx 149–151
    final Text err = tester.widget<Text>(find.text('加入失败'));
    expect(err.style?.color, AylaColors.destructive);
    expect(err.style?.fontSize, 13); // .post-editor-error
  });

  testWidgets('加入 / 离开两态：非成员 → primary「加入房间」；成员 → ghost「离开房间」', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(pane(isMember: false)));
    await tester.pump();
    expect(find.text('加入房间'), findsOneWidget); // tsx 182–184
    expect(find.text('离开房间'), findsNothing);
    expect(
      tester.widget<AylaGlassButton>(find.byType(AylaGlassButton).last).variant,
      AylaGlassButtonVariant.primary,
    );

  });

  testWidgets('成员 → ghost「离开房间」', (WidgetTester tester) async {
    await tester.pumpWidget(host(pane(isMember: true)));
    await tester.pump();
    expect(find.text('离开房间'), findsOneWidget); // tsx 178–180
    expect(
      tester.widget<AylaGlassButton>(find.byType(AylaGlassButton).last).variant,
      AylaGlassButtonVariant.ghost,
    );
  });

  testWidgets('busy：文案切「加入中… / 离开中…」且按钮禁用', (WidgetTester tester) async {
    await tester.pumpWidget(host(pane(isMember: false, busy: true)));
    await tester.pump();
    expect(find.text('加入中…'), findsOneWidget);
    expect(tester.widget<AylaGlassButton>(find.byType(AylaGlassButton).last).onPressed, isNull);

  });

  testWidgets('busy（成员）：文案切「离开中…」且按钮禁用', (WidgetTester tester) async {
    await tester.pumpWidget(host(pane(isMember: true, busy: true)));
    await tester.pump();
    expect(find.text('离开中…'), findsOneWidget);
    expect(tester.widget<AylaGlassButton>(find.byType(AylaGlassButton).last).onPressed, isNull);
  });

  testWidgets('房主控制：排除自己 + 移出/转让 + 删除房间（全宽）+ 分页件', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(pane(
      isOwner: true,
      currentUserId: 'u1',
      memberList: members,
      membersHasMore: true,
    )));
    await tester.pump();

    expect(find.text('房主控制'), findsOneWidget); // tsx 154
    // 成员行排除自己（tsx 155）
    expect(find.text('bob'), findsOneWidget);
    expect(find.text('卡罗尔'), findsOneWidget);
    expect(find.text('爱莉'), findsNothing);
    expect(find.text('移出'), findsNWidgets(2));
    expect(find.text('转让房主'), findsNWidgets(2));
    expect(find.text('删除房间'), findsOneWidget);
    expect(find.byType(AylaDirectoryLoadMore), findsOneWidget);

    // 删除键全宽（web 的 .game-room-owner-controls 是 flex column 默认 stretch）
    final Finder delBtn = find.ancestor(
      of: find.text('删除房间'),
      matching: find.byType(AylaGlassButton),
    );
    expect(delBtn, findsOneWidget);
    final Size del = tester.getSize(delBtn);
    expect(del.width, 680); // min(100%, 680px)
    expect(del.height, 40); // .btn { min-height: 40px }
  });

  testWidgets('非房主：不渲染房主控制区', (WidgetTester tester) async {
    await tester.pumpWidget(host(pane(isOwner: false)));
    await tester.pump();
    expect(find.text('房主控制'), findsNothing);
    expect(find.text('删除房间'), findsNothing);
    expect(find.text('移出'), findsNothing);
  });

  testWidgets('成员操作：点「移出」回传 user_id；actionBusy 时两键禁用', (
    WidgetTester tester,
  ) async {
    String? kicked;
    String? transferred;
    await tester.pumpWidget(host(pane(
      isOwner: true,
      currentUserId: 'u1',
      memberList: members,
      onKickMember: (String id) => kicked = id,
      onTransferOwner: (String id) => transferred = id,
    )));
    await tester.pump();

    await tester.tap(find.text('移出').first);
    await tester.pump();
    expect(kicked, 'u2'); // 第一行 = bob
    await tester.tap(find.text('转让房主').first);
    await tester.pump();
    expect(transferred, 'u2');

  });

  testWidgets('actionBusyUserId 非 null ⇒ 移出/转让一起禁用（tsx 157–158）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(pane(
      isOwner: true,
      currentUserId: 'u1',
      memberList: members,
      actionBusyUserId: 'u2',
    )));
    await tester.pump();

    for (final String label in <String>['移出', '转让房主']) {
      final Finder btn = find.ancestor(
        of: find.text(label).first,
        matching: find.byType(AylaGlassButton),
      );
      expect(btn, findsOneWidget, reason: label);
      expect(
        tester.widget<AylaGlassButton>(btn).onPressed,
        isNull,
        reason: label,
      );
    }
  });

  testWidgets('删除确认：打开弹窗 → 确认回调 → 取消关闭（tsx 163–176）', (
    WidgetTester tester,
  ) async {
    int deleted = 0;
    await tester.pumpWidget(host(pane(
      isOwner: true,
      currentUserId: 'u1',
      memberList: members,
      onDeleteRoom: () => deleted++,
    )));
    await tester.pump();

    expect(find.byType(AylaConfirmDialog), findsNothing);
    await tester.tap(find.text('删除房间'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300)); // 弹层入场

    expect(find.byType(AylaConfirmDialog), findsOneWidget);
    expect(find.text('删除桌游房间'), findsOneWidget); // tsx 165
    expect(
      find.text('确定删除桌游房间「爱莉的桌游室」？此操作不可撤销。'), // tsx 166
      findsOneWidget,
    );

    // 取消 → 关闭且不触发删除
    await tester.tap(find.text('取消'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(AylaConfirmDialog), findsNothing);
    expect(deleted, 0);

    // 确认 → 关闭并回调
    await tester.tap(find.text('删除房间'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('删除'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(deleted, 1);
    expect(find.byType(AylaConfirmDialog), findsNothing);
  });

  testWidgets('返回 / 分享 / 加入 / 离开回调', (WidgetTester tester) async {
    final List<String> log = <String>[];
    await tester.pumpWidget(host(pane(
      isMember: false,
      onBack: () => log.add('back'),
      onShare: () => log.add('share'),
      onJoin: () => log.add('join'),
      onLeave: () => log.add('leave'),
    )));
    await tester.pump();

    await tester.tap(find.byWidgetPredicate(
      (Widget w) => w is AylaIconButton && w.size == 40,
    ));
    await tester.pump();
    await tester.tap(find.byType(AylaShareButton));
    await tester.pump();
    await tester.tap(find.text('加入房间'));
    await tester.pump();
    expect(log, <String>['back', 'share', 'join']);

  });

  testWidgets('离开回调', (WidgetTester tester) async {
    final List<String> log = <String>[];
    await tester.pumpWidget(host(pane(
      isMember: true,
      onLeave: () => log.add('leave'),
    )));
    await tester.pump();
    await tester.tap(find.text('离开房间'));
    await tester.pump();
    expect(log, <String>['leave']);
  });
}
