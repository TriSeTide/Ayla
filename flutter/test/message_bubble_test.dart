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

import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
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

  /// 在**桌面平台**上跑一段断言。
  ///
  /// `flutter_test` 默认平台是 `TargetPlatform.android`（本属「触屏近似档」
  /// ⇒ 一律走点击档）。凡是要测**悬停档**（宽屏 + 有 hover 能力）或**宽度判据**的
  /// 用例都必须先切到桌面平台，否则会被平台判据直接命中、测不出那一级。
  ///
  /// ⚠️ `debugDefaultTargetPlatformOverride` 必须在**用例体内**（`try/finally`）复位：
  /// `addTearDown` 排在框架的 `_verifyInvariants` **之后**，只靠它会让每个用例
  /// 都报「a foundation debug variable was changed by the test」（实测）。
  Future<void> asDesktopPlatform(Future<void> Function() body) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
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

    // 气泡：padding 10/14 + **1px 边框计入内距** = 垂直 11 / 水平 15。
    // web `.bubble { padding: 10px 14px }`（app.css:1106）+ 这是他人消息
    // `.bubble-other { border: 1px solid var(--glass-border) }`（app.css:1133），
    // 而 web 全局 `box-sizing: border-box`（base.css:7）⇒ 边框加在 padding **之外**，
    // 外框 = 文本 + 14×2 + 1×2。Flutter 的 BoxDecoration.border 画在尺寸**内**，
    // 故内距须补上这 1px，外框才与 web 等宽（2026-10-22 对账实测：
    // web peer-short 44.91 / 修正前 Flutter 42.89，修正后 44.89）。
    final Rect text = tester.getRect(find.text('晚上一起看直播吗？我这边刚开播。'));
    final ClipRRect bubble = tester.widget<ClipRRect>(find.byType(ClipRRect).first);
    final Rect bubbleRect = tester.getRect(find.byType(ClipRRect).first);
    expect(text.left - bubbleRect.left, 15, reason: 'padding 左右 14 + border 1（app.css 1106/1133 + base.css:7 border-box）');
    expect(bubbleRect.bottom - text.bottom, 11, reason: 'padding 上下 10 + border 1');

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

  testWidgets('操作栏：默认 opacity 0 且不可点；宽屏 hover → 1；actionsOpen → 1', (
    WidgetTester tester,
  ) async {
    // ⚠️ 悬停档要求**宽屏 + 有 hover 能力**，两者都要显式给：
    // 视口默认 720（≤768 属窄屏档）、平台默认 android（属触屏档）。
    await asDesktopPlatform(() async {
      await tester.pumpWidget(
        host(
          tester,
          AylaMessageBubble(
            msg: _msg(),
            isSelf: false,
            senderAvatarLabel: '樱',
            onQuote: (_) {},
          ),
          viewport: const Size(900, 420),
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
  });

  testWidgets('工具栏：传了 onQuote → 收藏键与引用键都在（web tsx 246/247）', (
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
    expect(find.text('引用'), findsOneWidget, reason: '传了 onQuote ⇒ `{onQuote && (…)}` 成立（tsx 247）');
    await tester.tap(find.text('引用'));
    await tester.pump();
    expect(quoted?.id, 'm1');
  });

  testWidgets('未接线（无 onQuote）：引用键**不渲染**（MessageBubble.tsx:247 的 `{onQuote && (…)}`）', (
    WidgetTester tester,
  ) async {
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
    // 2026-10-02 订正：此前断言「引用键恒显示」，与 web 不符 ——
    // `components/chat/MessageBubble.tsx:247` 是条件渲染（`{onQuote && (…)}`），
    // 与 `:258` 的 `{onRecall && (…)}` 同一写法 ⇒ 未接线时不该有假按钮。
    expect(find.text('引用'), findsNothing);
    // 收藏键仍恒在（`tsx:246` 无条件渲染）
    expect(find.byType(AylaFavoriteButton), findsOneWidget);
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
          onQuote: (_) {},
          onRecall: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('撤回'), findsNothing, reason: '对方消息不可撤回（canRecall 判自己）');
    expect(find.text('引用'), findsOneWidget, reason: '传了 onQuote ⇒ 引用键在');
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
    expect(toggles, 1, reason: '触屏档点行展开工具栏（tsx 139–146）');
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
    expect(
      toggles,
      0,
      reason: '显式桌面档（touchMode: false）点行不切换 —— 调用方明确要求，不用指针维度',
    );
  });

  // ============ 工具栏两档触发：宽屏且有 hover ⇒ 悬停；否则 ⇒ 点击 ============
  //
  // 契约（**2026-10-13 用户定稿；Flutter 有意偏离 web**）：
  // - **宽屏且有 hover 能力** ⇒ 悬停显示、移开消失；
  // - **否则**（窄屏 **或** 无 hover 能力）⇒ 点气泡行切工具栏；
  // - `:focus-within` ⇒ **两档**都显示（键盘可达性，web `app.css:1301–1304` 同款）。
  //
  // ⚠️ **本条是单端偏离，不是「对齐 web」**：web 侧**保持原样**（用户 2026-10-13 裁决
  // 「回退 web，我说对的就是对的」）—— web 判据仍是**纯 hover 能力查询**
  // （`MessageBubble.tsx:135` `HOVER_NONE_QUERY`；`app.css:1307–1322` 只有
  // `@media (hover: hover)` / `@media (hover: none)`，**无宽度条件**）⇒ web 窄屏
  // 桌面窗口仍走悬停档。Flutter 端按用户要求让窄屏走点击档（Windows 窄窗口是用户的
  // 手机形态代理，而该环境**无法用真实触屏模拟**）。**冲突时以用户裁决为准。**
  //
  // ⚠️ 本区块**推翻**了 2026-10-09 §7.2 的旧结论（当时按 web 的纯能力查询判定
  // 「窄屏仍走 hover」）；用户再次实报后按窄屏判据定稿，旧说法已在
  // `docs/flutter/13-工作进度与待办.md` 就地改写，不留两种口径。

  testWidgets('★ 窄屏（420）鼠标 hover **不**显示工具栏（宽度参与判定）', (
    WidgetTester tester,
  ) async {
    // 用户实报的本条：窄屏聊天必须「点击才触发，而非鼠标悬停显示」。
    // ⚠️ 必须桌面平台：`flutter_test` 默认 android（本属触屏档）⇒ 那样无论宽度如何
    // 都走点击档、**测不出宽度判据**（负对照实测：把窄屏判据整个取消也照样绿）。
    await asDesktopPlatform(() async {
      await tester.pumpWidget(
        host(
          tester,
          AylaMessageBubble(
            msg: _msg(),
            isSelf: false,
            senderAvatarLabel: '樱',
            onToggleActions: () {},
            onQuote: (_) {},
          ),
          viewport: const Size(420, 640), // ≤768 ⇒ 点击档
        ),
      );
      await tester.pumpAndSettle();

      bool ignoring() => tester
          .widget<IgnorePointer>(
            find
                .ancestor(
                  of: find.byType(AylaFavoriteButton),
                  matching: find.byType(IgnorePointer),
                )
                .first,
          )
          .ignoring;
      expect(ignoring(), isTrue, reason: '初始隐藏（app.css:1299 opacity: 0）');

      final TestGesture g =
          await tester.createGesture(kind: PointerDeviceKind.mouse);
      await g.addPointer(location: Offset.zero);
      addTearDown(g.removePointer);
      await g.moveTo(tester.getCenter(find.text('晚上一起看直播吗？我这边刚开播。')));
      await tester.pumpAndSettle();

      expect(
        ignoring(),
        isTrue,
        reason: '★ 窄屏悬停**不**展开（app.css:1317 的 not(max-width:768px) 挡在档外）',
      );
    });
  });

  testWidgets('★ 窄屏（420）点行 ⇒ 切换工具栏（鼠标也走点击档）', (WidgetTester tester) async {
    // 窄屏按手机形态：**鼠标点**也要切换（用户是在 Windows 窄窗口上操作的）。
    // ⚠️ 必须桌面平台：android 档本就点击档，不切平台测不出「窄屏让鼠标也走点击」。
    await asDesktopPlatform(() async {
      int toggles = 0;
      await tester.pumpWidget(
        host(
          tester,
          AylaMessageBubble(
            msg: _msg(),
            isSelf: false,
            senderAvatarLabel: '樱',
            onToggleActions: () => toggles++,
          ),
          viewport: const Size(420, 640),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.text('晚上一起看直播吗？我这边刚开播。'),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      expect(
        toggles,
        1,
        reason: '★ 窄屏鼠标点行切换（app.css:1330 max-width:768px 档）',
      );
    });
  });

  testWidgets('★ 768 含等号 ⇒ 仍是窄屏档（与 web max-width:768px 逐字对齐）', (
    WidgetTester tester,
  ) async {
    // 边界：768 仍是窄屏档、769 起才是宽屏档。
    // web `NARROW_QUERY = "(max-width: 768px)"` 含等号（CSS 同）。
    // ⚠️ 桌面平台：android 档会掩盖宽度判据（见上两条注释）。
    await asDesktopPlatform(() async {
      await tester.pumpWidget(
        host(
          tester,
          AylaMessageBubble(
            msg: _msg(),
            isSelf: false,
            senderAvatarLabel: '樱',
            onToggleActions: () {},
            onQuote: (_) {},
          ),
          viewport: const Size(768, 640),
        ),
      );
      await tester.pumpAndSettle();

      final TestGesture g =
          await tester.createGesture(kind: PointerDeviceKind.mouse);
      await g.addPointer(location: Offset.zero);
      addTearDown(g.removePointer);
      await g.moveTo(tester.getCenter(find.text('晚上一起看直播吗？我这边刚开播。')));
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<IgnorePointer>(
              find
                  .ancestor(
                    of: find.byType(AylaFavoriteButton),
                    matching: find.byType(IgnorePointer),
                  )
                  .first,
            )
            .ignoring,
        isTrue,
        reason: '★ 768 = 窄屏档（`AylaBreakpoints.isNarrow` 与 NARROW_QUERY 都含等号）',
      );
    });
  });

  // web 侧初版把悬停档写成 `min-width: 769px`（而非 `not (max-width: 768px)`），
  // 真实浏览器实测（Playwright）**小数视口宽** 768.5 命中死区：两条媒体查询同时为假
  // ⇒ 工具栏既不能悬停展开、点击档也不生效 = 彻底打不开（真实桌面视口常为小数：
  // 滚动条 / 缩放）。Flutter 侧对该死区**结构性免疫** —— 只有一个 `_tapMode` 布尔、
  // 悬停取 `_hovered && !_tapMode` ⇒ 两档天然互补。下面每个宽度一条用例，
  // 断言两档**恰好一条可达且方向正确**。
  //
  // ⚠️ 必须**一条用例一个宽度**（不能在一个 testWidgets 里循环）：
  // 循环内反复 pumpWidget + 复用鼠标手势会让 MouseTracker 状态串场，
  // 实测 767 那次点击会静默丢失（hover=false 且 tap=false 的假死区）。
  for (final double width in <double>[320, 767, 768, 768.5, 769, 1024, 1440]) {
    testWidgets('★ 两档互补 @ ${width}px：恰好一条可达路径', (WidgetTester tester) async {
      await asDesktopPlatform(() async {
        int toggles = 0;
        await tester.pumpWidget(
          host(
            tester,
            AylaMessageBubble(
              msg: _msg(),
              isSelf: false,
              senderAvatarLabel: '樱',
              onToggleActions: () => toggles++,
              onQuote: (_) {},
            ),
            viewport: Size(width, 640),
          ),
        );
        await tester.pumpAndSettle();

        bool visible() => !tester
            .widget<IgnorePointer>(
              find
                  .ancestor(
                    of: find.byType(AylaFavoriteButton),
                    matching: find.byType(IgnorePointer),
                  )
                  .first,
            )
            .ignoring;
        final Offset center =
            tester.getCenter(find.text('晚上一起看直播吗？我这边刚开播。'));

        // 全程用**同一个**鼠标 TestGesture（addPointer → moveTo → down/up → removePointer）：
        // `tester.tap(kind: mouse)` 只发 PointerDownEvent、**不发 PointerAddedEvent**，
        // 之后再 `createGesture(mouse).addPointer()` 会让 MouseTracker 抛
        // 「(event is PointerAddedEvent) == (lastEvent is PointerRemovedEvent)」（实测踩到）。
        final TestGesture g =
            await tester.createGesture(kind: PointerDeviceKind.mouse);
        await g.addPointer(location: Offset.zero);
        await g.moveTo(center);
        await tester.pumpAndSettle();
        // ① 悬停维度（**在按下之前**量：按下会经 `:focus-within` 档把工具栏点亮）
        final bool hoverOpens = visible();

        // ② 点击维度：同一指针就地按下抬起
        await g.down(center);
        await g.up();
        await tester.pump();
        final bool tapToggles = toggles == 1;

        await g.removePointer();
        await tester.pumpAndSettle();

        expect(
          hoverOpens || tapToggles,
          isTrue,
          reason: '★ ${width}px：两档至少一档可达（死区 = 工具栏彻底打不开）',
        );
        expect(
          hoverOpens && tapToggles,
          isFalse,
          reason: '★ ${width}px：两档互斥（同时成立会让窄屏 hover 抢先、点击档形同虚设）',
        );
        // **方向**断言：光验「互补」不足以证明宽度判据生效 —— 负对照实测：把窄屏判据
        // 整个取消（`_narrow` 恒 false）后，android 档下所有宽度仍是「点击档」，
        // 单靠互补断言照样全绿。必须钉住**哪一档**：
        final bool expectHoverTier = width > 768;
        expect(
          hoverOpens,
          expectHoverTier,
          reason: '★ ${width}px：宽屏档才悬停展开（宽度判据生效的直接证据）',
        );
        expect(
          tapToggles,
          !expectHoverTier,
          reason: '★ ${width}px：窄屏档点行才切换（两档按宽度各自归位）',
        );
      });
    });
  }

  // ============ 点击档的可点区域 = **整行**（web `.msg-row` 整个盒子） ============
  //
  // web 的 `onClick` 挂在 `.msg-row`（block-level `display:flex` div）上 ⇒ 它**整个盒子**
  // （全宽 × 内容高，含 `padding: 0 var(--sp-1)`，`app.css:1041–1046`）都是点击目标。
  // 用户 2026-10-13 实报「点击区域不对，要有 web 那一整行点击」，根因两条：
  //  ① 手势层曾把 `Padding(horizontal: sp1)` 留在**外层** ⇒ 行左右各 4px 不可点；
  //  ② 点击档 `HitTestBehavior` 曾是默认 `deferToChild` ⇒ 只有**被子级覆盖**的位置可命中
  //     （实测 375 宽行只有 y≈90–118 的窄条能点中）。
  //
  // ⚠️ 每个「空白点」一条用例、且**只 pumpWidget 一次**：同一用例内二次 `pumpWidget`
  // 同一树位时，`MaterialApp.home` 被已入栈的 Route 持有 ⇒ 新回调**不生效**，
  // 点击仍打进上一个闭包（实测 a=2 / b=0），会造成「第二次点击丢失」的假象。

  testWidgets('★ 点击档（对方）：手势层含整行（含左右 padding 条）', (
    WidgetTester tester,
  ) async {
    await asDesktopPlatform(() async {
      await tester.pumpWidget(
        host(
          tester,
          AylaMessageBubble(
            msg: _msg(senderId: 'u1'),
            isSelf: false,
            currentUserId: 'me',
            senderAvatarLabel: '樱',
            onToggleActions: () {},
          ),
          viewport: const Size(420, 200),
        ),
      );
      await tester.pumpAndSettle();

      final Rect gd = tester.getRect(
        find
            .descendant(
              of: find.byType(AylaMessageBubble),
              matching: find.byType(GestureDetector),
            )
            .first,
      );
      expect(
        gd.left,
        0,
        reason: '★ 对方：左侧 padding 条须在手势层内（曾在 Padding 外层 ⇒ 不可点）',
      );
      expect(gd.right, 420, reason: '★ 对方：右侧 padding 条同样可点');
      expect(
        tester.widget<GestureDetector>(find.descendant(
          of: find.byType(AylaMessageBubble),
          matching: find.byType(GestureDetector),
        ).first).behavior,
        HitTestBehavior.opaque,
        reason: '★ 对方：点击档须 opaque（默认 deferToChild 只让被覆盖处可命中）',
      );
    });
  });

  testWidgets('★ 点击档（自己）：手势层含整行（含左右 padding 条）', (
    WidgetTester tester,
  ) async {
    await asDesktopPlatform(() async {
      await tester.pumpWidget(
        host(
          tester,
          AylaMessageBubble(
            msg: _msg(senderId: 'me'),
            isSelf: true,
            currentUserId: 'me',
            senderAvatarLabel: '樱',
            onToggleActions: () {},
          ),
          viewport: const Size(420, 200),
        ),
      );
      await tester.pumpAndSettle();

      final Rect gd = tester.getRect(
        find
            .descendant(
              of: find.byType(AylaMessageBubble),
              matching: find.byType(GestureDetector),
            )
            .first,
      );
      expect(
        gd.left,
        0,
        reason: '★ 自己：左侧 padding 条须在手势层内（曾在 Padding 外层 ⇒ 不可点）',
      );
      expect(gd.right, 420, reason: '★ 自己：右侧 padding 条同样可点');
      expect(
        tester.widget<GestureDetector>(find.descendant(
          of: find.byType(AylaMessageBubble),
          matching: find.byType(GestureDetector),
        ).first).behavior,
        HitTestBehavior.opaque,
        reason: '★ 自己：点击档须 opaque（默认 deferToChild 只让被覆盖处可命中）',
      );
    });
  });

  testWidgets('★ 点击档：空白处可点 —— 左上空白（气泡上方）', (WidgetTester tester) async {
    await asDesktopPlatform(() async {
      int toggles = 0;
      await tester.pumpWidget(
        host(
          tester,
          AylaMessageBubble(
            msg: _msg(),
            isSelf: false,
            currentUserId: 'me',
            senderAvatarLabel: '樱',
            onToggleActions: () => toggles++,
          ),
          viewport: const Size(420, 200),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tapAt(const Offset(2, 4));
      await tester.pump();
      expect(
        toggles,
        1,
        reason: '★ 左上空白（气泡上方） 应命中整行手势（web 整行可点）',
      );
    });
  });

  testWidgets('★ 点击档：空白处可点 —— 右上空白', (WidgetTester tester) async {
    await asDesktopPlatform(() async {
      int toggles = 0;
      await tester.pumpWidget(
        host(
          tester,
          AylaMessageBubble(
            msg: _msg(),
            isSelf: false,
            currentUserId: 'me',
            senderAvatarLabel: '樱',
            onToggleActions: () => toggles++,
          ),
          viewport: const Size(420, 200),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tapAt(const Offset(417, 4));
      await tester.pump();
      expect(
        toggles,
        1,
        reason: '★ 右上空白 应命中整行手势（web 整行可点）',
      );
    });
  });

  testWidgets('★ 点击档：空白处可点 —— 行正中空白', (WidgetTester tester) async {
    await asDesktopPlatform(() async {
      int toggles = 0;
      await tester.pumpWidget(
        host(
          tester,
          AylaMessageBubble(
            msg: _msg(),
            isSelf: false,
            currentUserId: 'me',
            senderAvatarLabel: '樱',
            onToggleActions: () => toggles++,
          ),
          viewport: const Size(420, 200),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tapAt(const Offset(210, 4));
      await tester.pump();
      expect(
        toggles,
        1,
        reason: '★ 行正中空白 应命中整行手势（web 整行可点）',
      );
    });
  });

  testWidgets('★ 点击档：空白处可点 —— 左下空白（头像左侧 padding 条）', (WidgetTester tester) async {
    await asDesktopPlatform(() async {
      int toggles = 0;
      await tester.pumpWidget(
        host(
          tester,
          AylaMessageBubble(
            msg: _msg(),
            isSelf: false,
            currentUserId: 'me',
            senderAvatarLabel: '樱',
            onToggleActions: () => toggles++,
          ),
          viewport: const Size(420, 200),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tapAt(const Offset(2, 197));
      await tester.pump();
      expect(
        toggles,
        1,
        reason: '★ 左下空白（头像左侧 padding 条） 应命中整行手势（web 整行可点）',
      );
    });
  });

  testWidgets('★ 点击档：空白处可点 —— 右下角落', (WidgetTester tester) async {
    await asDesktopPlatform(() async {
      int toggles = 0;
      await tester.pumpWidget(
        host(
          tester,
          AylaMessageBubble(
            msg: _msg(),
            isSelf: false,
            currentUserId: 'me',
            senderAvatarLabel: '樱',
            onToggleActions: () => toggles++,
          ),
          viewport: const Size(420, 200),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tapAt(const Offset(417, 197));
      await tester.pump();
      expect(
        toggles,
        1,
        reason: '★ 右下角落 应命中整行手势（web 整行可点）',
      );
    });
  });

  testWidgets('★ 整行 opaque 后：上滑/拖动仍能滚动，且不触发点行切换', (
    WidgetTester tester,
  ) async {
    // ⚠️ `opaque` 让整行参与命中，必须确认没把滚动手势吃掉（真实列表里用户会从
    // 气泡行**空白处**起手滑动）。`GestureDetector.onTap` 在拖动超过 slop 时本就会
    // 输给滚动竞技场，此例把该结论钉住。
    await asDesktopPlatform(() async {
      // ⚠️ 必须显式设视口：不设则用默认 800×600 物理像素（DPR 3 ⇒ 逻辑仅 266×200），
      // y=250 会落到屏幕外、拖动拿不到任何手势（首版就因此红）。
      setViewport(tester, const Size(420, 300));
      final ScrollController ctl = ScrollController();
      addTearDown(ctl.dispose);
      int toggles = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: previewScope(
            Builder(
              builder: (BuildContext ctx) => MediaQuery(
                data: MediaQuery.of(ctx).copyWith(size: const Size(420, 300)),
                child: SizedBox.fromSize(
                  size: const Size(420, 300),
                  child: ListView.builder(
                    controller: ctl,
                    itemCount: 20,
                    itemBuilder: (BuildContext c, int i) => AylaMessageBubble(
                      msg: _msg(senderId: 'u1', content: 'msg' + i.toString()),
                      isSelf: false,
                      currentUserId: 'me',
                      senderAvatarLabel: '樱',
                      onToggleActions: () => toggles++,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(ctl.offset, 0);

      // 从整行「空白」处（x=2 贴近左边缘）起手上滑
      await tester.dragFrom(const Offset(2, 250), const Offset(0, -200));
      await tester.pumpAndSettle();
      expect(ctl.offset, greaterThan(0), reason: '★ 整行 opaque 不得吞掉滚动手势');
      expect(toggles, 0, reason: '★ 拖动（超过 slop）不应触发点行切换');
    });
  });

  testWidgets('★ 点击档：气泡内的按钮仍优先（不误触整行回调）', (
    WidgetTester tester,
  ) async {
    await asDesktopPlatform(() async {
      int toggles = 0;
      await tester.pumpWidget(
        host(
          tester,
          AylaMessageBubble(
            msg: _msg(),
            isSelf: false,
            currentUserId: 'me',
            senderAvatarLabel: '樱',
            actionsOpen: true, // 让引用键真的可见可点
            onToggleActions: () => toggles++,
            onQuote: (_) {},
          ),
          viewport: const Size(420, 300),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('引用'));
      await tester.pump();
      expect(
        toggles,
        0,
        reason: '★ 点操作栏按钮不得触发整行「点行切换」（按钮在命中链内层、竞技场胜出）',
      );
    });
  });
  testWidgets('★ 769（宽屏档下界）鼠标 hover ⇒ 显示工具栏', (WidgetTester tester) async {
    // 与上一条互为边界对照：769 起进入悬停档（需宽屏 **且** 有 hover 能力）。
    await asDesktopPlatform(() async {
      await tester.pumpWidget(
        host(
          tester,
          AylaMessageBubble(
            msg: _msg(),
            isSelf: false,
            senderAvatarLabel: '樱',
            onToggleActions: () {},
            onQuote: (_) {},
          ),
          viewport: const Size(769, 640),
        ),
      );
      await tester.pumpAndSettle();

      final TestGesture g =
          await tester.createGesture(kind: PointerDeviceKind.mouse);
      await g.addPointer(location: Offset.zero);
      addTearDown(g.removePointer);
      await g.moveTo(tester.getCenter(find.text('晚上一起看直播吗？我这边刚开播。')));
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<IgnorePointer>(
              find
                  .ancestor(
                    of: find.byType(AylaFavoriteButton),
                    matching: find.byType(IgnorePointer),
                  )
                  .first,
            )
            .ignoring,
        isFalse,
        reason: '★ 769 起是宽屏档 ⇒ 悬停展开（app.css:1317）',
      );
    });
  });

  testWidgets('★ 触屏指针点行 ⇒ 切换工具栏（能力判定：桌面平台 + touch 指针）', (
    WidgetTester tester,
  ) async {
    // 这条锁 2026-10-09 修的真实偏离：原实现只按 `Theme.of(context).platform` 判定
    // ⇒ 触屏 Windows / 平板模式（平台名仍是桌面）在 web 上会报 `hover: none`、
    //   应走点击路径，Flutter 侧却**完全不挂**点行回调。
    // ⚠️ `flutter_test` 默认 `TargetPlatform.android`（已属触屏近似档，
    //    测不出该偏离）⇒ 必须显式把平台置为桌面。
    // ⚠️ 还必须给**宽屏**视口：默认 720 属窄屏档，那样本用例会被宽度判据直接命中，
    //    指针设备维度就测不到了（此用例专测「平台名 + 指针设备」这一级）。
    await asDesktopPlatform(() async {
      int toggles = 0;
      await tester.pumpWidget(
        host(
          tester,
          AylaMessageBubble(
            msg: _msg(),
            isSelf: false,
            senderAvatarLabel: '樱',
            onToggleActions: () => toggles++,
          ),
          viewport: const Size(900, 420),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        Theme.of(tester.element(find.byType(AylaMessageBubble))).platform,
        TargetPlatform.windows,
        reason: '前提：平台名是桌面（原实现据此判「非触屏」）',
      );

      // 用**触摸指针**点行 —— 等价 web 的 `@media (hover: none)` 设备。
      final TestGesture g = await tester.startGesture(
        tester.getCenter(find.text('晚上一起看直播吗？我这边刚开播。')),
        kind: PointerDeviceKind.touch,
      );
      await g.up();
      await tester.pump();

      expect(
        toggles,
        1,
        reason: '★ 宽屏 + 触摸指针 ⇒ 走点击路径（app.css:1330 的 hover:none 档）',
      );
    });
  });

  testWidgets('★ 宽屏鼠标点击行 ⇒ **不**切换工具栏（悬停档不接点击）', (
    WidgetTester tester,
  ) async {
    // 同上：必须在桌面平台上测「鼠标不切换」才有意义（android 档本就是触屏路径），
    // 且必须宽屏（窄屏档鼠标点行是**要**切换的，见前面的窄屏用例）。
    await asDesktopPlatform(() async {
      int toggles = 0;
      await tester.pumpWidget(
        host(
          tester,
          AylaMessageBubble(
            msg: _msg(),
            isSelf: false,
            senderAvatarLabel: '樱',
            onToggleActions: () => toggles++,
          ),
          viewport: const Size(900, 420),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.text('晚上一起看直播吗？我这边刚开播。'),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();

      expect(
        toggles,
        0,
        reason: '★ 宽屏 + 鼠标（有 hover 能力）⇒ 悬停档、点行不切换（app.css:1317）',
      );
    });
  });

  testWidgets('★ 显式 touchMode 仍最高优先：false 时窄屏 + 触摸指针也不切换', (
    WidgetTester tester,
  ) async {
    // 保住既有契约：`touchMode: false` 的调用方明确要求关闭点行路径
    //（**即使窄屏**，也按桌面档：悬停展开、点行不切换）。
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

    final TestGesture g = await tester.startGesture(
      tester.getCenter(find.text('晚上一起看直播吗？我这边刚开播。')),
      kind: PointerDeviceKind.touch,
    );
    await g.up();
    await tester.pump();

    expect(toggles, 0, reason: '显式档位覆盖能力推断与宽度判据（`_tapMode` 的最高优先）');
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
    // ⚠️ 2026-10-02 订正：web 的百分比基数是 **`.msg-row` 的 content box**
    // （`app.css:1045` 的 `padding: 0 sp1` 已扣掉 8px）⇒ 可分配宽 = 800 − 8。
    expect(wide.constraints.maxWidth, (800 - 2 * AylaSpacing.sp1) * 0.75, reason: '宽屏 75%');
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
    // 同上：基数 = 行 content box（600 − 2×sp1）
    expect(narrow.constraints.maxWidth, (600 - 2 * AylaSpacing.sp1) * 0.84, reason: '窄屏 84%');
  });

  // ======================= 问题 13 ③：focus-within 覆盖整行 =======================
  //
  // web `app.css:1301–1304` `.msg-row:focus-within .msg-actions { opacity: 1;
  // pointer-events: auto }` —— 命中**行内任何**可聚焦元素，含气泡内 `.quote-strip`
  // 的 button 分支（`MessageBubble.tsx:339–347`）。Flutter 此前 `Focus` 只包住操作栏
  // 自身 ⇒ 聚焦引用键时工具栏仍不可见、也点不到（`IgnorePointer(ignoring: true)`）。
  testWidgets('聚焦气泡内引用键 → 工具栏可见且可点（app.css:1301 :focus-within）', (
    WidgetTester tester,
  ) async {
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
          onQuote: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 初始：无 hover、无 actionsOpen、无焦点 → 操作栏隐藏（pointer-events: none）
    IgnorePointer ignoring() => tester.widget<IgnorePointer>(
          find.ancestor(
            of: find.byType(AylaFavoriteButton),
            matching: find.byType(IgnorePointer),
          ).first,
        );
    expect(ignoring().ignoring, isTrue, reason: '初始隐藏态');

    // 把焦点给引用条（web 是可聚焦的原生 button）
    final FocusNode quoteNode = FocusNode();
    addTearDown(quoteNode.dispose);
    final Element quoteEl = tester.element(find.text('那我先去占个位置'));
    Focus.maybeOf(quoteEl)?.requestFocus();
    await tester.pumpAndSettle();
    expect(
      ignoring().ignoring,
      isFalse,
      reason: '聚焦气泡内的引用键 ⇒ `.msg-row:focus-within` 命中 ⇒ 操作栏可见',
    );
    expect(find.text('引用'), findsOneWidget);
  });
}
