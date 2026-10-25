/// 群内桌游房「不让状态栏」的行为锁（2026-10-19 用户第三次实拍后补）。
///
/// ## 上一轮为什么没修好
/// `inGroup` 字段加在了 `AylaGameRoomHost` 上、页面也传了 `true`，
/// 但 Host 内部调用 `AylaGameRoomPlaceholder` 时**没把开关透传下去** ⇒ 群内空白带依旧。
/// `dart analyze` 不报（`topInset` 的默认值 `true` 让语法完全合法）。
///
/// ⇒ 两层锁：
/// 1. `group_top_inset_wiring_test.dart`：静态扫描**宿主的调用点是否传了开关**；
/// 2. 本文件：**行为锁** —— 真的渲染，断言有没有产出状态栏占位。
///
/// ⚠️ 不构造完整 `AylaGameRoom`：它依赖 `AylaUserPublic`（并行任务正在改的模块），
///    与本缺陷无关。这里锁的是 `AylaTopInsetGap`（唯一的让位入口）在两种媒体条件下的行为。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/widgets/base/safe_area.dart';

void main() {
  /// 直接搭 MaterialApp（**不套 previewScope**：它内部会重新包一层 MediaQuery，
  /// 把本测试要注入的 `viewPadding` 覆盖掉 ⇒ 量出来恒为 0）。
  Widget host({required double top}) => MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            viewPadding: EdgeInsets.only(top: top),
            padding: EdgeInsets.only(top: top),
          ),
          child: const Scaffold(
            body: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                AylaTopInsetGap(),
                SizedBox(height: 56, child: Text('头部')),
              ],
            ),
          ),
        ),
      );

  testWidgets('有状态栏（手机）⇒ 占位高度 = viewPadding.top', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(top: 24));
    await tester.pump();
    expect(find.byType(AylaTopInsetGap), findsOneWidget);
    expect(
      tester.getSize(find.byType(AylaTopInsetGap)).height,
      24,
      reason: '一级页（无壳层顶栏）必须自己让出状态栏',
    );
  });

  testWidgets('无状态栏（桌面/宽屏）⇒ 占位高度 0（零开销）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(top: 0));
    await tester.pump();
    expect(
      tester.getSize(find.byType(AylaTopInsetGap)).height,
      0,
      reason: '没有状态栏时不能白占高度',
    );
  });

  testWidgets('键盘弹出（viewInsets）不影响占位高度', (WidgetTester tester) async {
    // 顶栏不该因弹键盘而跳动 ⇒ 必须是 viewPadding 而非 padding 的语义。
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            viewPadding: EdgeInsets.only(top: 24),
            padding: EdgeInsets.only(top: 24),
            viewInsets: EdgeInsets.only(bottom: 300),
          ),
          child: const Scaffold(
            body: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                AylaTopInsetGap(),
                SizedBox(height: 56, child: Text('头部')),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.getSize(find.byType(AylaTopInsetGap)).height, 24);
  });
}
