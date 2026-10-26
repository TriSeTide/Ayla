/// 个人页 / 他人主页 **分享键**接线回归锁（用户 2026-10-26 实报「分享键点击无效」）。
///
/// ## 根因（本文件锁的就是它不得回退）
/// - lib/pages/profile_page.dart:376–380（修复前）：AylaShareButton(... onPressed: () {})
///   —— 空实现，点了没反应；
/// - lib/pages/user_profile_page.dart:492–496（修复前）：同上。
///
/// web 没这个问题：components/share/ShareButton.tsx:21–33 **自己** useState(open) +
/// createPortal 弹 ShareSheet，页面只传 payload（ProfilePage.tsx:176 /
/// UserProfilePage.tsx:129）⇒ 入口永远可点、永远能开弹窗，与页面是否「接线」无关。
///
/// Flutter 侧 widgets/base/share.dart 已有同构的**自给自足档**（不传 onPressed +
/// 传 payload/payloadBuilder ⇒ 本件自己 aylaOpenShareSheet），两页原先没走它。
///
/// ## 本文件锁五件事
/// ① 个人页分享键 onPressed == null（= 交给自给自足档）且带 payloadBuilder；
///    文案「分享我的主页」/ 尺寸 40 不变（web className 的 icon-btn-40 ... profile-card-share）；
/// ② 负载逐字段对齐 web userSharePayload（utils/sharePayload.ts:116–130）：
///    share_type=user / target_id=String(user.id) / 标题回退链 / cover 归一 /
///    subtitle·extra 恒 null；
/// ③ 点下去**真的打开** AylaShareSheet（web 的 setOpen(true)），且弹窗预览条用同一份负载；
/// ④ 他人主页同理（「分享用户」、载荷取自 AylaUserDetail.user）；
/// ⑤ 全库静态审计：AylaShareButton 的调用点不得再出现 onPressed 空实现
///    （样板/画布除外）—— 防止下一个页面照抄旧写法。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../lib/core/api/users_api.dart' show AylaFriendRelation, AylaUserDetail;
import '../lib/core/models/share_payload.dart';
import '../lib/core/models/user_public.dart' show AylaUserPublic;
import '../lib/pages/profile_content_support.dart';
import '../lib/widgets/base/profile_content_sections.dart'
    show AylaProfilePostItem;
import '../lib/pages/profile_page.dart';
import '../lib/pages/user_profile_page.dart';
import '../lib/state/auth_state.dart';
import '../lib/theme/app_theme.dart' show buildAylaTheme;
import '../lib/theme/buttons.dart' show AylaIconButton;
import '../lib/widgets/base/share.dart' show AylaShareButton, AylaShareSheet;
import '../lib/widgets/profile/profile_card.dart' show AylaProfileIdentity;

// ======================= 替身数据 =======================

/// 本人（GET /me/ 的投影）。头像刻意用站内相对路径 —— 用来验 normalizeCover。
const AuthUser _me = AuthUser(
  id: 'u1',
  username: 'ayla',
  nickname: '爱莉',
  avatar: '/api/v1/media/avatar-1/content',
  signature: '你好',
  status: 'auto',
  online: true,
  displayStatus: '在线',
  dateJoined: '2026-01-01',
  isInVoice: false,
  voiceRoomId: null,
  isLive: false,
  liveRoomId: null,
  showContent: false,
  email: 'a@b.c',
);

/// GET /users/u2/ 的替身结果（relation 非 self ⇒ 不会触发 /profile 重定向）。
AylaUserDetail _otherDetail() => const AylaUserDetail(
      user: AylaUserPublic(
        id: 'u2',
        username: 'bob',
        nickname: '鲍勃',
        avatar: '/api/v1/media/avatar-2/content',
      ),
      relation: AylaFriendRelation.none,
      showContent: false,
      signature: '嗨',
    );

/// 页面级宿主：真 Router（页面里 context.push/pop 需要）+ 注入替身。
Future<ProviderContainer> _pumpPage(
  WidgetTester tester, {
  required String initialLocation,
  required Widget page,
  ProviderContainer? container,
}) async {
  tester.view.physicalSize = const Size(1440, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final ProviderContainer c = container ?? ProviderContainer();
  addTearDown(c.dispose);
  final GoRouter router = GoRouter(
    initialLocation: initialLocation,
    routes: <RouteBase>[
      GoRoute(
        path: initialLocation,
        builder: (BuildContext ctx, GoRouterState s) => page,
      ),
      GoRoute(path: '/group', builder: (BuildContext ctx, GoRouterState s) => const Text('GROUP')),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp.router(
        routerConfig: router,
        theme: buildAylaTheme(),
        builder: (BuildContext ctx, Widget? child) =>
            Scaffold(backgroundColor: Colors.transparent, body: child),
      ),
    ),
  );
  return c;
}

/// 走完两列入场动画（AylaDurations.auroraqua = 300ms）与内容分区的首帧。
Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 4; i++) {
    await tester.pump();
  }
  await tester.pump(const Duration(milliseconds: 400));
}

/// 取「本次要分享的负载」（惰性构造 ⇒ 必须求值后再断言）。
AylaSharePayload _payloadOf(WidgetTester tester, Finder finder) {
  final AylaShareButton b = tester.widget<AylaShareButton>(finder);
  expect(
    b.onPressed,
    isNull,
    reason: '个人页/他人主页必须走**自给自足档**（= web ShareButton 自持弹窗）；'
        '传了 onPressed 就走注入档、弹不弹取决于页面实现 —— 正是用户实报的坑',
  );
  expect(b.payload, isNull, reason: '本页应传惰性 payloadBuilder（按下才构造）');
  expect(b.payloadBuilder, isNotNull);
  return b.payloadBuilder!();
}

void main() {
  // ==================== ③ 个人页 ====================

  group('个人页 /profile：分享键 = 自给自足档（web ProfilePage.tsx:176）', () {
    testWidgets('① 分享键可点：onPressed 交给自给自足档、带 payloadBuilder、尺寸 40',
        (WidgetTester tester) async {
      final ProviderContainer c = await _pumpPage(
        tester,
        initialLocation: '/profile',
        page: const ProfilePage(),
      );
      c.read(authNotifierProvider.notifier)
        ..setTokens('access', 'refresh')
        ..setUser(_me);
      await _settle(tester);

      // 身份行内的那一颗（AylaProfileIdentity.share 槽位）
      final Finder share = find.descendant(
        of: find.byType(AylaProfileIdentity),
        matching: find.byType(AylaShareButton),
      );
      expect(share, findsOneWidget);

      final AylaShareButton button = tester.widget<AylaShareButton>(share);
      expect(button.label, '分享我的主页', reason: 'web tsx 176 的 label 原文');
      expect(button.size, 40, reason: 'web className 的 icon-btn-40');

      // 底层 AylaIconButton 必须真有回调（onPressed == null 会落到禁用 +
      // SystemMouseCursors.forbidden，也就是「点了没反应」的形态）
      expect(
        tester
            .widget<AylaIconButton>(find.descendant(
              of: share,
              matching: find.byType(AylaIconButton),
            ))
            .onPressed,
        isNotNull,
        reason: '自给自足档必须在 build 里补出自己的 onPressed（share.dart:981–982）',
      );
    });

    testWidgets('② 负载逐字段对齐 web userSharePayload（sharePayload.ts:116–130）',
        (WidgetTester tester) async {
      final ProviderContainer c = await _pumpPage(
        tester,
        initialLocation: '/profile',
        page: const ProfilePage(),
      );
      c.read(authNotifierProvider.notifier)
        ..setTokens('access', 'refresh')
        ..setUser(_me);
      await _settle(tester);

      final AylaSharePayload p = _payloadOf(
        tester,
        find.descendant(
          of: find.byType(AylaProfileIdentity),
          matching: find.byType(AylaShareButton),
        ),
      );
      expect(p.shareType, AylaShareType.user);
      expect(p.targetId, 'u1', reason: 'String(currentUser.id)');
      expect(p.title, '爱莉', reason: 'nickname 优先');
      expect(p.cover, '/api/v1/media/avatar-1/content',
          reason: 'normalizeCover 保留站内相对路径');
      expect(p.subtitle, isNull, reason: 'web 恒 null');
      expect(p.extra, isNull, reason: 'web 恒 null');
      // 序列化键名必须是后端 snake_case（发送路径直接用这份）
      expect(p.toJson(), <String, Object?>{
        'share_type': 'user',
        'target_id': 'u1',
        'title': '爱莉',
        'cover': '/api/v1/media/avatar-1/content',
        'subtitle': null,
        'extra': null,
      });
    });

    testWidgets('② 补：昵称为空 ⇒ 回退 @username；两者都空 ⇒ 「用户」（sharePayload.ts:125）',
        (WidgetTester tester) async {
      const AuthUser noNick = AuthUser(
        id: 'u9',
        username: 'bob',
        nickname: '',
        avatar: '',
        signature: '',
        status: 'auto',
        online: true,
        displayStatus: '在线',
        dateJoined: '2026-01-01',
        isInVoice: false,
        voiceRoomId: null,
        isLive: false,
        liveRoomId: null,
        showContent: false,
        email: '',
      );
      const AuthUser blank = AuthUser(
        id: 'u9',
        username: '  ',
        nickname: ' ',
        avatar: '',
        signature: '',
        status: 'auto',
        online: true,
        displayStatus: '在线',
        dateJoined: '2026-01-01',
        isInVoice: false,
        voiceRoomId: null,
        isLive: false,
        liveRoomId: null,
        showContent: false,
        email: '',
      );
      for (final AuthUser user in <AuthUser>[noNick, blank]) {
        final ProviderContainer container = ProviderContainer();
        addTearDown(container.dispose);
        await _pumpPage(
          tester,
          initialLocation: '/profile',
          page: const ProfilePage(),
          container: container,
        );
        container.read(authNotifierProvider.notifier)
          ..setTokens('access', 'refresh')
          ..setUser(user);
        await _settle(tester);
        expect(
          _payloadOf(
            tester,
            find.descendant(
              of: find.byType(AylaProfileIdentity),
              matching: find.byType(AylaShareButton),
            ),
          ).title,
          user.username.trim().isEmpty ? '用户' : 'bob',
          reason: 'web 回退链 s(nickname) || s(username) || "用户"',
        );
      }
    });

    testWidgets('③ 点下去真的打开 AylaShareSheet，预览条 = 同一份负载',
        (WidgetTester tester) async {
      final ProviderContainer c = await _pumpPage(
        tester,
        initialLocation: '/profile',
        page: const ProfilePage(),
      );
      c.read(authNotifierProvider.notifier)
        ..setTokens('access', 'refresh')
        ..setUser(_me);
      await _settle(tester);

      expect(find.byType(AylaShareSheet), findsNothing);
      await tester.tap(find.descendant(
        of: find.byType(AylaProfileIdentity),
        matching: find.byType(AylaShareButton),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(
        find.byType(AylaShareSheet),
        findsOneWidget,
        reason: 'web ShareButton.tsx:27 的 onClick=setOpen(true) ⇒ 点一次就出弹窗',
      );
      // 弹窗头顶预览条显示 payload.title（ShareSheet 的 .share-sheet-preview-text）
      expect(
        find.descendant(
          of: find.byType(AylaShareSheet),
          matching: find.text('爱莉'),
        ),
        findsOneWidget,
        reason: '弹窗收到的必须就是本页构造的那份 user 负载',
      );

      // 收尾：点遮罩关闭（弹层挂在 Overlay，测试结束前显式收掉，避免残留动画）
      await tester.tapAt(const Offset(6, 6));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
    });
  });

  // ==================== ④ 他人主页 ====================

  group('他人主页 /user/:id：分享键 = 自给自足档（web UserProfilePage.tsx:129）', () {
    testWidgets('① 分享键可点 + 文案「分享用户」+ 尺寸 40', (WidgetTester tester) async {
      await _pumpPage(
        tester,
        initialLocation: '/user/u2',
        page: UserProfilePage(
          userId: 'u2',
          debugUserDetail: (String id) async => _otherDetail(),
          debugFetchers: AylaProfileContentFetchers(
            posts: (String ownerId, bool mine) async =>
                const <AylaProfilePostItem>[],
          ),
        ),
      );
      await _settle(tester);

      final Finder share = find.byType(AylaShareButton);
      expect(share, findsOneWidget);

      final AylaShareButton button = tester.widget<AylaShareButton>(share);
      expect(button.label, '分享用户', reason: 'web tsx 129 的 label 原文');
      expect(button.size, 40, reason: 'web className 的 icon-btn-40');
      expect(
        tester
            .widget<AylaIconButton>(find.descendant(
              of: share,
              matching: find.byType(AylaIconButton),
            ))
            .onPressed,
        isNotNull,
      );

      final AylaSharePayload p = _payloadOf(tester, share);
      expect(p.shareType, AylaShareType.user);
      expect(p.targetId, 'u2', reason: 'String(user.id) —— 不是当前登录用户');
      expect(p.title, '鲍勃');
      expect(p.cover, '/api/v1/media/avatar-2/content');
      expect(p.subtitle, isNull);
      expect(p.extra, isNull);
    });

    testWidgets('② 点下去真的打开 AylaShareSheet', (WidgetTester tester) async {
      await _pumpPage(
        tester,
        initialLocation: '/user/u2',
        page: UserProfilePage(
          userId: 'u2',
          debugUserDetail: (String id) async => _otherDetail(),
          debugFetchers: AylaProfileContentFetchers(
            posts: (String ownerId, bool mine) async =>
                const <AylaProfilePostItem>[],
          ),
        ),
      );
      await _settle(tester);

      await tester.tap(find.byType(AylaShareButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(find.byType(AylaShareSheet), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AylaShareSheet),
          matching: find.text('鲍勃'),
        ),
        findsOneWidget,
      );

      await tester.tapAt(const Offset(6, 6));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
    });
  });

  // ==================== ⑤ 全库静态审计 ====================

  group('全库审计：AylaShareButton 调用点不得再出现 onPressed 空实现', () {
    /// 样板/画布文件：它们演示的是「视觉槽位」，不是用户可点的入口。
    const Set<String> sampleOnly = <String>{
      'lib/preview/component_gallery.dart',
      // widgets/base/share.dart 尾部「样张」段（_shareSlot(...)）
      'lib/widgets/base/share.dart',
    };

    test('扫描 lib/**：空实现只剩样板，且调用点数不塌缩（防止正则失效变成假绿）', () {
      final List<_ShareSite> sites = _shareButtonCallSites();
      expect(
        sites.length,
        greaterThanOrEqualTo(12),
        reason: '解析出的调用点数远低于现状（16）⇒ 扫描逻辑本身坏了，本锁无效',
      );

      final List<String> emptyInProd = <String>[
        for (final _ShareSite s in sites)
          if (!sampleOnly.contains(s.path) &&
              RegExp(r'onPressed:\s*\(\)\s*\{\s*\}').hasMatch(s.args))
            '${s.path}:${s.line}',
      ];
      expect(
        emptyInProd,
        isEmpty,
        reason: '这些调用点把 onPressed 写成空实现 ⇒ 用户点了没反应（本轮实报的根因）：'
            '${emptyInProd.join('、')}'
            '。改走自给自足档（传 payload/payloadBuilder、不传 onPressed）。',
      );

      // 第二道：生产调用点必须至少有一条可用路径（有负载 → 自给自足；或有真回调）
      final List<String> deadSites = <String>[
        for (final _ShareSite s in sites)
          if (!sampleOnly.contains(s.path) &&
              !RegExp(r'payload\s*:').hasMatch(s.args) &&
              !RegExp(r'payloadBuilder\s*:').hasMatch(s.args) &&
              !RegExp(r'onPressed\s*:').hasMatch(s.args))
            '${s.path}:${s.line}',
      ];
      expect(
        deadSites,
        isEmpty,
        reason: '这些调用点既没有负载也没有回调 ⇒ 落到禁用态：${deadSites.join('、')}',
      );
    });
  });
}

/// 一个 AylaShareButton 调用点的完整实参文本。
class _ShareSite {
  const _ShareSite(this.path, this.line, this.args);
  final String path;
  final int line;
  final String args;
}

/// 解析 lib/**/*.dart 里每个 AylaShareButton( 的完整实参文本（括号配对）。
List<_ShareSite> _shareButtonCallSites() {
  final List<_ShareSite> out = <_ShareSite>[];
  const String marker = 'AylaShareButton(';
  for (final FileSystemEntity entity in Directory('lib').listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    final String src = entity.readAsStringSync();
    final String path = entity.path.replaceAll(r'\', '/');
    int index = src.indexOf(marker);
    while (index >= 0) {
      // 跳过**注释里**的示例写法（如 profile_card.dart 的
      // "通常传 AylaShareButton(size: 40, label: actionLabel)"）——
      // 那行是文档，不是真实调用点。
      final int lineStart = src.lastIndexOf('\n', index) + 1;
      final String prefix = src.substring(lineStart, index).trimLeft();
      if (prefix.startsWith('//')) {
        index = src.indexOf(marker, index + marker.length);
        continue;
      }
      final int argsStart = index + marker.length;
      int depth = 1;
      int cursor = argsStart;
      while (cursor < src.length && depth > 0) {
        final String ch = src[cursor];
        if (ch == '(') depth++;
        if (ch == ')') depth--;
        cursor++;
      }
      final String args = src.substring(argsStart, cursor - 1);
      // 跳过构造函数声明（const AylaShareButton({ ... }) 以 { 开头）
      if (!args.trimLeft().startsWith('{')) {
        final int line = '\n'.allMatches(src.substring(0, index)).length + 1;
        out.add(_ShareSite(path, line, args));
      }
      index = src.indexOf(marker, cursor);
    }
  }
  return out;
}
