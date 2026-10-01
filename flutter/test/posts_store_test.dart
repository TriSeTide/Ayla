/// 帖子 store 的 **WS 增量四件套**定向测试 —— 事实源：
/// `Ayla/web/src/stores/posts.ts:92–131`。
///
/// 口径：只锁可指到 web 行号的语义 —— upsert 的原位替换 vs 插头部（92–106）、
/// removePost（108–111，不回退排序）、markViewedBatch（113–124，空 map 早退 +
/// `is_viewed`/`view_count` 覆盖）、updatePostViewCount（126–131，**不**标已读）。
library;

import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/post.dart';
import '../lib/state/posts_store.dart';

AylaPost _post(int id, {String title = 'T', bool isViewed = false, int? viewCount}) =>
    AylaPost(
      id: id,
      title: title,
      body: 'body',
      isViewed: isViewed,
      viewCount: viewCount,
      createdAt: '2026-10-01T00:00:00Z',
    );

void main() {
  group('AylaPostsStore 的 WS 增量四件套（web stores/posts.ts:92–131）', () {
    test('upsertPost：不存在插到列表头部（最新优先，web 101–104）', () {
      final AylaPostsStore store = AylaPostsStore();
      store.setPage(<AylaPost>[_post(1), _post(2)], null, false);
      store.upsertPost(_post(3, title: '新帖'));
      expect(
        store.posts.map((AylaPost p) => p.id).toList(),
        <int>[3, 1, 2],
      );
    });

    test('upsertPost：已存在 ⇒ 原位替换（web 95–99）', () {
      final AylaPostsStore store = AylaPostsStore();
      store.setPage(<AylaPost>[_post(1), _post(2)], null, false);
      store.upsertPost(_post(2, title: '改名'));
      expect(
        store.posts.map((AylaPost p) => p.id).toList(),
        <int>[1, 2],
      );
      expect(store.posts[1].title, '改名');
      expect(store.posts.length, 2);
    });

    test('removePost：只去命中项，其余顺序不动（不回退排序，web 108–111）', () {
      final AylaPostsStore store = AylaPostsStore();
      store.setPage(<AylaPost>[_post(1), _post(2), _post(3)], null, false);
      store.removePost(2);
      expect(
        store.posts.map((AylaPost p) => p.id).toList(),
        <int>[1, 3],
      );
      int notifications = 0;
      store.addListener(() => notifications += 1);
      store.removePost(999);
      expect(notifications, 0, reason: '未命中 ⇒ 不通知');
    });

    test('markViewedBatch：命中的写 is_viewed=true + 覆盖 view_count（web 113–124）', () {
      final AylaPostsStore store = AylaPostsStore();
      store.setPage(
        <AylaPost>[_post(1, viewCount: 3), _post(2, viewCount: 4)],
        null,
        false,
      );
      store.markViewedBatch(<String, int>{'1': 7});
      expect(store.posts[0].isViewed, isTrue);
      expect(store.posts[0].viewCount, 7);
      // 未命中项完全不动。
      expect(store.posts[1].isViewed, isFalse);
      expect(store.posts[1].viewCount, 4);
    });

    test('markViewedBatch：viewCount 缺席时保留原值（web 的 ?? 链，120）', () {
      final AylaPostsStore store = AylaPostsStore();
      store.setPage(<AylaPost>[_post(1, viewCount: 3)], null, false);
      store.markViewedBatch(<String, int>{'1': 0});
      expect(store.posts[0].viewCount, 0, reason: '0 是合法值，不是缺席');
      expect(store.posts[0].isViewed, isTrue);
    });

    test('markViewedBatch：空 map 早退（web 115–116）', () {
      final AylaPostsStore store = AylaPostsStore();
      store.setPage(<AylaPost>[_post(1)], null, false);
      int notifications = 0;
      store.addListener(() => notifications += 1);
      store.markViewedBatch(const <String, int>{});
      expect(notifications, 0);
      expect(store.posts[0].isViewed, isFalse);
    });

    test('updatePostViewCount：只刷浏览量，**不**标已读（web 126–131）', () {
      final AylaPostsStore store = AylaPostsStore();
      store.setPage(<AylaPost>[_post(1, viewCount: 3)], null, false);
      store.updatePostViewCount(1, 42);
      expect(store.posts[0].viewCount, 42);
      expect(store.posts[0].isViewed, isFalse);
    });

    test('updatePostViewCount：未命中 ⇒ 不通知', () {
      final AylaPostsStore store = AylaPostsStore();
      store.setPage(<AylaPost>[_post(1)], null, false);
      int notifications = 0;
      store.addListener(() => notifications += 1);
      store.updatePostViewCount(777, 9);
      expect(notifications, 0);
    });

    test('重建实例保留其余字段（本轮 helper 的正确性）', () {
      final AylaPostsStore store = AylaPostsStore();
      store.setPage(
        <AylaPost>[
          AylaPost(
            id: 5,
            author: const AylaPostAuthor(id: 'u1', nickname: '小樱'),
            authorId: 'u1',
            title: '标题',
            body: '正文',
            groupId: 'g1',
            allowedGroupIds: const <String>['g1', 'g2'],
            commentCount: 3,
            isAuthor: true,
            viewCount: 1,
            createdAt: '2026-10-01T00:00:00Z',
            updatedAt: '2026-10-02T00:00:00Z',
          ),
        ],
        null,
        false,
      );
      store.updatePostViewCount(5, 9);
      final AylaPost after = store.posts.single;
      expect(after.title, '标题');
      expect(after.body, '正文');
      expect(after.groupId, 'g1');
      expect(after.allowedGroupIds, <String>['g1', 'g2']);
      expect(after.commentCount, 3);
      expect(after.isAuthor, isTrue);
      expect(after.author?.displayName, '小樱');
      expect(after.createdAt, '2026-10-01T00:00:00Z');
      expect(after.updatedAt, '2026-10-02T00:00:00Z');
      expect(after.viewCount, 9);
    });
  });
}
