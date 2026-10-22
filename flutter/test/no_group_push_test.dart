/// 群路由**绝不能 push** 的回归锁（2026-10-19 两次实机红屏的教训）。
///
/// ## 背景
/// 群页 5 条路由共用同一个 `kAylaGroupShellPageKey`（`router/app_router.dart:91`），
/// 这是「切场景不重建整页」的前提。同一个 Page key 被压到栈上两次 ⇒ Navigator 抛：
/// ```text
/// 'package:flutter/src/widgets/navigator.dart': Failed assertion:
/// !keyReservation.contains(key)': is not true.
/// ```
/// ⇒ 整屏红。
///
/// ## 为什么需要这个**静态扫描**测试
/// 这是一个**运行期才炸、且只在特定点击路径上炸**的缺陷：
/// · `dart analyze` 不报（push / go 签名相同）；
/// · 常规 widget 测试不报（除非恰好点到那条路径）；
/// · 同一天内两次漏过（第一次修了 3 处，第二次又发现 2 处）。
/// ⇒ 改用源码静态扫描：**任何 `context.push(` 的实参里出现 `/group` 即为违规**。
///
/// 群内的逐级返回由 `GroupPage` 的 `PopScope` + 场景历史栈（`_popScene`）承担，
/// 不依赖路由栈 ⇒ 用 `go` 不会损失返回能力。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('源码中不存在「push 到 /group 路由」——群页共用 Page key，push 必红屏', () {
    final List<String> violations = <String>[];
    final Directory lib = Directory('lib');
    expect(lib.existsSync(), isTrue, reason: '测试需在 flutter 工程根目录运行');

    for (final FileSystemEntity entity in lib.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final String src = entity.readAsStringSync();
      int from = 0;
      while (true) {
        final int idx = src.indexOf('context.push(', from);
        if (idx < 0) break;
        from = idx + 1;
        int depth = 1;
        int i = idx + 'context.push('.length;
        while (i < src.length && depth > 0) {
          final String ch = src[i];
          if (ch == '(') depth++;
          if (ch == ')') depth--;
          i++;
        }
        final String args = src.substring(idx, i);
        if (args.contains('/group')) {
          final int line = src.substring(0, idx).split('\n').length;
          violations.add(entity.path + ':' + line.toString());
        }
      }
    }

    expect(
      violations,
      isEmpty,
      reason: '以下位置 push 到了群路由，会红屏（必须改用 context.go）：\n' +
          violations.join('\n'),
    );
  });
}
