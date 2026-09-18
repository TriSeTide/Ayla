/// 组件库 Batch 1 冒烟测试:渲染画布全量组件,捕获任何运行期类型/布局错误。
///
/// 用途:widget-preview 宿主页面把错误画进 canvas(DOM 不可读),测试是
/// 拿到「文件:行」定位的最快路径。跑法(Windows 侧):
///   E:\flutter-3.47.4\bin\flutter.bat test test/smoke_gallery_test.dart
library;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/preview/component_gallery.dart';
import '../lib/theme/preview_theme.dart';

void main() {
  /// 真实宿主等价环境:MaterialApp 提供 Directionality/Material/
  /// Localizations(widget-preview 宿主自带壳;previewTheme 的三层兜底
  /// 留给无壳场景)。
  Widget host(Widget child) => MaterialApp(home: previewScope(child));

  testWidgets('Batch 1 全组件渲染无异常', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(const ComponentGallery()),
    );
    // 完整帧 + 让骨架脉冲/呼吸/扫光各自走若干帧
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 600));

    // 分区标题应全部存在
    expect(
      find.text('GlassButton（app.css .btn 21–67 / auroraqua.css 54–166）'),
      findsOneWidget,
    );
    expect(
      find.text('GlassCard（app.css .glass-card 230–248）'),
      findsOneWidget,
    );
    expect(
      find.text('AvatarHalo（app.css .avatar-halo 312–380 / base.css halo-breathe）'),
      findsOneWidget,
    );
    expect(
      find.text('TabBadge（shell.css .tab-badge 579–593）'),
      findsOneWidget,
    );
    expect(find.text('登录'), findsWidgets);
    expect(find.text('注册'), findsOneWidget);
  });

  testWidgets('hover GlassButton 触发扫光与缩放不抛错', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(const ComponentGallery()),
    );
    await tester.pump();

    // 模拟鼠标指针(3.47 无 tester.hover,用 createGesture)
    final TestGesture mouse =
        await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('登录').first));
    await tester.pump();
    // 扫光 600ms 全段
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 200));

    // 移出后再走一遍 reverse
    await mouse.moveTo(const Offset(0, 0));
    await tester.pump(const Duration(milliseconds: 700));
  });
}
