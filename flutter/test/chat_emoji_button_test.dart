/// 群表情包键的**接线回归锁** —— 真实页面链（不是组件样张）。
///
/// ## 为什么必须有这条（用户实报 + Lead 真机验收 2026-10-02）
/// web `MessageInput.tsx:88-89`：
/// `const isGroup = !!groupId || (!!members && members.length > 0)`
/// —— 注释原文「群聊才有 members：@ 与群表情包按钮均仅群聊展示（**私信不显示表情包按钮**）」；
/// 宽屏 `:464-476` 与窄屏 `:559-571` **两处**都渲染
/// `{isGroup && (<button aria-label="群表情包" ...><IconEmoji/></button>)}`。
///
/// 修复前：`showEmojiButton`（message_input.dart:131，默认 false）与 `emojiPanel`
/// 都没有任何真实页面传 ⇒ 群聊与私聊**都看不到**该键（真机确认）。
///
/// ## 口径
/// 群聊走**真实路由** `/group/:id`（GroupPage）+ 真实主题；无网络 ⇒ 取数失败静默
/// （与 `group_page_shell_test.dart` 同款）。
///
/// 私聊**不在这里走真实路由**：`AylaChatPaneHost.initState` 里
/// `unawaited(_runtime.open())` 写 provider（chat_support.dart:880）⇒ 建树期改 provider
/// 断言 + 卸载期 `closeConversation` 断言（chat_support.dart:815）——
/// 这两个是**本任务范围外**的既有缺陷（本任务没动 chat_support.dart / private_chat_pane.dart）。
/// 私聊侧的锁分两层，都不依赖那条链路：
/// ① 本文件末组：面板件 [AylaPrivateChatPane] 直接挂 composer ⇒ 无该键；
/// ② `emoji_private_call_sites_test.dart`：源码级审计 —— 私聊的每个
///    `AylaMessageInput(...)` 调用点都**没有**传 showEmojiButton / emojiPanel。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../lib/core/models/chat_message.dart';
import '../lib/core/net/dio_client.dart';
import '../lib/core/models/conversation.dart';
import '../lib/core/models/subgroup.dart';
import '../lib/core/models/user_public.dart';
import '../lib/layout/app_shell.dart';
import '../lib/pages/group_page.dart';
import '../lib/router/app_router.dart';
import '../lib/state/auth_state.dart';
import '../lib/state/group_providers.dart';
import '../lib/state/subgroup_state.dart';
import '../lib/theme/app_theme.dart';
import '../lib/theme/buttons.dart' show AylaToolButton;
import '../lib/theme/preview_theme.dart';
import '../lib/widgets/chat/emoji_pack_panel.dart';
import '../lib/widgets/chat/message_input.dart';
import '../lib/widgets/chat/private_chat_pane.dart';

/// 「群表情包」**工具键** —— 按 [AylaToolButton.semanticLabel] 精确定位。
///
/// 不用 `find.bySemanticsLabel('群表情包')`：面板打开后标题文本也叫「群表情包」
/// （web 的按钮 aria-label 与面板标题同名，`EmojiPackPanel.tsx:159-161`）⇒ 会歧义。
Finder emojiKey() => find.byWidgetPredicate(
      (Widget w) => w is AylaToolButton && w.semanticLabel == '群表情包',
    );

/// 同组其余工具键（证明 emoji 键是**新增**而不是替换）。
final Finder imageKey = find.bySemanticsLabel('发送图片或视频');

/// 面板本体（既有件）与面板关闭钮（tsx:162-164 的 aria-label「关闭表情面板」）。
final Finder panel = find.byType(AylaEmojiPackPanel);
final Finder panelClose = find.bySemanticsLabel('关闭表情面板');

/// 取走树上挂着的异常（无网络下群页自身的取数失败；与本任务无关的既有噪声）。
void drainExceptions(WidgetTester tester) {
  while (tester.takeException() != null) {}
}

/// 面板数据面用的假传输层：摘要/列表挂在一个闸门后，由用例显式放行
/// （用来复现「面板先开、数据后到」这个宽屏 Overlay 场景）。
class _PanelDataAdapter implements HttpClientAdapter {
  Completer<void>? _gate = Completer<void>();

  /// 放行挂起的摘要 / 列表响应。
  void release() {
    final Completer<void>? g = _gate;
    _gate = null;
    if (g != null && !g.isCompleted) g.complete();
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final String path = options.path;
    if (path.contains('/emoji/groups/')) {
      final Completer<void>? g = _gate;
      if (g != null) await g.future;
      final Object body = path.endsWith('/pack/')
          ? <String, dynamic>{
              'pack': <String, dynamic>{
                'id': '77',
                'name': '群表情',
                'item_count': 1,
              },
              'allow_member_upload': true,
              'can_upload': true,
              'can_delete': true,
            }
          : <String, dynamic>{
              'results': <Map<String, dynamic>>[
                <String, dynamic>{
                  'id': '5',
                  'tag': '',
                  'media': <String, dynamic>{
                    'media_id': 'm5',
                    'kind': 'emoji',
                  },
                },
              ],
              'next_cursor': null,
              'has_more': false,
              'total': 1,
            };
      return ResponseBody.fromString(
        jsonEncode(body),
        200,
        headers: <String, List<String>>{
          'content-type': <String>['application/json; charset=utf-8'],
        },
      );
    }
    return ResponseBody.fromString(
      jsonEncode(<String, dynamic>{}),
      200,
      headers: <String, List<String>>{
        'content-type': <String>['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 无令牌占位（本文件只关心数据面，不关心鉴权头）。
class _NoTokens implements AuthTokenStore {
  @override
  String? get accessToken => null;
  @override
  String? get refreshToken => null;
  @override
  void setTokens(String access, String? refresh) {}
  @override
  void clear() {}
}

/// 启动真实路由（登录态注入 = `group_page_shell_test` 同款）。
Future<ProviderContainer> pumpApp(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final ProviderContainer container = ProviderContainer();
  addTearDown(container.dispose);
  container.read(authNotifierProvider.notifier).setTokens('access', 'refresh');
  final GoRouter router = container.read(appRouterProvider);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        theme: buildAylaTheme(),
        builder: (BuildContext context, Widget? child) => Scaffold(
          backgroundColor: Colors.transparent,
          body: child,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

/// 进群聊并选中一个子群 —— 面板数据面（摘要 + items）只在选中子群后才拉
/// （web `GroupChat.tsx:126 / MessageInput.tsx:126` 的 composer 以 active 为前置）。
Future<void> openGroupChat(WidgetTester tester, ProviderContainer c) async {
  c.read(appRouterProvider).go('/group/g1');
  await tester.pumpAndSettle();
  final AylaSubGroupState state = c.read(subgroupStateProvider);
  state.setSubgroups('g1', <AylaSubGroup>[
    const AylaSubGroup(
      id: 'sg1',
      conversationId: 'g1',
      name: '默认组',
      isDefault: true,
      unreadCount: 0,
    ),
  ]);
  state.setActiveSubgroup('g1', 'sg1');
  await tester.pumpAndSettle();
  drainExceptions(tester);
}

void main() {
  const Size wide = Size(1440, 900);
  const Size narrow = Size(420, 760);

  group('群聊输入框：渲染群表情包键（web MessageInput.tsx:464-476 / 559-571）', () {
    testWidgets('★ 宽屏群聊：工具条里有「群表情包」键', (WidgetTester tester) async {
      final ProviderContainer c = await pumpApp(tester, wide);
      await openGroupChat(tester, c);

      expect(find.byType(GroupPage), findsOneWidget);
      expect(
        emojiKey(),
        findsOneWidget,
        reason: '★ 这是用户实报「群聊看不到表情包键」的直接判据'
            '（web tsx:88-89 isGroup ⇒ 群聊必渲染）',
      );
      expect(imageKey, findsOneWidget, reason: '同组其余工具键仍在（本键是新增，不是替换）');
    });

    testWidgets('★ 窄屏群聊：工具条里同样有「群表情包」键', (WidgetTester tester) async {
      final ProviderContainer c = await pumpApp(tester, narrow);
      await openGroupChat(tester, c);

      expect(find.byType(GroupPage), findsOneWidget);
      expect(emojiKey(), findsOneWidget,
          reason: '窄屏档（tsx:559-571）与宽屏档（tsx:464-476）两处都要渲染');
      drainExceptions(tester);
    });

    testWidgets('默认不开面板：未点之前 [AylaEmojiPackPanel] 不在树上', (WidgetTester tester) async {
      final ProviderContainer c = await pumpApp(tester, wide);
      await openGroupChat(tester, c);

      expect(emojiKey(), findsOneWidget);
      expect(panel, findsNothing,
          reason: 'web tsx:588 的 {emojiOpen && ...} ⇒ 默认 emojiOpen=false');
    });
  });

  group('点表情键 → 面板出现；再点 → 收起（web tsx:468 的 setEmojiOpen(v => !v)）', () {
    testWidgets('★ 宽屏：点一次出现、再点收起（面板在 composer 上方弹出）', (
      WidgetTester tester,
    ) async {
      final ProviderContainer c = await pumpApp(tester, wide);
      await openGroupChat(tester, c);

      await tester.tap(emojiKey());
      await tester.pumpAndSettle();
      expect(panel, findsOneWidget, reason: '★ 点表情键 ⇒ 面板出现（web tsx:588）');
      // 宽屏定位由 AylaMessageInput 持有（message_input.dart:563-586 的 root Overlay：
      // left sp3 / width composer-2*sp3 / bottom = viewport - composerTop + 8）。
      // 这里只锁「在 composer 的**上方**」——面板底沿 <= composer 顶沿。
      final double panelBottom = tester.getBottomLeft(panel).dy;
      final double composerTop =
          tester.getTopLeft(find.byType(AylaMessageInput)).dy;
      expect(panelBottom, lessThanOrEqualTo(composerTop),
          reason: '宽屏是**向上弹**（app.css 2186-2204 的 bottom: calc(100% + 8px)）');

      await tester.tap(emojiKey());
      await tester.pumpAndSettle();
      expect(panel, findsNothing, reason: '★ 再点一次 ⇒ 收起（setEmojiOpen(v => !v)）');
      drainExceptions(tester);
    });

    testWidgets('★ 窄屏：点一次出现、再点收起（面板在 composer 内向下展开）', (
      WidgetTester tester,
    ) async {
      final ProviderContainer c = await pumpApp(tester, narrow);
      await openGroupChat(tester, c);

      await tester.tap(emojiKey());
      await tester.pumpAndSettle();
      expect(panel, findsOneWidget, reason: '★ 窄屏同样要能开（tsx:559-571 的键）');
      // 窄屏 = 正常流向下展开（app.css 3211-3215 的 position: static）
      final double panelTop = tester.getTopLeft(panel).dy;
      final double composerTop =
          tester.getTopLeft(find.byType(AylaMessageInput)).dy;
      expect(panelTop, greaterThanOrEqualTo(composerTop),
          reason: '窄屏面板在 composer 内（正常流），不是向上弹');

      await tester.tap(emojiKey());
      await tester.pumpAndSettle();
      expect(panel, findsNothing, reason: '★ 再点一次 ⇒ 收起');
      drainExceptions(tester);
    });

    testWidgets('面板关闭钮：只关面板，表情键仍在（等价 setEmojiOpen(false)）', (
      WidgetTester tester,
    ) async {
      final ProviderContainer c = await pumpApp(tester, wide);
      await openGroupChat(tester, c);

      await tester.tap(emojiKey());
      await tester.pumpAndSettle();
      expect(panel, findsOneWidget);

      await tester.tap(panelClose);
      await tester.pumpAndSettle();
      expect(panel, findsNothing, reason: 'tsx:162-164 的 .icon-btn-32 关闭钮 ⇒ onClose');
      expect(emojiKey(), findsOneWidget, reason: '关面板不影响键本身');
      drainExceptions(tester);
    });
  });

  group('宽屏面板的数据面（root Overlay 里的那份必须能收到数据）', () {
    testWidgets('★ 摘要/列表在面板打开后到达 ⇒ 面板上能看到（防 OverlayEntry 冻结）', (
      WidgetTester tester,
    ) async {
      // 背景（2026-10-02 实测缺陷）：宽屏面板由 AylaMessageInput 插进 **root Overlay**
      // （message_input.dart:575-585）⇒ 页面的 setState **传不到**那份子树。
      // 首版接线用「构造时求值的 data:」⇒ 面板永远停在 summaryLoaded=false / items=0
      // （闸门探针实测：放行响应后仍为 false/0）。修复 = 页面用 ValueNotifier 推数据面。
      final _PanelDataAdapter adapter = _PanelDataAdapter();
      // `dio` 是 late final ⇒ 必须先 init 才有实例，再换传输层。
      DioClient.instance.init(tokenStore: _NoTokens(), onSessionExpired: () {});
      final HttpClientAdapter previous = DioClient.instance.dio.httpClientAdapter;
      DioClient.instance.dio.httpClientAdapter = adapter;
      addTearDown(() => DioClient.instance.dio.httpClientAdapter = previous);

      final ProviderContainer c = await pumpApp(tester, wide);
      c.read(appRouterProvider).go('/group/g1');
      await tester.pumpAndSettle();
      final AylaSubGroupState st = c.read(subgroupStateProvider);
      st.setSubgroups('g1', <AylaSubGroup>[
        const AylaSubGroup(
          id: 'sg1',
          conversationId: 'g1',
          name: '默认组',
          isDefault: true,
          unreadCount: 0,
        ),
      ]);
      st.setActiveSubgroup('g1', 'sg1');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      drainExceptions(tester);

      // 开面板（此轮摘要已被闸门挡住）
      await tester.tap(emojiKey());
      await tester.pump();
      expect(panel, findsOneWidget);

      // 放行摘要 + items
      adapter.release();
      for (int i = 0; i < 10; i += 1) {
        await tester.pump(const Duration(milliseconds: 120));
      }

      final AylaEmojiPackPanel p = tester.widget<AylaEmojiPackPanel>(panel);
      expect(p.data.summaryLoaded, isTrue,
          reason: '★ 摘要到达后宽屏面板必须看到（冻结的话恒 false）');
      expect(p.data.packId, '77');
      expect(p.data.items, hasLength(1),
          reason: '★ 列表项到达后宽屏面板必须看到（冻结的话恒空）');
      drainExceptions(tester);
    });
  });

  group('私聊面板件：composer 在、该键不在（web MessageInput.tsx:89）', () {
    /// 私聊面板件直接挂 composer（不经过会写 provider 的 AylaChatPaneHost）
    /// ⇒ 结构与本仓 chat_panes_test.dart:411 同款。
    Widget host(Widget child, Size viewport) => MaterialApp(
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

    AylaPrivateChatPane pane({required bool narrow}) => AylaPrivateChatPane(
          conversation: AylaConversationSummary(
            id: 'c1',
            type: AylaConversationType.private,
            title: '',
            avatar: '',
            peer: const AylaUserPublic(
              id: 'u2',
              nickname: '小樱',
              username: 'sakura',
            ),
          ),
          messages: const <AylaChatMessage>[],
          currentUserId: 'me',
          narrow: narrow,
          peerOnline: true,
          peerStatus: '在线',
          composer: AylaMessageInput(
            onSubmit: (_) {},
            draftKey: 'private-lock',
            narrow: narrow,
          ),
        );

    testWidgets('★ 宽屏私聊：composer 在、图片键在、「群表情包」键与面板件都不在', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = wide;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(host(pane(narrow: false), wide));
      await tester.pump(const Duration(milliseconds: 50));

      // 先证明 composer 真的在场，否则下面的 findsNothing 是无意义的空断言。
      expect(find.byType(AylaMessageInput), findsOneWidget);
      expect(imageKey, findsOneWidget, reason: '私聊同组其余键都在（图片键）');

      expect(emojiKey(), findsNothing,
          reason: '★ web tsx:89 注释原文：私信不显示表情包按钮');
      expect(panel, findsNothing);
    });

    testWidgets('★ 窄屏私聊：composer 在、「群表情包」键不在', (WidgetTester tester) async {
      tester.view.physicalSize = narrow;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(host(pane(narrow: true), narrow));
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byType(AylaMessageInput), findsOneWidget);
      expect(emojiKey(), findsNothing);
      expect(panel, findsNothing);
    });
  });

  group('外壳（确认上面几条跑的是真页面链）', () {
    testWidgets('真实路由下 AppShell 在场', (WidgetTester tester) async {
      final ProviderContainer c = await pumpApp(tester, wide);
      await openGroupChat(tester, c);
      expect(find.byType(AppShell), findsOneWidget);
      drainExceptions(tester);
    });
  });
}
