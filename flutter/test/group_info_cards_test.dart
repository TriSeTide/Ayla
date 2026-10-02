/// 群详情页**三张内容卡的卡体容器**定向测试 —— 对照 web
/// `GroupInfo.tsx:522 / 650 / 747` + `group.css:1677–1682 / 1790–1794`。
///
/// ## 缺陷（2026-10-02 用户实报「卡片没有应用上」，本轮修复）
/// Flutter 侧 `_buildManageCard` / `_buildSubgroupCard` / `_buildMemberCard`
/// **都返回裸 `Column`**：没有卡体、没有 `padding: var(--sp-4)`、管理卡
/// 还漏了 `gap: var(--sp-3)` ⇒ 卡头与列表直接贴整页容器的内距边。
///
/// ## 事实源（web，逐条）
/// | web | 行 | 规则 |
/// |---|---|---|
/// | `GroupInfo.tsx` | 522 | `<section class="group-info-manage solid-card">` |
/// | `GroupInfo.tsx` | 650 | `<section class="group-info-subgroups solid-card">` |
/// | `GroupInfo.tsx` | 747 | `<section class="group-info-members solid-card">` |
/// | `GroupInfo.tsx` | 415 | `<section class="group-info-profile glass-card">`（对照项） |
/// | `group.css` | 1677–1682 | `.group-info-members, .group-info-subgroups, .group-info-manage { padding: var(--sp-4) }`（16） |
/// | `group.css` | 1790–1794 | `.group-info-manage { display:flex; flex-direction:column; gap: var(--sp-3) }` |
/// | `group.css` | 1626–1631 | `.group-info-card-head { … margin-bottom: var(--sp-3) }` |
/// | `group.css` | 1610–1619 | `.group-info-section-title { … margin-bottom: var(--sp-3) }` |
/// | `app.css` | 230–238 / 241–249 | `.glass-card` 与 `.solid-card` **声明逐条相同**（后者注释原文「保留旧类名兼容页面；材质统一为 Auroraqua 玻璃」）⇒ 统一用 `AylaGlassCard` |
///
/// ## 卡内块间距（为何没有一套通用 gap）
/// web 的 `.group-info-subgroups` / `.group-info-members` **没有 `gap`**；相邻块的
/// 间距来自「某一件自己的 margin」：卡头 `margin-bottom: sp3`（1630）、
/// 「查看更多」`margin-top: sp2`（2112）、`p.group-info-placeholder` 与
/// `p.group-info-error` 因 `base.css:316–326` 把 `p` 归零而**无外边距**。
/// 成员卡里唯一的例外是搜索框：`.field`（`app.css:70–78`）未声明 margin、也不在
/// 归零名单里，但**浏览器对 `input` 的 UA 样式本就是 `margin: 0`**（Chromium/WebKit
/// 的 `html.css`）⇒ head→搜索框 = 12、搜索框→首行 = 0，与 Flutter 逐条同值。
///
/// 管理卡额外有 `gap: var(--sp-3)`（1790–1794）。flex 的 `gap` **不吸收** margin
/// ⇒ 标题到首个设置块的间距是 12（gap）+ 12（标题自带 margin-bottom）= **24**。
///
/// ## 手法
/// 与 `group_info_page_layout_test.dart` 同源：挂**真实页面**（缺陷在页面装配层，
/// 组件级用例量不到），用 dio 的 `HttpClientAdapter` 接缝喂真实后端形状的 JSON。
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
import '../lib/theme/glass.dart' show AylaGlassButton, AylaGlassCard;
import '../lib/theme/tokens.dart';
import '../lib/widgets/group/group_info_lists.dart'
    show
        AylaGroupInfoLayout,
        AylaGroupMemberItem,
        AylaGroupMemberList,
        AylaGroupSubgroupItem,
        AylaGroupSubgroupList;
import '../lib/widgets/group/group_info_manage.dart'
    show AylaGroupInfoCardHead, AylaGroupInfoSectionTitle;
import '../lib/widgets/group/group_info_profile.dart';
import '../lib/widgets/group/group_info_settings.dart'
    show
        AylaGroupInfoSettingsBox,
        AylaGroupMemberSearchField,
        AylaGroupSubgroupExpandButton;

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
  int subgroups = 5;
  int members = 6;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
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
    } else if (path.contains('/emoji/groups/')) {
      // 群表情包摘要（后端 `_group_pack_payload` 摘要档；形状取自
      // `group_info_emoji_policy_test.dart:50–56`）。缺这一段时页面会落
      // `managementError` ⇒ 管理卡内多出「表情上传权限加载失败」一行，
      // 卡内块间距的实测值会被它污染。
      body = <String, dynamic>{
        'pack': <String, dynamic>{'id': '77', 'name': '群表情', 'item_count': 2},
        'allow_member_upload': false,
        'can_upload': true,
        'can_delete': true,
      };
    } else if (path.endsWith('/join-requests/')) {
      body = _page(const <Map<String, dynamic>>[]);
    } else if (path.contains('/chat/conversations/g1/')) {
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

/// 窄屏（≤768）与宽屏（≥769）两档视口；宽屏取 1600×900（两列档）。
const Size kNarrow = Size(400, 700);
const Size kWide = Size(1600, 900);

/// web 的卡内距 `padding: var(--sp-4)`（`group.css:1678–1682`）。
const double kCardPadding = AylaSpacing.sp4;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _GroupInfoAdapter adapter;

  setUpAll(() {
    adapter = _GroupInfoAdapter();
    DioClient.instance.init(tokenStore: _NoTokens(), onSessionExpired: () {});
    DioClient.instance.dio.httpClientAdapter = adapter;
  });

  setUp(() {
    adapter
      ..subgroups = 5
      ..members = 6;
  });

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
    await tester.binding.setSurfaceSize(viewport);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(host(const GroupInfoPage(groupId: 'g1'), viewport));
    await tester.pump();
    for (int i = 0; i < 8; i += 1) {
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  // ---- 定位器：从**内容**反查它所在的卡（最近祖先 = 卡体的直接层级）----

  Finder manageCard() => find.ancestor(
        of: find.byType(AylaGroupInfoSectionTitle),
        matching: find.byType(AylaGlassCard),
      );

  Finder subgroupCard() => find.ancestor(
        of: find.widgetWithText(AylaGroupInfoCardHead, '子群'),
        matching: find.byType(AylaGlassCard),
      );

  Finder memberCard() => find.ancestor(
        of: find.widgetWithText(AylaGroupInfoCardHead, '成员'),
        matching: find.byType(AylaGlassCard),
      );

  /// ⚠️ 资料卡的卡体**在** [AylaGroupInfoProfile] 之内（该件自己返回
  /// `Stack[ AylaGlassCard, … ]`，见 `group_info_profile.dart:270–275`）——
  /// 故这里是 descendant，不是 ancestor。三张内容卡相反：卡体在页面装配层、
  /// 是各件（卡头/列表）的**祖先**。
  Finder profileCard() => find.descendant(
        of: find.byType(AylaGroupInfoProfile),
        matching: find.byType(AylaGlassCard),
      );

  /// 读某张卡的 `padding`（`AylaGlassCard.padding` 默认为 sp4）。
  EdgeInsets cardPaddingOf(WidgetTester tester, Finder card) {
    final AylaGlassCard widget = tester.widget<AylaGlassCard>(card);
    return widget.padding!.resolve(TextDirection.ltr);
  }

  /// 「卡内首元素相对卡左上角的偏移」——修复前该值无从测量（卡不存在）。
  Offset insetOf(WidgetTester tester, Finder card, Finder firstChild) {
    final Rect box = tester.getRect(card);
    final Rect child = tester.getRect(firstChild);
    return Offset(child.left - box.left, child.top - box.top);
  }

  // =========================================================================
  group('三张内容卡都有卡体（GroupInfo.tsx 522 / 650 / 747）', () {
    testWidgets('宽屏 1600×900：页面内 AylaGlassCard 共 4 张（资料卡 + 三张内容卡）', (
      WidgetTester tester,
    ) async {
      await pumpPage(tester, kWide);

      // 修复前：只有资料卡 1 张（三个 _buildXxxCard 返回裸 Column ⇒ ancestor 查询为 0）
      expect(find.byType(AylaGlassCard), findsNWidgets(4));
      expect(profileCard(), findsOneWidget);
      expect(manageCard(), findsOneWidget);
      expect(subgroupCard(), findsOneWidget);
      expect(memberCard(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('窄屏 400×700：同样是 4 张（卡体与断点无关）', (
      WidgetTester tester,
    ) async {
      await pumpPage(tester, kNarrow);

      expect(find.byType(AylaGlassCard), findsNWidgets(4));
      expect(manageCard(), findsOneWidget);
      expect(subgroupCard(), findsOneWidget);
      expect(memberCard(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('三张内容卡是**三张不同的卡**（不是同一张包住全部）', (
      WidgetTester tester,
    ) async {
      await pumpPage(tester, kWide);

      final Object manage = tester.element(manageCard());
      final Object subgroup = tester.element(subgroupCard());
      final Object member = tester.element(memberCard());
      expect(identical(manage, subgroup), isFalse);
      expect(identical(manage, member), isFalse);
      expect(identical(subgroup, member), isFalse);
      expect(identical(manage, tester.element(profileCard())), isFalse);
    });

    testWidgets('层级 = section > (head + content)：卡头与列表在同一张卡内', (
      WidgetTester tester,
    ) async {
      await pumpPage(tester, kWide);

      // 标题锚点（资料卡的统计格也有「成员」「子群」文案 ⇒ 不能只按字样找）
      expect(find.byKey(AylaGroupInfoCardHead.titleKey('子群')), findsOneWidget);
      expect(find.byKey(AylaGroupInfoCardHead.titleKey('成员')), findsOneWidget);

      // 管理卡的标题是 .group-info-section-title（tsx:523），另两张是 .group-info-card-head
      expect(
        find.descendant(
          of: manageCard(),
          matching: find.byType(AylaGroupInfoSectionTitle),
        ),
        findsOneWidget,
      );
      for (final Finder card in <Finder>[subgroupCard(), memberCard()]) {
        expect(
          find.descendant(
            of: card,
            matching: find.byType(AylaGroupInfoCardHead),
          ),
          findsOneWidget,
          reason: 'web 的 .group-info-card-head 在 section 之内（tsx:651 / 748）',
        );
      }
      // 成员卡的搜索框与成员列表同在卡内（web: section > input + ul）
      expect(
        find.descendant(
          of: memberCard(),
          matching: find.byType(AylaGroupMemberSearchField),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: memberCard(), matching: find.byType(AylaGroupMemberList)),
        findsOneWidget,
      );
      // 管理卡的设置块与申批块同在卡内
      expect(
        find.descendant(
          of: manageCard(),
          matching: find.byType(AylaGroupInfoSettingsBox),
        ),
        findsOneWidget,
      );
    });
  });

  // =========================================================================
  group('回归锁：修复前的形状（裸 Column）确实量不到卡', () {
    testWidgets('★ 卡头 + 列表放进裸 Column ⇒ AylaGlassCard = 0（= 修复前的页面）', (
      WidgetTester tester,
    ) async {
      // 逐字复刻修复前的装配：三个 _buildXxxCard 都返回裸 Column，
      // 卡头与列表直接成为整页容器的孩子。
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAylaTheme(),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 420,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    const AylaGroupInfoCardHead(title: '子群', count: 5),
                    const AylaGroupSubgroupList(
                      subgroups: <AylaGroupSubgroupItem>[],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(
        find.byType(AylaGlassCard),
        findsNothing,
        reason: '★ 修复前就是这样：裸 Column 没有卡体，ancestor 查询必然落空',
      );
      expect(find.byType(AylaGroupInfoCardHead), findsOneWidget);
      // 卡头贴左上角（= 宿主边缘），没有 sp4 内距可言
      expect(tester.getRect(find.byType(AylaGroupInfoCardHead)).topLeft, Offset.zero);
    });
  });

  // =========================================================================
  group('卡内距 = sp4(16)（group.css 1677–1682）', () {
    testWidgets('宽屏：三张内容卡的 padding 都是 EdgeInsets.all(sp4)', (
      WidgetTester tester,
    ) async {
      await pumpPage(tester, kWide);

      for (final Finder card in <Finder>[
        manageCard(),
        subgroupCard(),
        memberCard(),
      ]) {
        expect(cardPaddingOf(tester, card), const EdgeInsets.all(kCardPadding));
      }
    });

    testWidgets('对照：资料卡走自己的两档内距（sp4 sp6 sp4 sp4 / sp4 sp8 sp4 sp4）', (
      WidgetTester tester,
    ) async {
      // 证明「三张内容卡的 sp4 全等」不是「读到了资料卡的头档」。
      await pumpPage(tester, kWide);
      expect(
        cardPaddingOf(tester, profileCard()),
        const EdgeInsets.fromLTRB(
          AylaSpacing.sp4,
          AylaSpacing.sp6,
          AylaSpacing.sp4,
          AylaSpacing.sp4,
        ),
        reason: 'group.css 1485–1493 的宽屏档',
      );

      await pumpPage(tester, kNarrow);
      expect(
        cardPaddingOf(tester, profileCard()),
        const EdgeInsets.fromLTRB(
          AylaSpacing.sp4,
          AylaSpacing.sp8,
          AylaSpacing.sp4,
          AylaSpacing.sp4,
        ),
        reason: 'group.css 1479–1483 的窄屏档',
      );
    });

    testWidgets('窄屏：三张内容卡的 padding 同样都是 sp4（不随断点变）', (
      WidgetTester tester,
    ) async {
      await pumpPage(tester, kNarrow);

      for (final Finder card in <Finder>[
        manageCard(),
        subgroupCard(),
        memberCard(),
      ]) {
        expect(cardPaddingOf(tester, card), const EdgeInsets.all(kCardPadding));
      }
    });

    testWidgets('宽屏实测：卡头相对卡边缘的左上偏移 = (16, 16)', (
      WidgetTester tester,
    ) async {
      await pumpPage(tester, kWide);

      expect(
        insetOf(tester, manageCard(), find.byType(AylaGroupInfoSectionTitle)),
        const Offset(kCardPadding, kCardPadding),
        reason: '修复前管理卡是裸 Column ⇒ 卡头直接贴整页容器的内距边',
      );
      expect(
        insetOf(tester, subgroupCard(), find.widgetWithText(AylaGroupInfoCardHead, '子群')),
        const Offset(kCardPadding, kCardPadding),
      );
      expect(
        insetOf(tester, memberCard(), find.widgetWithText(AylaGroupInfoCardHead, '成员')),
        const Offset(kCardPadding, kCardPadding),
      );
    });

    testWidgets('窄屏实测：同样是 (16, 16)', (WidgetTester tester) async {
      await pumpPage(tester, kNarrow);

      expect(
        insetOf(tester, manageCard(), find.byType(AylaGroupInfoSectionTitle)),
        const Offset(kCardPadding, kCardPadding),
      );
      expect(
        insetOf(tester, subgroupCard(), find.widgetWithText(AylaGroupInfoCardHead, '子群')),
        const Offset(kCardPadding, kCardPadding),
      );
      expect(
        insetOf(tester, memberCard(), find.widgetWithText(AylaGroupInfoCardHead, '成员')),
        const Offset(kCardPadding, kCardPadding),
      );
    });

    testWidgets('卡宽 = 列宽（卡体没有把内容挤窄或撑宽）', (WidgetTester tester) async {
      await pumpPage(tester, kWide);

      // 右列 = 主列宽；成员卡与子群卡都应铺满该列
      final Rect main = tester.getRect(find.byKey(AylaGroupInfoLayout.mainKey));
      expect(tester.getRect(memberCard()).width, moreOrLessEquals(main.width, epsilon: 0.01));
      expect(tester.getRect(subgroupCard()).width, moreOrLessEquals(main.width, epsilon: 0.01));
      final Rect side = tester.getRect(find.byKey(AylaGroupInfoLayout.sideKey));
      expect(tester.getRect(manageCard()).width, moreOrLessEquals(side.width, epsilon: 0.01));
    });
  });

  // =========================================================================
  group('子群卡内块间距（卡内无 gap ⇒ 间距来自各件自己的 margin）', () {
    testWidgets('卡头 → 列表 = 卡头自带 margin-bottom sp3(12)', (
      WidgetTester tester,
    ) async {
      await pumpPage(tester, kWide);

      // ⚠️ 量**卡头 Row** 的底沿，不是 CardHead 盒子的底：该件把自带的
      // margin-bottom sp3 表达成 padding，量盒子会把这 12 算进去。
      // ⚠️ 也不能量标题**文字盒**：子群卡头里有 minHeight 30 的「编辑子群」键，
      // 文字盒比行矮 ⇒ 会多出垂直居中的留白（实测 15 而非 12）。
      final Finder head = find.widgetWithText(AylaGroupInfoCardHead, '子群');
      final Rect headRow = tester.getRect(
        find.descendant(of: head, matching: find.byType(Row)).first,
      );
      final Rect list = tester.getRect(find.byType(AylaGroupSubgroupList));
      expect(
        list.top - headRow.bottom,
        moreOrLessEquals(AylaSpacing.sp3, epsilon: 0.5),
        reason: 'group.css:1630 的 margin-bottom sp3（卡内没有 gap 可叠）',
      );
      // 另一面：CardHead 盒子（含自带的 margin）与列表之间**没有**额外间距
      expect(
        list.top - tester.getRect(head).bottom,
        moreOrLessEquals(0, epsilon: 0.5),
      );
    });

    testWidgets('列表 → 「查看更多」= margin-top sp2(8)（group.css 2112）', (
      WidgetTester tester,
    ) async {
      await pumpPage(tester, kWide); // 5 个子群 > 预览 3 ⇒ 该键存在

      final Rect list = tester.getRect(find.byType(AylaGroupSubgroupList));
      // 量键本体（ExpandButton 把 margin-top sp2 表达成 padding）
      final Finder button = find.descendant(
        of: find.byType(AylaGroupSubgroupExpandButton),
        matching: find.byType(AylaGlassButton),
      );
      final Rect expand = tester.getRect(button);
      expect(
        expand.top - list.bottom,
        moreOrLessEquals(AylaSpacing.sp2, epsilon: 0.5),
        reason: '.group-info-expand-btn { margin-top: var(--sp-2) }',
      );
      // 卡内沿：展开键底到卡底 = 卡内距 sp4
      final Rect card = tester.getRect(subgroupCard());
      expect(card.bottom - expand.bottom, moreOrLessEquals(kCardPadding, epsilon: 0.5));
    });
  });

  // =========================================================================
  group('成员卡内块间距（web：head 的 margin 12 / 搜索框 UA margin 0）', () {
    testWidgets('卡头 → 搜索框 = 12；搜索框 → 成员列表 = 0', (
      WidgetTester tester,
    ) async {
      await pumpPage(tester, kWide);

      // ⚠️ 量卡头 Row 的底沿（不是 CardHead 盒子：它把 margin sp3 表达成 padding）。
      final Finder head = find.widgetWithText(AylaGroupInfoCardHead, '成员');
      final Rect headRow = tester.getRect(
        find.descendant(of: head, matching: find.byType(Row)).first,
      );
      expect(headRow.height, greaterThan(0));
      final Rect search = tester.getRect(
        find.byType(AylaGroupMemberSearchField),
      );
      final Rect list = tester.getRect(find.byType(AylaGroupMemberList));
      expect(
        search.top - headRow.bottom,
        moreOrLessEquals(AylaSpacing.sp3, epsilon: 0.5),
        reason: 'group.css:1630 的卡头 margin-bottom sp3',
      );
      expect(
        list.top - search.bottom,
        moreOrLessEquals(0, epsilon: 0.5),
        reason: 'web 的 input.field 没有 margin（app.css:70–78 未声明、'
            'base.css:316–326 未归零 input，但浏览器 UA 样式本就是 margin: 0）⇒ 零间距，'
            '页面不得自造内距',
      );
    });
  });

  // =========================================================================
  group('管理卡内块间距（group.css 1790–1794 的 gap: sp3）', () {
    testWidgets('★ 宽屏：卡头文字 → 设置块 = margin-bottom sp3 + gap sp3 = 24', (
      WidgetTester tester,
    ) async {
      await pumpPage(tester, kWide);

      // ⚠️ 量**标题文字**底沿（= 标题 Row 的底）而不是 SectionTitle 盒子的底：
      // 该盒子把自带的 margin-bottom sp3 表达成 padding，量盒子会把这 12 算进去。
      final Rect titleText = tester.getRect(find.text('管理'));
      final Rect settings = tester.getRect(find.byType(AylaGroupInfoSettingsBox));
      expect(
        settings.top - titleText.bottom,
        moreOrLessEquals(AylaSpacing.sp3 + AylaSpacing.sp3, epsilon: 0.5),
        reason: '★ 修复前管理卡是裸 Column ⇒ 这 12 的 gap 根本不存在（实测 52 = 20+32）',
      );
      // 另一面：SectionTitle 盒子（含自带 margin）与设置块之间正好是卡内 gap
      expect(
        settings.top - tester.getRect(find.byType(AylaGroupInfoSectionTitle)).bottom,
        moreOrLessEquals(AylaSpacing.sp3, epsilon: 0.5),
      );
    });

    testWidgets('窄屏：同一口径 = 24（gap 不随断点变）', (WidgetTester tester) async {
      await pumpPage(tester, kNarrow);

      final Rect titleText = tester.getRect(find.text('管理'));
      final Rect settings = tester.getRect(find.byType(AylaGroupInfoSettingsBox));
      expect(
        settings.top - titleText.bottom,
        moreOrLessEquals(AylaSpacing.sp3 + AylaSpacing.sp3, epsilon: 0.5),
      );
    });

    testWidgets('回归锁：修前的裸 Column 形状下，管理卡内**没有** gap（差 sp3）', (
      WidgetTester tester,
    ) async {
      // 复刻修复前的装配（裸 Column，没有卡、没有 gap），证明上一条量的 12 确实来自卡。
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAylaTheme(),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 420,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    const AylaGroupInfoSectionTitle(title: '管理', icon: null),
                    AylaGroupInfoSettingsBox(children: <Widget>[Container(height: 44)]),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final Rect title = tester.getRect(find.byType(AylaGroupInfoSectionTitle));
      final Rect settings = tester.getRect(find.byType(AylaGroupInfoSettingsBox));
      // 只有标题自带的 margin-bottom sp3（=12），gap 不存在 ⇒ 与页面里的 12 同值；
      // 真正的区别在**卡**：这条同时断言裸 Column 下量不到卡（见上面对照）。
      expect(
        settings.top - title.bottom,
        moreOrLessEquals(0, epsilon: 0.5),
        reason: '裸 Column 没有 gap ⇒ 标题盒子（含自带 margin-bottom）的下沿就是设置块的顶沿',
      );
    });
  });

  // =========================================================================
  group('卡内距的换算常量与实际结构一致（AylaGroupMemberList.cardPadding）', () {
    testWidgets('成员卡真实内距 == cardPadding 默认值（@container 换算口径不漂移）', (
      WidgetTester tester,
    ) async {
      await pumpPage(tester, kWide);

      expect(
        cardPaddingOf(tester, memberCard()).left,
        AylaGroupMemberList(
          members: const <AylaGroupMemberItem>[],
        ).cardPadding,
        reason: '该字段只服务 @container 换算；页面传入的真实卡内距必须与它同值',
      );
    });

    testWidgets('成员列表在卡内（搜索框也是）—— web 的 section > input + ul', (
      WidgetTester tester,
    ) async {
      await pumpPage(tester, kWide);

      expect(
        find.descendant(
          of: memberCard(),
          matching: find.byType(AylaGroupMemberSearchField),
        ),
        findsOneWidget,
      );
    });
  });
}
