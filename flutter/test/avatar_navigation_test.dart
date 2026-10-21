/// 头像导航回归 —— 「点头像进个人主页」四处 web 事实源的 Flutter 等价物。
///
/// 事实源（web）：
/// - components/live/DanmakuList.tsx:52–58：弹幕发送者 Avatar
///   onClick={() => goUserProfile(null, item.sender.user_id)}；
/// - components/live/LiveHostAvatar.tsx:44–49：主播 Avatar
///   onClick={() => ownerId && goUserProfile(null, ownerId)}；
/// - components/voice/VoiceMemberRow.tsx:143–149：语音成员 Avatar
///   onClick={() => goUserProfile(currentUserId, member.user_id)}；
/// - components/posts/PostCard.tsx:70–79：帖子卡作者 Avatar
///   onClick={(e) => { e.stopPropagation(); goUserProfile(currentUserId, author.id!) }}；
/// - 跳转口径 utils/navigation.ts:24–35（自己 → /profile，他人 → /user/:id，空 id 不跳）。
///
/// 本文件锁的是**真实 tap**（tester.tap，不是只断言参数存在）：这四处在页面层
/// 曾因「组件有参数、调用点没传」而不可点（本任务的核心缺口）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../lib/core/media/media_signer.dart';
import '../lib/core/models/post.dart';
import '../lib/pages/live_room_page.dart';
import '../lib/pages/live_studio_page.dart';
import '../lib/pages/voice_hub_page.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/widgets/base/avatar_halo.dart';
import '../lib/widgets/live/danmaku.dart' show AylaDanmakuEntry;
import '../lib/widgets/live/live_channel_snapshot.dart';
import '../lib/widgets/live/live_hall.dart' show AylaLiveCardData, AylaLiveStatus;
import '../lib/widgets/live/live_player.dart' show AylaLiveSrsStatus;
import '../lib/widgets/live/live_room_body.dart';
import '../lib/widgets/live/live_studio.dart' show AylaLiveHostAvatar;
import '../lib/widgets/posts/post_card.dart';
import '../lib/widgets/voice/voice_channel_panel.dart';
import '../lib/widgets/voice/voice_member_row.dart'
    show AylaVoiceMember, AylaVoiceMemberRow;

void main() {
  setUp(() => MediaSigner.instance.detach()); // 隔离：不触真实签名请求
  tearDown(() => MediaSigner.instance.detach());

  void setViewport(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Widget host(
    WidgetTester tester,
    Widget child, {
    Size viewport = const Size(1200, 800),
  }) {
    setViewport(tester, viewport);
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

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400)); // 头部进退场 300ms
  }

  /// 按语义标签取头像（web 的 aria-label 同源：「查看 {名} 的个人主页」）。
  Finder avatarWithLabel(String label) => find.byWidgetPredicate(
        (Widget w) => w is AylaAvatarHalo && w.semanticLabel == label,
      );

  group('直播间（LiveRoomBody）头像导航', () {
    const List<AylaLiveCardData> channels = <AylaLiveCardData>[
      AylaLiveCardData(id: 'lc1', title: '第一场直播', status: AylaLiveStatus.live),
    ];
    const AylaLiveChannelSnapshot channel = AylaLiveChannelSnapshot(
      id: 'lc1',
      title: '深夜电台',
      status: AylaLiveStatus.live,
      visibility: 'public',
      ownerId: 'owner-1',
      ownerNickname: '爱莉',
    );

    Widget room({
      ValueChanged<String>? onOpenSenderProfile,
      ValueChanged<String>? onOpenHostProfile,
    }) =>
        AylaLiveRoomBody(
          channelId: 'lc1',
          isNarrow: false,
          channels: channels,
          data: const AylaLiveRoomData(
            channel: channel,
            srsStatus: AylaLiveSrsStatus.live,
            danmaku: <AylaDanmakuEntry>[
              AylaDanmakuEntry(
                id: 'd1',
                senderNickname: '观众A',
                senderUserId: 'u-a',
                content: '来了来了',
              ),
              AylaDanmakuEntry(
                id: 'd2',
                senderNickname: '观众B',
                senderUserId: 'u-b',
                content: '好看',
              ),
            ],
          ),
          videoView: const SizedBox(),
          onOpenSenderProfile: onOpenSenderProfile,
          onOpenHostProfile: onOpenHostProfile,
        );

    testWidgets('弹幕发送者头像 tap → onOpenSenderProfile 收到 senderUserId（DanmakuList.tsx:52–58）',
        (WidgetTester tester) async {
      final List<String> opened = <String>[];
      await tester.pumpWidget(host(tester, room(onOpenSenderProfile: opened.add)));
      await settle(tester);

      // 未点击前没有任何回调（防「参数已传但没有可点热区」的假绿）。
      expect(opened, isEmpty);

      await tester.tap(avatarWithLabel('查看 观众A 的个人主页'));
      await tester.pump();
      expect(opened, <String>['u-a']);

      await tester.tap(avatarWithLabel('查看 观众B 的个人主页'));
      await tester.pump();
      expect(opened, <String>['u-a', 'u-b']);
    });

    testWidgets('主播头像 tap → onOpenHostProfile 收到 ownerId（LiveHostAvatar.tsx:44–49）',
        (WidgetTester tester) async {
      final List<String> opened = <String>[];
      await tester.pumpWidget(host(tester, room(onOpenHostProfile: opened.add)));
      await settle(tester);

      // 头部主播头像是 32 的光环头像（web tsx 243 / 313 的 size={32}）。
      final AylaAvatarHalo halo =
          tester.widget<AylaAvatarHalo>(avatarWithLabel('查看主播 爱莉 的个人主页'));
      expect(halo.size, 32);

      await tester.tap(avatarWithLabel('查看主播 爱莉 的个人主页'));
      await tester.pump();
      expect(opened, <String>['owner-1']);
    });

    testWidgets('未注入回调 ⇒ 弹幕/主播头像都不可点（web 无回调面一致）',
        (WidgetTester tester) async {
      await tester.pumpWidget(host(tester, room()));
      await settle(tester);

      expect(
        tester
            .widget<AylaLiveHostAvatar>(find.byType(AylaLiveHostAvatar))
            .onOpenProfile,
        isNull,
      );
      final Iterable<AylaAvatarHalo> halos =
          tester.widgetList<AylaAvatarHalo>(find.byType(AylaAvatarHalo));
      expect(halos.any((AylaAvatarHalo h) => h.onTap != null), isFalse);
    });

    testWidgets('ownerId 为空 ⇒ 主播头像点击不触发（web 的 ownerId && 同义）',
        (WidgetTester tester) async {
      final List<String> opened = <String>[];
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveRoomBody(
            channelId: 'lc1',
            isNarrow: false,
            channels: channels,
            data: const AylaLiveRoomData(
              channel: AylaLiveChannelSnapshot(
                id: 'lc1',
                title: '深夜电台',
                status: AylaLiveStatus.live,
                ownerNickname: '爱莉',
              ),
              srsStatus: AylaLiveSrsStatus.live,
            ),
            videoView: const SizedBox(),
            onOpenHostProfile: opened.add,
          ),
        ),
      );
      await settle(tester);

      await tester.tap(avatarWithLabel('查看主播 爱莉 的个人主页'));
      await tester.pump();
      expect(opened, isEmpty);
    });
  });

  group('语音房成员头像导航（VoiceMemberRow.tsx:143–149）', () {
    const List<AylaVoicePanelMember> members = <AylaVoicePanelMember>[
      AylaVoicePanelMember(
        member: AylaVoiceMember(userId: 'u2'),
        displayName: '爱莉',
        online: true,
      ),
      AylaVoicePanelMember(
        member: AylaVoiceMember(userId: 'u3'),
        displayName: '小满',
      ),
    ];

    testWidgets('成员行头像 tap → onOpenProfile 收到成员 id', (WidgetTester tester) async {
      final List<String> opened = <String>[];
      await tester.pumpWidget(
        host(
          tester,
          AylaVoiceChannelPanel(
            channelName: '深夜电台',
            members: members,
            selfUserId: 'self',
            onOpenProfile: opened.add,
          ),
          viewport: const Size(700, 620),
        ),
      );
      await settle(tester);

      expect(opened, isEmpty);
      await tester.tap(avatarWithLabel('查看 爱莉 的个人主页'));
      await tester.pump();
      expect(opened, <String>['u2']);

      await tester.tap(avatarWithLabel('查看 小满 的个人主页'));
      await tester.pump();
      expect(opened, <String>['u2', 'u3']);
    });

    testWidgets('未注入 onOpenProfile ⇒ 成员行头像不可点', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          const AylaVoiceChannelPanel(
            channelName: '深夜电台',
            members: members,
            selfUserId: 'self',
          ),
          viewport: const Size(700, 620),
        ),
      );
      await settle(tester);

      final List<AylaVoiceMemberRow> rows = tester
          .widgetList<AylaVoiceMemberRow>(find.byType(AylaVoiceMemberRow))
          .toList();
      expect(rows, isNotEmpty);
      expect(
        rows.every((AylaVoiceMemberRow r) => r.onOpenProfile == null),
        isTrue,
      );
    });
  });

  group('帖子卡作者头像导航（PostCard.tsx:70–79）', () {
    AylaPost post({String? authorId = 'u1'}) => AylaPost(
          id: 1,
          author: const AylaPostAuthor(id: 'u1', nickname: '星野遥', online: true),
          authorId: authorId,
          body: '正文',
          createdAt: '2026-09-20T11:00:00Z',
          images: const <AylaPostImage>[],
        );

    testWidgets('作者头像 tap → onAuthorTap 触发', (WidgetTester tester) async {
      int taps = 0;
      await tester.pumpWidget(
        host(
          tester,
          SizedBox(
            width: 360,
            child: AylaPostCard(
              post: post(),
              onOpen: () {},
              onAuthorTap: () => taps += 1,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(taps, 0);
      await tester.tap(avatarWithLabel('查看 星野遥 的个人主页'));
      await tester.pump();
      expect(taps, 1);
    });

    testWidgets('未传 onAuthorTap ⇒ 头像不可点（光环无 onTap）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          SizedBox(width: 360, child: AylaPostCard(post: post(), onOpen: () {})),
        ),
      );
      await tester.pump();

      final AylaAvatarHalo halo =
          tester.widget<AylaAvatarHalo>(avatarWithLabel('查看 星野遥 的个人主页'));
      expect(halo.onTap, isNull);
    });
  });

  // =================== 页面层接线（防「组件有参数、调用点没传」回归） ===================
  //
  // 本任务的核心缺口正是**页面调用点漏传**（live_room_body.dart:365/470、
  // voice_channel_panel.dart:251、group_posts_page.dart:998、search_page.dart:1148）。
  // 上面三组锁组件契约；这一组锁「真实页面确实把回调传下去了」。
  group('页面层接线（web 三处 goUserProfile 调用方）', () {
    Widget routerHost(
      WidgetTester tester,
      Widget child, {
      Size viewport = const Size(1440, 900),
    }) {
      setViewport(tester, viewport);
      final GoRouter router = GoRouter(
        initialLocation: '/room',
        routes: <RouteBase>[
          GoRoute(
            path: '/room',
            builder: (BuildContext c, GoRouterState s) => previewScope(child),
          ),
          GoRoute(
            path: '/:rest(.*)',
            builder: (BuildContext c, GoRouterState s) =>
                const Scaffold(body: SizedBox.shrink()),
          ),
        ],
      );
      return ProviderScope(
        child: MaterialApp.router(
          routerConfig: router,
          builder: (BuildContext context, Widget? nav) => MediaQuery(
            data: MediaQuery.of(context).copyWith(size: viewport),
            child: nav ?? const SizedBox.shrink(),
          ),
        ),
      );
    }

    testWidgets('LiveRoomPage：弹幕发送者 / 主播两个头像回调都已接线', (WidgetTester tester) async {
      await tester.pumpWidget(routerHost(tester, const LiveRoomPage(channelId: '7')));
      await tester.pump();
      final AylaLiveRoomBody body =
          tester.widget<AylaLiveRoomBody>(find.byType(AylaLiveRoomBody));
      // web DanmakuList.tsx:52-58 / LiveHostAvatar.tsx:44-49 的调用面
      expect(body.onOpenSenderProfile, isNotNull, reason: '弹幕头像必须可点');
      expect(body.onOpenHostProfile, isNotNull, reason: '主播头像必须可点');
      await tester.pumpAndSettle();
    });

    testWidgets('LiveStudioPage：两个头像回调都已接线', (WidgetTester tester) async {
      await tester.pumpWidget(routerHost(tester, const LiveStudioPage(channelId: '7')));
      await tester.pump();
      final AylaLiveRoomBody body =
          tester.widget<AylaLiveRoomBody>(find.byType(AylaLiveRoomBody));
      expect(body.onOpenSenderProfile, isNotNull);
      expect(body.onOpenHostProfile, isNotNull);
      await tester.pumpAndSettle();
    });

    testWidgets('VoiceHubPage 房内分支：成员面板 onOpenProfile 已接线',
        (WidgetTester tester) async {
      await tester.pumpWidget(routerHost(tester, const VoiceHubPage(channelId: 'v1')));
      await tester.pump();
      final AylaVoiceChannelPanel panel =
          tester.widget<AylaVoiceChannelPanel>(find.byType(AylaVoiceChannelPanel));
      // web VoiceMemberRow.tsx:143-149 的调用面（页面层注入，组件本身不持导航）。
      expect(panel.onOpenProfile, isNotNull, reason: '语音成员头像必须可点');
      await tester.pumpAndSettle();
    });
  });
}
