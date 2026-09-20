/// B5：分享族定向测试（SharePayload 契约 + AylaShareSheet 行为 + AylaShareButton）。
///
/// 对照 web：`web/src/vitest/share-sheet.test.tsx` 与 `utils/sharePayload.ts`。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/share_payload.dart';
import '../lib/theme/buttons.dart' show AylaIconButton;
import '../lib/theme/preview_theme.dart';
import '../lib/widgets/dialogs.dart' show AylaModalCard;
import '../lib/widgets/primitives.dart'
    show AylaNavHighlight, AylaSegmentedTabs, AylaSegmentedTabsVariant;
import '../lib/widgets/share.dart';

void main() {
  Widget host(Widget child) => MaterialApp(home: previewScope(child));

  void setViewport(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  final AylaSharePayload livePayload = const AylaSharePayload(
    shareType: AylaShareType.live,
    targetId: 'lc9',
    title: '爱莉的直播间',
  );

  AylaShareTargetPage pageOf(List<AylaShareTarget> items, {String? error}) {
    return AylaShareTargetPage(
      items: items,
      loading: false,
      hasMore: false,
      error: error,
      loadMore: () async {},
      refresh: () async {},
    );
  }

  // ==================== SharePayload 工厂 ====================

  group('AylaSharePayload（utils/sharePayload.ts 逐条对照）', () {
    test('group：人数/加入方式进 extra，人数进 subtitle，标题 trim', () {
      final AylaSharePayload p = AylaSharePayload.group(
        id: 'g1',
        title: ' 技术群 ',
        avatar: '/api/v1/media/m1/content',
        memberCount: 3,
        joinPolicy: 'public',
      );
      expect(p.shareType, AylaShareType.group);
      expect(p.targetId, 'g1');
      expect(p.title, '技术群');
      expect(p.cover, '/api/v1/media/m1/content');
      expect(p.subtitle, '3 人');
      expect(p.extra, <String, Object?>{
        'member_count': 3,
        'join_policy': 'public',
      });
    });

    test('group：无成员数 → extra 空对象（非 null）；非站内封面归一为 null', () {
      final AylaSharePayload p = AylaSharePayload.group(
        id: 'g2',
        title: '爱莉之家',
        avatar: 'https://cdn.example.com/a.png',
      );
      expect(p.extra, isNotNull);
      expect(p.extra, isEmpty);
      expect(p.subtitle, isNull);
      expect(p.cover, isNull);
      expect(AylaSharePayload.group(id: 'g3', title: 'x', avatar: '').cover, isNull);
      expect(AylaSharePayload.group(id: 'g4', title: 'x', avatar: '/').cover, isNull);
    });

    test('voice：cover 恒为 null；group_id 进 extra', () {
      final AylaSharePayload p = AylaSharePayload.voice(
        id: 'v1',
        name: ' 深夜电台 ',
        memberCount: 5,
        groupId: 'g1',
      );
      expect(p.title, '深夜电台');
      expect(p.cover, isNull);
      expect(p.subtitle, '5 人');
      expect(p.extra, <String, Object?>{'group_id': 'g1'});
      final AylaSharePayload bare = AylaSharePayload.voice(id: 'v2', name: '空房');
      expect(bare.subtitle, isNull);
      expect(bare.extra, isNull);
    });

    test('live：封面归一 + 主播名进 subtitle', () {
      final AylaSharePayload p = AylaSharePayload.live(
        id: 'lc1',
        title: '爱莉的直播间',
        cover: '/api/v1/media/c1/thumbnail',
        ownerName: '爱莉',
        groupId: 'g1',
      );
      expect(p.cover, '/api/v1/media/c1/thumbnail');
      expect(p.subtitle, '爱莉');
      expect(p.extra, <String, Object?>{'group_id': 'g1'});
      expect(AylaSharePayload.live(id: 'lc2', title: 't', ownerName: '').subtitle, isNull);
    });

    test('post：正文空白归一 + 24 码元截断 + 省略号', () {
      final AylaSharePayload short = AylaSharePayload.post(
        id: '42',
        title: '标题',
        body: '  第一行\n第二行   第三行  ',
        group: 'g1',
      );
      expect(short.subtitle, '第一行 第二行 第三行');
      expect(short.extra, <String, Object?>{'group_id': 'g1'});
      final String long = List<String>.filled(30, 'a').join();
      final AylaSharePayload truncated = AylaSharePayload.post(
        id: '43',
        title: '标题',
        body: long,
      );
      expect(truncated.subtitle, '${List<String>.filled(24, 'a').join()}\u2026');
      expect(
        AylaSharePayload.post(id: '44', title: 't', body: '   ').subtitle,
        isNull,
      );
    });

    test('boardgame：extra 无内容时为 null；玩法类型进 subtitle', () {
      expect(
        AylaSharePayload.boardgame(id: 'b1', name: '房间').extra,
        isNull,
      );
      final AylaSharePayload p = AylaSharePayload.boardgame(
        id: 'b1',
        name: ' 房间 ',
        group: 'g1',
        gameType: 'uno',
      );
      expect(p.title, '房间');
      expect(p.cover, isNull);
      expect(p.subtitle, 'uno');
      expect(p.extra, <String, Object?>{'group_id': 'g1', 'game_type': 'uno'});
    });

    test('user：昵称 → 用户名 → 用户 回退链', () {
      expect(
        AylaSharePayload.user(id: 'u1', nickname: '爱莉', username: 'elysia').title,
        '爱莉',
      );
      expect(
        AylaSharePayload.user(id: 'u1', nickname: '  ', username: 'elysia').title,
        'elysia',
      );
      expect(AylaSharePayload.user(id: 'u1').title, '用户');
      expect(
        AylaSharePayload.user(id: 'u1', avatar: '/api/v1/media/a/content').cover,
        '/api/v1/media/a/content',
      );
    });

    test('toJson：snake_case 键名，null 字段保留', () {
      final Map<String, Object?> json =
          AylaSharePayload.voice(id: 'v1', name: '电台').toJson();
      expect(json.keys.toSet(), <String>{
        'share_type',
        'target_id',
        'title',
        'cover',
        'subtitle',
        'extra',
      });
      expect(json['share_type'], 'voice');
      expect(json['cover'], isNull);
    });

    test('AylaShareType.parse：未知返回 null（不 fallback）', () {
      expect(AylaShareType.parse('live'), AylaShareType.live);
      expect(AylaShareType.parse('unknown'), isNull);
      expect(AylaShareType.parse(null), isNull);
    });
  });

  // ==================== AylaShareSheet ====================

  group('AylaShareSheet（share.css + ShareSheet.tsx 对照）', () {
    testWidgets('渲染：预览标题 + 两 tab + 群列表，未读 > 99 显示 99+', (WidgetTester tester) async {
      setViewport(tester, const Size(1440, 900));
      await tester.pumpWidget(
        host(
          AylaShareSheet(
            payload: livePayload,
            groups: pageOf(const <AylaShareTarget>[
              AylaShareTarget(id: 'g1', title: '技术群', unreadCount: 3),
              AylaShareTarget(id: 'g2', title: '爱莉之家'),
              AylaShareTarget(id: 'g3', title: '大群', unreadCount: 128),
            ]),
            privates: pageOf(const <AylaShareTarget>[]),
            onClose: () {},
          ),
        ),
      );
      expect(find.text('分享'), findsOneWidget);
      expect(find.text('爱莉的直播间'), findsOneWidget);
      expect(find.text('群聊'), findsOneWidget);
      expect(find.text('私信'), findsOneWidget);
      expect(find.text('技术群'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(find.text('99+'), findsOneWidget);
    });

    testWidgets('群项子群 > 1：展开后可发往指定子群（携带 subgroup_id）', (WidgetTester tester) async {
      setViewport(tester, const Size(1440, 900));
      AylaShareSendRequest? sent;
      await tester.pumpWidget(
        host(
          AylaShareSheet(
            payload: livePayload,
            groups: pageOf(const <AylaShareTarget>[
              AylaShareTarget(id: 'g1', title: '技术群', unreadCount: 3),
            ]),
            privates: pageOf(const <AylaShareTarget>[]),
            onLoadSubgroups: (String id) async => const <AylaShareSubGroup>[
              AylaShareSubGroup(id: '11', name: '默认组', isDefault: true),
              AylaShareSubGroup(id: '12', name: '闲聊'),
            ],
            onSend: (AylaShareSendRequest request) async {
              sent = request;
            },
            onClose: () {},
          ),
        ),
      );
      await tester.tap(find.text('技术群'));
      await tester.pumpAndSettle();
      expect(find.text('默认'), findsOneWidget);
      expect(find.text('闲聊'), findsOneWidget);
      await tester.tap(find.text('闲聊'));
      await tester.pumpAndSettle();
      expect(sent, isNotNull);
      expect(sent!.conversationId, 'g1');
      expect(sent!.subgroupId, 12);
      expect(sent!.content, '[分享]爱莉的直播间');
      expect(sent!.payload.shareType, AylaShareType.live);
    });

    testWidgets('群项子群仅默认组：点击直接发送（subgroup_id 为 null）', (WidgetTester tester) async {
      setViewport(tester, const Size(1440, 900));
      AylaShareSendRequest? sent;
      await tester.pumpWidget(
        host(
          AylaShareSheet(
            payload: livePayload,
            groups: pageOf(const <AylaShareTarget>[
              AylaShareTarget(id: 'g2', title: '爱莉之家'),
            ]),
            privates: pageOf(const <AylaShareTarget>[]),
            onLoadSubgroups: (String id) async => const <AylaShareSubGroup>[
              AylaShareSubGroup(id: '21', name: '默认组', isDefault: true),
            ],
            onSend: (AylaShareSendRequest request) async {
              sent = request;
            },
            onClose: () {},
          ),
        ),
      );
      await tester.tap(find.text('爱莉之家'));
      await tester.pumpAndSettle();
      expect(sent, isNotNull);
      expect(sent!.conversationId, 'g2');
      expect(sent!.subgroupId, isNull);
      expect(sent!.content, '[分享]爱莉的直播间');
    });

    testWidgets('群项已展开：再次点击收起（不再发送）', (WidgetTester tester) async {
      setViewport(tester, const Size(1440, 900));
      int sends = 0;
      await tester.pumpWidget(
        host(
          AylaShareSheet(
            payload: livePayload,
            groups: pageOf(const <AylaShareTarget>[
              AylaShareTarget(id: 'g1', title: '技术群'),
            ]),
            privates: pageOf(const <AylaShareTarget>[]),
            onLoadSubgroups: (String id) async => const <AylaShareSubGroup>[
              AylaShareSubGroup(id: '11', name: '默认组', isDefault: true),
              AylaShareSubGroup(id: '12', name: '闲聊'),
            ],
            onSend: (AylaShareSendRequest request) async {
              sends++;
            },
            onClose: () {},
          ),
        ),
      );
      await tester.tap(find.text('技术群'));
      await tester.pumpAndSettle();
      expect(find.text('闲聊'), findsOneWidget);
      await tester.tap(find.text('技术群'));
      await tester.pumpAndSettle();
      expect(find.text('闲聊'), findsNothing);
      expect(sends, 0);
    });

    testWidgets('私信 tab：对端昵称/用户名回退 + 自己是「我」+ 发送无 subgroup_id',
        (WidgetTester tester) async {
      setViewport(tester, const Size(1440, 900));
      AylaShareSendRequest? sent;
      await tester.pumpWidget(
        host(
          AylaShareSheet(
            payload: livePayload,
            groups: pageOf(const <AylaShareTarget>[]),
            privates: pageOf(const <AylaShareTarget>[
              AylaShareTarget(
                id: 'p1',
                title: '私聊',
                peerId: 'u-2',
                peerNickname: '小汐',
                peerUsername: 'xiaoxi',
              ),
              AylaShareTarget(
                id: 'p2',
                title: '私聊',
                peerId: 'u-3',
                peerUsername: 'no-nickname',
              ),
              AylaShareTarget(id: 'p3', title: '我自己', peerId: 'u-me'),
            ]),
            currentUserId: 'u-me',
            onSend: (AylaShareSendRequest request) async {
              sent = request;
            },
            onClose: () {},
          ),
        ),
      );
      await tester.tap(find.text('私信'));
      await tester.pumpAndSettle();
      expect(find.text('小汐'), findsOneWidget);
      expect(find.text('no-nickname'), findsOneWidget);
      // 两处：头像首字（AvatarHalo label 首字）+ 行标题
      expect(find.text('我'), findsNWidgets(2));
      await tester.tap(find.text('小汐'));
      await tester.pumpAndSettle();
      expect(sent!.conversationId, 'p1');
      expect(sent!.subgroupId, isNull);
      expect(sent!.content, '[分享]爱莉的直播间');
    });

    testWidgets('payload 标题为空：正文回退到目标名', (WidgetTester tester) async {
      setViewport(tester, const Size(1440, 900));
      AylaShareSendRequest? sent;
      await tester.pumpWidget(
        host(
          AylaShareSheet(
            payload: const AylaSharePayload(
              shareType: AylaShareType.group,
              targetId: 'g1',
              title: '',
            ),
            groups: pageOf(const <AylaShareTarget>[
              AylaShareTarget(id: 'g1', title: '技术群'),
            ]),
            privates: pageOf(const <AylaShareTarget>[]),
            onSend: (AylaShareSendRequest request) async {
              sent = request;
            },
            onClose: () {},
          ),
        ),
      );
      expect(find.text('分享'), findsWidgets);
      await tester.tap(find.text('技术群'));
      await tester.pumpAndSettle();
      expect(sent!.content, '[分享]技术群');
    });

    testWidgets('发送失败：错误条出现且不关闭', (WidgetTester tester) async {
      setViewport(tester, const Size(1440, 900));
      bool closed = false;
      await tester.pumpWidget(
        host(
          AylaShareSheet(
            payload: livePayload,
            groups: pageOf(const <AylaShareTarget>[
              AylaShareTarget(id: 'g1', title: '技术群'),
            ]),
            privates: pageOf(const <AylaShareTarget>[]),
            onSend: (AylaShareSendRequest request) async {
              throw Exception('发送失败');
            },
            onClose: () => closed = true,
          ),
        ),
      );
      await tester.tap(find.text('技术群'));
      await tester.pumpAndSettle();
      expect(find.text('发送失败'), findsOneWidget);
      expect(closed, isFalse);
    });

    testWidgets('加载失败态：列表区错误 + 重试按钮', (WidgetTester tester) async {
      setViewport(tester, const Size(1440, 900));
      await tester.pumpWidget(
        host(
          AylaShareSheet(
            payload: livePayload,
            groups: pageOf(const <AylaShareTarget>[], error: '网络不可用'),
            privates: pageOf(const <AylaShareTarget>[]),
            onClose: () {},
          ),
        ),
      );
      expect(find.text('加载失败：网络不可用'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
    });

    testWidgets('空态：暂无群聊 / 暂无私信', (WidgetTester tester) async {
      setViewport(tester, const Size(1440, 900));
      await tester.pumpWidget(
        host(
          AylaShareSheet(
            payload: livePayload,
            groups: pageOf(const <AylaShareTarget>[]),
            privates: pageOf(const <AylaShareTarget>[]),
            onClose: () {},
          ),
        ),
      );
      expect(find.text('暂无群聊'), findsOneWidget);
      await tester.tap(find.text('私信'));
      await tester.pumpAndSettle();
      expect(find.text('暂无私信'), findsOneWidget);
    });

    testWidgets('选项卡复用组件库：shareSheet 档 + 无共享滑动胶囊', (WidgetTester tester) async {
      setViewport(tester, const Size(1440, 900));
      await tester.pumpWidget(
        host(
          AylaShareSheet(
            payload: livePayload,
            groups: pageOf(const <AylaShareTarget>[]),
            privates: pageOf(const <AylaShareTarget>[]),
            onClose: () {},
          ),
        ),
      );
      final AylaSegmentedTabs tabs =
          tester.widget<AylaSegmentedTabs>(find.byType(AylaSegmentedTabs));
      expect(tabs.variant, AylaSegmentedTabsVariant.shareSheet);
      expect(tabs.labels, <String>['群聊', '私信']);
      expect(tabs.index, 0);
      expect(tabs.semanticLabel, '分享目标类型');
      // share.css 63–91 没有 `.auroraqua-nav-highlight` 元素 → 无共享滑动胶囊，
      // 选中底由 `AylaSegmentedTab` 自身静态层提供
      expect(find.byType(AylaNavHighlight), findsNothing);
      await tester.tap(find.text('私信'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<AylaSegmentedTabs>(find.byType(AylaSegmentedTabs)).index,
        1,
      );
    });

    testWidgets('关闭：关闭按钮触发 onClose，且重复关闭只回调一次', (WidgetTester tester) async {
      setViewport(tester, const Size(1440, 900));
      int closes = 0;
      await tester.pumpWidget(
        host(
          AylaShareSheet(
            payload: livePayload,
            groups: pageOf(const <AylaShareTarget>[]),
            privates: pageOf(const <AylaShareTarget>[]),
            onClose: () => closes++,
          ),
        ),
      );
      await tester.tap(find.byType(AylaIconButton));
      expect(closes, 1);
      // web `closedRef`：关闭后不再重复回调
      await tester.tapAt(const Offset(20, 20)); // 卡片外 = 遮罩
      expect(closes, 1);
    });

    testWidgets('关闭：点遮罩触发 onClose', (WidgetTester tester) async {
      setViewport(tester, const Size(1440, 900));
      int closes = 0;
      await tester.pumpWidget(
        host(
          AylaShareSheet(
            payload: livePayload,
            groups: pageOf(const <AylaShareTarget>[]),
            privates: pageOf(const <AylaShareTarget>[]),
            onClose: () => closes++,
          ),
        ),
      );
      await tester.tapAt(const Offset(20, 20)); // 卡片外 = 遮罩
      expect(closes, 1);
    });

    testWidgets('形态：窄屏 60dvh 贴底 / 宽屏 480 居中', (WidgetTester tester) async {
      setViewport(tester, const Size(375, 812));
      await tester.pumpWidget(
        host(
          AylaShareSheet(
            payload: livePayload,
            groups: pageOf(const <AylaShareTarget>[
              AylaShareTarget(id: 'g1', title: '技术群'),
            ]),
            privates: pageOf(const <AylaShareTarget>[]),
            onClose: () {},
          ),
        ),
      );
      final Size narrowSize = tester.getSize(find.byType(AylaModalCard));
      expect(narrowSize.width, closeTo(375, 1.0));
      expect(narrowSize.height, closeTo(812 * 0.6, 1.0));
      expect(
        tester.getTopLeft(find.byType(AylaModalCard)).dy,
        closeTo(812 * 0.4, 1.0),
      );

      setViewport(tester, const Size(1440, 900));
      await tester.pumpWidget(
        host(
          AylaShareSheet(
            payload: livePayload,
            groups: pageOf(const <AylaShareTarget>[
              AylaShareTarget(id: 'g1', title: '技术群'),
            ]),
            privates: pageOf(const <AylaShareTarget>[]),
            onClose: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      final Size wideSize = tester.getSize(find.byType(AylaModalCard));
      expect(wideSize.width, closeTo(480, 1.0));
      expect(
        tester.getCenter(find.byType(AylaModalCard)).dx,
        closeTo(720, 1.0),
      );
    });
  });

  // ==================== AylaShareButton ====================

  group('AylaShareButton', () {
    testWidgets('点击触发回调；语义标签 = label', (WidgetTester tester) async {
      int taps = 0;
      await tester.pumpWidget(
        host(AylaShareButton(label: '分享帖子', onPressed: () => taps++)),
      );
      await tester.tap(find.byType(AylaIconButton));
      expect(taps, 1);
      final AylaIconButton button =
          tester.widget<AylaIconButton>(find.byType(AylaIconButton));
      expect(button.semanticLabel, '分享帖子');
      expect(button.onPressed, isNotNull);
    });

    testWidgets('禁用态：onPressed 为 null', (WidgetTester tester) async {
      await tester.pumpWidget(host(const AylaShareButton(onPressed: null)));
      expect(
        tester.widget<AylaIconButton>(find.byType(AylaIconButton)).onPressed,
        isNull,
      );
    });
  });
}
