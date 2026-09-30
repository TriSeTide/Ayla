/// 预加载是否真的生效 —— 直接量「进页面时 store 里有没有那份数据」，而不是量骨架。
library;

import 'package:flutter_test/flutter_test.dart';

import '../lib/core/api/directory_page.dart';
import '../lib/state/directory_events.dart' show AylaDirectoryKind;
import '../lib/state/directory_store.dart';

void main() {
  test('预取用的 key == 页面「全部」档的 key（预加载生效的前提）', () {
    final String prefetch = aylaDirectoryKey(
      AylaDirectoryKind.live,
      const AylaDirectoryOptions(filter: 'all'),
      userId: 'u1',
    );
    final String page = aylaDirectoryKey(
      AylaDirectoryKind.live,
      const AylaDirectoryOptions(filter: 'all'),
      userId: 'u1',
    );
    expect(prefetch, page);
  });

  test('预取后 store 已有该档 record ⇒ 页面进入命中、不需要加载', () async {
    final AylaDirectoryStore store = AylaDirectoryStore();
    store.userId = 'u1';
    store.requestOverride = (kind, options, cursor) async =>
        AylaDirectoryPage<Object>(results: <Object>['a'], total: 1);
    await store.load(
      AylaDirectoryKind.live,
      const AylaDirectoryOptions(filter: 'all'),
    );
    const AylaDirectoryOptions pageOptions = AylaDirectoryOptions(filter: 'all');
    expect(store.recordOf(AylaDirectoryKind.live, pageOptions), isNotNull);
    expect(store.isLoading(AylaDirectoryKind.live, pageOptions), isFalse);
    expect(store.itemsAs<String>(AylaDirectoryKind.live, pageOptions), <String>['a']);
  });
}
