/// 语音房房内聊天「贴底跟随」回归锁 —— 用户 2026-10-26 实报
/// 「语音房聊天老是新消息不自动滚底」。
///
/// ## 根因（三条叠加，全部是**接线缺口**，不是数据层问题）
/// 1. **零消费方**：`voice_support.dart` 建的
///    `AylaCursorHistory<api.AylaVoiceChatMessage>` 在 `append` 时只把
///    `pendingScrollToBottom` 置位（`cursor_history.dart:301`），**全仓没有任何消费方**
///    ⇒ 新消息进了窗口但列表原地不动。
/// 2. **控制器归属错**：`voice_room_body.dart` 自己 `new ScrollController()`，页面拿不到
///    ⇒ 想消费也消费不了。web 是反过来的：滚动容器归数据 hook
///    （`useCursorHistory.ts:54` `listRef`，`VoiceRoomBody.tsx:97` 取 `history.listRef`）。
/// 3. **无滚动上报**：web 有 `onScroll={history.handleScroll}`（`tsx:187` →
///    `useCursorHistory.ts:160–164`：距底 < 40 才继续跟随）；Flutter 侧没有 ⇒
///    `following` 恒为 true ⇒ 修好 ① 之后会变成「上翻读历史时被强行拉到底」。
///
/// ## 本文件锁什么（对齐 `live_danmaku_follow_test.dart` 的 ①–④ 组写法）
/// ① 绑定层：`AylaCursorHistory.append` + 真实 `ScrollController`/列表 ⇒ 贴底；
/// ② 绑定层：用户上翻 > 40px 后 `append` ⇒ **不贴底**、`hasNewer` 亮（web 语义）；
/// ③ 绑定层：`jumpToBottom()` ⇒ 贴底 + `following` 恢复；
/// ④ 装配层：页面注入了控制器 / 跟随上报，组件新增了 `chatListScroll` 参数；
/// ⑤ 组件层：`AylaVoiceRoomBody` 真的用注入的控制器滚列表（端到端接线）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ayla_flutter/core/api/media_page.dart';
import 'package:ayla_flutter/state/cursor_history.dart';
import 'package:ayla_flutter/theme/preview_theme.dart';
import 'package:ayla_flutter/widgets/base/history_scroll_binding.dart';
import 'package:ayla_flutter/widgets/voice/voice_room_body.dart';

/// 历史条目（形状对齐 `api.AylaVoiceChatMessage` 的 id / createdAt 投影键）。
class _Row {
  const _Row(this.id, this.at, this.text);
  final String id;
  final String at;
  final String text;
}

/// 内存版 `listVoiceChatMessagesPage`。
AylaCursorHistory<_Row> _history(List<_Row> seed) =>
    AylaCursorHistory<_Row>(
      owner: 'voice-chat:self:v1',
      fetchPage: (String? cursor, String? beforeId) async =>
          AylaMediaCursorPage<_Row>(results: seed),
      idOf: (_Row r) => r.id,
      createdAtOf: (_Row r) => r.at,
    );

/// 40 条，足以在 200 高的列表槽里撑出滚动。
List<_Row> _many() => <_Row>[
      for (int i = 0; i < 40; i++)
        _Row('e${i.toString().padLeft(3, '0')}',
            '2026-10-26T10:00:${i.toString().padLeft(2, '0')}Z', 'c$i'),
    ];

/// 读仓库内文件（静态接线审计用；cwd = flutter/）。
String _read(String relative) => File(relative).readAsStringSync();

/// 宿主：把组件与注入的控制器装进固定视口（触发真实滚动语义）。
///
/// ⚠️ **必须跟着历史窗口重建**：真实页面里 `_chat` 的 listener 是
/// `_onChanged() => setState(() {})`（`voice_support.dart`），新消息先经 setState
/// 进 `widget.messages`，才有更高的内容高度可供滚动 —— web 同理（`useCursorHistory`
/// 的 `setState` 才触发 `useLayoutEffect`）。静态 `messages` 的宿主会停在旧高度，
/// 测出来的「没滚到底」是宿主假象，不是产品缺陷。
Widget _listFrom(
  AylaCursorHistory<_Row> history,
  ScrollController controller,
) =>
    MaterialApp(
      home: previewScope(
        Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(size: const Size(420, 300)),
            child: _HistoryDriven(
              history: history,
              controller: controller,
            ),
          ),
        ),
      ),
    );

class _HistoryDriven extends StatefulWidget {
  const _HistoryDriven({required this.history, required this.controller});

  final AylaCursorHistory<_Row> history;
  final ScrollController controller;

  @override
  State<_HistoryDriven> createState() => _HistoryDrivenState();
}

class _HistoryDrivenState extends State<_HistoryDriven> {
  @override
  void initState() {
    super.initState();
    widget.history.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.history.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 300,
        width: 420,
        child: AylaVoiceRoomBody(
          channelName: '深夜电台',
          channelId: 'v1',
          selfUserId: 'self',
          messages: <AylaVoiceChatMessage>[
            for (final _Row r in widget.history.items)
              AylaVoiceChatMessage(
                  id: r.id, senderNickname: '爱莉', content: r.text),
          ],
          chatListScroll: widget.controller,
          onBack: () {},
          voicePanelBuilder: (bool ownMaterial) => const SizedBox.expand(),
        ),
      );
}


/// 让绑定的「排帧消费 + 跟 [kAylaHistorySettleFrames] 帧」全部走完。
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  for (int i = 0; i < kAylaHistorySettleFrames + 2; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  await tester.pump();
}

void main() {
  group('① 绑定层：append 后贴底（web useCursorHistory 的 anchor=bottom）', () {
    testWidgets('新消息进窗口 ⇒ 列表落到 maxScrollExtent', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(420, 400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final AylaCursorHistory<_Row> history = _history(_many());
      addTearDown(history.dispose);
      await history.reset();

      final ScrollController controller = ScrollController();
      final AylaHistoryScrollBinding<_Row> binding =
          AylaHistoryScrollBinding<_Row>(history: history, controller: controller)
            ..bind();
      addTearDown(() {
        binding.dispose();
        controller.dispose();
      });

      await tester.pumpWidget(_listFrom(history, controller));
      await _settle(tester);
      final ScrollPosition p = controller.position;
      expect(p.maxScrollExtent, greaterThan(0.0),
          reason: '40 条必须可滚动（否则本测试无意义）');

      // 跟随态：停在（旧）底部。append 之后内容变高、pixels 不动 ⇒ 判别力来自
      // 「新 maxScrollExtent 比旧的大，而 pixels 仍停在旧值」这一段。
      // ⚠️ 不能先 jumpTo(0)：那会让绑定把 following 判成 false，append 就退化成
      // 「上翻期间只亮按钮」（那是 ② 的语义，见 web append 的 `!following || hasNewer`
      // 分支 —— useCursorHistory.ts:150）。
      controller.jumpTo(p.maxScrollExtent);
      await tester.pump();
      expect(history.following, isTrue, reason: '贴底 ⇒ 跟随');
      final double oldMax = p.maxScrollExtent;

      history.append(const _Row('new1', '2026-10-26T10:01:00Z', 'new'));
      await _settle(tester);

      expect(p.maxScrollExtent, greaterThan(oldMax),
          reason: '新消息必须真的把内容撑高（否则本测试无判别力）');
      expect(p.pixels, moreOrLessEquals(p.maxScrollExtent, epsilon: 0.5),
          reason: '新消息 append 后必须贴底（web useCursorHistory.ts:67–78）');
    });

    testWidgets('无新消息时不动滚动位置（不伪造贴底）', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(420, 400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final AylaCursorHistory<_Row> history = _history(_many());
      addTearDown(history.dispose);
      await history.reset();

      final ScrollController controller = ScrollController();
      final AylaHistoryScrollBinding<_Row> binding =
          AylaHistoryScrollBinding<_Row>(history: history, controller: controller)
            ..bind();
      addTearDown(() {
        binding.dispose();
        controller.dispose();
      });

      await tester.pumpWidget(_listFrom(history, controller));
      await _settle(tester);
      controller.jumpTo(30);
      await tester.pump();
      final double before = controller.position.pixels;
      await _settle(tester);
      expect(controller.position.pixels, moreOrLessEquals(before, epsilon: 0.5),
          reason: '没有 pendingScrollToBottom 就不得动列表');
    });
  });

  group('② 绑定层：上翻 >40px 后 append ⇒ 不贴底、hasNewer 亮（web 语义）', () {
    testWidgets('following 由控制器监听判定，上翻即停', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(420, 400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final AylaCursorHistory<_Row> history = _history(_many());
      addTearDown(history.dispose);
      await history.reset();

      final ScrollController controller = ScrollController();
      final AylaHistoryScrollBinding<_Row> binding =
          AylaHistoryScrollBinding<_Row>(history: history, controller: controller)
            ..bind();
      addTearDown(() {
        binding.dispose();
        controller.dispose();
      });

      await tester.pumpWidget(_listFrom(history, controller));
      await _settle(tester);

      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pump();
      expect(history.following, isTrue, reason: '贴底 ⇒ 跟随');
      controller.jumpTo(0);
      await tester.pump();
      expect(history.following, isFalse, reason: '距底 > 40 ⇒ 停跟随');

      final double before = controller.position.pixels;
      history.append(const _Row('new2', '2026-10-26T10:02:00Z', 'new'));
      await _settle(tester);

      expect(history.hasNewer, isTrue,
          reason: '上翻期间新内容只亮「返回最新消息」（cursor_history.dart:296–300）');
      expect(controller.position.pixels, moreOrLessEquals(before, epsilon: 0.5),
          reason: '上翻读历史时新消息**不得**把列表强行拉到底（web 明确不会）');
      expect(history.items.length, _many().length,
          reason: '脱挂期间新内容不进已读窗口');
    });
  });

  group('③ 绑定层：jumpToBottom ⇒ 贴底 + following 恢复', () {
    testWidgets('「返回最新消息」的落位语义', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(420, 400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final AylaCursorHistory<_Row> history = _history(_many());
      addTearDown(history.dispose);
      await history.reset();

      final ScrollController controller = ScrollController();
      final AylaHistoryScrollBinding<_Row> binding =
          AylaHistoryScrollBinding<_Row>(history: history, controller: controller)
            ..bind();
      addTearDown(() {
        binding.dispose();
        controller.dispose();
      });

      await tester.pumpWidget(_listFrom(history, controller));
      await _settle(tester);

      controller.jumpTo(0);
      await tester.pump();
      expect(history.following, isFalse);

      binding.jumpToBottom();
      await _settle(tester);
      expect(controller.position.pixels,
          moreOrLessEquals(controller.position.maxScrollExtent, epsilon: 0.5));
      expect(history.following, isTrue, reason: '跳回最新 ⇒ 恢复跟随');
      expect(binding.isAtBottom, isTrue);
      expect(binding.distanceToBottom, lessThan(kAylaHistoryBottomSlack));
    });
  });

  group('④ 装配层：页面接线（静态锁）', () {
    void expectWired(String path, List<String> required) {
      final String text = _read(path);
      for (final String token in required) {
        expect(text.contains(token), isTrue, reason: '$path 缺少接线：$token');
      }
    }

    test('voice_support.dart：控制器上移 + 绑定 + 注入', () {
      expectWired('lib/pages/voice_support.dart', <String>[
        'AylaHistoryScrollBinding<api.AylaVoiceChatMessage>',
        'controller: _chatScroll,',
        ')..bind();',
        'chatListScroll: _chatScroll,',
        'setFollowing: _chat.setFollowing,',
        '_chatScrollBinding.dispose();',
      ]);
    });

    test('voice_room_body.dart：控制器可由外部注入、且不释放外部控制器', () {
      expectWired('lib/widgets/voice/voice_room_body.dart', <String>[
        'final ScrollController? chatListScroll;',
        'this.chatListScroll,',
        'widget.chatListScroll ?? _ownScroll',
        'final ValueChanged<bool>? setFollowing;',
        '_ownScroll.dispose();',
      ]);
      expect(
        _read('lib/widgets/voice/voice_room_body.dart')
            .contains('_listScroll.dispose()'),
        isFalse,
        reason: '注入的控制器归页面所有；组件不得释放它',
      );
    });
  });

  group('⑤ 组件层：注入的控制器真的驱动列表（端到端）', () {
    testWidgets('同一条 append 会把组件列表滚到底', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(420, 400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final AylaCursorHistory<_Row> history = _history(_many());
      addTearDown(history.dispose);
      await history.reset();

      final ScrollController controller = ScrollController();
      final AylaHistoryScrollBinding<_Row> binding =
          AylaHistoryScrollBinding<_Row>(history: history, controller: controller)
            ..bind();
      addTearDown(() {
        binding.dispose();
        controller.dispose();
      });

      await tester.pumpWidget(_listFrom(history, controller));
      await _settle(tester);
      expect(controller.hasClients, isTrue,
          reason: '组件必须把 widget.chatListScroll 挂到列表上');
      final ScrollPosition p = controller.position;
      expect(p.maxScrollExtent, greaterThan(0.0));

      // 组件列表停在底部（跟随态）⇒ 新消息必须把它带到新的底部
      controller.jumpTo(p.maxScrollExtent);
      await tester.pump();
      final double oldMax = p.maxScrollExtent;
      history.append(const _Row('new3', '2026-10-26T10:03:00Z', 'new'));
      await _settle(tester);
      expect(p.maxScrollExtent, greaterThan(oldMax));
      expect(p.pixels, moreOrLessEquals(p.maxScrollExtent, epsilon: 0.5),
          reason: '语音房真实列表必须跟随到新消息');
    });
  });

  /// 组件自己的滚动上报（web `onScroll={history.handleScroll}`，tsx:187）。
  ///
  /// 页面注入了控制器时，首选消费者是绑定（它也监听同一个控制器）；但组件被单独
  /// 使用时（画布 / 本文件这种最小宿主）必须有同一语义，否则 `following` 恒 true
  /// ⇒ 用户上翻读历史时新消息会被强行拉到底（web 明确不会）。
  group('⑥ 组件层：上翻上报 following（web tsx:187 / useCursorHistory.ts:160–164）',
      () {
    testWidgets('jumpTo(0) ⇒ setFollowing(false)；贴底 ⇒ setFollowing(true)',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(420, 400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final ScrollController controller = ScrollController();
      addTearDown(controller.dispose);
      final List<bool> reports = <bool>[];
      final List<AylaVoiceChatMessage> rows = <AylaVoiceChatMessage>[
        for (final _Row r in _many())
          AylaVoiceChatMessage(
              id: r.id, senderNickname: '爱莉', content: r.text),
      ];

      await tester.pumpWidget(MaterialApp(
        home: previewScope(
          Builder(
            builder: (BuildContext context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(size: const Size(420, 300)),
              child: SizedBox(
                height: 300,
                width: 420,
                child: AylaVoiceRoomBody(
                  channelName: '深夜电台',
                  channelId: 'v1',
                  selfUserId: 'self',
                  messages: rows,
                  chatListScroll: controller,
                  history: AylaVoiceChatHistory(
                    setFollowing: reports.add,
                  ),
                  onBack: () {},
                  voicePanelBuilder: (bool ownMaterial) =>
                      const SizedBox.expand(),
                ),
              ),
            ),
          ),
        ),
      ));
      await _settle(tester);
      expect(controller.hasClients, isTrue);

      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pump();
      expect(reports, isNotEmpty, reason: '滚动必须上报给页面（web onScroll）');
      expect(reports.last, isTrue, reason: '贴底 ⇒ 继续跟随');

      controller.jumpTo(0);
      await tester.pump();
      expect(controller.position.maxScrollExtent, greaterThan(kAylaHistoryBottomSlack),
          reason: '可滚高度必须 > 40px 容差，否则判定无意义');
      expect(reports.last, isFalse, reason: '距底 > 40 ⇒ 停跟随');
    });

    testWidgets('窗口已脱挂（hasNewer）时不上报（web 那条 `&& !hasNewer`）',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(420, 400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final ScrollController controller = ScrollController();
      addTearDown(controller.dispose);
      int reports = 0;
      await tester.pumpWidget(MaterialApp(
        home: previewScope(
          Builder(
            builder: (BuildContext context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(size: const Size(420, 300)),
              child: SizedBox(
                height: 300,
                width: 420,
                child: AylaVoiceRoomBody(
                  channelName: '深夜电台',
                  channelId: 'v1',
                  selfUserId: 'self',
                  messages: <AylaVoiceChatMessage>[
                    for (final _Row r in _many())
                      AylaVoiceChatMessage(
                          id: r.id,
                          senderNickname: '爱莉',
                          content: r.text),
                  ],
                  chatListScroll: controller,
                  history: AylaVoiceChatHistory(
                    hasNewer: true,
                    setFollowing: (_) => reports++,
                  ),
                  onBack: () {},
                  voicePanelBuilder: (bool ownMaterial) =>
                      const SizedBox.expand(),
                ),
              ),
            ),
          ),
        ),
      ));
      await _settle(tester);
      controller.jumpTo(0);
      await tester.pump();
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pump();
      expect(reports, 0,
          reason: '脱挂期间不得把 following 翻回 true —— 否则停在底部的读者会被新消息'
              '强行拉到底（web useCursorHistory.ts:163 的 && !hasNewer）');
    });
  });
}
