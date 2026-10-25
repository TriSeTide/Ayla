/// 群内桌游房返回键落点回归锁 —— 用户 2026-10-23 实报
/// 「群内桌游房间返回键怎么还是返回到群外桌游列表，没修这个」。
///
/// ## 缺陷
/// `AylaGameRoomHost` 的两处返回回调都写死：
/// ```dart
/// onBack: () => context.canPop() ? context.pop() : context.go('/games')
/// ```
/// ⇒ **绕过了宿主的 `onExit`**。群内进房按返回 ⇒ 直接跳到群外桌游大厅 `/games`。
///
/// ## web 事实源（正确语义）
/// `GroupGames.tsx:66–78`：房内 `onBack={() => setCurrent(null)}`
/// —— 只清本地 state、**回群内桌游列表**（URL 都不变）。
/// `GroupGames` 是群场景的一个子界面，房内态是**页面私有 state 而非子路由**
/// （所以也不存在 `canPop` 可判的情形）。
///
/// ## 本文件锁三件事
/// ① 群内（给了 onExit）⇒ 返回走 onExit，**不** `go('/games')`；
/// ② 全屏右滑与顶部返回键**同一落点**（两处曾各自写死同一错误表达式）；
/// ③ 群外（无 onExit）⇒ 保持原行为（能 pop 就 pop，栈底回大厅）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 复刻 `_AylaGameRoomHostState._back()` 的判据（生产实现的纯逻辑投影）。
///
/// 迁出成纯函数是为了在**不起整页/不连网**的前提下锁住分档顺序；
/// 生产代码里的 `_back` 与此逐行对应（有 onExit 先走 onExit）。
class _BackProbe {
  _BackProbe({this.onExit, required this.canPop});

  final VoidCallback? onExit;
  final bool canPop;

  final List<String> calls = <String>[];

  void back() {
    final VoidCallback? exit = onExit;
    if (exit != null) {
      calls.add('onExit');
      exit();
      return;
    }
    if (canPop) {
      calls.add('pop');
      return;
    }
    calls.add('go:/games');
  }
}

void main() {
  group('群内桌游房返回 ⇒ 回群内列表（不回群外大厅）', () {
    test('① 给了 onExit（群内）⇒ 走 onExit，绝不 go /games', () {
      int exits = 0;
      final _BackProbe probe = _BackProbe(
        onExit: () => exits += 1,
        canPop: false,
      )..back();

      expect(exits, 1, reason: '★ 群内必须交回宿主（清 _currentRoomId 回列表）');
      expect(
        probe.calls,
        <String>['onExit'],
        reason: '★ 返回键不得跳到群外桌游大厅',
      );
      expect(probe.calls.contains('go:/games'), isFalse);
    });

    test('② onExit 存在时，即便 canPop 为真也优先 onExit（顺序不能颠倒）', () {
      int exits = 0;
      final _BackProbe probe = _BackProbe(
        onExit: () => exits += 1,
        canPop: true,
      )..back();

      expect(exits, 1, reason: 'onExit 档必须在 canPop 之前');
      expect(probe.calls, <String>['onExit']);
    });

    test('③ 群外（无 onExit）：能 pop 就 pop，栈底才回大厅', () {
      final _BackProbe popped = _BackProbe(canPop: true)..back();
      expect(popped.calls, <String>['pop'],
          reason: '进房是 push ⇒ 返回先回大厅列表');
      expect(popped.calls.contains('go:/games'), isFalse);

      final _BackProbe stackBottom = _BackProbe(canPop: false)..back();
      expect(stackBottom.calls, <String>['go:/games'],
          reason: '栈底兜底回大厅（群外既有口径）');
    });
  });

  group('生产代码接线锁（静态扫描，防再次写死 /games）', () {
    test('④ game_support.dart 的**代码行**不含「canPop ? pop : go(/games)」硬编码', () {
      final String raw =
          File('lib/pages/game_support.dart').readAsStringSync();
      // ⚠️ 只扫**非注释行**：_back 的文件注释里为说明缺陷成因**引用**了该表达式，
      // 那不是可执行代码。直接扫全文会误报（本用例首跑即红过，已修正口径）。
      final List<String> codeLines = <String>[
        for (final String line in raw.split('\n'))
          if (!line.trimLeft().startsWith('//')) line,
      ];
      final String code = codeLines.join('\n');

      // 该表达式曾出现在两处（顶部返回键 + 全屏右滑）并绕过 onExit。
      expect(
        code.contains("context.canPop() ? context.pop() : context.go('/games')"),
        isFalse,
        reason: '★ 硬编码返回会绕过宿主 onExit ⇒ 群内跳到群外大厅（用户实报）',
      );
      // 两处必须都走统一入口 _back。
      expect(
        RegExp(r'onBack: _back').allMatches(code).length,
        2,
        reason: '顶部返回键与全屏右滑都必须走 _back（同一落点）',
      );
    });

    test('⑤ _back 的**代码**里有 onExit 优先档（且早于 canPop / go /games）', () {
      final String raw =
          File('lib/pages/game_support.dart').readAsStringSync();
      final int backAt = raw.indexOf('void _back()');
      expect(backAt, greaterThan(0), reason: '_back 必须存在');

      // ⚠️ 必须剔除注释再判：_back 的文件注释里为说明缺陷成因**提到了 onExit**，
      // 只扫原文会让本用例在「真把 onExit 档删掉」时照样绿（实测变异未抓到，已修正）。
      final List<String> bodyLines = <String>[
        for (final String line
            in raw.substring(backAt).split('\n'))
          if (!line.trimLeft().startsWith('//')) line,
      ];
      final String body = bodyLines.join('\n');

      final int exitAt = body.indexOf('widget.onExit');
      expect(exitAt, greaterThan(0),
          reason: '★ 群内落点必须由宿主 onExit 决定（回群内列表）');

      final int canPopAt = body.indexOf('context.canPop()');
      final int goGamesAt = body.indexOf("context.go('/games')");
      expect(canPopAt, greaterThan(exitAt),
          reason: '★ onExit 档必须在 canPop 之前（群内房内态不产生路由栈）');
      expect(goGamesAt, greaterThan(exitAt),
          reason: '★ onExit 档必须在 go(/games) 之前');
    });
  });
}
