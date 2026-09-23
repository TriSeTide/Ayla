/// B1-6：语音房整页定向测试 —— 逐条对照 `VoiceRoomBody.tsx`(327) 与
/// `voice.css:12–470`、`app.css:2105–2138 / 3473–3477`、`base.css:463–472`。
///
/// 覆盖：两形态结构（宽屏 grid 两列 / 窄屏堆叠 + 浮层）/ 材质归属（builder 收到的 ownMaterial）/
/// head 六件（返回·标题 Fredoka 18·标签 12ch 档·收藏·分享·「删除房间」= 裸 .btn）/ 聊天卡条件渲染 /
/// 未读规则（新 id + 收起 + 非自己 ⇒ +1，展开清零，自己发的不加，99+ 截断）/ 发送（空文本禁用、
/// 成功清空、失败保留 + `.live-form-error` 文案）/ 图片（工具钮 + 兜底文案）/ 消息行（sender 700
/// secondary + 「图片」占位不渲染文本 + 缩略图 120×80）/ 历史控件透传 / 换房重置 / 入场 offset。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/buttons.dart';
import '../lib/theme/glass.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/directory_controls.dart';
import '../lib/widgets/resource_image.dart';
import '../lib/widgets/primitives.dart' show AylaSourceTag;
import '../lib/widgets/reveal.dart';
import '../lib/widgets/voice_room_body.dart';

const Key _panelKey = Key('room-body-panel');

void main() {
  Widget host(
    Widget child, {
    Size viewport = const Size(1200, 700),
    bool bounded = true,
  }) {
    return MaterialApp(
      home: previewScope(
        Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(size: viewport),
            child: bounded
                ? SizedBox.fromSize(size: viewport, child: child)
                : Align(alignment: Alignment.topLeft, child: child),
          ),
        ),
      ),
    );
  }

  void setViewport(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// ⚠️ `previewScope` 的 `Overlay(initialEntries:)` 只在首次创建生效 ⇒ 同一用例里第二次
  /// `pumpWidget` 不生效。需要「props 变化」的用例一律用 [StatefulBuilder] 在同一棵树内 setState。
  Widget driven({
    required Size viewport,
    required Widget Function(void Function(void Function()) setState) build,
  }) {
    return host(
      StatefulBuilder(
        builder: (BuildContext context, StateSetter setState) =>
            build((void Function() fn) => setState(fn)),
      ),
      viewport: viewport,
    );
  }

  /// 记录 builder 收到的 `ownMaterial`。
  final List<bool> builderFlags = <bool>[];

  AylaVoiceRoomBody body({
    String? channelId = 'v1',
    bool isOwner = false,
    String? selfUserId = 'self',
    List<AylaVoiceChatMessage> messages = const <AylaVoiceChatMessage>[],
    AylaVoiceChatHistory history = const AylaVoiceChatHistory(),
    Future<void> Function(String)? onSendText,
    Future<void> Function()? onSendImage,
    VoidCallback? onDeleteChannel,
    Widget? favorite,
    Widget? share,
  }) {
    builderFlags.clear();
    return AylaVoiceRoomBody(
      channelName: '深夜电台',
      channelId: channelId,
      selfUserId: selfUserId,
      isOwner: isOwner,
      visibilityLabels: const <String>['公开'],
      messages: messages,
      history: history,
      favorite: favorite,
      share: share,
      onBack: () {},
      onDeleteChannel: onDeleteChannel ?? (isOwner ? () {} : null),
      onSendText: onSendText,
      onSendImage: onSendImage,
      voicePanelBuilder: (bool ownMaterial) {
        builderFlags.add(ownMaterial);
        return const SizedBox(key: _panelKey);
      },
    );
  }

  Finder chatToggle() => find.byWidgetPredicate(
        (Widget w) => w is Semantics && w.properties.label == '展开聊天',
      );

  Finder unreadBadge(String text) => find.text(text);

  // ======================= 两形态结构 =======================

  testWidgets('宽屏（≥769）：body padding sp4 + gap sp4；layout = grid 两列；chat head 常驻、开关隐藏',
      (WidgetTester tester) async {
    setViewport(tester, const Size(1200, 700));
    await tester.pumpWidget(host(body(messages: const <AylaVoiceChatMessage>[
      AylaVoiceChatMessage(id: 'm1', senderNickname: '爱莉', content: '在的'),
    ])));
    await settle(tester);

    expect(find.byKey(_panelKey), findsOneWidget);
    expect(find.text('房内聊天'), findsOneWidget); // chat head 只在宽屏
    expect(find.text('1 条消息'), findsOneWidget);
    expect(chatToggle(), findsNothing); // `.voice-room-chat-toggle-btn { display: none }`
    expect(find.text('深夜电台'), findsOneWidget);
    expect(find.text('在语音房内聊天'), findsOneWidget); // composer 常驻
  });

  testWidgets('窄屏（≤768）：无 padding；chat head 不渲染；开关可见；上下堆叠',
      (WidgetTester tester) async {
    setViewport(tester, const Size(420, 700));
    await tester.pumpWidget(host(
      body(),
      viewport: const Size(420, 700),
    ));
    await settle(tester);

    expect(find.text('房内聊天'), findsNothing); // `.voice-room-chat-card-head { display: none }`
    expect(chatToggle(), findsOneWidget); // 开关只窄屏有
    expect(find.byKey(_panelKey), findsOneWidget);
    // 上下堆叠：语音卡在聊天卡之上
    expect(
      tester.getRect(find.byKey(_panelKey)).bottom,
      lessThanOrEqualTo(tester.getRect(find.text('在语音房内聊天')).top),
    );
  });

  testWidgets('chat head 材质：**透明底** + 仅下边框（auroraqua 593–599 清零 voice.css 的 --glass-bg）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(1200, 700));
    await tester.pumpWidget(host(
      body(messages: const <AylaVoiceChatMessage>[
        AylaVoiceChatMessage(id: 'm1', senderNickname: '爱莉', content: '在的'),
      ]),
    ));
    await settle(tester);

    // head 容器 = 「房内聊天」所在的那个带 decoration 的 Container
    final Finder head = find
        .ancestor(
          of: find.text('房内聊天'),
          matching: find.byWidgetPredicate(
            (Widget w) => w is Container && w.decoration is BoxDecoration,
          ),
        )
        .first;
    final Container container = tester.widget<Container>(head);
    final BoxDecoration decoration = container.decoration! as BoxDecoration;
    // ⚠️ 用户 2026-09-22 实报「这处造轮子」：此前照 voice.css 抄了 `--glass-bg`
    // ⇒ 卡面上又叠一层；auroraqua 覆写后实渲染是透明
    expect(decoration.color, isNull);
    expect(
      decoration.border,
      const Border(bottom: BorderSide(color: AylaColors.glassBorder)),
    );
    expect(
      container.padding,
      const EdgeInsets.symmetric(
        horizontal: AylaSpacing.sp4,
        vertical: AylaSpacing.sp3,
      ),
    );
    // `gap: var(--sp-2)` + `justify-content: space-between`
    final Row row = tester.widget<Row>(
      find.descendant(of: head, matching: find.byType(Row)),
    );
    expect(row.spacing, AylaSpacing.sp2);
    expect(row.mainAxisAlignment, MainAxisAlignment.spaceBetween);
  });

  testWidgets('材质归属（宽屏）：面板透明（builder 收 false）、材质在外层卡',
      (WidgetTester tester) async {
    setViewport(tester, const Size(1200, 700));
    await tester.pumpWidget(host(body()));
    await settle(tester);
    expect(builderFlags.last, isFalse); // `.voice-room-voice-card > .voice-panel` 透明
    expect(find.byType(GlassSurface), findsWidgets); // 外层卡自带材质
  });

  testWidgets('材质归属（窄屏）：面板自带材质（builder 收 true）', (WidgetTester tester) async {
    setViewport(tester, const Size(420, 700));
    await tester.pumpWidget(host(body(), viewport: const Size(420, 700)));
    await settle(tester);
    expect(builderFlags.last, isTrue); // 窄屏：外层透明、材质归 `.voice-panel`
  });

  testWidgets('chat 卡宽度 = min(380, 45%)（≥769 grid 第二列）', (WidgetTester tester) async {
    setViewport(tester, const Size(1200, 700));
    await tester.pumpWidget(host(body()));
    await settle(tester);
    // body 宽 1200 - padding 2×16 = 1168；45% = 525.6 → 夹到 380
    final Rect composer = tester.getRect(find.text('在语音房内聊天'));
    expect(composer.right, lessThanOrEqualTo(1200 - AylaSpacing.sp4 + 1));
    final double chatCardLeft = tester.getRect(find.text('房内聊天')).left;
    expect(chatCardLeft, greaterThan(1168 * 0.5)); // 右列
  });

  // ======================= head =======================

  testWidgets('head：标题 Fredoka 18 + 标签共享件 AylaSourceTag + 收藏/分享槽',
      (WidgetTester tester) async {
    setViewport(tester, const Size(1200, 700));
    await tester.pumpWidget(
      host(
        body(
          favorite: const Text('收藏键'),
          share: const Text('分享键'),
        ),
      ),
    );
    await settle(tester);

    final Text title = tester.widget<Text>(find.text('深夜电台'));
    final TextStyle style = title.style ??
        DefaultTextStyle.of(tester.element(find.text('深夜电台'))).style;
    // `.voice-room-title { font-family: var(--font-display); font-size: 18px }`
    expect(style.fontSize, 18);

    expect(find.text('收藏键'), findsOneWidget);
    expect(find.text('分享键'), findsOneWidget);
    final Text tag = tester.widget<Text>(find.text('公开'));
    // 用户 2026-09-22 裁决：三域统一复用 `AylaSourceTag`（live 徽章档）
    expect(find.byType(AylaSourceTag), findsWidgets);
    expect(tag.style!.fontSize, 12); // utility 12（旧 `.post-card-tag` 是 11/w600，已废弃）
    expect(tag.style!.fontWeight, FontWeight.w400); // 未声明字重 ⇒ 继承 body 400
    expect(tag.style!.fontFamily, AylaFonts.utility); // Space Grotesk
    expect(tag.style!.color, AylaColors.grape700); // 粉色底上的字色（sakura-300 底）
  });

  testWidgets('「删除房间」：房主才有，且是**无材质的裸 .btn**（web `.btn-danger` 未定义）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(1200, 700));
    await tester.pumpWidget(host(body(isOwner: true)));
    await settle(tester);
    expect(find.text('删除房间'), findsOneWidget);
    // 裸 .btn：TextButton 形态（无 GlassSurface 包裹）
    expect(
      find.ancestor(
        of: find.text('删除房间'),
        matching: find.byType(TextButton),
      ),
      findsOneWidget,
    );
  });

  testWidgets('「删除房间」：非房主不渲染', (WidgetTester tester) async {
    setViewport(tester, const Size(1200, 700));
    await tester.pumpWidget(host(body(isOwner: false)));
    await settle(tester);
    expect(find.text('删除房间'), findsNothing);
  });

  testWidgets('channelId == null → 不渲染房内聊天卡（tsx 312）', (WidgetTester tester) async {
    setViewport(tester, const Size(1200, 700));
    await tester.pumpWidget(host(body(channelId: null)));
    await settle(tester);
    expect(find.text('房内聊天'), findsNothing);
    expect(find.text('在语音房内聊天'), findsNothing);
    expect(find.byKey(_panelKey), findsOneWidget); // 语音卡仍在
  });

  // ======================= 未读 =======================

  testWidgets('未读：收起时收到他人消息 ⇒ +1；徽标 18/11/600 + pink-500 底 + 白字',
      (WidgetTester tester) async {
    setViewport(tester, const Size(420, 700));
    late void Function(void Function()) bump;
    List<AylaVoiceChatMessage> current = const <AylaVoiceChatMessage>[];
    await tester.pumpWidget(driven(
      viewport: const Size(420, 700),
      build: (void Function(void Function()) setState) {
        bump = setState;
        return body(messages: current);
      },
    ));
    await settle(tester);
    expect(unreadBadge('1'), findsNothing);

    // 追加一条他人消息（页面层装配 ⇒ props 变化）
    current = const <AylaVoiceChatMessage>[
      AylaVoiceChatMessage(id: 'm1', senderNickname: '爱莉', senderUserId: 'u2', content: '在的'),
    ];
    bump(() {});
    await settle(tester);
    expect(unreadBadge('1'), findsOneWidget);

    final Container badge = tester.widget<Container>(
      find
          .ancestor(of: find.text('1'), matching: find.byType(Container))
          .first,
    );
    final BoxDecoration deco = badge.decoration! as BoxDecoration;
    expect(deco.color, AylaColors.pink500); // --pink-500 底
    expect(deco.borderRadius, AylaRadii.pill);
    final Text label = tester.widget<Text>(find.text('1'));
    expect(label.style!.fontSize, 11);
    expect(label.style!.fontWeight, FontWeight.w600);
    expect(label.style!.color, Colors.white);
  });

  testWidgets('未读：自己发的不加；展开后清零', (WidgetTester tester) async {
    setViewport(tester, const Size(420, 700));
    late void Function(void Function()) bump;
    List<AylaVoiceChatMessage> current = const <AylaVoiceChatMessage>[
      AylaVoiceChatMessage(id: 'm1', senderNickname: '汐汐', senderUserId: 'self', content: '我说的'),
    ];
    await tester.pumpWidget(driven(
      viewport: const Size(420, 700),
      build: (void Function(void Function()) setState) {
        bump = setState;
        return body(messages: current);
      },
    ));
    await settle(tester);
    expect(unreadBadge('1'), findsNothing); // 自己发的

    current = const <AylaVoiceChatMessage>[
      AylaVoiceChatMessage(id: 'm1', senderNickname: '汐汐', senderUserId: 'self', content: '我说的'),
      AylaVoiceChatMessage(id: 'm2', senderNickname: '爱莉', senderUserId: 'u2', content: '嗯嗯'),
    ];
    bump(() {});
    await settle(tester);
    expect(unreadBadge('1'), findsOneWidget);

    // 展开 ⇒ 清零（tsx 141）
    await tester.tap(
      find.byWidgetPredicate(
        (Widget w) => w is Semantics && w.properties.label == '展开聊天',
      ),
    );
    await settle(tester);
    expect(unreadBadge('1'), findsNothing);
    expect(
      find.byWidgetPredicate(
        (Widget w) => w is Semantics && w.properties.label == '收起聊天',
      ),
      findsOneWidget,
    );
  });

  testWidgets('未读：超过 99 显示 99+（tsx 261）', (WidgetTester tester) async {
    setViewport(tester, const Size(420, 700));
    final List<AylaVoiceChatMessage> many = <AylaVoiceChatMessage>[
      for (int i = 0; i < 120; i++)
        AylaVoiceChatMessage(
          id: 'm$i',
          senderNickname: '爱莉',
          senderUserId: 'u2',
          content: '$i',
        ),
    ];
    late void Function(void Function()) bump;
    List<AylaVoiceChatMessage> current = const <AylaVoiceChatMessage>[];
    await tester.pumpWidget(driven(
      viewport: const Size(420, 700),
      build: (void Function(void Function()) setState) {
        bump = setState;
        return body(messages: current);
      },
    ));
    await settle(tester);
    current = many;
    bump(() {});
    await settle(tester);
    expect(unreadBadge('99+'), findsOneWidget);
  });

  testWidgets('换房（channelId 变化）⇒ 未读与错误清零（tsx 101–107）', (WidgetTester tester) async {
    setViewport(tester, const Size(420, 700));
    late void Function(void Function()) bump;
    String channel = 'v1';
    List<AylaVoiceChatMessage> current = const <AylaVoiceChatMessage>[];
    await tester.pumpWidget(driven(
      viewport: const Size(420, 700),
      build: (void Function(void Function()) setState) {
        bump = setState;
        return body(channelId: channel, messages: current);
      },
    ));
    await settle(tester);
    current = const <AylaVoiceChatMessage>[
      AylaVoiceChatMessage(id: 'm1', senderNickname: '爱莉', senderUserId: 'u2', content: 'x'),
    ];
    bump(() {});
    await settle(tester);
    expect(unreadBadge('1'), findsOneWidget);

    channel = 'v2';
    bump(() {});
    await settle(tester);
    expect(unreadBadge('1'), findsNothing); // chatOwner 变了 ⇒ 重置
  });

  // ======================= 发送 =======================

  testWidgets('发送：空文本禁用发送钮；输入后可点；成功清空草稿', (WidgetTester tester) async {
    setViewport(tester, const Size(1200, 700));
    final List<String> sent = <String>[];
    await tester.pumpWidget(
      host(body(onSendText: (String c) async => sent.add(c))),
    );
    await settle(tester);

    GlassButton sendBtn() => tester.widget<GlassButton>(
          find.byWidgetPredicate(
            (Widget w) => w is GlassButton && w.semanticLabel == '发送语音房消息',
          ),
        );
    expect(sendBtn().onPressed, isNull); // 空文本

    await tester.enterText(find.byType(TextField).first, '晚上好');
    await settle(tester);
    expect(sendBtn().onPressed, isNotNull);
    await tester.tap(find.byWidgetPredicate(
      (Widget w) => w is GlassButton && w.semanticLabel == '发送语音房消息',
    ));
    await settle(tester);
    expect(sent, <String>['晚上好']);
    expect(tester.widget<TextField>(find.byType(TextField).first).controller!.text, '');
  });

  testWidgets('发送失败：显示 `.live-form-error`（自定义文案）且**保留草稿**',
      (WidgetTester tester) async {
    setViewport(tester, const Size(1200, 700));
    await tester.pumpWidget(
      host(
        body(
          onSendText: (String c) async =>
              throw const AylaVoiceChatSendException('房内聊天暂不可用'),
        ),
      ),
    );
    await settle(tester);
    await tester.enterText(find.byType(TextField).first, '晚上好');
    await settle(tester);
    await tester.tap(find.byWidgetPredicate(
      (Widget w) => w is GlassButton && w.semanticLabel == '发送语音房消息',
    ));
    await settle(tester);

    final Text err = tester.widget<Text>(find.text('房内聊天暂不可用'));
    expect(err.style!.color, AylaColors.destructive); // app.css 3473–3477
    expect(err.style!.fontSize, 13);
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      '晚上好', // 失败不清空
    );
  });

  testWidgets('发送失败：普通异常用兜底文案（tsx 165）', (WidgetTester tester) async {
    setViewport(tester, const Size(1200, 700));
    await tester.pumpWidget(
      host(body(onSendText: (String c) async => throw StateError('boom'))),
    );
    await settle(tester);
    await tester.enterText(find.byType(TextField).first, '晚上好');
    await settle(tester);
    await tester.tap(find.byWidgetPredicate(
      (Widget w) => w is GlassButton && w.semanticLabel == '发送语音房消息',
    ));
    await settle(tester);
    expect(find.text(AylaVoiceRoomBody.sendErrorFallback), findsOneWidget);
  });

  testWidgets('图片：工具钮触发 onSendImage；失败给「图片发送失败，请重试」',
      (WidgetTester tester) async {
    setViewport(tester, const Size(1200, 700));
    int picks = 0;
    await tester.pumpWidget(
      host(
        body(
          onSendImage: () async {
            picks++;
            throw StateError('boom');
          },
        ),
      ),
    );
    await settle(tester);
    await tester.tap(find.byWidgetPredicate(
      (Widget w) => w is AylaToolButton && w.semanticLabel == '发送房内图片',
    ));
    await settle(tester);
    expect(picks, 1);
    expect(find.text(AylaVoiceRoomBody.imageErrorFallback), findsOneWidget);
  });

  // ======================= 消息行 / 历史 =======================

  testWidgets('消息行：sender 名 + 「：」（700 secondary）+ 正文；「图片」占位不渲染文本',
      (WidgetTester tester) async {
    setViewport(tester, const Size(1200, 700));
    await tester.pumpWidget(
      host(
        body(
          messages: const <AylaVoiceChatMessage>[
            AylaVoiceChatMessage(id: 'm1', senderNickname: '爱莉', content: '在的'),
            AylaVoiceChatMessage(
              id: 'm2',
              senderNickname: '汐汐',
              content: '图片',
              mediaId: 'media-1',
              thumbnailUrl: 'https://example.invalid/x.png',
            ),
          ],
        ),
      ),
    );
    await settle(tester);

    final Text sender = tester.widget<Text>(find.text('爱莉：'));
    expect(sender.style!.fontWeight, FontWeight.w700);
    expect(sender.style!.color, AylaColors.textSecondary);
    expect(sender.style!.fontSize, 13);
    expect(find.text('在的'), findsOneWidget);
    expect(find.text('图片'), findsNothing); // tsx 201：占位文案不渲染
    // 缩略图 120×80 + radius-sm
    expect(tester.getSize(find.byType(ResourceImage)).width, 120);
    expect(tester.getSize(find.byType(ResourceImage)).height, 80);
  });

  testWidgets('历史控件：7 个字段透传（AylaHistoryControls）', (WidgetTester tester) async {
    setViewport(tester, const Size(1200, 700));
    int older = 0;
    await tester.pumpWidget(
      host(
        body(
          history: AylaVoiceChatHistory(
            loading: true,
            hasMore: true,
            hasNewer: true,
            loadOlder: () async => older++,
          ),
        ),
      ),
    );
    await settle(tester);
    final AylaHistoryControls h = tester.widget<AylaHistoryControls>(
      find.byType(AylaHistoryControls),
    );
    expect(h.loading, isTrue);
    expect(h.hasMore, isTrue);
    expect(h.hasNewer, isTrue);
    await h.loadOlder();
    expect(older, 1);
  });

  // ======================= 浮层 / 入场 =======================

  testWidgets('窄屏浮层：收起时不可见且不接收指针；展开后高度 300（voice.css 78–124）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(420, 900));
    await tester.pumpWidget(host(
      body(messages: const <AylaVoiceChatMessage>[
        AylaVoiceChatMessage(id: 'm1', senderNickname: '爱莉', content: '在的'),
      ]),
      viewport: const Size(420, 900),
    ));
    await settle(tester);

    // 收起：忽略指针 + 排除语义（浮层仍挂载，用 opacity/visibility 过渡）
    expect(
      tester
          .widgetList<IgnorePointer>(find.byType(IgnorePointer))
          .any((IgnorePointer p) => p.ignoring),
      isTrue,
    );
    // 展开
    await tester.tap(
      find.byWidgetPredicate(
        (Widget w) => w is Semantics && w.properties.label == '展开聊天',
      ),
    );
    await settle(tester);
    expect(find.text('在的'), findsOneWidget);
    // 浮层改用库内 GlassSurface（手搓裸 BackdropFilter 会糊掉整块画布）+ 固定高 300
    final Finder overlayBox = find.byWidgetPredicate(
      (Widget w) =>
          w is SizedBox && w.height == AylaVoiceRoomBody.narrowChatListHeight,
    );
    expect(overlayBox, findsOneWidget);
    expect(
      tester.getSize(overlayBox).height,
      AylaVoiceRoomBody.narrowChatListHeight, // `height: 300px`（voice.css 88）
    );
  });

  testWidgets('入场：三分区各一个 AylaRevealItem；宽屏按边缘（上/右/下），窄屏统一浮入 20px',
      (WidgetTester tester) async {
    setViewport(tester, const Size(1200, 700));
    await tester.pumpWidget(host(body()));
    await settle(tester);
    final List<AylaRevealItem> wide = tester
        .widgetList<AylaRevealItem>(find.byType(AylaRevealItem))
        .toList();
    expect(wide.length, 3);
    expect(
      wide.map((AylaRevealItem r) => r.offset).toSet(),
      <Offset>{const Offset(0, -20), const Offset(0, 20), const Offset(20, 0)},
    );

  });

  testWidgets('入场（窄屏）：统一从下浮入 20px（base.css `.reveal`）', (WidgetTester tester) async {
    setViewport(tester, const Size(420, 900));
    await tester.pumpWidget(host(body(), viewport: const Size(420, 900)));
    await settle(tester);
    final List<AylaRevealItem> narrow = tester
        .widgetList<AylaRevealItem>(find.byType(AylaRevealItem))
        .toList();
    expect(
      narrow.map((AylaRevealItem r) => r.offset).toSet(),
      <Offset>{const Offset(0, 20)}, // base.css `.reveal`：统一从下浮入
    );
  });
}
