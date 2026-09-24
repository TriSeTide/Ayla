/// B3 chat 第三批：消息滚动区定向测试 —— 对照 `MessageList.tsx`（1125 行）
/// 与 `app.css` 795–1037。
///
/// 覆盖：纯函数（时间格式 / 5 分钟分组 / 戳一戳文案 / 段预览 / 引用预览）/
/// 时间分隔 / 戳一戳胶囊 / 空态 / 历史控制 / 回底键显隐 / 跳转标签（未读·@我·回复）与
/// 点击批量已读 / 贴底跟随 / reverse 顺序（最新在下）/ 引用文案传气泡。
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/chat_message.dart';
import '../lib/core/models/conversation.dart';
import '../lib/core/models/user_public.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/sample_media.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/message_bubble.dart';
import '../lib/widgets/message_list.dart';

AylaChatMessage _msg({
  required String id,
  required int seq,
  required String senderId,
  String content = '',
  AylaMessageType type = AylaMessageType.text,
  AylaMessageStatus status = AylaMessageStatus.sent,
  DateTime? at,
  List<AylaMediaSegment> segments = const <AylaMediaSegment>[],
  String? replyTo,
}) =>
    AylaChatMessage(
      id: id,
      conversationId: 'c1',
      senderId: senderId,
      type: type,
      content: content,
      status: status,
      seq: seq,
      createdAt: (at ?? DateTime(2026, 9, 24, 21, 30)).toUtc().toIso8601String(),
      segments: segments,
      replyTo: replyTo,
    );

AylaConversationSummary _conv({bool group = true}) => AylaConversationSummary(
      id: 'c1',
      type: group ? AylaConversationType.group : AylaConversationType.private,
      title: group ? '深夜电台群' : '',
      avatar: '',
      members: <AylaConversationMember>[
        AylaConversationMember(
          id: 'm1',
          user: const AylaUserPublic(id: 'u1', nickname: '汐汐', username: 'xixi'),
        ),
      ],
      peer: group
          ? null
          : const AylaUserPublic(id: 'u2', nickname: '小樱', username: 'sakura'),
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
    Size viewport = const Size(720, 420),
  }) {
    setViewport(tester, viewport);
    return MaterialApp(
      home: previewTheme(
        Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(size: viewport),
            child: SizedBox(
              width: viewport.width,
              height: viewport.height,
              child: child,
            ),
          ),
        ),
      ),
    );
  }

  // ======================= 纯函数 =======================

  group('纯函数（tsx 24–76 / utils/segment.ts）', () {
    test('时间格式：`YYYY-MM-DD HH:mm`；无效返回空串', () {
      // 用本地时区构造再转 UTC，保证断言与实现同源
      final String iso = DateTime(2026, 9, 24, 21, 5).toUtc().toIso8601String();
      expect(aylaMessageListTime(iso), '2026-09-24 21:05');
      expect(aylaMessageListTime('bogus'), '');
    });

    test('5 分钟分组：首条必分组；间隔 > 5 分钟分组', () {
      final DateTime base = DateTime(2026, 9, 24, 21, 0);
      final AylaChatMessage a = _msg(id: 'a', seq: 1, senderId: 'u1', at: base);
      final AylaChatMessage b = _msg(
        id: 'b',
        seq: 2,
        senderId: 'u1',
        at: base.add(const Duration(minutes: 4, seconds: 59)),
      );
      final AylaChatMessage c = _msg(
        id: 'c',
        seq: 3,
        senderId: 'u1',
        at: base.add(const Duration(minutes: 5, seconds: 1)),
      );
      expect(aylaShouldGroup(null, a), isTrue);
      expect(aylaShouldGroup(a, b), isFalse);
      expect(aylaShouldGroup(a, c), isTrue);
    });

    test('戳一戳文案：自己归一为「我」；缺名回退对端名', () {
      final Map<String, String> names = <String, String>{'u1': '汐汐'};
      final AylaChatMessage m = _msg(
        id: 'p',
        seq: 1,
        senderId: 'u1',
        content: 'u2',
        type: AylaMessageType.poke,
      );
      expect(aylaPokeLabel(m, names, 'me', '小樱'), '汐汐戳了戳小樱');
      // 发送者是自己
      final AylaChatMessage self = _msg(
        id: 'p2',
        seq: 2,
        senderId: 'me',
        content: 'u2',
        type: AylaMessageType.poke,
      );
      expect(aylaPokeLabel(self, names, 'me', '小樱'), '我戳了戳小樱');
      // 目标是当前用户
      final AylaChatMessage toMe = _msg(
        id: 'p3',
        seq: 3,
        senderId: 'u1',
        content: 'me',
        type: AylaMessageType.poke,
      );
      expect(aylaPokeLabel(toMe, names, 'me', '小樱'), '汐汐戳了戳我');
    });

    test('段预览：仅 image/video 有专名，mention → @昵称', () {
      expect(aylaSegmentPreview(const <AylaMediaSegment>[]), isNull);
      expect(
        aylaSegmentPreview(const <AylaMediaSegment>[
          AylaMediaSegment(type: AylaSegmentType.text, text: '看图'),
          AylaMediaSegment(type: AylaSegmentType.image, mediaId: 'm'),
          AylaMediaSegment(type: AylaSegmentType.video, mediaId: 'v'),
          AylaMediaSegment(type: AylaSegmentType.mention, userId: 'u1', name: '汐汐'),
        ]),
        '看图[图片][视频]@汐汐',
      );
    });

    test('引用预览：text 用 content（空则「…」）；非 text 用段预览再按类型兜底', () {
      expect(aylaQuotePreview(_msg(id: 'a', seq: 1, senderId: 'u1', content: 'hi')), 'hi');
      expect(aylaQuotePreview(_msg(id: 'b', seq: 2, senderId: 'u1')), '…');
      expect(
        aylaQuotePreview(_msg(
          id: 'c',
          seq: 3,
          senderId: 'u1',
          type: AylaMessageType.voice,
        )),
        '[语音]',
      );
      expect(
        aylaQuotePreview(_msg(
          id: 'd',
          seq: 4,
          senderId: 'u1',
          type: AylaMessageType.image,
        )),
        '[图片]',
      );
    });
  });

  // ======================= 渲染 =======================

  testWidgets('时间分隔：跨 5 分钟出现（utility 12）；同段内不出现', (WidgetTester tester) async {
    final DateTime base = DateTime(2026, 9, 24, 21, 0);
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageList(
          messages: <AylaChatMessage>[
            _msg(id: 'a', seq: 1, senderId: 'u1', content: '早', at: base),
            _msg(id: 'b', seq: 2, senderId: 'u1', content: '早2',
                at: base.add(const Duration(minutes: 1))),
            _msg(id: 'c', seq: 3, senderId: 'u1', content: '晚',
                at: base.add(const Duration(minutes: 30))),
          ],
          conversation: _conv(),
          currentUserId: 'me',
        ),
        viewport: const Size(720, 600),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    // 两条分隔（首条 + 第三条跨段），文案 = 各自的本地时间
    final Iterable<Text> texts = tester.widgetList<Text>(find.byType(Text));
    final List<String> timeLabels = <String>[
      for (final Text t in texts)
        if (t.style?.fontFamily == AylaFonts.utility &&
            t.style?.fontSize == 12 &&
            (t.data ?? '').contains('2026-09-24'))
          t.data!,
    ];
    expect(timeLabels.length, 2, reason: '首条 + 跨段各一条');
    // reverse 列表在树中的顺序与时间序相反（最新在前），故只断言集合
    expect(
      timeLabels,
      containsAll(<String>['2026-09-24 21:00', '2026-09-24 21:30']),
    );
  });

  testWidgets('戳一戳：居中胶囊文案（非气泡）', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageList(
          messages: <AylaChatMessage>[
            _msg(
              id: 'p',
              seq: 1,
              senderId: 'u1',
              content: 'me',
              type: AylaMessageType.poke,
            ),
          ],
          conversation: _conv(),
          currentUserId: 'me',
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('汐汐戳了戳我'), findsOneWidget);
    expect(find.byType(AylaMessageBubble), findsNothing, reason: '戳一戳不是气泡');
  });

  testWidgets('reverse 顺序：最新消息在最下（y 最大）；空态文案', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageList(
          messages: <AylaChatMessage>[
            _msg(id: 'a', seq: 1, senderId: 'u1', content: '第一条'),
            _msg(id: 'b', seq: 2, senderId: 'u1', content: '第二条'),
          ],
          conversation: _conv(),
          currentUserId: 'me',
        ),
        viewport: const Size(720, 600),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      tester.getBottomLeft(find.text('第二条')).dy,
      greaterThan(tester.getBottomLeft(find.text('第一条')).dy),
      reason: 'reverse 列表：最新在底部',
    );
  });

  testWidgets('空态文案', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageList(
          messages: const <AylaChatMessage>[],
          conversation: _conv(group: false),
          currentUserId: 'me',
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('还没有消息，说点什么吧'), findsOneWidget);
  });

  testWidgets('历史控制：hasMore 显示「加载更早消息」，点击触发 onLoadMore', (WidgetTester tester) async {
    int loads = 0;
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageList(
          messages: <AylaChatMessage>[
            _msg(id: 'a', seq: 1, senderId: 'u1', content: '旧'),
          ],
          conversation: _conv(),
          currentUserId: 'me',
          hasMore: true,
          onLoadMore: () async => loads++,
        ),
        viewport: const Size(720, 600),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('加载更早消息'), findsOneWidget);

    await tester.tap(find.text('加载更早消息'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(loads, 1);
  });

  testWidgets('引用文案：replyTo 命中预览表，未命中回退「引用的消息」', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageList(
          messages: <AylaChatMessage>[
            _msg(id: 'a', seq: 1, senderId: 'u1', content: '被引用的正文'),
            _msg(id: 'b', seq: 2, senderId: 'me', content: '回复', replyTo: 'a'),
            _msg(id: 'c', seq: 3, senderId: 'me', content: '悬空引用', replyTo: 'zzz'),
          ],
          conversation: _conv(),
          currentUserId: 'me',
        ),
        viewport: const Size(720, 800),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('被引用的正文'), findsWidgets, reason: '命中预览表');
    expect(find.text('引用的消息'), findsOneWidget, reason: '悬空引用兜底');
  });

  // ======================= 回底键与贴底跟随 =======================

  testWidgets('回底键：贴底时隐藏（opacity 0）；滚远超过一屏后显示', (WidgetTester tester) async {
    final DateTime base = DateTime(2026, 9, 24, 21, 0);
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageList(
          messages: <AylaChatMessage>[
            for (int i = 0; i < 20; i++)
              _msg(
                id: 'm$i',
                seq: i + 1,
                senderId: i.isEven ? 'u1' : 'me',
                content: '第 $i 行消息内容，用于撑高列表',
                at: base.add(Duration(minutes: i)),
              ),
          ],
          conversation: _conv(),
          currentUserId: 'me',
        ),
        viewport: const Size(720, 360),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    // 回底键的 AnimatedOpacity（气泡内部也有 AnimatedOpacity ⇒ 用件自带的 key）
    final Finder jumpBtn = find.byKey(const ValueKey<String>('message-jump-bottom'));
    double opacity() => tester.widget<AnimatedOpacity>(jumpBtn).opacity;
    expect(opacity(), 0, reason: '初始贴底（reverse offset 0）');

    // reverse 列表：手指**向下**拖 = 内容下移 = 看到更早（offset 从 0 增大）
    await tester.drag(find.byType(ListView), const Offset(0, 900));
    await tester.pump(const Duration(milliseconds: 100));
    expect(opacity(), 1, reason: '距底超过一屏 ⇒ `is-visible`');

    // 点回底键 → 回到 offset 0（用件自带 key 定位：测试默认不开语义树，不宜依赖语义标签）
    await tester.tap(jumpBtn);
    await tester.pump(); // 处理点击
    await tester.pump(const Duration(milliseconds: 350)); // 走完 300ms 回底动画
    final ScrollableState after = tester
        .state<ScrollableState>(find.byType(Scrollable).first);
    expect(after.position.pixels, 0, reason: '回底键把偏移拉回 0');
    expect(opacity(), 0, reason: '回底后隐藏');
  });

  testWidgets('贴底跟随：贴底时新增消息仍贴底（offset 保持 0）', (WidgetTester tester) async {
    final DateTime base = DateTime(2026, 9, 24, 21, 0);
    late StateSetter setLocal;
    List<AylaChatMessage> messages = <AylaChatMessage>[
      _msg(id: 'a', seq: 1, senderId: 'u1', content: '一', at: base),
    ];
    await tester.pumpWidget(
      host(
        tester,
        StatefulBuilder(
          builder: (BuildContext context, StateSetter setter) {
            setLocal = setter;
            return AylaMessageList(
              messages: messages,
              conversation: _conv(),
              currentUserId: 'me',
            );
          },
        ),
        viewport: const Size(720, 600),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    setLocal(() {
      messages = <AylaChatMessage>[
        ...messages,
        _msg(
          id: 'b',
          seq: 2,
          senderId: 'u2',
          content: '二',
          at: base.add(const Duration(minutes: 1)),
        ),
      ];
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final ScrollableState scrollable =
        tester.state<ScrollableState>(find.byType(Scrollable).first);
    expect(scrollable.position.pixels, 0, reason: '贴底跟随：仍贴底');
    expect(find.text('二'), findsOneWidget);
  });

  // ======================= 跳转标签 =======================

  testWidgets('跳转标签：未读标签文案 + 点击批量已读到该 seq', (WidgetTester tester) async {
    int? throughSeq;
    List<String>? excludeIds;
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageList(
          messages: <AylaChatMessage>[
            _msg(id: 'a', seq: 1, senderId: 'u1', content: '一'),
            _msg(id: 'b', seq: 2, senderId: 'u2', content: '二'),
          ],
          conversation: _conv(group: false),
          currentUserId: 'me',
          unreadSeqs: const <int>[1],
          onMarkRead: (_, __) async {},
          onMarkConversationRead: (int seq, List<String> exclude) async {
            throughSeq = seq;
            excludeIds = exclude;
          },
        ),
        viewport: const Size(720, 600),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('1 条新消息'), findsOneWidget);
    await tester.tap(find.text('1 条新消息'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(throughSeq, 1, reason: '普通未读标签：批量标记到该 seq');
    expect(excludeIds, isEmpty, reason: '无特殊未读 ⇒ 排除列表为空');
  });

  testWidgets('跳转标签：@我 与 回复标签各自文案（特殊未读不回退到未读标签）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageList(
          messages: <AylaChatMessage>[
            _msg(id: 'a', seq: 1, senderId: 'u1', content: '一'),
            _msg(id: 'b', seq: 2, senderId: 'u2', content: '二'),
          ],
          conversation: _conv(group: false),
          currentUserId: 'me',
          mentionUnreadSeqs: const <int>[1],
          replyUnreadSeqs: const <int>[2],
          onMarkRead: (_, __) async {},
          onMarkConversationRead: (_, __) async {},
        ),
        viewport: const Size(720, 600),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('@我 1'), findsOneWidget);
    expect(find.text('回复 1'), findsOneWidget);
    expect(find.text('1 条新消息'), findsNothing, reason: '无普通未读序号 ⇒ 不出现未读标签');
  });

  testWidgets('跳转高亮：只在形状之外画环，不把整行填实（CSS box-shadow 语义）', (
    WidgetTester tester,
  ) async {
    // 用户实报「跳转提示是一整块」的回归锁：Flutter 的 `BoxDecoration(boxShadow:)`
    // 会连形状内部一起铺（CSS 的 box-shadow 不画在 border-box 内）⇒ 必须用
    // `AylaGlassShadow.ring`（自绘「只画形状之外」）。本用例逐像素采样高亮行内部。
    setViewport(tester, const Size(720, 400));
    final GlobalKey boundaryKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: previewTheme(
          RepaintBoundary(
            key: boundaryKey,
            child: SizedBox(
              width: 720,
              height: 400,
              child: AylaMessageList(
                messages: <AylaChatMessage>[
                  _msg(id: 'a', seq: 1, senderId: 'u2', content: '睡了吗？'),
                  _msg(id: 'b', seq: 2, senderId: 'me', content: '还没，在写文档'),
                ],
                conversation: _conv(group: false),
                currentUserId: 'me',
                unreadSeqs: const <int>[1],
                onMarkRead: (_, __) async {},
                onMarkConversationRead: (_, __) async {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('1 条新消息'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200)); // 高亮最强的阶段

    // 高亮行的**内部**（行内右侧空白：x = 行宽 - 120）不应被填成粉色
    final RenderRepaintBoundary boundary =
        boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    ByteData? bytes;
    await tester.runAsync(() async {
      final ui.Image image = await boundary.toImage();
      bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    });
    final ByteData data = bytes!;
    const int width = 720;
    int alpha(int x, int y) => data.getUint8((y * width + x) * 4 + 3);
    int red(int x, int y) => data.getUint8((y * width + x) * 4);
    int green(int x, int y) => data.getUint8((y * width + x) * 4 + 1);
    int blue(int x, int y) => data.getUint8((y * width + x) * 4 + 2);

    // 采样「高亮行的行内空白区」（x 560–660：气泡只占左侧，这里在修好前会被填成实心粉）
    final Rect rowRect = tester.getRect(find.text('睡了吗？'));
    final int y0 = rowRect.top.round() + 4;
    final int y1 = rowRect.bottom.round() + 4;
    int pinkish = 0;
    for (int y = y0; y <= y1; y += 6) {
      for (int x = 560; x <= 660; x += 20) {
        final int r = red(x, y);
        final int g = green(x, y);
        final int b = blue(x, y);
        // 透明像素 rgba = 0,0,0,0 ⇒ 不会命中；命中即「内部被填粉」
        if (r > 225 && g < 190 && b > 235) pinkish++;
      }
    }
    expect(pinkish, 0, reason: '高亮行内部不得被填成实心粉（只允许形状之外有环）');
  });
}
