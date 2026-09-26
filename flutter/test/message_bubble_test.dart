/// B3 chat 域第一批：消息气泡定向测试 —— 逐条对照
/// `components/chat/MessageBubble.tsx`(377) 与 `app.css:1041–1102 / 1104–1136 /
/// 1225–1250 / 1261–1285 / 1287–1322 / 1335–1360`、`auroraqua.css:54–94 / 124–166`、
/// `base.css:426–434`（frost-rise）。
///
/// 覆盖：结构（行/头像/发送者名/气泡/时间/操作栏）/ 关键尺寸（头像 32、气泡 padding 10/14、
/// radius 18+6 小角、body max 75% 与窄屏 84%）/ 三态材质 / 撤回态退化 / 交互
/// （头像单击延迟与双击、长按 @、引用与撤回键、触屏点行、发送态三档）/ 到达动画中间帧 /
/// 纯函数（timeAgo / canRecall）。
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/chat_message.dart';
import '../lib/core/models/media_kind.dart';
import '../lib/core/models/post.dart' show AylaMediaDescriptor;
import '../lib/theme/preview_theme.dart';
import '../lib/theme/sample_media.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/base/avatar_halo.dart';
import '../lib/widgets/base/directory_controls.dart' show AylaFavoriteButton;
import '../lib/widgets/chat/message_bubble.dart';
import '../lib/widgets/base/resource_image.dart';

AylaChatMessage _msg({
  String id = 'm1',
  AylaMessageType type = AylaMessageType.text,
  String content = '晚上一起看直播吗？我这边刚开播。',
  String senderId = 'u1',
  AylaMessageStatus status = AylaMessageStatus.sent,
  String? createdAt,
  bool pending = false,
  bool sendFailed = false,
  double? uploadProgress,
  AylaMediaDescriptor? media,
}) {
  return AylaChatMessage(
    id: id,
    conversationId: 'c1',
    senderId: senderId,
    type: type,
    content: content,
    mediaId: media?.mediaId,
    media: media,
    status: status,
    seq: 1,
    createdAt: createdAt ??
        DateTime.now().subtract(const Duration(minutes: 3)).toUtc().toIso8601String(),
    pending: pending,
    sendFailed: sendFailed,
    uploadProgress: uploadProgress,
  );
}

void main() {
  setUp(aylaDisableSampleMedia);
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

  // ======================= 纯函数 =======================

  group('timeAgo / canRecall（tsx 24–44）', () {
    final DateTime now = DateTime.utc(2026, 9, 24, 12, 30, 0);

    test('timeAgo 三档：刚刚 / N 分钟前 / HH:mm', () {
      expect(
        aylaMessageTimeAgo(now.subtract(const Duration(seconds: 30)).toIso8601String(), now: now),
        '刚刚',
      );
      expect(
        aylaMessageTimeAgo(now.subtract(const Duration(minutes: 5)).toIso8601String(), now: now),
        '5 分钟前',
      );
      final DateTime older = DateTime(2026, 9, 24, 9, 5);
      expect(aylaMessageTimeAgo(older.toIso8601String(), now: now), '09:05');
      expect(aylaMessageTimeAgo('not-a-date', now: now), '');
    });

    test('canRecall：仅自己 + 未撤回 + 120s 内', () {
      final AylaChatMessage mine = _msg(
        senderId: 'me',
        createdAt: now.subtract(const Duration(seconds: 120)).toIso8601String(),
      );
      expect(aylaCanRecall(mine, 'me', now: now), isTrue, reason: '整 120s 仍可撤回');
      expect(aylaCanRecall(mine, 'other', now: now), isFalse, reason: '非自己');
      expect(
        aylaCanRecall(
          _msg(
            senderId: 'me',
            createdAt: now.subtract(const Duration(seconds: 121)).toIso8601String(),
          ),
          'me',
          now: now,
        ),
        isFalse,
        reason: '超过窗口',
      );
      expect(
        aylaCanRecall(
          _msg(senderId: 'me', status: AylaMessageStatus.recalled),
          'me',
          now: now,
        ),
        isFalse,
        reason: '已撤回',
      );
    });
  });

  // ======================= 结构与尺寸 =======================

  testWidgets('他人消息：头像 32 + 发送者名 + 气泡 padding 10/14 + 圆角左小角 + 时间', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageBubble(
          msg: _msg(),
          isSelf: false,
          senderName: '小樱',
          senderAvatarLabel: '樱',
          senderOnline: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 头像（`AylaAvatarHalo(size: 32)`，光环外径 = size + 2×2.5）
    final AylaAvatarHalo halo = tester.widget<AylaAvatarHalo>(find.byType(AylaAvatarHalo));
    expect(halo.size, 32);
    expect(halo.online, isTrue);
    expect(find.text('小樱'), findsOneWidget);

    // 气泡：padding 10/14（量文本相对气泡裁剪层的位移）
    final Rect text = tester.getRect(find.text('晚上一起看直播吗？我这边刚开播。'));
    final ClipRRect bubble = tester.widget<ClipRRect>(find.byType(ClipRRect).first);
    final Rect bubbleRect = tester.getRect(find.byType(ClipRRect).first);
    expect(text.left - bubbleRect.left, 14, reason: 'padding 左右 14（app.css 1106）');
    expect(bubbleRect.bottom - text.bottom, 10, reason: 'padding 上下 10（app.css 1106）');

    // 圆角：他人消息 `18 18 18 6`（左下 6）
    final BorderRadius radius = bubble.borderRadius as BorderRadius;
    expect(radius.topLeft.x, AylaRadii.rBubble);
    expect(radius.bottomLeft.x, 6, reason: '左下小角（app.css 1135）');
    expect(radius.bottomRight.x, AylaRadii.rBubble);

    // 时间（3 分钟前 → 「3 分钟前」）
    expect(find.text('3 分钟前'), findsOneWidget);
  });

  testWidgets('自己消息：整体置右（头像在最右）、气泡右下小角', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageBubble(
          msg: _msg(senderId: 'me', content: '好呀，我这就来'),
          isSelf: true,
          senderAvatarLabel: '我',
          currentUserId: 'me',
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 气泡 = 正文的最近 ClipRRect 祖先（工具栏里有 `AylaMsgActionButton` 自己的 ClipRRect，
    // 不能再拿 `find.byType(ClipRRect).first`）
    final Finder bubbleFinder = find
        .ancestor(
          of: find.text('好呀，我这就来'),
          matching: find.byType(ClipRRect),
        )
        .first;

    final double haloCenter = tester.getCenter(find.byType(AylaAvatarHalo)).dx;
    final double bubbleCenter = tester.getCenter(bubbleFinder).dx;
    expect(haloCenter, greaterThan(bubbleCenter), reason: '自己行 `row-reverse`（app.css 1069–1071）');

    // 置右：自己消息的气泡中心必须在行中线右侧（用户 2026-09-24 实报「没有置右」）
    final Rect row = tester.getRect(find.byType(AylaMessageBubble));
    expect(
      bubbleCenter,
      greaterThan(row.center.dx),
      reason: '`flex-direction: row-reverse` 把主轴起点移到右侧 ⇒ 内容整体靠右',
    );

    final BorderRadius radius =
        tester.widget<ClipRRect>(bubbleFinder).borderRadius as BorderRadius;
    expect(radius.bottomRight.x, 6, reason: '自己的右下小角（app.css 1117）');
    expect(radius.bottomLeft.x, AylaRadii.rBubble);
  });

  testWidgets('爱莉消息：樱粉渐变 + 1px rgba(247,150,255,.5) 描边 + 左下小角', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageBubble(
          msg: _msg(content: '我在的～', senderId: 'elysia'),
          isSelf: false,
          isElysia: true,
          senderName: '爱莉',
          senderAvatarLabel: '爱莉',
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 渐变底（独立层）
    final Iterable<DecoratedBox> boxes =
        tester.widgetList<DecoratedBox>(find.byType(DecoratedBox));
    final bool hasElysiaGradient = boxes.any((DecoratedBox b) {
      final Decoration d = b.decoration;
      return d is BoxDecoration &&
          d.gradient is LinearGradient &&
          (d.gradient! as LinearGradient).colors.first == AylaColors.sakura100;
    });
    expect(hasElysiaGradient, isTrue, reason: '--bubble-elysia 渐变（app.css 1122）');

    // 描边
    final bool hasBorder = boxes.any((DecoratedBox b) {
      final Decoration d = b.decoration;
      return d is BoxDecoration &&
          d.border is Border &&
          (d.border! as Border).top.color == AylaColors.elysiaBubbleBorder;
    });
    expect(hasBorder, isTrue, reason: '1px rgba(247,150,255,.5)（app.css 1124）');

    final BorderRadius radius =
        tester.widget<ClipRRect>(find.byType(ClipRRect).first).borderRadius as BorderRadius;
    expect(radius.bottomLeft.x, 6, reason: '爱莉左下小角（app.css 1125）');
  });

  testWidgets('撤回态：气泡退化为 other 样式（无渐变）+ opacity .6 + 文案', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageBubble(
          msg: _msg(status: AylaMessageStatus.recalled, senderId: 'me'),
          isSelf: true,
          senderAvatarLabel: '我',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('你撤回了一条消息'), findsOneWidget, reason: '自己撤回的文案（tsx 355）');
    // 撤回态不显示头像（tsx 220–221）
    expect(find.byType(AylaAvatarHalo), findsNothing);

    // ⚠️ 有意偏离 web：web 是 `font-style: italic`（app.css 1227），但中文无真斜体变体
    // ⇒ Flutter 合成斜体倾角明显更大（用户 2026-09-24 实报「过于斜」）⇒ 只保留 opacity 弱化。
    final DefaultTextStyle recalledStyle = tester
        .widgetList<DefaultTextStyle>(find.descendant(
          of: find.byType(AylaMessageBubble),
          matching: find.byType(DefaultTextStyle),
        ))
        .firstWhere((DefaultTextStyle s) => s.style.fontSize == 15);
    expect(recalledStyle.style.fontStyle, FontStyle.normal, reason: '不叠斜体（用户实报）');

    // `.bubble.recalled { opacity: .6 }`：内容层 opacity
    final Iterable<Opacity> ops = tester.widgetList<Opacity>(find.byType(Opacity));
    expect(ops.any((Opacity o) => o.opacity == 0.6), isTrue);

    // 退化为 other（有玻璃底而非 self 渐变）——范围收紧到组件内（宿主极光底也有渐变）
    final Iterable<DecoratedBox> boxes = tester.widgetList<DecoratedBox>(
      find.descendant(
        of: find.byType(AylaMessageBubble),
        matching: find.byType(DecoratedBox),
      ),
    );
    expect(
      boxes.any((DecoratedBox b) =>
          b.decoration is BoxDecoration &&
          (b.decoration as BoxDecoration).color == AylaColors.bubbleOther),
      isTrue,
    );
    expect(
      boxes.any((DecoratedBox b) =>
          b.decoration is BoxDecoration &&
          (b.decoration as BoxDecoration).gradient != null),
      isFalse,
      reason: '撤回态不带渐变（tsx 210–216 用 bubble-other）',
    );
  });

  testWidgets('系统消息：无头像、无操作栏、无引用条', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageBubble(
          msg: _msg(type: AylaMessageType.system, content: '小樱 加入了群聊'),
          isSelf: false,
          senderName: '小樱',
          senderAvatarLabel: '樱',
          onQuote: (_) {},
          onRecall: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('小樱 加入了群聊'), findsOneWidget);
    expect(find.byType(AylaAvatarHalo), findsNothing);
    expect(find.byType(AylaFavoriteButton), findsNothing, reason: '系统消息无操作栏（tsx 244）');
    expect(find.text('引用'), findsNothing);
  });

  testWidgets('引用条：左 3px --ice-500 竖条 + 文案 + 点击定位原消息', (WidgetTester tester) async {
    int jumps = 0;
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageBubble(
          msg: _msg(),
          isSelf: false,
          senderAvatarLabel: '樱',
          quoteText: '那我先去占个位置',
          onQuoteJump: (_) => jumps++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('那我先去占个位置'), findsOneWidget);
    // 左竖条：3px 宽的 ice-500 色条（`Positioned` + `ColoredBox`）
    final Iterable<ColoredBox> bars = tester.widgetList<ColoredBox>(
      find.descendant(
        of: find.byType(AylaMessageBubble),
        matching: find.byType(ColoredBox),
      ),
    );
    expect(
      bars.any((ColoredBox c) => c.color == AylaColors.ice500),
      isTrue,
      reason: 'border-left 3px --ice-500（app.css 1266）',
    );
    expect(
      tester.getRect(find.byWidgetPredicate(
        (Widget w) => w is ColoredBox && w.color == AylaColors.ice500,
      )).width,
      3,
      reason: '竖条宽 3px',
    );

    await tester.tap(find.text('那我先去占个位置'));
    await tester.pump();
    expect(jumps, 1);
  });

  testWidgets('图片消息：气泡紧贴媒体、右侧不留空白（用户 2026-09-24 实报）', (
    WidgetTester tester,
  ) async {
    aylaEnableSampleMedia();
    addTearDown(aylaDisableSampleMedia);
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageBubble(
          msg: _msg(
            type: AylaMessageType.image,
            media: AylaMediaDescriptor(
              mediaId: 'm-img',
              kind: AylaMediaKind.image,
              mimeType: 'image/png',
              size: 240000,
              width: 640,
              height: 480,
              thumbnail: '/api/v1/media/m-img/thumbnail',
              status: 'ready',
            ),
          ),
          isSelf: false,
          senderAvatarLabel: '樱',
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    // 气泡 = 最外层 ClipRRect（`.first` 是 `_ImageMedia` 自己的图片圆角裁剪，宽 = 图片宽）
    final Finder bubbleFinder = find.ancestor(
      of: find.byType(AylaResourceImage),
      matching: find.byType(ClipRRect),
    );
    final Rect bubble = tester.getRect(bubbleFinder.last);
    // `.bubble-media { padding: var(--sp-1) }`（app.css 1514–1518）⇒ 气泡 = 媒体 + 2×4
    expect(
      bubble.width,
      320 + 2 * AylaSpacing.sp1,
      reason: '气泡必须紧贴媒体（`AylaMediaContent` 的 Align 需收缩到内容尺寸）',
    );
    expect(bubble.height, 240 + 2 * AylaSpacing.sp1);
  });

  // ======================= 操作栏 =======================

  testWidgets('操作栏：默认 opacity 0 且不可点；hover → 1；actionsOpen → 1', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageBubble(
          msg: _msg(),
          isSelf: false,
          senderAvatarLabel: '樱',
          onQuote: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 隐藏态：包装器**恒在**（只翻转标志位），IgnorePointer 拦住点击
    expect(find.byType(AylaFavoriteButton), findsOneWidget);
    expect(tester.widget<IgnorePointer>(find.ancestor(
      of: find.byType(AylaFavoriteButton),
      matching: find.byType(IgnorePointer),
    ).first).ignoring, isTrue);

    // hover → 显示
    final TestGesture gesture =
        await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.text('晚上一起看直播吗？我这边刚开播。')));
    await tester.pumpAndSettle();
    expect(tester.widget<IgnorePointer>(find.ancestor(
      of: find.byType(AylaFavoriteButton),
      matching: find.byType(IgnorePointer),
    ).first).ignoring, isFalse);
    expect(find.text('引用'), findsOneWidget);
  });

  testWidgets('工具栏：每条消息都有收藏键与引用键（引用恒显示，不依赖回调）', (
    WidgetTester tester,
  ) async {
    AylaChatMessage? quoted;
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageBubble(
          msg: _msg(),
          isSelf: false,
          senderAvatarLabel: '樱',
          actionsOpen: true,
          onQuote: (AylaChatMessage m) => quoted = m,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AylaFavoriteButton), findsOneWidget, reason: '收藏键恒在（tsx 246）');
    expect(find.text('引用'), findsOneWidget, reason: '引用键恒显示（MessageList.tsx:1082 恒传 onQuote）');
    await tester.tap(find.text('引用'));
    await tester.pump();
    expect(quoted?.id, 'm1');
  });

  testWidgets('未接线（无 onQuote）：引用键仍渲染、点击无副作用', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageBubble(
          msg: _msg(),
          isSelf: false,
          senderAvatarLabel: '樱',
          actionsOpen: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('引用'), findsOneWidget);
    await tester.tap(find.text('引用'));
    await tester.pump(); // 不抛异常即可（接线属页面层）
  });

  testWidgets('撤回键：只有自己 120s 内的消息才显示（用户 2026-09-24 明确）', (
    WidgetTester tester,
  ) async {
    AylaChatMessage? recalled;
    // 自己 + 30 秒前 → 显示
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageBubble(
          msg: _msg(
            senderId: 'me',
            createdAt: DateTime.now()
                .subtract(const Duration(seconds: 30))
                .toUtc()
                .toIso8601String(),
          ),
          isSelf: true,
          currentUserId: 'me',
          senderAvatarLabel: '我',
          actionsOpen: true,
          onRecall: (AylaChatMessage m) => recalled = m,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('撤回'), findsOneWidget, reason: '自己 + 120s 内');
    await tester.tap(find.text('撤回'));
    await tester.pump();
    expect(recalled?.id, 'm1');
  });

  testWidgets('撤回键：对方消息即使传了 onRecall 也不显示', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageBubble(
          msg: _msg(senderId: 'u1'),
          isSelf: false,
          currentUserId: 'me', // 当前用户是 me，发送者是 u1
          senderAvatarLabel: '樱',
          actionsOpen: true,
          onRecall: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('撤回'), findsNothing, reason: '对方消息不可撤回（canRecall 判自己）');
    expect(find.text('引用'), findsOneWidget);
  });

  testWidgets('撤回键：自己但超过 120s 不显示', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageBubble(
          msg: _msg(
            senderId: 'me',
            createdAt: DateTime.now()
                .subtract(const Duration(minutes: 5))
                .toUtc()
                .toIso8601String(),
          ),
          isSelf: true,
          currentUserId: 'me',
          senderAvatarLabel: '我',
          actionsOpen: true,
          onRecall: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('撤回'), findsNothing, reason: '超出 120s 撤回窗口');
  });

  testWidgets('触屏模式（touchMode: true）点行切换工具栏', (WidgetTester tester) async {
    int toggles = 0;
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageBubble(
          msg: _msg(),
          isSelf: false,
          senderAvatarLabel: '樱',
          touchMode: true,
          onToggleActions: () => toggles++,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('晚上一起看直播吗？我这边刚开播。'));
    await tester.pump();
    expect(toggles, 1, reason: '触屏点行展开工具栏（tsx 139–144）');
  });

  testWidgets('桌面模式（touchMode: false）点行不切换工具栏', (WidgetTester tester) async {
    int toggles = 0;
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageBubble(
          msg: _msg(),
          isSelf: false,
          senderAvatarLabel: '樱',
          touchMode: false,
          onToggleActions: () => toggles++,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('晚上一起看直播吗？我这边刚开播。'));
    await tester.pump();
    expect(toggles, 0, reason: '桌面（hover 能力设备）不挂点行回调（@media (hover:none)）');
  });

  // ======================= 头像手势 =======================

  testWidgets('头像单击：延迟 250ms 后触发；窗口内第二次点击 → 戳一戳', (WidgetTester tester) async {
    int clicks = 0;
    int pokes = 0;
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageBubble(
          msg: _msg(),
          isSelf: false,
          senderAvatarLabel: '樱',
          senderName: '小樱',
          onSenderClick: () => clicks++,
          onPokeSender: (String id) => pokes++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(AylaAvatarHalo));
    await tester.pump(const Duration(milliseconds: 200));
    expect(clicks, 0, reason: '双击窗口内先不跳转（DOUBLE_CLICK_MS = 250）');
    await tester.pump(const Duration(milliseconds: 100));
    expect(clicks, 1);

    // 双击：取消挂起单击，触发 poke
    await tester.tap(find.byType(AylaAvatarHalo));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byType(AylaAvatarHalo));
    await tester.pump(const Duration(milliseconds: 400));
    expect(pokes, 1);
    expect(clicks, 1, reason: '双击不再触发单击跳转');
  });

  testWidgets('长按头像 500ms → 插入 @该用户（群聊非自己）', (WidgetTester tester) async {
    String? mentioned;
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageBubble(
          msg: _msg(),
          isSelf: false,
          senderAvatarLabel: '樱',
          senderName: '小樱',
          onMentionSender: (String userId, String name) => mentioned = name,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(find.byType(AylaAvatarHalo));
    await tester.pumpAndSettle();
    expect(mentioned, '小樱');
  });

  testWidgets('自己的消息：长按头像不触发 @（canMention 要求 !isSelf）', (WidgetTester tester) async {
    String? mentioned;
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageBubble(
          msg: _msg(senderId: 'me'),
          isSelf: true,
          senderAvatarLabel: '我',
          senderName: '汐汐',
          onMentionSender: (String userId, String name) => mentioned = name,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.longPress(find.byType(AylaAvatarHalo));
    await tester.pumpAndSettle();
    expect(mentioned, isNull);
  });

  // ======================= 发送态 =======================

  testWidgets('上传中：显示百分比 + 取消键可点（状态在气泡左侧且可命中）', (WidgetTester tester) async {
    int cancels = 0;
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageBubble(
          msg: _msg(senderId: 'me', pending: true, uploadProgress: 42),
          isSelf: true,
          currentUserId: 'me',
          onCancel: (_) => cancels++,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('上传中 42%'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pump();
    expect(cancels, 1, reason: '取消键必须可点（不能因溢出父边界而收不到指针）');

    // 状态块位于气泡左侧（web `right: calc(100% + 8px)`）
    final Rect state = tester.getRect(find.text('上传中 42%'));
    final Rect bubble = tester.getRect(
      find
          .ancestor(
            of: find.text('晚上一起看直播吗？我这边刚开播。'),
            matching: find.byType(ClipRRect),
          )
          .first,
    );
    expect(state.right, lessThan(bubble.left), reason: '状态整体在气泡左缘之外');
  });

  testWidgets('发送失败：文案 + 重试 / 删除键', (WidgetTester tester) async {
    int retries = 0;
    int removes = 0;
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageBubble(
          msg: _msg(senderId: 'me', sendFailed: true),
          isSelf: true,
          currentUserId: 'me',
          onRetry: (_) => retries++,
          onRemove: (_) => removes++,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('发送失败'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pump();
    await tester.tap(find.text('删除'));
    await tester.pump();
    expect(retries, 1);
    expect(removes, 1);
  });

  // ======================= 到达动画（量中间帧） =======================

  testWidgets('到达动画 frost-rise：180ms 内 opacity 从 0 升到 1（量活值而非终值）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageBubble(
          msg: _msg(),
          isSelf: false,
          senderAvatarLabel: '樱',
          justArrived: true,
        ),
      ),
    );
    // 首帧：动画刚开始（opacity ≈ 0）
    await tester.pump();
    double opacityOf(WidgetTester t) => t
        .widgetList<Opacity>(find.byType(Opacity))
        .map((Opacity o) => o.opacity)
        .reduce((double a, double b) => a < b ? a : b);
    expect(opacityOf(tester), lessThan(1.0), reason: '首帧不是终值（否则等于没有动画）');

    await tester.pump(const Duration(milliseconds: 90));
    final double mid = opacityOf(tester);
    expect(mid, greaterThan(0.0));
    expect(mid, lessThan(1.0), reason: '中间帧应仍在过渡中');

    await tester.pump(const Duration(milliseconds: 200));
    expect(opacityOf(tester), 1.0, reason: '180ms 后到终态');

    // 非新到达消息：直接终态
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageBubble(msg: _msg(), isSelf: false, senderAvatarLabel: '樱'),
      ),
    );
    await tester.pump();
    expect(opacityOf(tester), 1.0);
  });

  testWidgets('主体 max-width：宽屏 75%（app.css 1074）', (WidgetTester tester) async {
    const String longText =
        '这是一条非常长的消息用来测量气泡主体的最大宽度上限，看看在宽屏与窄屏下分别是百分之多少，'
        '宽度上限来自 msg-body 的 max-width 规则，超过之后文本应当折行而不是继续变宽。';
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageBubble(msg: _msg(content: longText), isSelf: false, senderAvatarLabel: '樱'),
        viewport: const Size(800, 420),
      ),
    );
    await tester.pumpAndSettle();
    // 量**布局约束**（文本实际宽度受换行影响，不等于上限）
    final ConstrainedBox wide = tester.widget<ConstrainedBox>(
      find
          .ancestor(of: find.text(longText), matching: find.byType(ConstrainedBox))
          .first,
    );
    expect(wide.constraints.maxWidth, 800 * 0.75, reason: '宽屏 75%');
  });

  testWidgets('主体 max-width：窄屏 84%（app.css 3217–3219）', (WidgetTester tester) async {
    const String longText =
        '这是一条非常长的消息用来测量气泡主体的最大宽度上限，看看在宽屏与窄屏下分别是百分之多少，'
        '宽度上限来自 msg-body 的 max-width 规则，超过之后文本应当折行而不是继续变宽。';
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageBubble(msg: _msg(content: longText), isSelf: false, senderAvatarLabel: '樱'),
        viewport: const Size(600, 420),
      ),
    );
    await tester.pumpAndSettle();
    final ConstrainedBox narrow = tester.widget<ConstrainedBox>(
      find
          .ancestor(of: find.text(longText), matching: find.byType(ConstrainedBox))
          .first,
    );
    expect(narrow.constraints.maxWidth, 600 * 0.84, reason: '窄屏 84%');
  });
}
