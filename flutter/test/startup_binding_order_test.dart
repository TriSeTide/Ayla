/// release 档启动顺序的回归锁（2026-10-31 实报「手机端更新后一点 App 直接白屏」）。
///
/// ## 缺陷与根因
/// `main()` 把 `WidgetsFlutterBinding.ensureInitialized()` 包在
/// `if (kDebugMode || kProfileMode)` 里；release 档不执行。原本靠下面
/// `if (aylaUsesDesktopFullscreen())` 分支补一次，但该条件**只对 Windows/macOS/Linux 为真**
/// ⇒ Android/iOS 在 release 档从头到尾没有初始化 binding。
///
/// 于是 `AylaDetachedLiveEvents.instance.bind()` 调
/// `MethodChannel.setMethodCallHandler`（内部取 `ServicesBinding.instance`）时断言失败
/// ⇒ `main()` 抛出 ⇒ `runApp` 永不执行 ⇒ **纯白屏**（进程活着、无任何页面）。
///
/// ## 为什么既有测试没抓到
/// · 单元测试框架**自己**会初始化 binding ⇒ 测不到；
/// · `flutter build apk --debug` 是 debug 档 ⇒ `kDebugMode` 为真，缺陷分支不触发；
/// · 只有 **release 档 + 移动平台** 才命中 —— 也就是用户装的包。
///
/// ## 断言方式
/// widget test 无法改变 `kDebugMode`，故本文件对**源码本身**做契约检查：
/// 先把注释剥掉（注释里会提到这些符号，直接 indexOf 会误命中），再断言
/// ① `main()` 在 runApp 之前有一次**无条件**的 `ensureInitialized()`；
/// ② 它早于 `bind()` 这个最早的 MethodChannel 使用者；
/// ③ `bind()` 自带 try/catch 降级。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 剥掉 `//` 行注释（本文件只做行级剥离；块注释在本仓库的 Dart 代码里不用）。
String stripLineComments(String source) {
  final StringBuffer out = StringBuffer();
  for (final String line in source.split('\n')) {
    final int idx = line.indexOf('//');
    // 只剥「整行注释」与「行尾注释」；字符串里的 // 不会出现在这几行关键语句里。
    out.writeln(idx >= 0 ? line.substring(0, idx) : line);
  }
  return out.toString();
}

void main() {
  late String mainSource;
  late String contractSource;

  setUpAll(() {
    mainSource = stripLineComments(File('lib/main.dart').readAsStringSync());
    contractSource =
        stripLineComments(File('lib/core/platform/detached_live.dart').readAsStringSync());
  });

  /// `main()` 函数体（从 `void main() {` 到 `runApp(` 之前），已剥注释。
  String mainBodyBeforeRunApp() {
    final int start = mainSource.indexOf('void main() {');
    expect(start, greaterThan(-1), reason: 'lib/main.dart 里必须有 void main()');
    final int runApp = mainSource.indexOf('runApp(', start);
    expect(runApp, greaterThan(start), reason: 'main() 里必须有 runApp(');
    return mainSource.substring(start, runApp);
  }

  test('main() 在 runApp 之前存在一次**无条件**的 ensureInitialized()', () {
    final String body = mainBodyBeforeRunApp();
    final List<String> lines = body.split('\n');

    bool foundUnconditional = false;
    for (int i = 0; i < lines.length; i += 1) {
      if (!lines[i].contains('WidgetsFlutterBinding.ensureInitialized()')) continue;
      // 向上找最近的非空行，判断这一句是否被 if 包住。
      int j = i - 1;
      String prev = '';
      while (j >= 0) {
        final String t = lines[j].trim();
        if (t.isEmpty) {
          j -= 1;
          continue;
        }
        prev = t;
        break;
      }
      final bool guardedByIf = prev.startsWith('if (') || prev.startsWith('} else if (');
      if (!guardedByIf) {
        foundUnconditional = true;
        break;
      }
    }

    expect(
      foundUnconditional,
      isTrue,
      reason: 'main() 必须在 runApp 之前**无条件**初始化 binding —— '
          '否则 release 档（kDebugMode/kProfileMode 均为 false）在移动平台上不会初始化，'
          '后续任何 MethodChannel / Binding.instance 使用都会抛异常，'
          '导致 runApp 不执行、整屏白屏（2026-10-31 实报）。',
    );
  });

  test('无条件 ensureInitialized 必须早于 bind() 这个最早的 MethodChannel 使用者', () {
    final String body = mainBodyBeforeRunApp();
    final int init = body.indexOf('WidgetsFlutterBinding.ensureInitialized()');
    expect(init, greaterThan(-1));

    final int bind = body.indexOf('AylaDetachedLiveEvents.instance.bind()');
    expect(bind, greaterThan(-1), reason: 'main() 必须挂载脱离事件绑定');
    expect(
      init,
      lessThan(bind),
      reason: 'ensureInitialized 必须早于 bind()（bind 内部取 ServicesBinding.instance）',
    );
  });

  test('AylaDetachedLiveEvents.bind() 自带 try/catch 降级（失败不拖死启动）', () {
    final int start = contractSource.indexOf('void bind() {');
    expect(start, greaterThan(-1));
    final int end = contractSource.indexOf('\n  }', start);
    expect(end, greaterThan(start));
    final String body = contractSource.substring(start, end);

    expect(
      body.contains('try {'),
      isTrue,
      reason: 'bind() 必须用 try/catch 包住 setMethodCallHandler：'
          '「脱离应用」是可选增强，绑不上只该退化成没有原生事件，'
          '不该让用户连 App 都进不去。',
    );
    expect(body.contains('catch'), isTrue);
  });
}
