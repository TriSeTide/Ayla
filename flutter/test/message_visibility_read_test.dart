/// 「屏幕中看到即已读」定向测试 —— 对照 `components/chat/MessageList.tsx:896–922`
/// 与 `stores/message.ts:85–88`。
///
/// 覆盖：
/// 1. 纯函数 `aylaMessageVisibleRatio`（= `IntersectionObserverEntry.intersectionRatio`）；
/// 2. 几何边界：10 条、视口露出 6 条、第 6 条露出比例 0.5
///    ⇒ 前 5 条各触发一次，第 6 条与其余**不触发**（tsx 904 的 `< 0.6` ⇒ continue）；
/// 3. `AylaMessageList` 端到端的条件过滤（tsx 907：`read_by_me` / 自己发的 / `poke` / 在途）；
/// 4. in-flight 去重与「同一帧重复通知只调一次」（tsx 908–909）；
/// 5. `prefers-reduced-motion`（`MediaQuery.disableAnimations`）不影响已读判定；
/// 6. 观察节点 = 含时间分隔的**外层行 wrapper**（tsx 1030–1035 / 1048–1053 口径）。
///
/// ## 环境注意（本项目实测坑，本文件全部按此构造）
/// - 默认测试表面 800×600 ⇒ 几何断言先 `tester.view.physicalSize` + `addTearDown`；
/// - 宿主高度必须**由同一份 `MediaQuery` 决定**（内层 `Builder` 读尺寸），
///   否则「宿主 800 / 视口 600」会把第 6 条挤出视口；
/// - 探针的测量排在 post-frame ⇒ 每次改动后 `pump()` 起帧、再 `pump(时长)` 走完。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/chat_message.dart';
import '../lib/core/models/conversation.dart';
import '../lib/core/models/user_public.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/widgets/chat/message_list.dart';
import '../lib/widgets/chat/message_visibility.dart';

AylaChatMessage _msg({
  required String id,
  required int seq,
  required String senderId,
  String content = '',
  AylaMessageType type = AylaMessageType.text,
  bool? readByMe,
  bool pending = false,
  bool sendFailed = false,
  DateTime? at,
}) =>
    AylaChatMessage(
      id: id,
      conversationId: 'c1',
      senderId: senderId,
      type: type,
      content: content,
      status: AylaMessageStatus.sent,
      seq: seq,
      readByMe: readByMe,
      pending: pending,
      sendFailed: sendFailed,
      createdAt: (at ?? DateTime(2026, 9, 24, 21, 30)).toUtc().toIso8601String(),
    );

AylaConversationSummary _conv() => AylaConversationSummary(
      id: 'c1',
      type: AylaConversationType.group,
      title: '深夜电台群',
      avatar: '',
      members: <AylaConversationMember>[
        AylaConversationMember(
          id: 'm1',
          user: const AylaUserPublic(id: 'u1', nickname: '汐汐', username: 'xixi'),
        ),
      ],
    );

void main() {
  // ======================= 纯函数：intersectionRatio =======================

  group('aylaMessageVisibleRatio（= IntersectionObserverEntry.intersectionRatio）', () {
    test('阈值常量对齐 web threshold: 0.6（tsx 904 / 912）', () {
      expect(kAylaMessageReadVisibleRatio, 0.6);
    });

    test('完全在视口内 ⇒ 1；完全在外 ⇒ 0；一半 ⇒ 0.5', () {
      const Rect self = Rect.fromLTWH(0, 100, 200, 120);
      expect(aylaMessageVisibleRatio(self, const Rect.fromLTWH(0, 0, 400, 800)), 1.0);
      expect(aylaMessageVisibleRatio(self, const Rect.fromLTWH(0, 0, 400, 50)), 0.0);
      // 视口下沿切在 160 ⇒ 露出 60/120
      expect(
        aylaMessageVisibleRatio(self, const Rect.fromLTWH(0, 0, 400, 160)),
        closeTo(0.5, 1e-9),
      );
    });

    test('视口为 null（无祖先 viewport）⇒ 0，不误判为可见', () {
      expect(aylaMessageVisibleRatio(const Rect.fromLTWH(0, 0, 10, 10), null), 0.0);
    });

    test('零尺寸目标 ⇒ 0（web 对零尺寸目标不越过阈值）', () {
      expect(
        aylaMessageVisibleRatio(const Rect.fromLTWH(0, 0, 0, 0), const Rect.fromLTWH(0, 0, 400, 800)),
        0.0,
      );
    });
  });

  // ======================= 几何边界 =======================

  testWidgets('10 条、露出 6 条、第 6 条 0.5 ⇒ 只有前 5 条触发一次', (WidgetTester tester) async {
    // 几何：padding 12 + 行高 120 + 行距 10 ⇒ 第 i 条 top = 12 + (i-1)*130
    //   · 第 5 条 bottom = 652 ≤ 720（720 即 web 的 clientHeight，非窗口高度）
    //   · 第 6 条 top = 662 ⇒ 露出 58/120 ≈ 0.4833 < 0.6 ⇒ 必须**不触发**
    const double viewportHeight = 720;
    const double rowHeight = 120;
    const double rowGap = 10;
    const double padding = 12;

    tester.view.physicalSize = const Size(720, viewportHeight);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final List<String> fired = <String>[];
    addTearDown(() => fired.clear());

    await tester.pumpWidget(
      MaterialApp(
        home: previewTheme(
          Builder(
            builder: (BuildContext context) {
              final Size size = MediaQuery.sizeOf(context);
              return SizedBox(
                width: size.width,
                height: size.height,
                child: ListView.builder(
                  padding: const EdgeInsets.all(padding),
                  itemCount: 10,
                  itemBuilder: (BuildContext context, int index) {
                    final String id = 'm${index + 1}';
                    // 与 `AylaMessageList._row` 同构：探针包住「时间分隔 + 行内容」。
                    return Padding(
                      padding: const EdgeInsets.only(bottom: rowGap),
                      child: AylaMessageVisibilityProbe(
                        messageId: id,
                        onVisible: () => fired.add(id),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            const SizedBox(height: 0),
                            SizedBox(height: rowHeight, child: const SizedBox.expand()),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              );
            },
          ),
        ),
      ),
    );
    // 先起帧（post-frame 回调在本帧末执行），再走一帧收尾。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      fired,
      <String>['m1', 'm2', 'm3', 'm4', 'm5'],
      reason: '视口 720 内完整可见的是前 5 条；第 6 条露出 0.483 < 0.6 ⇒ 不触发，其余更不触发',
    );
  });

  testWidgets('滚动进入视口才触发（先露 2 条，滚动后补触发更多）', (WidgetTester tester) async {
    const double viewportHeight = 300; // 只露前 2 条（12 + 2*130 = 272 ≤ 300）
    const double rowHeight = 120;
    const double rowGap = 10;

    tester.view.physicalSize = const Size(720, viewportHeight);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final List<String> fired = <String>[];
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: previewTheme(
          Builder(
            builder: (BuildContext context) {
              final Size size = MediaQuery.sizeOf(context);
              return SizedBox(
                width: size.width,
                height: size.height,
                child: ListView.builder(
                  controller: controller,
                  padding: const EdgeInsets.all(12),
                  itemCount: 10,
                  itemBuilder: (BuildContext context, int index) {
                    final String id = 'm${index + 1}';
                    return Padding(
                      padding: const EdgeInsets.only(bottom: rowGap),
                      child: AylaMessageVisibilityProbe(
                        messageId: id,
                        onVisible: () => fired.add(id),
                        child: SizedBox(height: rowHeight, child: const SizedBox.expand()),
                      ),
                    );
                  },
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(fired, <String>['m1', 'm2'], reason: '初始视口只露 2 条');

    // 向下滚动（非 reverse 列表）⇒ 后续行进入视口
    controller.jumpTo(260);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      fired,
      <String>['m1', 'm2', 'm3', 'm4'],
      reason: '跳转后第 3、4 条进入视口（top 272 / 402，视口 260–560）',
    );
  });

  // ======================= AylaMessageList 端到端 =======================

  testWidgets('条件过滤（tsx 907）：已读 / 自己发的 / poke / 本地未确认 一律不触发', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(720, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final List<String> marked = <String>[];
    final DateTime base = DateTime(2026, 9, 24, 21, 0);

    await tester.pumpWidget(
      MaterialApp(
        home: previewTheme(
          Builder(
            builder: (BuildContext context) {
              final Size size = MediaQuery.sizeOf(context);
              return SizedBox(
                width: size.width,
                height: size.height,
                child: AylaMessageList(
                  messages: <AylaChatMessage>[
                    _msg(id: 'm1', seq: 1, senderId: 'u1', content: '未读 1', at: base),
                    _msg(
                      id: 'm2',
                      seq: 2,
                      senderId: 'u1',
                      content: '已读',
                      readByMe: true,
                      at: base.add(const Duration(minutes: 10)),
                    ),
                    _msg(
                      id: 'm3',
                      seq: 3,
                      senderId: 'me',
                      content: '自己发的',
                      at: base.add(const Duration(minutes: 20)),
                    ),
                    _msg(
                      id: 'm4',
                      seq: 4,
                      senderId: 'u1',
                      type: AylaMessageType.poke,
                      content: 'u1',
                      at: base.add(const Duration(minutes: 30)),
                    ),
                    _msg(
                      id: 'm5',
                      seq: 5,
                      senderId: 'u2',
                      content: '未读 2',
                      at: base.add(const Duration(minutes: 40)),
                    ),
                    _msg(
                      id: 'm6',
                      seq: 6,
                      senderId: 'u1',
                      content: '乐观发送中',
                      pending: true,
                      at: base.add(const Duration(minutes: 50)),
                    ),
                  ],
                  conversation: _conv(),
                  currentUserId: 'me',
                  onMarkRead: (AylaChatMessage m, bool exact) async {
                    expect(exact, isTrue, reason: '必须走精确已读路径（web tsx 909 传 true）');
                    marked.add(m.id);
                  },
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // ⚠️ 不比较顺序：`AylaMessageList` 是 `reverse: true`，`ListView.builder` 从
    // 列表尾部（最新）开始建项 ⇒ 探针的 post-frame 回调顺序是「新 → 旧」，
    // 而 web 是正向 DOM 顺序。IO 是逐条独立判定，次序无语义。
    expect(marked.toSet(), <String>{'m1', 'm5'});
    expect(marked.length, 2, reason: '两条未读各上报一次（无重复）');
  });

  testWidgets('in-flight 去重（tsx 907–909）：请求未落地 + 滚动往返也**只调一次**', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(720, 360);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final List<String> marked = <String>[];
    final DateTime base = DateTime(2026, 9, 24, 21, 0);

    await tester.pumpWidget(
      MaterialApp(
        home: previewTheme(
          Builder(
            builder: (BuildContext context) {
              final Size size = MediaQuery.sizeOf(context);
              return SizedBox(
                width: size.width,
                height: size.height,
                child: AylaMessageList(
                  messages: <AylaChatMessage>[
                    for (int i = 0; i < 20; i++)
                      _msg(
                        id: 'm$i',
                        seq: i + 1,
                        senderId: 'u1',
                        content: '第 $i 行消息内容，用于撑高列表',
                        at: base.add(Duration(minutes: i)),
                      ),
                  ],
                  conversation: _conv(),
                  currentUserId: 'me',
                  // 永远不完成 ⇒ 始终处于 in-flight（web 的 pendingReadIdsRef 同样
                  // 在 finally 前拦住重复上报）。
                  onMarkRead: (AylaChatMessage m, bool exact) {
                    marked.add(m.id);
                    return Completer<void>().future;
                  },
                ),
              );
            },
          ),
        ),
      ),
    );
    // ⚠️ 不能用 pumpAndSettle：in-flight Future 永不完结
    //（且 AylaMessageList 内含 AnimatedOpacity 等有限动画，settle 也会一直等）。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final int first = marked.length;
    expect(first, greaterThan(0), reason: '首屏至少上报一条（列表贴底 = 最新几条可见）');
    expect(marked.toSet().length, first, reason: '同一条不得在同一次上报里重复');

    // 连续多帧：不得重复上报
    for (int i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(marked.length, first, reason: '同一帧内重复通知只调一次；持续可见不重复上报');

    // 滚动往返：行离开视口再回来。
    // ⚠️ 滚动会**引入别的新行**（它们也是「进入视口」⇒ 应该上报）
    // ⇒ 这里断言的是「不重复」，不是「不增加」。
    await tester.drag(find.byType(ListView), const Offset(0, 2000));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.drag(find.byType(ListView), const Offset(0, -2000));
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      marked.toSet().length,
      marked.length,
      reason: '同一条消息在 in-flight / 已上报集拦阻下**永不重复**上报',
    );
  });

  testWidgets('prefers-reduced-motion（disableAnimations）不影响已读判定', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(720, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    Future<List<String>> run({required bool disableAnimations}) async {
      // ⚠️ **必须先卸载整棵树再挂第二轮**：`previewTheme` 用
      // `Overlay(initialEntries: ...)`，而 entry 只在**首次挂载**时构建 ⇒
      // 第二次 `pumpWidget` 不会替换 entry 内的子树（实测：第二轮探针 0 次上报，
      // 因为复用了第一轮的 `AylaMessageList` State，已上报集仍非空）。
      // 这是测试宿主的语义，不是产品行为（对比：两个独立 testWidgets 各自正常）。
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      final List<String> marked = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: previewTheme(
            Builder(
              builder: (BuildContext context) {
                final Size size = MediaQuery.sizeOf(context);
                return MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(disableAnimations: disableAnimations),
                  child: SizedBox(
                    width: size.width,
                    height: size.height,
                    child: AylaMessageList(
                      // 两轮必须是**独立挂载**：同位置同类型会被 Element 复用 ⇒
                      // 第二轮沿用第一轮的「已上报集」，测的就不是 motion 差异了。
                      key: ValueKey<bool>(disableAnimations),
                      messages: <AylaChatMessage>[
                        _msg(id: 'a', seq: 1, senderId: 'u1', content: '未读 A'),
                        _msg(
                          id: 'b',
                          seq: 2,
                          senderId: 'u2',
                          content: '未读 B',
                          at: DateTime(2026, 9, 24, 22, 0),
                        ),
                      ],
                      conversation: _conv(),
                      currentUserId: 'me',
                      onMarkRead: (AylaChatMessage m, bool exact) async {
                        marked.add(m.id);
                      },
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      return marked;
    }

    final List<String> normal = await run(disableAnimations: false);
    final List<String> reduced = await run(disableAnimations: true);
    expect(normal.toSet(), <String>{'a', 'b'});
    expect(normal.length, 2);
    expect(
      reduced.toSet(),
      normal.toSet(),
      reason: '已读判定只依赖可见性，与动画开关无关（reduced-motion 只降级入场动画）',
    );
    expect(reduced.length, normal.length);
  });

  testWidgets('已读上报失败：不炸渲染、不伪造已读，且允许再次进入视口重试', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(720, 360);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final Map<String, int> calls = <String, int>{};
    final DateTime base = DateTime(2026, 9, 24, 21, 0);

    await tester.pumpWidget(
      MaterialApp(
        home: previewTheme(
          Builder(
            builder: (BuildContext context) {
              final Size size = MediaQuery.sizeOf(context);
              return SizedBox(
                width: size.width,
                height: size.height,
                child: AylaMessageList(
                  messages: <AylaChatMessage>[
                    for (int i = 0; i < 20; i++)
                      _msg(
                        id: 'm$i',
                        seq: i + 1,
                        senderId: 'u1',
                        content: '第 $i 行消息内容，用于撑高列表',
                        at: base.add(Duration(minutes: i)),
                      ),
                  ],
                  conversation: _conv(),
                  currentUserId: 'me',
                  // 每次上报都失败（模拟网络/鉴权错误）。
                  onMarkRead: (AylaChatMessage m, bool exact) async {
                    calls[m.id] = (calls[m.id] ?? 0) + 1;
                    throw StateError('mark read failed');
                  },
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // web tsx 909 的 `.finally` 没有 `catch` ⇒ promise reject 不影响渲染；
    // Flutter 侧必须显式消费该错误，否则会走 FlutterError.onError。
    expect(tester.takeException(), isNull, reason: '已读上报失败不得冒泡成渲染异常');
    expect(calls, isNotEmpty, reason: '首屏可见的未读消息应已尝试上报');

    // 滚出视口再滚回来 ⇒ 失败的行不在「已上报」集里 ⇒ 允许重试。
    await tester.drag(find.byType(ListView), const Offset(0, 3000));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.drag(find.byType(ListView), const Offset(0, -3000));
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.takeException(), isNull, reason: '重试路径同样不得抛渲染异常');
    expect(
      calls.values.any((int n) => n > 1),
      isTrue,
      reason: '失败后未被永久拉黑：再次进入视口会重试（web：read_by_me 仍 false、ref 已清空）',
    );
  });

  // ======================= 观察节点口径 =======================

  testWidgets('观察节点 = 含时间分隔的外层行 wrapper（tsx 1030–1035 / 1048–1053）', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(720, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final DateTime base = DateTime(2026, 9, 24, 21, 0);
    // 间隔 > 5 分钟（tsx 24 的 GROUP_GAP_MS）⇒ 两条都各自带时间分隔。
    final AylaChatMessage first = _msg(
      id: 'a',
      seq: 1,
      senderId: 'u1',
      content: '一',
      at: base,
    );
    final AylaChatMessage second = _msg(
      id: 'b',
      seq: 2,
      senderId: 'u1',
      content: '二',
      at: base.add(const Duration(minutes: 10)),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: previewTheme(
          Builder(
            builder: (BuildContext context) {
              final Size size = MediaQuery.sizeOf(context);
              return SizedBox(
                width: size.width,
                height: size.height,
                child: AylaMessageList(
                  messages: <AylaChatMessage>[first, second],
                  conversation: _conv(),
                  currentUserId: 'me',
                  onMarkRead: (AylaChatMessage m, bool exact) async {},
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // 每条消息恰好一个探针，且 id 对齐（tsx 915–920：逐条 observe）。
    final List<AylaMessageVisibilityProbe> probes =
        tester.widgetList<AylaMessageVisibilityProbe>(
      find.byType(AylaMessageVisibilityProbe),
    ).toList();
    expect(
      probes.map((AylaMessageVisibilityProbe p) => p.messageId).toSet(),
      <String>{'a', 'b'},
      reason: '每条消息恰好一个探针（顺序随 reverse 建项，无语义）',
    );
    expect(probes.length, 2);

    // 探针盒**包含**该行的时间分隔（外层 wrapper 口径，与 web 的 data-message-id 节点一致）。
    final Finder firstProbe = find.byWidgetPredicate(
      (Widget w) => w is AylaMessageVisibilityProbe && w.messageId == 'a',
    );
    final String timeLabel = aylaMessageListTime(first.createdAt);
    expect(timeLabel, isNotEmpty);
    expect(
      find.descendant(of: firstProbe, matching: find.text(timeLabel)),
      findsOneWidget,
      reason: '时间分隔在探针盒子内 ⇒ 观察的是外层 wrapper',
    );
    expect(
      tester.getRect(firstProbe).height,
      greaterThan(tester.getRect(find.text(timeLabel)).height),
      reason: 'wrapper 高于时间分隔本身',
    );
  });
}
