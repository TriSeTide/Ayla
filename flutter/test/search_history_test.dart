/// 搜索历史（AylaSearchHistoryController）定向测试。
///
/// 事实源：web stores/search.ts —— 去重置顶 · 上限 10 · 可清空 · 存储不可用静默。
library;

import 'package:flutter_test/flutter_test.dart';

import '../lib/state/search_history.dart';

void main() {
  test('push 去重置顶（栈顶最新）', () async {
    final List<String> writer = <String>[];
    final AylaSearchHistoryController controller = AylaSearchHistoryController(
      reader: () async => <String>['旧词'],
      writer: (List<String> history) async {
        writer
          ..clear()
          ..addAll(history);
      },
    );
    await controller.load();
    expect(controller.history, <String>['旧词']);
    controller.push('爱莉');
    controller.push('直播');
    controller.push('爱莉'); // 重复 ⇒ 置顶且不新增
    expect(controller.history, <String>['爱莉', '直播', '旧词']);
    expect(writer, <String>['爱莉', '直播', '旧词']); // 最后一次写回的快照
    controller.dispose();
  });

  test('上限 10（超出丢弃最旧）', () async {
    final AylaSearchHistoryController controller = AylaSearchHistoryController(
      reader: () async => const <String>[],
      writer: (List<String> history) async {},
    );
    await controller.load();
    for (int i = 0; i < 12; i += 1) {
      controller.push('词$i');
    }
    expect(controller.history.length, 10);
    expect(controller.history.first, '词11');
    expect(controller.history.last, '词2');
    controller.dispose();
  });

  test('空白查询忽略；清空写回空数组', () async {
    final List<List<String>> writes = <List<String>>[];
    final AylaSearchHistoryController controller = AylaSearchHistoryController(
      reader: () async => <String>['a'],
      writer: (List<String> history) async => writes.add(history),
    );
    await controller.load();
    controller.push('   ');
    expect(controller.history, <String>['a']);
    expect(writes, isEmpty);
    controller.clear();
    expect(controller.history, isEmpty);
    expect(writes.single, isEmpty);
    controller.dispose();
  });

  test('存储不可用静默：读失败 → 空历史；写失败不抛', () async {
    final AylaSearchHistoryController controller = AylaSearchHistoryController(
      reader: () async => throw StateError('no storage'),
      writer: (List<String> history) async => throw StateError('no storage'),
    );
    await controller.load();
    expect(controller.history, isEmpty);
    controller.push('爱莉');
    expect(controller.history, <String>['爱莉']);
    await Future<void>.delayed(Duration.zero);
    controller.dispose();
  });

  test('load 只读一次（重复调用不覆盖内存态）', () async {
    int reads = 0;
    final AylaSearchHistoryController controller = AylaSearchHistoryController(
      reader: () async {
        reads += 1;
        return <String>['磁盘词'];
      },
      writer: (List<String> history) async {},
    );
    await controller.load();
    controller.push('内存词');
    await controller.load();
    expect(reads, 1);
    expect(controller.history, <String>['内存词', '磁盘词']);
    controller.dispose();
  });
}
