/// 用户实报两个缺陷的回归锁（2026-10-15）。
///
/// ## 缺陷 1：收藏页帖子卡全变「内容不可用」
/// 后端 apps/favorites/target_cards.py:138 有 card["id"] = str(target.pk)，
/// 而 AylaPost.fromJson 此前只接受 num ⇒ 解析失败 ⇒ 卡片退化。
/// 真实 API 实测（/api/v1/favorites/）：target.id = '106'（字符串）。
///
/// ## 缺陷 2：搜索页除「全部」外的选项卡内容区全空白
/// _onFilterChange 先 setState(_filter = next) 再 context.replace ⇒
/// didUpdateWidget 里 nextFilter == _filter 成立 ⇒ **早退** ⇒ 不重取、
/// _resultsScope 停在旧 scope ⇒ _body 取不到 results ⇒ 空白。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../lib/core/models/post.dart';
import '../lib/pages/search_page.dart';
import '../lib/theme/app_theme.dart';

void main() {
  group('缺陷 1：收藏投影的 id 是字符串', () {
    test('后端真实形状（id="106"）必须解析成功', () {
      final AylaPost? post = AylaPost.fromJson(<String, dynamic>{
        'id': '106',
        'author_id': 'u-1',
        'author_nickname': '123',
        'raw_title': '帖子标题',
        'title': '帖子标题',
        'body': '正文',
        'visibility': 'public',
        'created_at': '2026-08-29T10:00:00+08:00',
        'images': <Object?>[],
        'comment_count': 2,
      });
      expect(post, isNotNull,
          reason: '字符串 id 是收藏投影的真实形状；解析失败会让卡片退化为「内容不可用」');
      expect(post!.id, 106);
    });

    test('REST feed 的数字 id 不得回归', () {
      expect(AylaPost.fromJson(<String, dynamic>{'id': 44})!.id, 44);
    });

    test('非法 id 仍返回 null（不伪造）', () {
      expect(AylaPost.fromJson(<String, dynamic>{'id': 'abc'}), isNull);
      expect(AylaPost.fromJson(<String, dynamic>{'id': null}), isNull);
      expect(AylaPost.fromJson(<String, dynamic>{'id': ''}), isNull);
      expect(AylaPost.fromJson(<String, dynamic>{'id': 0}), isNull);
      expect(AylaPost.fromJson(<String, dynamic>{'id': -3}), isNull);
    });
  });

  group('缺陷 2：切分类必须驱动重取（不得早退）', () {
    testWidgets('点击「用户」后 URL 必须带 type=user', (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1500, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final GoRouter router = GoRouter(
        initialLocation: '/search?q=zzz',
        routes: <RouteBase>[
          GoRoute(
            path: '/search',
            builder: (BuildContext c, GoRouterState s) => SearchPage(
              initialQuery: s.uri.queryParameters['q'],
              initialType: s.uri.queryParameters['type'],
            ),
          ),
        ],
      );
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp.router(
          theme: buildAylaTheme(),
          routerConfig: router,
        ),
      ));
      for (int i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(router.state.uri.queryParameters['type'], isNull,
          reason: '初始是「全部」档（URL 无 type）');
      await tester.tap(find.text('用户'));
      for (int i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(router.state.uri.queryParameters['type'], 'user',
          reason: '点击后 URL 必须带 type=user');
    });

    testWidgets('切分类必须真的发起重取（旧缺陷会因早退而不取）', (WidgetTester tester) async {
      // 判别依据：修复后 didUpdateWidget **不会**早退 ⇒ 会调 `_refreshSearch` ⇒
      // `_loading = true` ⇒ 内容区出现「搜索中…」，且 stats 变回「… 条结果」。
      // 旧缺陷（`nextFilter == _filter` 早退）**两者都不会发生** —— 这一对观测量有辨别力，
      // 与「有网络/无网络」无关（加载态是同步进入的）。
      await tester.binding.setSurfaceSize(const Size(1500, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final GoRouter router = GoRouter(
        initialLocation: '/search?q=zzz',
        routes: <RouteBase>[
          GoRoute(
            path: '/search',
            builder: (BuildContext c, GoRouterState s) => SearchPage(
              initialQuery: s.uri.queryParameters['q'],
              initialType: s.uri.queryParameters['type'],
            ),
          ),
        ],
      );
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp.router(
          theme: buildAylaTheme(),
          routerConfig: router,
        ),
      ));
      for (int i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      await tester.tap(find.text('群聊'));
      await tester.pump(); // 只推进一帧：此时请求仍在途 ⇒ 必须是加载态

      final List<String> texts = tester.allWidgets
          .whereType<Text>()
          .map((Text t) => t.data ?? '')
          .toList();
      debugPrint('切档一帧后的文本: ' + texts.join(' | '));
      expect(texts.any((String s) => s.contains('搜索中')), isTrue,
          reason: '切档必须触发重取（旧缺陷早退 ⇒ 不进入加载态）');
      expect(texts.any((String s) => s == '… 条结果'), isTrue,
          reason: '统计行必须回到「… 条结果」（不得留旧分类数字）');
    });
  });
}