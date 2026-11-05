/// Windows 自绘标题栏的**窗口键锁**回归锁（2026-11-05）。
///
/// ## 为什么需要（审计发现的真实逃逸口）
/// `main.dart` 的装配是 `Column[ if(自定义标题栏) AylaTitleBar, Expanded(Stack[Navigator]) ]`：
/// 标题栏是 Navigator 的**兄弟且在上方**，而所有弹层（含强制更新弹窗）都挂在
/// root Overlay 里 —— root Overlay 的宿主 Navigator 在 `Expanded` 里面 ⇒
/// **任何弹窗都盖不住那 32px**。
///
/// 后果不是视觉问题而是**功能逃逸**：强制更新弹窗开着时右上角的关闭键仍可点，
/// 用户点 X 直接关掉 App，等于绕过强制更新。
///
/// ⇒ `AylaTitleBar.windowKeysLocked = true` 时必须禁用最小化/最大化/关闭三键
///（拖拽与边缘缩放不受影响 —— 那些不构成逃逸）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:window_manager/window_manager.dart' show WindowListener;

import '../lib/layout/app_back.dart' show aylaWindowChromeLock;
import '../lib/theme/app_theme.dart';
import '../lib/widgets/shell/title_bar.dart';

/// 窗口动作替身：只记录被调用了什么（不碰真实通道）。
class _FakeChrome extends AylaWindowChromeController {
  _FakeChrome();

  final List<String> calls = <String>[];
  bool maximized = false;

  @override
  Future<void> minimize() async => calls.add('minimize');

  @override
  Future<void> maximize() async {
    calls.add('maximize');
    maximized = true;
  }

  @override
  Future<void> unmaximize() async {
    calls.add('unmaximize');
    maximized = false;
  }

  @override
  Future<void> close() async => calls.add('close');

  @override
  Future<void> startDragging() async => calls.add('startDragging');

  @override
  Future<bool> isMaximized() async => maximized;
}

/// 事件源替身：不派发任何窗口事件。
class _NoopEvents extends AylaWindowEvents {
  const _NoopEvents();

  @override
  void addListener(WindowListener listener) {}

  @override
  void removeListener(WindowListener listener) {}
}

Future<void> _pump(
  WidgetTester tester, {
  required _FakeChrome chrome,
  required bool locked,
}) async {
  tester.view.physicalSize = const Size(800, 200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAylaTheme(),
      home: Scaffold(
        body: AylaTitleBar(
          controller: chrome,
          events: const _NoopEvents(),
          windowKeysLocked: locked,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 按语义标签找窗口键（三键的 Semantics label 就是「最小化 / 最大化|还原 / 关闭」）。
Finder _windowKey(String label) => find.byWidgetPredicate(
      (Widget w) => w is Semantics && w.properties.label == label,
    );

void main() {
  tearDown(() => aylaWindowChromeLock.value = false);

  group('① 未锁：三键照常可用', () {
    testWidgets('点关闭键 ⇒ 调用 controller.close', (WidgetTester tester) async {
      final _FakeChrome chrome = _FakeChrome();
      await _pump(tester, chrome: chrome, locked: false);
      await tester.tap(_windowKey('关闭'));
      await tester.pumpAndSettle();
      expect(chrome.calls, contains('close'));
    });

    testWidgets('点最小化键 ⇒ 调用 controller.minimize', (WidgetTester tester) async {
      final _FakeChrome chrome = _FakeChrome();
      await _pump(tester, chrome: chrome, locked: false);
      await tester.tap(_windowKey('最小化'));
      await tester.pumpAndSettle();
      expect(chrome.calls, contains('minimize'));
    });
  });

  group('② 锁定（强制更新期间）：三键全部失效', () {
    testWidgets('点关闭键**不**调用 controller.close（不能绕过强制更新）', (
      WidgetTester tester,
    ) async {
      final _FakeChrome chrome = _FakeChrome();
      await _pump(tester, chrome: chrome, locked: true);
      await tester.tap(_windowKey('关闭'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(chrome.calls, isEmpty, reason: '锁定期间点关闭键必须毫无效果');
    });

    testWidgets('点最小化键同样失效', (WidgetTester tester) async {
      final _FakeChrome chrome = _FakeChrome();
      await _pump(tester, chrome: chrome, locked: true);
      await tester.tap(_windowKey('最小化'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(chrome.calls, isEmpty);
    });
  });

  group('③ 模块级标志（更新宿主 ↔ main 的共享面）', () {
    test('默认 false；可置真；可复位', () {
      expect(aylaWindowChromeLock.value, isFalse);
      aylaWindowChromeLock.value = true;
      expect(aylaWindowChromeLock.value, isTrue);
      aylaWindowChromeLock.value = false;
      expect(aylaWindowChromeLock.value, isFalse);
    });
  });
}
