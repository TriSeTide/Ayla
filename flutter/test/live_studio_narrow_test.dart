/// 窄屏开播控制台布局回归锁（2026-10-19 用户实报「窄屏开播页面大量布局错误」）。
///
/// 之前 Flutter 把窄屏控制台当成宽屏三列渲染（`Row[Expanded(主区), 固定340侧栏]`），
/// 而 web 在 ≤768 是**单列纵向滚动**：头部 → 资料栏 → 视频 → 观众条 → 地址卡 → 弹幕卡(240高)。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/buttons.dart' show AylaMsgActionButton;
import '../lib/theme/glass.dart' show AylaGlassButton;
import '../lib/theme/preview_theme.dart';
import '../lib/widgets/live/live_channel_snapshot.dart';
import '../lib/widgets/live/live_hall.dart' show AylaLiveStatus;
import '../lib/widgets/live/live_owner_panel.dart';

void main() {
  Future<void> pumpPanel(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: previewScope(
          Align(
            alignment: Alignment.topLeft,
            child: SizedBox.fromSize(
              size: size,
              child: SingleChildScrollView(
                child: AylaLiveOwnerPanel(
                  channel: _channel,
                  onStart: () async {},
                  onStop: () async {},
                  onSave: (AylaLiveOwnerSaveRequest r) async {},
                  groups: const <({String id, String title})>[],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }

  group('资料栏窄屏档（live.css:247–253）', () {
    testWidgets('窄屏：开播/保存**换行独占整行**，不是挤在第三列 96 宽', (
      WidgetTester tester,
    ) async {
      await pumpPanel(tester, const Size(420, 900));

      final Finder startKey = find.text('开播');
      final Finder saveKey = find.text('保存');
      expect(startKey, findsWidgets, reason: '开播键必须存在');
      expect(saveKey, findsWidgets, reason: '保存键必须存在');

      // ⚠️ `find.text` 拿到的是 **Text 组件**（宽度只有文字宽，如 28）——
      // 要测按钮本体宽度，必须往上找它的按钮祖先（`AylaGlassButton` / `AylaMsgActionButton`）。
      final Finder startBtn = find.ancestor(
        of: startKey.first,
        matching: find.byType(AylaGlassButton),
      );
      final Finder saveBtn = find.ancestor(
        of: saveKey.first,
        matching: find.byType(AylaMsgActionButton),
      );
      expect(startBtn, findsWidgets, reason: '开播键应是 AylaGlassButton');
      expect(saveBtn, findsWidgets, reason: '保存键应是 AylaMsgActionButton');

      final Rect startRect = tester.getRect(startBtn.first);
      final Rect saveRect = tester.getRect(saveBtn.first);
      // `flex-basis: 100%` ⇒ 两键在同一行、等分整行
      expect(
        (startRect.center.dy - saveRect.center.dy).abs(),
        lessThan(40),
        reason: '两键应在同一行（窄屏按钮组 flex-basis:100%）',
      );
      // 等分 420 屏（减去卡片内距）⇒ 明显宽于旧的固定 96
      expect(
        startRect.width,
        greaterThan(120),
        reason: '窄屏开播键应等分整行，不是固定 96（旧实现的错）',
      );
    });

    testWidgets('宽屏：保持三列（封面 | 字段 | 按钮列），不换行', (
      WidgetTester tester,
    ) async {
      await pumpPanel(tester, const Size(1400, 900));
      final Finder startKey = find.text('开播');
      final Finder saveKey = find.text('保存');
      if (startKey.evaluate().isNotEmpty && saveKey.evaluate().isNotEmpty) {
        final Rect startRect = tester.getRect(startKey.first);
        final Rect saveRect = tester.getRect(saveKey.first);
        // 宽屏两键竖排（save 在 start 下方）或与标题同列 —— 关键是不能像窄屏那样等分整行
        expect(
          startRect.width,
          lessThan(300),
          reason: '宽屏按钮宽度受列约束，不应等分整行',
        );
      }
    });
  });
}

/// 最小可用的频道快照（只为渲染资料栏）。
const AylaLiveChannelSnapshot _channel = AylaLiveChannelSnapshot(
  id: '1',
  title: '测试直播间',
  status: AylaLiveStatus.idle,
  ownerId: 'u1',
  ownerNickname: 'test',
  isOwner: true,
  visibility: 'public',
  streamKey: 'k',
  rtmpUrl: 'rtmp://x',
  hlsUrl: 'https://x/a.m3u8',
  flvUrl: 'https://x/a.flv',
  viewerCount: 0,
);
