/// 群详情页**整页滚动容器**定向测试 —— 对照 web `.group-info`
/// （`group.css:1382–1401`）与 `GroupInfo.tsx:392–412`。
///
/// ## 事实源（web，逐条）
/// | web | 行 | 规则 |
/// |---|---|---|
/// | `group.css` | 1382–1390 | `.group-info { height: 100%; overflow-y: auto; display: flex; flex-direction: column; gap: var(--sp-3); padding: var(--sp-3); width: 100% }` |
/// | `group.css` | 1392 | 注释原文「整页持有滚动；列保持自然高度，卡片阴影由外沿留白容纳」 |
/// | `group.css` | 1393–1401 | `@media (min-width: 769px)` ⇒ `padding: var(--sp-6) var(--sp-6) var(--sp-8)`（24/24/24/32）· `.group-info-layout { flex: none }` |
/// | `GroupInfo.tsx` | 392–408 | `!conv` 的加载骨架 / 错误态**也返回在 `<div class="group-info">` 内** |
/// | `GroupInfo.tsx` | 410–412 | 正常档 `<div class="group-info"> > <div class="group-info-layout">` |
/// | `group.css` | 2235–2240 | `.group-info-actions-row { margin-top: var(--sp-3) }`（资料卡内动作行上间距 12） |
///
/// ## 修复前 / 后实测（同一口径：真实页面 + 真实后端形状的响应）
/// ```
/// 修复前  1526×900 : RenderFlex overflowed by 1355 pixels on the bottom · SingleChildScrollView = 0
/// 修复前   400×700 : RenderFlex overflowed by 3388 pixels on the bottom · SingleChildScrollView = 0
/// 修复后  1526×900 : 无溢出 · 容器 1 个 · 可滚到 maxScrollExtent
/// 修复后   400×700 : 无溢出 · 容器 1 个 · 可滚到 maxScrollExtent
/// ```
///
/// ## 手法：为什么挂**真实页面**而不是直接造 `AylaGroupInfoLayout`
/// 缺陷在页面装配层（缺一整页滚动容器），不在任何组件内 —— 组件级用例量不到。
/// 与 `group_scene_padding_test.dart` 同源：用 dio 的 `HttpClientAdapter`
/// 接缝喂**真实后端形状**的 JSON，数据链路（JSON → 模型 → Pager → 页面）仍然真实，
/// 只有传输层被替换。
///
/// ## 已修（2026-10-02，本轮；契约收敛到 `group_info_cards_test.dart`）
/// 1. **三张内容卡的卡体容器与内距**：web 的
///    `.group-info-subgroups` / `.group-info-members` /
///    `.group-info-manage` 都是 `solid-card` +
///    `padding: var(--sp-4)`（`GroupInfo.tsx:522/650/747` +
///    `group.css:1677–1682`；管理卡另有 `gap: var(--sp-3)`，`1790–1794`）。
///    此前页面的 `_buildSubgroupCard` / `_buildMemberCard` /
///    `_buildManageCard` 返回裸 `Column` ⇒ 卡头与列表**直接贴容器内距边**。
///    现三处都改为 `AylaGlassCard(padding: EdgeInsets.all(sp4))`
///    （材质依据：`app.css:241–249` 的 `.solid-card` 与 `230–238` 的
///    `.glass-card` 声明逐条相同）。卡内间距、`cardPadding` 的换算口径、
///    宽窄屏几何在 `group_info_cards_test.dart` 另有 19 条定向用例。
///
/// ## 待修的**既有缺陷**（本文件不锁，避免把错误行为写成契约）
/// 2. **卡内错误行的 8px 内距**：`_managementError` / `_subgroupError` 两处
///    仍是 `Padding(bottom: sp2)`，而 web 的 `p.group-info-error` 因
///    `base.css:316–326` 把 `p` 归零而**没有**外边距（`group.css:1604–1607`
///    只给字号与色）。本轮只补卡体与块间距，未扩大改动面。
/// 3. **`.field` 的块级默认边距**：web `app.css:70` 的 `.field`
///    没有 `margin`，而 `base.css:324` 的归零名单是
///    `p, ...`（**未涵盖 `input`**）⇒ 成员搜索框在 web 里带浏览器
///    默认外边距；Flutter 侧为 0。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/net/dio_client.dart';
import '../lib/pages/group_info_page.dart';
import '../lib/theme/app_theme.dart' show buildAylaTheme;
import '../lib/theme/preview_theme.dart' show previewScope;
import '../lib/theme/tokens.dart';
import '../lib/theme/glass.dart' show AylaGlassButton;
import '../lib/widgets/base/share.dart' show AylaShareButton;
import '../lib/widgets/group/transfer_owner_dialog.dart'
    show AylaTransferOwnerDialog;
import '../lib/widgets/group/group_info_profile.dart';
import '../lib/widgets/group/group_info_lists.dart';

// ===========================================================================
// 假传输层：群详情页用到的端点 → 真实后端形状
// ===========================================================================

Map<String, dynamic> _page(List<Map<String, dynamic>> results) =>
    <String, dynamic>{
      'results': results,
      'next_cursor': null,
      'has_more': false,
      'total': results.length,
    };

class _GroupInfoAdapter implements HttpClientAdapter {
  /// 子群条数（页面只预览 3 条，其余由「查看更多」展开）。
  int subgroups = 20;

  /// 成员条数 —— 撑高成员卡，制造「内容高于视口」。
  int members = 30;

  /// metadata 请求返回 500 ⇒ 页面走错误档（`GroupInfo.tsx:396–400`）。
  bool metadataFails = false;

  /// 全部请求挂起（不 resolve）⇒ 页面停在加载档（`GroupInfo.tsx:401–405`）。
  bool neverResolve = false;

  final List<RequestOptions> requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (neverResolve) {
      // 永不 complete：页面停在 `conv == null && loadError == null` 的加载档。
      return Completer<ResponseBody>().future;
    }
    final String path = options.path;
    Object? body;
    int status = 200;
    if (path.endsWith('/subgroups/')) {
      body = _page(<Map<String, dynamic>>[
        for (int i = 1; i <= subgroups; i += 1)
          <String, dynamic>{
            'id': 'sg$i',
            'conversation_id': 'g1',
            'name': '子群 $i',
            'is_default': i == 1,
            'unread_count': 0,
          },
      ]);
    } else if (path.endsWith('/members/')) {
      body = _page(<Map<String, dynamic>>[
        for (int i = 1; i <= members; i += 1)
          <String, dynamic>{
            'id': 'm$i',
            'role': 'member',
            'user': <String, dynamic>{
              'id': 'u$i',
              'username': 'user$i',
              'nickname': '成员 $i',
              'online': false,
            },
          },
      ]);
    } else if (path.endsWith('/join-requests/')) {
      body = _page(const <Map<String, dynamic>>[]);
    } else if (path.contains('/chat/conversations/g1/')) {
      if (metadataFails) {
        status = 500;
        body = <String, dynamic>{'detail': '群信息加载失败（测试注入）'};
      } else {
        body = <String, dynamic>{
          'id': 'g1',
          'type': 'group',
          'title': '星海观测站',
          'announcement': '一起看星星',
          'avatar': '',
          'join_policy': 'application',
          'owner_id': 'u1',
          'my_role': 'owner',
          'member_count': members,
          'created_at': '2026-01-01T00:00:00Z',
        };
      }
    } else {
      body = <String, dynamic>{};
    }
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: <String, List<String>>{
        'content-type': <String>['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

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

// ===========================================================================

/// 窄屏（<769）与宽屏（≥769）两档视口。
const Size kNarrow = Size(400, 700);
const Size kWide = Size(1526, 900);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _GroupInfoAdapter adapter;

  setUpAll(() {
    adapter = _GroupInfoAdapter();
    // `DioClient.dio` 是 late final ⇒ 先 init 再换传输层。
    DioClient.instance.init(tokenStore: _NoTokens(), onSessionExpired: () {});
    DioClient.instance.dio.httpClientAdapter = adapter;
  });

  setUp(() {
    adapter
      ..requests.clear()
      ..subgroups = 20
      ..members = 30
      ..metadataFails = false
      ..neverResolve = false;
  });

  Future<void> useViewport(WidgetTester tester, Size size) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  Widget host(Widget child, Size viewport) => ProviderScope(
        child: MaterialApp(
          theme: buildAylaTheme(),
          home: Scaffold(
            body: Builder(
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
        ),
      );

  /// 挂页面 → 数据落地 → 入场动画走完（几何断言必须在**终态**上量）。
  Future<void> pumpPage(WidgetTester tester, Size viewport) async {
    await useViewport(tester, viewport);
    await tester.pumpWidget(host(const GroupInfoPage(groupId: 'g1'), viewport));
    await tester.pump(); // 假适配器的响应在同一 zone 的微任务里落地
    for (int i = 0; i < 8; i += 1) {
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  Finder pageScroll() => find.byType(AylaGroupInfoPageScroll);

  Finder pageScrollView() => find.descendant(
        of: pageScroll(),
        matching: find.byType(SingleChildScrollView),
      );

  ScrollableState scrollState(WidgetTester tester) =>
      tester.state<ScrollableState>(
        find
            .descendant(of: pageScroll(), matching: find.byType(Scrollable))
            .first,
      );

  // =========================================================================
  group('不溢出（group.css 1382–1390 的 overflow-y: auto）', () {
    testWidgets('宽屏 1526×900：30 名成员 + 20 个子群 ⇒ 无 RenderFlex overflow', (
      WidgetTester tester,
    ) async {
      await pumpPage(tester, kWide);

      // 修复前：RenderFlex overflowed by 1355 pixels on the bottom
      expect(
        tester.takeException(),
        isNull,
        reason: '内容高于视口时必须由整页滚动容器承接（web .group-info）',
      );
      expect(pageScroll(), findsOneWidget);
    });

    testWidgets('窄屏 400×700：同样无溢出', (WidgetTester tester) async {
      await pumpPage(tester, kNarrow);

      // 修复前：RenderFlex overflowed by 3388 pixels on the bottom
      expect(tester.takeException(), isNull);
      expect(pageScroll(), findsOneWidget);
    });

    testWidgets('内容确实高于视口（证明上条不是空转）', (WidgetTester tester) async {
      await pumpPage(tester, kNarrow);
      final ScrollableState state = scrollState(tester);
      expect(
        state.position.maxScrollExtent,
        greaterThan(0),
        reason: 'maxScrollExtent > 0 ⇒ 内容确实超出视口，溢出风险真实存在',
      );
    });
  });

  // =========================================================================
  group('可滚动（overflow-y: auto ⇒ SingleChildScrollView）', () {
    testWidgets('容器内恰好一个滚动视图 + 拖动 240 后 offset 变化', (
      WidgetTester tester,
    ) async {
      await pumpPage(tester, kNarrow);

      expect(pageScrollView(), findsOneWidget, reason: '整页只有这一层滚动');
      final ScrollableState state = scrollState(tester);
      expect(state.position.pixels, 0);

      // 在页面内容上竖直拖动（web：整页 overflow-y auto 的滚轮 / 触控拖动）。
      await tester.drag(pageScroll(), const Offset(0, -240));
      await tester.pump();

      expect(state.position.pixels, moreOrLessEquals(240, epsilon: 0.5));
      expect(tester.takeException(), isNull);
    });

    testWidgets('滚到底：内容下沿距视口下沿 = padding 的底部档', (
      WidgetTester tester,
    ) async {
      await pumpPage(tester, kNarrow);
      await tester.drag(pageScroll(), const Offset(0, -100000));
      await tester.pump();

      // 窄屏 .group-info 的 padding 四边 sp3 ⇒ 内容底贴视口底 − 12
      final Rect main = tester.getRect(find.byKey(AylaGroupInfoLayout.mainKey));
      expect(
        kNarrow.height - main.bottom,
        moreOrLessEquals(AylaSpacing.sp3, epsilon: 0.5),
      );
    });
  });

  // =========================================================================
  group('padding 两档（group.css 1388 / 1395）', () {
    testWidgets('窄屏 ≤768：四边 sp3(12) —— 容器内距与首卡偏移一致', (
      WidgetTester tester,
    ) async {
      await pumpPage(tester, kNarrow);

      final SingleChildScrollView view = tester.widget<SingleChildScrollView>(
        pageScrollView(),
      );
      expect(view.padding, const EdgeInsets.all(AylaSpacing.sp3));

      // 首列（资料卡所在列）相对视口的左上偏移 = 容器内距
      final Rect side = tester.getRect(find.byKey(AylaGroupInfoLayout.sideKey));
      expect(side.left, AylaSpacing.sp3);
      expect(side.top, AylaSpacing.sp3);
      // 内容宽 = 视口宽 − 2×12
      expect(side.width, closeTo(kNarrow.width - 2 * AylaSpacing.sp3, 0.01));
      expect(tester.takeException(), isNull);
    });

    testWidgets('宽屏 ≥769：24 / 24 / 24 / 32（padding: sp6 sp6 sp8）', (
      WidgetTester tester,
    ) async {
      await pumpPage(tester, kWide);

      final SingleChildScrollView view = tester.widget<SingleChildScrollView>(
        pageScrollView(),
      );
      expect(
        view.padding,
        const EdgeInsets.fromLTRB(
          AylaSpacing.sp6,
          AylaSpacing.sp6,
          AylaSpacing.sp6,
          AylaSpacing.sp8,
        ),
      );

      final Rect side = tester.getRect(find.byKey(AylaGroupInfoLayout.sideKey));
      expect(side.left, AylaSpacing.sp6);
      expect(side.top, AylaSpacing.sp6);
      // 右列右沿 = 视口宽 − sp6
      final Rect main = tester.getRect(find.byKey(AylaGroupInfoLayout.mainKey));
      expect(
        kWide.width - main.right,
        moreOrLessEquals(AylaSpacing.sp6, epsilon: 0.01),
      );
    });

    testWidgets('宽屏滚到底：底部呼吸 = sp8(32)（不是 sp6）', (
      WidgetTester tester,
    ) async {
      await pumpPage(tester, kWide);
      await tester.drag(pageScroll(), const Offset(0, -100000));
      await tester.pump();

      final Rect main = tester.getRect(find.byKey(AylaGroupInfoLayout.mainKey));
      // ⚠️ 容差 1.5：AylaGlassCard 的 hover 抬升（auroraqua.css 29–52 的 translate 0 -2px）
      // 会把卡片矩形上移最多 2px，卡片底沿随之变化 ⇒ 不能按 0.5 严判。
      expect(
        kWide.height - main.bottom,
        moreOrLessEquals(AylaSpacing.sp8, epsilon: 1.5),
        reason: 'group.css:1395 的 padding 底档是 --sp-8（32），不是 --sp-6',
      );
    });

    testWidgets('断点与布局同源：769 命中宽屏档、768 命中窄屏档', (
      WidgetTester tester,
    ) async {
      Widget probe(double width) => MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(size: Size(width, 900)),
              child: Builder(
                builder: (BuildContext context) => Text(
                  '${AylaGroupInfoPageScroll.paddingFor(context).top}',
                ),
              ),
            ),
          );

      // 769 是 CSS min-width: 769px 的边界（AylaBreakpoints.isNarrow 是 ≤768）
      await tester.pumpWidget(probe(769));
      expect(find.text('${AylaSpacing.sp6}'), findsOneWidget);

      await tester.pumpWidget(probe(768));
      expect(find.text('${AylaSpacing.sp3}'), findsOneWidget);
    });
  });

  // =========================================================================
  group('加载档 / 错误档也在同一层容器内（GroupInfo.tsx 392–408）', () {
    testWidgets('加载档：容器 + 骨架，无溢出', (WidgetTester tester) async {
      adapter.neverResolve = true; // 请求永不落地 ⇒ conv == null && loadError == null
      await useViewport(tester, kWide);
      await tester.pumpWidget(host(const GroupInfoPage(groupId: 'g1'), kWide));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));

      expect(
        pageScroll(),
        findsOneWidget,
        reason: 'tsx 393 的 .group-info 是加载档外层',
      );
      expect(find.byKey(AylaGroupInfoLayout.loadingKey), findsOneWidget);
      final SingleChildScrollView view = tester.widget<SingleChildScrollView>(
        pageScrollView(),
      );
      expect(view.padding!.resolve(TextDirection.ltr).top, AylaSpacing.sp6);
      // ⚠️ 骨架的 frost-pulse 是无限动画 ⇒ 不能 pumpAndSettle
      expect(tester.takeException(), isNull);
    });

    testWidgets('错误档：容器 + 群信息加载失败，无溢出', (WidgetTester tester) async {
      adapter.metadataFails = true;
      await pumpPage(tester, kWide);

      expect(
        pageScroll(),
        findsOneWidget,
        reason: 'tsx 394 的 .group-info 是错误档外层',
      );
      expect(find.text('群信息加载失败'), findsOneWidget);
      final SingleChildScrollView view = tester.widget<SingleChildScrollView>(
        pageScrollView(),
      );
      expect(view.padding!.resolve(TextDirection.ltr).top, AylaSpacing.sp6);
      expect(tester.takeException(), isNull);
    });

    testWidgets('错误档窄屏：内距走窄屏档 sp3', (WidgetTester tester) async {
      adapter.metadataFails = true;
      await pumpPage(tester, kNarrow);

      expect(find.text('群信息加载失败'), findsOneWidget);
      final SingleChildScrollView view = tester.widget<SingleChildScrollView>(
        pageScrollView(),
      );
      expect(view.padding, const EdgeInsets.all(AylaSpacing.sp3));
      expect(tester.takeException(), isNull);
    });
  });

  // =========================================================================
  group('弹层是滚动容器的兄弟（GroupInfo.tsx 795/797–889）', () {
    testWidgets('点「转让群主」：弹层铺满视口且不被滚动视图裁剪/吞掉点击', (
      WidgetTester tester,
    ) async {
      await pumpPage(tester, kWide);

      // 键在滚动内容里 ⇒ 能点中即证明滚动视图没有吞掉点击。
      final Finder transfer = find.widgetWithText(AylaGlassButton, '转让群主');
      expect(transfer, findsOneWidget);
      await tester.tap(transfer);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(AylaTransferOwnerDialog), findsOneWidget);
      // web：五个弹层渲染在 `.group-info` **之外**（tsx 795 闭 `</div>` 之后）
      // ⇒ 遮罩仍铺满整个视口，不随页面滚动、不被滚动视图裁剪。
      final Rect overlay = tester.getRect(find.byType(AylaTransferOwnerDialog));
      expect(overlay.left, 0);
      expect(overlay.top, 0);
      expect(overlay.width, moreOrLessEquals(kWide.width, epsilon: 0.01));
      expect(overlay.height, moreOrLessEquals(kWide.height, epsilon: 0.01));
      expect(tester.takeException(), isNull);
    });
  });

  // =========================================================================
  group('资料卡动作行上间距（group.css 2235–2240）', () {
    testWidgets('页面装配（宽屏）：动作行与统计格之间 = gap sp2 + margin sp3 = 20', (
      WidgetTester tester,
    ) async {
      await pumpPage(tester, kWide);

      // 动作行锚点（`.group-info-actions-row`）。⚠️ 分享入口是不可见文案的图标钮
      // （`aria-label`/`title` = label，`ShareButton.tsx:29` + `home.css:121–134`）
      // ⇒ 不能 find.text('分享群聊')。
      // ⚠️ 量的是锚点盒子**内部的 Row**：锚点盒子自身带 `marginTop` 的 padding，
      // 其 rect 顶 = 父级 gap 的终点；Row 顶才是「gap + margin-top」的合成位置。
      final Finder actionsRow = find
          .descendant(
            of: find.byKey(AylaGroupInfoProfile.actionsRowKey),
            matching: find.byType(Row),
          )
          .first;
      expect(find.byType(AylaShareButton), findsOneWidget);
      // 统计格（.group-info-stats：上下 1px 分隔线 + padding sp3 0 sp2）
      final Finder statsBox = find
          .ancestor(
            of: find.text('已载入在线'),
            matching: find.byType(Container),
          )
          .first;
      // 两段之和：父级 flex gap（宽屏 = .group-info-profile 的 sp2）+ 行自身的 margin-top sp3
      expect(
        tester.getRect(actionsRow).top - tester.getRect(statsBox).bottom,
        moreOrLessEquals(AylaSpacing.sp2 + AylaSpacing.sp3, epsilon: 0.5),
        reason: 'gap sp2（group.css:1486）+ .group-info-actions-row 的 margin-top sp3（2239）',
      );
    });

    testWidgets('窄屏：父级 gap 换 sp3 ⇒ 两段共 24', (WidgetTester tester) async {
      await pumpPage(tester, kNarrow);

      final Finder actionsRow = find
          .descendant(
            of: find.byKey(AylaGroupInfoProfile.actionsRowKey),
            matching: find.byType(Row),
          )
          .first;
      final Finder statsBox = find
          .ancestor(
            of: find.text('已载入在线'),
            matching: find.byType(Container),
          )
          .first;
      // 窄屏 .group-info-profile 的 gap 是 sp3（group.css:1473）⇒ 12 + 12 = 24
      expect(
        tester.getRect(actionsRow).top - tester.getRect(statsBox).bottom,
        moreOrLessEquals(AylaSpacing.sp3 + AylaSpacing.sp3, epsilon: 0.5),
      );
    });

    testWidgets('回归锁：把档位去掉则只是 gap（证明本档确实生效）', (
      WidgetTester tester,
    ) async {
      // 直接用组件默认（actionsRowMarginTop = 0）复刻「修前形状」。
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAylaTheme(),
          home: previewScope(
            Builder(
              builder: (BuildContext context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  size: const Size(420, 900),
                ),
                child: const Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: 420,
                    child: AylaGroupInfoProfile(
                      title: '星海观测站',
                      createdAt: null,
                      canManage: true, // 出「编辑群资料」⇒ 动作行非空
                      stats: <AylaGroupInfoStat>[
                        AylaGroupInfoStat(value: '128', label: '成员'),
                        AylaGroupInfoStat(value: '37', label: '已载入在线'),
                        AylaGroupInfoStat(value: '4', label: '子群'),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final Finder statsBox = find
          .ancestor(
            of: find.text('已载入在线'),
            matching: find.byType(Container),
          )
          .first;
      // 不传档 ⇒ 只剩父级 gap sp3（12）——与群详情页的 24 相差正好一行 margin
      final Finder actionsRow = find
          .descendant(
            of: find.byKey(AylaGroupInfoProfile.actionsRowKey),
            matching: find.byType(Row),
          )
          .first;
      expect(
        tester.getRect(actionsRow).top - tester.getRect(statsBox).bottom,
        moreOrLessEquals(AylaSpacing.sp3, epsilon: 0.5),
      );
    });
  });
}
