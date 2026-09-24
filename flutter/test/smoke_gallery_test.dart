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

  /// 画布真实宽度（组件画布按 1800 宽排布；样张舞台最宽 1240/1100）。
  ///
  /// ⚠️ 必须显式钉死：默认测试窗口物理 800×600 / **DPR 3** ⇒ 逻辑仅 266×200，
  /// 样张里那些 1100 宽的舞台会被挤到 ~150 ⇒ 带固定侧栏的样张（如直播间三栏）
  /// 主区被挤没、头部报 RenderFlex overflow（2026-09-22 实测）。
  void pinCanvas(WidgetTester tester) {
    tester.view.physicalSize = const Size(1800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('Batch 1 全组件渲染无异常', (WidgetTester tester) async {
    pinCanvas(tester);
    await tester.pumpWidget(
      host(const ComponentGallery()),
    );
    // 完整帧 + 让骨架脉冲/呼吸/扫光各自走若干帧
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 600));

    // 分区标题应全部可渲染（⚠️ 2026-09-24 起画布是**懒加载** `ListView.builder`：
    // 只为可见 section 建 Element/语义节点——一次性 1685 个语义节点会让 Windows
    // accessibility bridge 更新失败并 `Lost connection to device`）⇒ 逐个滚动到可见再断言。
    // 分区标题应全部存在（画布整体 `ExcludeSemantics` + 一次性构建；
    // 注：曾尝试 `ListView.builder` 懒加载来减语义节点，但样张里的 autofocus 组件
    // 在被滚动销毁时会触发 framework 焦点断言 ⇒ 已回退，改在组件侧关语义）
    void expectSection(String title) {
      expect(find.text(title), findsOneWidget, reason: title);
    }

    for (final String title in <String>[
      'GlassButton（app.css .btn 21–67 / auroraqua.css 54–166）',
      'GlassCard（app.css .glass-card 230–248）',
      'AvatarHalo（app.css .avatar-halo 312–380 / base.css halo-breathe）',
      // 2026-09-20 审查 R8：TabBadge 分区标题改为「三档规格」写法
      'TabBadge（shell.css .tab-badge 579–593 · home.css .group-badge 302–317 · messages.css .messages-tab-badge 43–55）',
      // 2026-09-20 审查 R7：入场件分区
      'AylaRevealItem / AylaRevealScope（base.css .reveal-item · auroraqua.css 8–26 · useListEntryMotion）',
      // 2026-09-21 A3：Shell 弹层分区（CreateSheet 两形态）
      'AylaCreateSheet（layout/CreateSheet.tsx 1–61 + private.css 185–275）',
      // 2026-09-21 A4：右下浮层按钮族分区
      'AylaCornerFabStack / AylaRefreshFab / AylaScrollTopFab / AylaQuickMessageFab（layout/*.tsx + shell.css 423–456 / 679–787）',
      // 2026-09-21 A5：会话活动悬浮球分区
      'AylaSessionActivityIndicator（layout/SessionActivityIndicator.tsx 1–181 + shell.css 458–575 / 651–660）',
      // 2026-09-21 B1-1：voice 域第一批分区
      'AylaVoiceChannelCard / AylaVoiceChannelList / AylaVoiceControls（components/voice/*.tsx 121 行 + app.css 2811–2832 · 2910–2915 · 3099–3120 + voice.css 471–485 · 505–628 · 647–659 · 690–789）',
      // 2026-09-21 B1-2：voice 成员行（含音量条）分区
      'AylaVoiceMemberRow（components/voice/VoiceMemberRow.tsx 219 行 + app.css 2917–3095 + auroraqua.css 59/77/89/664）',
      // 2026-09-21 B1-3：建语音频道表单分区
      'AylaVoiceChannelCreate（components/voice/VoiceChannelCreate.tsx 80 行 + app.css 2848–2869 + auroraqua.css 502–531 + private.css 229–236）',
      // 2026-09-21 B1-4：语音频道面板分区
      'AylaVoiceChannelPanel（components/voice/VoiceChannelPanel.tsx 158 行 + app.css 2873–2915 + voice.css 32–56/377–381 + auroraqua.css 584–610）',
      // 2026-09-21 B1-5：爱莉语音面板分区
      'AylaElysiaVoicePanel（components/voice/ElysiaVoicePanel.tsx 108 行 + app.css 3122–3156 / 1324–1333 / 1362）',
      // 2026-09-21 B1-6：语音房整页分区
      'AylaVoiceRoomBody（components/voice/VoiceRoomBody.tsx 327 行 + voice.css 12–470 + app.css 2105–2138/3473–3477 + base.css 463–472）',
      // 2026-09-24 B3 chat 域第一批三节（本批新增）
      '聊天消息气泡（MessageBubble.tsx）',
      '媒体消息族（MediaContent.tsx）',
      '分享卡 / 爱莉入口卡（ShareBubble.tsx + ElysiaEntry.tsx）',
      // 2026-09-24 B3 chat 域第二批三节
      '会话列表（ConversationList.tsx）',
      '@ 成员选择器（MentionPicker.tsx）',
      '群表情包面板（EmojiPackPanel.tsx）',
      // 2026-09-24 B3 chat 域第三批两节
      '消息输入区（MessageInput.tsx）',
      '消息滚动区（MessageList.tsx）',
      // 2026-09-24 B3 chat 域第四批三节
      '消息中心选项卡（messages-tabs；WideMessagesSidebar 与 QuickMessagesSheet 共用）',
      '认证消息面板（WideMessagesSidebar / QuickMessagesSheet 共用）',
      '私聊面板（PrivateChatPane.tsx）',
      // 2026-09-24 B3 chat 域第四批下两节（chat 域收官）
      '宽屏消息左列（WideMessagesSidebar.tsx）',
      '快捷消息栏（QuickMessagesSheet.tsx）',
    ]) {
      expectSection(title);
    }
    expect(find.text('登录'), findsWidgets);
    expect(find.text('注册'), findsOneWidget);
  });

  testWidgets('hover GlassButton 触发扫光与缩放不抛错', (WidgetTester tester) async {
    pinCanvas(tester);
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
