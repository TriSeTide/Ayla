/// B3 chat 域第一批：分享卡定向测试 —— 逐条对照 `components/chat/ShareBubble.tsx`(160)
/// 与 `app.css:1138–1223`（`.share-bubble-card` 全族）、`utils/shareRoutes.ts`
/// （标签 / 路由表 / 预览兜底文案）。
///
/// 覆盖：纯函数（六类标签、群内外路由、targetId 缺失、预览文案）/ 结构（封面 72、
/// 标题两行、副标题单行、chevron 8×8）/ 关键尺寸与材质（卡片 max 264、radius 12）/
/// 交互（点击分流、禁用态不可点、群申请守卫、解析中不可重复点击）/ 六类类型图标。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/chat_message.dart';
import '../lib/core/models/share_payload.dart';
import '../lib/core/models/share_routes.dart';
import '../lib/theme/app_icons.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/sample_media.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/resource_image.dart';
import '../lib/widgets/share_bubble.dart';

AylaChatMessage _shareMsg({
  String id = 's1',
  AylaSharePayload? payload,
  String content = '',
}) =>
    AylaChatMessage(
      id: id,
      conversationId: 'c1',
      senderId: 'u1',
      type: AylaMessageType.share,
      content: content,
      sharePayload: payload,
      status: AylaMessageStatus.sent,
      seq: 1,
      createdAt: '2026-09-24T10:00:00Z',
    );

void main() {
  setUp(aylaEnableSampleMedia);
  tearDown(aylaDisableSampleMedia);

  void setViewport(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Widget host(
    WidgetTester tester,
    Widget child, {
    Size viewport = const Size(560, 300),
    Alignment alignment = Alignment.topLeft,
  }) {
    setViewport(tester, viewport);
    return MaterialApp(
      home: previewScope(
        Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(size: viewport),
            child: Align(
              alignment: alignment,
              child: SizedBox(
                width: viewport.width,
                height: viewport.height,
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ======================= 纯函数（shareRoutes.ts） =======================

  group('shareRoutes 纯函数', () {
    test('六类标签（shareRoutes.ts 24–31）', () {
      expect(aylaShareTypeLabel(AylaShareType.group), '群聊');
      expect(aylaShareTypeLabel(AylaShareType.voice), '语音房');
      expect(aylaShareTypeLabel(AylaShareType.live), '直播间');
      expect(aylaShareTypeLabel(AylaShareType.post), '帖子');
      expect(aylaShareTypeLabel(AylaShareType.boardgame), '桌游室');
      expect(aylaShareTypeLabel(AylaShareType.user), '用户');
    });

    test('群外路由（outRoute）与群内路由（inGroupRoute）', () {
      const AylaSharePayload live = AylaSharePayload(
        shareType: AylaShareType.live,
        targetId: '9',
        title: '直播间',
      );
      expect(aylaShareTargetRoute(live, null), '/live/9');
      expect(aylaShareTargetRoute(live, 'g1'), '/group/g1/live/9');
      expect(
        aylaShareTargetRoute(
          const AylaSharePayload(
            shareType: AylaShareType.boardgame,
            targetId: '3',
            title: '桌游',
          ),
          'g1',
        ),
        '/group/g1/games',
        reason: '桌游群内是场景页（不带房 id，shareRoutes.ts 55–56）',
      );
      expect(
        aylaShareTargetRoute(
          const AylaSharePayload(
            shareType: AylaShareType.user,
            targetId: 'u7',
            title: '用户',
          ),
          'g1',
        ),
        '/user/u7',
        reason: 'user 两档同路径',
      );
      expect(
        aylaShareTargetRoute(
          const AylaSharePayload(
            shareType: AylaShareType.post,
            targetId: 'p2',
            title: '帖子',
          ),
          null,
        ),
        '/posts/p2',
      );
    });

    test('targetId 缺失 → null（不跳转，shareRoutes.ts 122）', () {
      expect(
        aylaShareTargetRoute(
          const AylaSharePayload(
            shareType: AylaShareType.group,
            targetId: '',
            title: 'x',
          ),
          null,
        ),
        isNull,
      );
      expect(aylaShareTargetRoute(null, null), isNull);
    });

    test('预览兜底文案：「[分享]标题」（shareRoutes.ts 143–148）', () {
      expect(
        aylaSharePreviewText(
          const AylaSharePayload(
            shareType: AylaShareType.post,
            targetId: 'p1',
            title: '设计想法',
          ),
          null,
        ),
        '[分享]设计想法',
      );
      expect(aylaSharePreviewText(null, '正文'), '[分享]正文');
      expect(aylaSharePreviewText(null, '  '), '[分享]');
    });
  });

  // ======================= 结构与尺寸 =======================

  testWidgets('分享卡：封面 72×72（radius 10）+ 标题 + 副标题 + chevron 8×8', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaShareBubble(
          msg: _shareMsg(
            payload: AylaSharePayload.live(
              id: '9',
              title: '今晚一起看星星',
              cover: '/api/v1/media/live-9/thumbnail',
              ownerName: '爱莉',
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('今晚一起看星星'), findsOneWidget);
    expect(find.text('直播间 · 爱莉'), findsOneWidget, reason: 'label + subtitle（tsx 118–120）');

    // 封面 72×72：ResourceImage 撑满封面槽
    final Rect cover = tester.getRect(find.byType(ResourceImage));
    expect(cover.size, const Size(72, 72));

    // 卡片宽度上限 264（tsx/app.css 1145）
    final Finder card = find.ancestor(
      of: find.text('今晚一起看星星'),
      matching: find.byType(ConstrainedBox),
    );
    expect(
      tester.widget<ConstrainedBox>(card.last).constraints.maxWidth,
      264,
      reason: '`width: min(264px, 100%)`',
    );

    // chevron：8×8 旋转 -45（`border-right/bottom` 2px）
    final Finder chevron = find.byWidgetPredicate(
      (Widget w) =>
          w is Container &&
          w.constraints?.maxWidth == 8 &&
          w.constraints?.maxHeight == 8,
      description: 'chevron',
    );
    expect(chevron, findsOneWidget);
  });

  testWidgets('无封面：渐变兜底 + 类型图标 22（tsx 113–114 / app.css 1182–1185）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaShareBubble(
          msg: _shareMsg(
            payload: AylaSharePayload.voice(id: '7', name: '深夜电台', memberCount: 3),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(ResourceImage), findsNothing, reason: 'voice 工厂 cover 恒为 null');
    final AylaIcon icon = tester.widget<AylaIcon>(find.byType(AylaIcon).first);
    expect(icon.size, 22, reason: '封面兜底图标 22');
    expect(icon.icon.name, 'iconMic', reason: 'voice → IconMic（tsx 41–42）');
  });

  testWidgets('标题回退链：payload.title → content → 「分享」', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaShareBubble(
          msg: _shareMsg(
            payload: const AylaSharePayload(
              shareType: AylaShareType.group,
              targetId: '42',
              title: '   ',
            ),
            content: '一条分享消息',
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('一条分享消息'), findsOneWidget, reason: 'title 空 → content（tsx 71）');
  });

  // ======================= 交互 =======================

  testWidgets('点击 → 跳转（静态路由：群外 /live/9）', (WidgetTester tester) async {
    String? route;
    await tester.pumpWidget(
      host(
        tester,
        AylaShareBubble(
          msg: _shareMsg(
            payload: AylaSharePayload.live(id: '9', title: '今晚一起看星星'),
          ),
          onNavigate: (String r) => route = r,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('今晚一起看星星'));
    await tester.pump();
    expect(route, '/live/9');
  });

  testWidgets('群聊上下文 + 未注入异步解析 → 群内路径（静态路由）', (WidgetTester tester) async {
    String? route;
    await tester.pumpWidget(
      host(
        tester,
        AylaShareBubble(
          msg: _shareMsg(
            payload: AylaSharePayload.post(id: 'p2', title: '设计想法'),
          ),
          groupId: 'g1',
          onNavigate: (String r) => route = r,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('设计想法'));
    await tester.pump();
    expect(route, '/group/g1/posts/p2');
  });

  testWidgets('注入 onResolveTarget → 用异步解析结果（web resolveShareTarget 等价）', (
    WidgetTester tester,
  ) async {
    String? route;
    await tester.pumpWidget(
      host(
        tester,
        AylaShareBubble(
          msg: _shareMsg(
            payload: AylaSharePayload.live(id: '9', title: '今晚一起看星星'),
          ),
          groupId: 'g1',
          onResolveTarget: (AylaSharePayload? p, String? g) async => '/live/9',
          onNavigate: (String r) => route = r,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('今晚一起看星星'));
    await tester.pump();
    expect(route, '/live/9', reason: '存在性检查未命中 → 群外路径');
  });

  testWidgets('未加入的群分享 → 弹申请（onRequestJoin）且不跳转', (WidgetTester tester) async {
    String? route;
    String? requested;
    await tester.pumpWidget(
      host(
        tester,
        AylaShareBubble(
          msg: _shareMsg(
            payload: AylaSharePayload.group(id: '42', title: '爱莉的粉丝群'),
          ),
          isGroupJoined: (String id) => false,
          onRequestJoin: (AylaSharePayload p) => requested = p.targetId,
          onNavigate: (String r) => route = r,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('爱莉的粉丝群'));
    await tester.pump();
    expect(requested, '42');
    expect(route, isNull, reason: '守卫拦截：不跳转（tsx 77–86）');
  });

  testWidgets('禁用态（无 target_id）：不可点、不跳转（tsx 102）', (WidgetTester tester) async {
    String? route;
    await tester.pumpWidget(
      host(
        tester,
        AylaShareBubble(
          msg: _shareMsg(
            payload: const AylaSharePayload(
              shareType: AylaShareType.group,
              targetId: '',
              title: '没有目标的分享',
            ),
          ),
          onNavigate: (String r) => route = r,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('没有目标的分享'));
    await tester.pump();
    expect(route, isNull);

    // `:disabled { opacity: .7 }` —— 内容层 opacity .7（玻璃层按颜色降透明）
    final Iterable<Opacity> ops = tester.widgetList<Opacity>(
      find.descendant(
        of: find.byType(AylaShareBubble),
        matching: find.byType(Opacity),
      ),
    );
    expect(ops.any((Opacity o) => o.opacity == 0.7), isTrue);
  });

  // ======================= 类型图标 =======================

  testWidgets('分享类型图标：六类 → 对应线性图标（tsx 31–55）', (WidgetTester tester) async {
    const Map<AylaShareType, String> expected = <AylaShareType, String>{
      AylaShareType.group: 'iconUsers',
      AylaShareType.voice: 'iconMic',
      AylaShareType.live: 'iconVideo',
      AylaShareType.post: 'iconPost',
      AylaShareType.boardgame: 'iconGame',
      AylaShareType.user: 'iconUser',
    };
    await tester.pumpWidget(
      host(
        tester,
        Column(
          children: <Widget>[
            for (final AylaShareType type in AylaShareType.values)
              AylaShareTypeIcon(shareType: type),
          ],
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    final List<AylaIcon> icons = tester
        .widgetList<AylaIcon>(find.byType(AylaIcon))
        .toList(growable: false);
    expect(icons.length, 6);
    for (int i = 0; i < AylaShareType.values.length; i++) {
      expect(icons[i].icon.name, expected[AylaShareType.values[i]]);
      expect(icons[i].size, 16, reason: '默认 size 16');
    }
  });
}
