/// B3 chat 域第二批：会话列表定向测试 —— 逐条对照
/// `components/chat/ConversationList.tsx`(164) 与 `app.css:490–713`（会话列表族）、
/// `auroraqua.css:169–197`（`has-auroraqua-highlight` 的圆角覆写与选中底取消）、
/// `utils/displayStatus.ts:17–32`（displayStatusOf）。
///
/// 覆盖：纯函数（previewLabel 六档 / displayStatusOf 四档）/ 结构（行/头像/标题/预览/
/// 未读徽标/⋯菜单/空态）/ 关键尺寸（行 padding 12 + padding-right 52、圆角 12、置顶竖条 3px、
/// 状态胶囊 6px 圆点、未读徽标 20×20 字号 12）/ 交互（点行选中、头像导航开关、置顶底色、
/// 选中胶囊 300ms 迁移 + 选中行自身底透明）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/chat_message.dart';
import '../lib/core/models/conversation.dart';
import '../lib/core/models/user_public.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/avatar_halo.dart';
import '../lib/widgets/conversation_list.dart';
import '../lib/widgets/conversation_more_menu.dart';
import '../lib/widgets/primitives.dart' show AylaNavHighlight;
import '../lib/widgets/tab_badge.dart';

AylaConversationSummary _conv({
  String id = 'c1',
  String? title,
  bool group = false,
  String? peerName = '小樱',
  bool online = false,
  String? status,
  int unread = 0,
  int mention = 0,
  bool pinned = false,
  AylaLastMessagePreview? last,
  String? peerId,
}) =>
    AylaConversationSummary(
      id: id,
      type: group ? AylaConversationType.group : AylaConversationType.private,
      title: group ? (title ?? '群聊') : (title ?? ''),
      avatar: group ? '/api/v1/media/conv-$id/thumbnail' : '',
      isPinned: pinned,
      unreadCount: unread,
      mentionUnreadCount: mention,
      lastMessage: last,
      peer: group
          ? null
          : AylaUserPublic(
              id: peerId ?? 'u-$id',
              nickname: peerName,
              username: 'user_$id',
              status: status,
              online: online,
            ),
    );

AylaLastMessagePreview _last(
  String content, {
  AylaMessageType type = AylaMessageType.text,
  String? senderName,
  String? senderId,
  String? preview,
  String status = 'sent',
}) =>
    AylaLastMessagePreview(
      seq: 5,
      type: type,
      content: content,
      senderId: senderId,
      senderName: senderName ?? '',
      status: status,
      preview: preview,
    );

void main() {
  void setViewport(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Widget host(
    WidgetTester tester,
    Widget child, {
    Size viewport = const Size(360, 480),
  }) {
    setViewport(tester, viewport);
    return MaterialApp(
      home: previewTheme(
        Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(size: viewport),
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: viewport.width, child: child),
            ),
          ),
        ),
      ),
    );
  }

  // ======================= 纯函数 =======================

  group('previewLabel / displayStatusOf（tsx 26–52 + displayStatus.ts 17–32）', () {
    test('previewLabel 六档', () {
      expect(aylaConversationPreviewLabel(_conv()), '暂无消息');
      expect(
        aylaConversationPreviewLabel(_conv(last: _last('你好'))),
        '你好',
      );
      expect(
        aylaConversationPreviewLabel(_conv(last: _last('', type: AylaMessageType.image))),
        '[图片]',
      );
      expect(
        aylaConversationPreviewLabel(
          _conv(last: _last('混排摘要', preview: '文本[图片]文本')),
        ),
        '文本[图片]文本',
        reason: '后端 preview 优先于 content（tsx 44）',
      );
      expect(
        aylaConversationPreviewLabel(_conv(last: _last('', status: 'recalled'))),
        '[已撤回]',
      );
      expect(
        aylaConversationPreviewLabel(
          _conv(group: true, last: _last('开播了', senderName: '汐汐', senderId: 'u9')),
        ),
        '汐汐: 开播了',
        reason: '群聊带发送者名前缀（tsx 48–50）',
      );
      expect(
        aylaConversationPreviewLabel(
          _conv(
            group: true,
            last: _last('汐汐 戳了戳 你', type: AylaMessageType.poke, senderName: '汐汐', senderId: 'u9'),
          ),
        ),
        '汐汐 戳了戳 你',
        reason: 'poke 不加发送者前缀（tsx 48）',
      );
    });

    test('displayStatusOf 四档', () {
      expect(aylaDisplayStatusOf('dnd', true), '勿扰');
      expect(aylaDisplayStatusOf('away', false), '离开');
      expect(aylaDisplayStatusOf('invisible', true), '离线');
      expect(aylaDisplayStatusOf('auto', true), '在线');
      expect(aylaDisplayStatusOf(null, false), '离线');
    });
  });

  // ======================= 结构与尺寸 =======================

  testWidgets('行结构：头像 40 + 标题 15/700 + 预览 13 + ⋯ 菜单 + 行 padding', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaConversationList(
          conversations: <AylaConversationSummary>[
            _conv(last: _last('晚上一起看直播吗？')),
          ],
          activeId: null,
          onSelect: (_) {},
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(tester.widget<AvatarHalo>(find.byType(AvatarHalo)).size, 40);
    expect(find.text('小樱'), findsOneWidget);
    expect(find.text('晚上一起看直播吗？'), findsOneWidget);
    expect(find.byType(AylaConversationMoreMenu), findsOneWidget, reason: '⋯ 菜单（tsx 158）');

    // 行 padding 12 / padding-right 52（app.css 500–501）
    final Container row = tester.widget<Container>(
      find.ancestor(of: find.text('小樱'), matching: find.byType(Container)).first,
    );
    expect(
      row.padding,
      const EdgeInsets.fromLTRB(
        AylaSpacing.sp3,
        AylaSpacing.sp3,
        52,
        AylaSpacing.sp3,
      ),
    );
    // 圆角实际 12（auroraqua 172 覆写 app.css 的 16）
    expect(
      (row.decoration! as BoxDecoration).borderRadius,
      BorderRadius.circular(AylaRadii.rInput),
    );
  });

  testWidgets('状态胶囊：文案 + 6px 圆点；在线转 success 色', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaConversationList(
          conversations: <AylaConversationSummary>[
            _conv(id: 'a', peerName: '在线者', online: true, last: _last('hi')),
            _conv(id: 'b', peerName: '勿扰者', status: 'dnd', last: _last('hi')),
          ],
          activeId: null,
          onSelect: (_) {},
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('在线'), findsOneWidget);
    expect(find.text('勿扰'), findsOneWidget);

    // 圆点 6×6 + 颜色（在线 = --success；否则 #b9c6dc）
    final Finder dots = find.byWidgetPredicate(
      (Widget w) =>
          w is Container &&
          w.constraints?.maxWidth == 6 &&
          w.constraints?.maxHeight == 6,
      description: 'status dot',
    );
    expect(dots, findsNWidgets(2));
    final Iterable<Container> containers = tester.widgetList<Container>(dots);
    final List<Color?> colors = <Color?>[
      for (final Container c in containers)
        ((c.decoration! as BoxDecoration).color),
    ];
    expect(colors.contains(AylaColors.success), isTrue, reason: '在线档用 --success');
    expect(colors.contains(const Color(0xFFB9C6DC)), isTrue);
  });

  testWidgets('置顶：左 3px 辉光竖条 + 粉底 + 标题转 grape', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaConversationList(
          conversations: <AylaConversationSummary>[
            _conv(pinned: true, last: _last('置顶会话')),
          ],
          activeId: null,
          onSelect: (_) {},
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    final Container row = tester.widget<Container>(
      find.ancestor(of: find.text('小樱'), matching: find.byType(Container)).first,
    );
    expect(
      (row.decoration! as BoxDecoration).color,
      const Color(0x1AF9B0FF),
      reason: '置顶非选中底 rgba(249,176,255,.1)（app.css 521–523）',
    );
    final Text title = tester.widget<Text>(find.text('小樱'));
    expect(title.style!.color, AylaColors.grape700, reason: '置顶标题转 grape（app.css 541–543）');

    // 竖条：宽 3 + glow-500
    final Finder bar = find.byWidgetPredicate(
      (Widget w) => w is Container && w.constraints?.maxWidth == 3,
      description: 'pin bar',
    );
    expect(bar, findsOneWidget);
    expect(
      (tester.widget<Container>(bar).decoration! as BoxDecoration).color,
      AylaColors.glow500,
    );
  });

  testWidgets('未读徽标：20×20 / utility 12 w500 / pink 底；0 不渲染', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaConversationList(
          conversations: <AylaConversationSummary>[
            _conv(id: 'a', unread: 3, last: _last('hi')),
            _conv(id: 'b', peerName: '无未读', last: _last('hi')),
          ],
          activeId: null,
          onSelect: (_) {},
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('3'), findsOneWidget);
    final TabBadge badge = tester.widget<TabBadge>(find.byType(TabBadge));
    expect(badge.metrics, TabBadgeMetrics.convUnread);
    expect(badge.metrics.minSize, 20);
    expect(badge.metrics.fontSize, 12);
    expect(badge.metrics.fontFamily, AylaFonts.utility);
    expect(badge.metrics.fontWeight, FontWeight.w500);
    expect(
      tester.getSize(find.byType(TabBadge)).height,
      20,
      reason: '`.conv-unread { height: 20px }`（app.css 697）',
    );
  });

  testWidgets('@我 前缀：pink-500 700；无未读 @ 时不渲染', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaConversationList(
          conversations: <AylaConversationSummary>[
            _conv(id: 'a', group: true, mention: 2, last: _last('在吗', senderName: '汐汐', senderId: 'u9')),
            _conv(id: 'b', peerName: '无@', last: _last('hi')),
          ],
          activeId: null,
          onSelect: (_) {},
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('@我'), findsOneWidget);
    final Text mention = tester.widget<Text>(find.text('@我'));
    expect(mention.style!.color, AylaColors.pink500);
    expect(mention.style!.fontWeight, FontWeight.w700);
  });

  testWidgets('空态文案（`.conv-empty`）', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaConversationList(
          conversations: const <AylaConversationSummary>[],
          activeId: null,
          onSelect: (_) {},
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('暂无会话，点击上方「新会话」发起'), findsOneWidget);
  });

  // ======================= 交互 =======================

  testWidgets('点行 → onSelect(id)；私聊头像 → onAvatarTap(peer)', (WidgetTester tester) async {
    String? selected;
    AylaUserPublic? avatarTarget;
    await tester.pumpWidget(
      host(
        tester,
        AylaConversationList(
          conversations: <AylaConversationSummary>[
            _conv(id: 'c9', last: _last('hi')),
          ],
          activeId: null,
          onSelect: (String id) => selected = id,
          onAvatarTap: (AylaUserPublic p) => avatarTarget = p,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.text('hi'));
    await tester.pump();
    expect(selected, 'c9');

    await tester.tap(find.byType(AvatarHalo));
    await tester.pump();
    expect(avatarTarget?.id, 'u-c9');
  });

  testWidgets('disableAvatarNav：头像不可点（不跳个人主页）', (WidgetTester tester) async {
    AylaUserPublic? avatarTarget;
    await tester.pumpWidget(
      host(
        tester,
        AylaConversationList(
          conversations: <AylaConversationSummary>[_conv(last: _last('hi'))],
          activeId: null,
          disableAvatarNav: true,
          onSelect: (_) {},
          onAvatarTap: (AylaUserPublic p) => avatarTarget = p,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.widget<AvatarHalo>(find.byType(AvatarHalo)).onTap, isNull);
    expect(avatarTarget, isNull);
  });

  testWidgets('选中胶囊：选中行自身底透明 + 胶囊尺寸 = 行矩形（300ms 迁移）', (
    WidgetTester tester,
  ) async {
    String active = 'a';
    late StateSetter setLocal;
    await tester.pumpWidget(
      host(
        tester,
        StatefulBuilder(
          builder: (BuildContext context, StateSetter setter) {
            setLocal = setter;
            return AylaConversationList(
              conversations: <AylaConversationSummary>[
                _conv(id: 'a', peerName: '甲', last: _last('第一条')),
                _conv(id: 'b', peerName: '乙', last: _last('第二条')),
              ],
              activeId: active,
              onSelect: (_) {},
            );
          },
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50)); // 等 postFrame 测量

    expect(find.byType(AylaNavHighlight), findsOneWidget, reason: '容器级单实例胶囊（tsx 109）');
    final Rect first = tester.getRect(find.byType(AylaNavHighlight));
    final Rect rowA = tester.getRect(
      find.ancestor(of: find.text('第一条'), matching: find.byType(Container)).first,
    );
    expect(first.top, moreOrLessEquals(rowA.top, epsilon: 0.5));
    expect(first.height, moreOrLessEquals(rowA.height, epsilon: 0.5));

    // 选中行自身底透明（auroraqua 194–197）
    final Container activeRow = tester.widget<Container>(
      find.ancestor(of: find.text('第一条'), matching: find.byType(Container)).first,
    );
    expect((activeRow.decoration! as BoxDecoration).color, isNull);

    // 切换选中 → 胶囊迁移到第二行（300ms）
    setLocal(() => active = 'b');
    await tester.pump(); // 重建（didUpdateWidget 当帧重测）
    await tester.pump(const Duration(milliseconds: 400)); // 走完 300ms 迁移
    final Rect second = tester.getRect(find.byType(AylaNavHighlight));
    final Rect rowB = tester.getRect(
      find.ancestor(of: find.text('第二条'), matching: find.byType(Container)).first,
    );
    expect(second.top, moreOrLessEquals(rowB.top, epsilon: 0.5));
    expect(second.top, greaterThan(first.top));
  });
}
