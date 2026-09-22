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
    // 2026-09-20 审查 R8：TabBadge 分区标题改为「三档规格」写法
    expect(
      find.text(
        'TabBadge（shell.css .tab-badge 579–593 · home.css .group-badge 302–317 · messages.css .messages-tab-badge 43–55）',
      ),
      findsOneWidget,
    );
    // 2026-09-20 审查 R7：入场件分区
    expect(
      find.text(
        'AylaRevealItem / AylaRevealScope（base.css .reveal-item · auroraqua.css 8–26 · useListEntryMotion）',
      ),
      findsOneWidget,
    );
    // 2026-09-21 A3：Shell 弹层分区（CreateSheet 两形态）
    expect(
      find.text(
        'AylaCreateSheet（layout/CreateSheet.tsx 1–61 + private.css 185–275）',
      ),
      findsOneWidget,
    );
    // 2026-09-21 A4：右下浮层按钮族分区
    expect(
      find.text(
        'AylaCornerFabStack / AylaRefreshFab / AylaScrollTopFab / AylaQuickMessageFab（layout/*.tsx + shell.css 423–456 / 679–787）',
      ),
      findsOneWidget,
    );
    // 2026-09-21 A5：会话活动悬浮球分区
    expect(
      find.text(
        'AylaSessionActivityIndicator（layout/SessionActivityIndicator.tsx 1–181 + shell.css 458–575 / 651–660）',
      ),
      findsOneWidget,
    );
    // 2026-09-21 B1-1：voice 域第一批分区
    expect(
      find.text(
        'AylaVoiceChannelCard / AylaVoiceChannelList / AylaVoiceControls（components/voice/*.tsx 121 行 + app.css 2811–2832 · 2910–2915 · 3099–3120 + voice.css 471–485 · 505–628 · 647–659 · 690–789）',
      ),
      findsOneWidget,
    );
    // 2026-09-21 B1-2：voice 成员行（含音量条）分区
    expect(
      find.text(
        'AylaVoiceMemberRow（components/voice/VoiceMemberRow.tsx 219 行 + app.css 2917–3095 + auroraqua.css 59/77/89/664）',
      ),
      findsOneWidget,
    );
    // 2026-09-21 B1-3：建语音频道表单分区
    expect(
      find.text(
        'AylaVoiceChannelCreate（components/voice/VoiceChannelCreate.tsx 80 行 + app.css 2848–2869 + auroraqua.css 502–531 + private.css 229–236）',
      ),
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
