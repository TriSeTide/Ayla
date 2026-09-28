/// AylaPagedList（游标分页状态机）定向测试。
///
/// 事实源：web stores/directory.ts 的 loadDirectory（264–341）——
/// 首页 cursor=null · 追加用 nextCursor · 游标无效静默降级 · 错误保留已加载 items ·
/// 在途作废（revision 守卫）。
library;

import 'package:flutter_test/flutter_test.dart';

import 'dart:async';

import '../lib/core/api/directory_page.dart';
import '../lib/core/net/dio_client.dart' show ApiException;
import '../lib/state/paged_list.dart';

/// 测试条目（只用 id 做键）。
class _Item {
  const _Item(this.id);
  final String id;
}

void main() {
  test('首页取 cursor=null；追加用返回的 nextCursor', () async {
    final List<String?> cursors = <String?>[];
    final AylaPagedList<_Item> pager = AylaPagedList<_Item>(
      request: (String? cursor) async {
        cursors.add(cursor);
        if (cursor == null) {
          return const AylaDirectoryPage<_Item>(
            results: <_Item>[_Item('a')],
            nextCursor: 'c2',
            hasMore: true,
            total: 2,
          );
        }
        return const AylaDirectoryPage<_Item>(
          results: <_Item>[_Item('b')],
          nextCursor: null,
          hasMore: false,
          total: 2,
        );
      },
      keyOf: (_Item item) => item.id,
    );

    await pager.load();
    expect(cursors, <String?>[null]);
    expect(pager.items.map((_Item i) => i.id), <String>['a']);
    expect(pager.hasMore, isTrue);
    expect(pager.total, 2);
    expect(pager.loaded, isTrue);

    await pager.loadMore();
    expect(cursors, <String?>[null, 'c2']);
    expect(pager.items.map((_Item i) => i.id), <String>['a', 'b']);
    expect(pager.hasMore, isFalse);
    // 没有下一页时追加是 no-op
    await pager.loadMore();
    expect(cursors.length, 2);
  });

  test('刷新整体替换（不是追加）', () async {
    int round = 0;
    final AylaPagedList<_Item> pager = AylaPagedList<_Item>(
      request: (String? cursor) async {
        round += 1;
        return AylaDirectoryPage<_Item>(
          results: <_Item>[_Item('r${round}')],
          nextCursor: 'c',
          hasMore: true,
          total: 1,
        );
      },
      keyOf: (_Item item) => item.id,
    );
    await pager.load();
    await pager.loadMore(); // 追加：同一 id ⇒ 合并后仍 1 条
    expect(pager.items.length, 1);
    await pager.refresh(); // 刷新：整体替换
    expect(pager.items.single.id, 'r3');
  });

  test('游标无效（has_more 但 next_cursor 与请求相同）⇒ 静默降级，不报错', () async {
    final AylaPagedList<_Item> pager = AylaPagedList<_Item>(
      request: (String? cursor) async => const AylaDirectoryPage<_Item>(
        results: <_Item>[_Item('a')],
        nextCursor: 'same',
        hasMore: true,
        total: 5,
      ),
      keyOf: (_Item item) => item.id,
    );
    await pager.load();
    expect(pager.items.length, 1);
    await pager.loadMore(); // 第二次请求返回同一个游标 ⇒ 判定无效
    await pager.loadMore();
    expect(pager.error, isNull); // 不打扰用户
    expect(pager.loading, isFalse);
  });

  test('错误保留已加载 items，并把可读消息写进 error', () async {
    bool fail = false;
    final AylaPagedList<_Item> pager = AylaPagedList<_Item>(
      request: (String? cursor) async {
        if (fail) throw const ApiException(503, '服务暂不可用');
        return const AylaDirectoryPage<_Item>(
          results: <_Item>[_Item('a')],
          nextCursor: 'c2',
          hasMore: true,
          total: 9,
        );
      },
      keyOf: (_Item item) => item.id,
    );
    await pager.load();
    fail = true;
    await pager.refresh();
    expect(pager.error, '服务暂不可用');
    expect(pager.items.length, 1); // 保留
    expect(pager.loading, isFalse);
  });

  test('刷新使在途请求作废（旧响应不写回）', () async {
    final List<Completer<void>> gates = <Completer<void>>[];
    int round = 0;
    final AylaPagedList<_Item> pager = AylaPagedList<_Item>(
      request: (String? cursor) async {
        final int index = round++;
        final Completer<void> gate = Completer<void>();
        gates.add(gate);
        await gate.future;
        return AylaDirectoryPage<_Item>(
          results: <_Item>[_Item('r${index + 1}')],
          total: 1,
        );
      },
      keyOf: (_Item item) => item.id,
    );
    final Future<void> first = pager.load();
    final Future<void> second = pager.refresh();
    // 先放行第二次（它是当前 revision）
    gates[1].complete();
    await second;
    expect(pager.items.single.id, 'r2');
    // 再放行第一次：应被丢弃
    gates[0].complete();
    await first;
    expect(pager.items.single.id, 'r2');
  });

  test('dispose 后在途结果丢弃', () async {
    final Completer<void> gate = Completer<void>();
    final AylaPagedList<_Item> pager = AylaPagedList<_Item>(
      request: (String? cursor) async {
        await gate.future;
        return const AylaDirectoryPage<_Item>(results: <_Item>[_Item('a')]);
      },
      keyOf: (_Item item) => item.id,
    );
    final Future<void> pending = pager.load();
    pager.dispose();
    gate.complete();
    await pending;
    expect(pager.items, isEmpty);
  });
}
