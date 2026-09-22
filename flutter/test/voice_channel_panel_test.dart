/// B1-4：语音频道面板定向测试 —— 逐条对照 `VoiceChannelPanel.tsx`(158) 与
/// `app.css:2873–2915`、`voice.css:32–56 / 377–381`、`auroraqua.css:584–610`。
///
/// 覆盖：结构（标题 16/700 + 人数 baseline）/ 材质两档 / 空态三分支 / 自己置顶兜底 /
/// 成员行字段透传 / 房主操作行的出现条件 / busy（两个按钮一起禁用 + 「处理中…」+ 重复点击守卫）/
/// 失败静默 / 分页透传 / 控制条透传 / 成员列表滚动档 / 人数省略。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/glass.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/directory_controls.dart';
import '../lib/widgets/voice_channel_panel.dart';
import '../lib/widgets/voice_member_row.dart';

void main() {
  const AylaVoicePanelMember elysia = AylaVoicePanelMember(
    member: AylaVoiceMember(userId: 'u2'),
    displayName: '爱莉',
    online: true,
  );
  const AylaVoicePanelMember other = AylaVoicePanelMember(
    member: AylaVoiceMember(userId: 'u3', muted: true),
    displayName: '小满',
  );
  const AylaVoicePanelMember self = AylaVoicePanelMember(
    member: AylaVoiceMember(userId: 'self'),
    displayName: '汐汐',
  );

  Widget host(Widget child, {Size viewport = const Size(700, 620)}) {
    return MaterialApp(
      home: previewScope(
        Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(size: viewport),
            child: SizedBox.fromSize(
              size: viewport,
              child: SingleChildScrollView(child: child),
            ),
          ),
        ),
      ),
    );
  }

  /// 有界高度宿主：房间上下文档用（`Expanded` 需要有限高；竖向滚动视图给不出）。
  Widget hostBounded(Widget child, {Size viewport = const Size(700, 420)}) {
    return MaterialApp(
      home: previewScope(
        Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(size: viewport),
            child: SizedBox.fromSize(size: viewport, child: child),
          ),
        ),
      ),
    );
  }

  void setViewport(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  AylaVoiceChannelPanel panelOf(WidgetTester tester) =>
      tester.widget<AylaVoiceChannelPanel>(find.byType(AylaVoiceChannelPanel));

  List<AylaVoiceMemberRow> rows(WidgetTester tester) =>
      tester.widgetList<AylaVoiceMemberRow>(find.byType(AylaVoiceMemberRow)).toList();

  /// 房主操作行的按钮（按 label 取；**每个成员行各一个** ⇒ 返回列表）。
  List<GlassButton> actionButtons(WidgetTester tester, String label) => tester
      .widgetList<GlassButton>(
        find.byWidgetPredicate(
          (Widget w) => w is GlassButton && w.label == label,
        ),
      )
      .toList();

  // ======================= 结构 =======================

  testWidgets('结构：head（标题 16/700 + 人数 12/secondary）→ 成员列表 → 控制条',
      (WidgetTester tester) async {
    setViewport(tester, const Size(700, 620));
    await tester.pumpWidget(
      host(
        const AylaVoiceChannelPanel(
          channelName: '深夜电台',
          members: <AylaVoicePanelMember>[elysia, other],
          count: 3,
        ),
      ),
    );

    final Text title = tester.widget<Text>(find.text('深夜电台'));
    expect(title.style!.fontSize, 16); // `.voice-panel-title { font-size: 16px }`
    expect(title.style!.fontWeight, FontWeight.w700); // h3 默认 bold（base.css 未重置）
    final Text count = tester.widget<Text>(find.text('3 人'));
    expect(count.style!.fontSize, 12);
    expect(count.style!.color, AylaColors.textSecondary);

    // `.voice-panel-head { align-items: baseline }`：标题与人数**基线对齐**
    final double titleBaseline =
        tester.getRect(find.text('深夜电台')).bottom;
    final double countBaseline = tester.getRect(find.text('3 人')).bottom;
    expect((titleBaseline - countBaseline).abs(), lessThan(2.0));

    expect(rows(tester).length, 2);
    expect(find.text('离开频道'), findsOneWidget); // 控制条在底部
    expect(
      tester.getRect(find.text('离开频道')).top,
      greaterThan(tester.getRect(find.byType(AylaVoiceMemberRow).last).bottom),
    );
  });

  testWidgets('材质档：ownMaterial=true 自带玻璃（radius 16 / blur24 / glass 阴影 / padding 16 / max-width 560）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(700, 620));
    // ⚠️ 宿主必须给**宽松宽度**：竖向 `SingleChildScrollView` 会给紧宽约束，
    //    `max-width: 560` 就无从生效（min>max 时 min 胜出）。
    await tester.pumpWidget(
      host(
        Align(
          alignment: Alignment.topLeft,
          child: AylaVoiceChannelPanel(
            channelName: '深夜电台',
            members: const <AylaVoicePanelMember>[elysia],
          ),
        ),
      ),
    );
    final GlassSurface surface =
        tester.widget<GlassSurface>(find.byType(GlassSurface));
    expect(
      surface.radiusOverride,
      BorderRadius.all(Radius.circular(AylaRadii.rCard)), // --radius-card 16
    );
    expect(surface.blur, AylaGlass.blurCard); // blur(24) saturate(1.4)
    expect(surface.shadow, AylaShadows.glass); // --glass-shadow
    expect(surface.padding, const EdgeInsets.all(AylaSpacing.sp4)); // padding: sp4
    // `max-width: 560px`（app.css:2877）
    expect(tester.getSize(find.byType(AylaVoiceChannelPanel)).width, 560);


  });

  testWidgets('房间上下文档：max-width 被覆写为 none（voice.css 32–38）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(700, 620));
    await tester.pumpWidget(
      hostBounded(
        Align(
          alignment: Alignment.topLeft,
          child: AylaVoiceChannelPanel(
            channelName: '深夜电台',
            members: const <AylaVoicePanelMember>[elysia],
            roomContext: true,
            ownMaterial: false,
          ),
        ),
        viewport: const Size(700, 420),
      ),
    );
    expect(
      tester.getSize(find.byType(AylaVoiceChannelPanel)).width,
      greaterThan(560),
    );
  });

  testWidgets('材质档：ownMaterial=false 透明（宽屏房间把材质交给外层卡）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(700, 620));
    await tester.pumpWidget(
      host(
        const AylaVoiceChannelPanel(
          channelName: '深夜电台',
          members: <AylaVoicePanelMember>[elysia],
          ownMaterial: false,
        ),
      ),
    );
    expect(find.byType(GlassSurface), findsNothing);
    expect(find.byType(AylaVoiceMemberRow), findsOneWidget);
  });

  testWidgets('空态：行数为 0 且不在加载/无错误 → 「当前还没有成员」',
      (WidgetTester tester) async {
    setViewport(tester, const Size(700, 620));
    await tester.pumpWidget(
      host(const AylaVoiceChannelPanel(channelName: '深夜电台')),
    );
    expect(find.text(AylaVoiceChannelPanel.emptyText), findsOneWidget);
    // `.voice-list-empty`：13px + secondary + 居中 + padding sp4
    final Text empty = tester.widget<Text>(
      find.text(AylaVoiceChannelPanel.emptyText),
    );
    expect(empty.style!.fontSize, 13);
    expect(empty.style!.color, AylaColors.textSecondary);
    expect(empty.textAlign, TextAlign.center);
    expect(
      tester
          .widget<Padding>(
            find
                .ancestor(
                  of: find.text(AylaVoiceChannelPanel.emptyText),
                  matching: find.byType(Padding),
                )
                .last,
          )
          .padding,
      const EdgeInsets.all(AylaSpacing.sp4),
    );
  });

  testWidgets('空态：加载中或出错时**不显示**（tsx 122–123）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(700, 620));
    await tester.pumpWidget(
      host(
        const AylaVoiceChannelPanel(
          channelName: '深夜电台',
          page: AylaVoiceMembersPage(loading: true),
        ),
      ),
    );
    expect(find.text(AylaVoiceChannelPanel.emptyText), findsNothing);
  });

  // ======================= 自己置顶兜底 =======================

  testWidgets('自己兜底：store 有自己但列表没有 → 置顶插入（tsx 65–72）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(700, 620));
    await tester.pumpWidget(
      host(
        const AylaVoiceChannelPanel(
          channelName: '深夜电台',
          members: <AylaVoicePanelMember>[elysia, other],
          selfUserId: 'self',
          selfMember: self,
        ),
      ),
    );
    final List<AylaVoiceMemberRow> list = rows(tester);
    expect(list.length, 3);
    expect(list.first.member.userId, 'self'); // 置顶
    expect(list.first.isSelf, isTrue);
  });

  testWidgets('自己兜底：列表里已有自己 → 不重复插入', (WidgetTester tester) async {
    setViewport(tester, const Size(700, 620));
    await tester.pumpWidget(
      host(
        const AylaVoiceChannelPanel(
          channelName: '深夜电台',
          members: <AylaVoicePanelMember>[elysia, self],
          selfUserId: 'self',
          selfMember: self,
        ),
      ),
    );
    expect(rows(tester).length, 2);
    expect(
      rows(tester).where((AylaVoiceMemberRow r) => r.member.userId == 'self').length,
      1,
    );
  });

  // ======================= 成员行透传 =======================

  testWidgets('成员行透传：isSelf / isElysia / 展示投影 / 回调', (WidgetTester tester) async {
    setViewport(tester, const Size(700, 620));
    final List<(String, double)> volumes = <(String, double)>[];
    final List<double> locals = <double>[];
    int mics = 0;
    final List<String> muted = <String>[];
    await tester.pumpWidget(
      host(
        AylaVoiceChannelPanel(
          channelName: '深夜电台',
          members: const <AylaVoicePanelMember>[elysia, other],
          selfUserId: 'self',
          selfMember: self,
          elysiaUserId: 'u2',
          self: const AylaVoiceSelfState(localVolume: 70),
          onVolumeChange: (String id, double v) => volumes.add((id, v)),
          onLocalVolumeChange: locals.add,
          onToggleMic: () => mics++,
          onToggleMemberMuted: muted.add,
        ),
      ),
    );

    final List<AylaVoiceMemberRow> list = rows(tester);
    final AylaVoiceMemberRow elysiaRow =
        list.firstWhere((AylaVoiceMemberRow r) => r.member.userId == 'u2');
    expect(elysiaRow.isElysia, isTrue); // tsx 126
    expect(elysiaRow.isSelf, isFalse);
    expect(elysiaRow.displayName, '爱莉');
    expect(elysiaRow.online, isTrue);
    expect(elysiaRow.onVolumeChange, isNotNull);

    final AylaVoiceMemberRow selfRow =
        list.firstWhere((AylaVoiceMemberRow r) => r.member.userId == 'self');
    expect(selfRow.isSelf, isTrue);
    expect(selfRow.self!.localVolume, 70); // 本地事实透传
    expect(selfRow.onToggleMic, isNotNull);

    // 回调真的通到行里：拖远端音量条
    elysiaRow.onVolumeChange!('u2', 42);
    expect(volumes, <(String, double)>[('u2', 42)]);
    selfRow.onLocalVolumeChange!(55);
    expect(locals, <double>[55]);
    selfRow.onToggleMic!();
    expect(mics, 1);
    list.last.onToggleMemberMuted!('u3');
    expect(muted, <String>['u3']);
  });

  // ======================= 房主操作 =======================

  testWidgets('房主操作：isOwner 且非自己 → 每行下方两个 ghost 按钮',
      (WidgetTester tester) async {
    setViewport(tester, const Size(700, 620));
    await tester.pumpWidget(
      host(
        const AylaVoiceChannelPanel(
          channelName: '深夜电台',
          members: <AylaVoicePanelMember>[elysia, other],
          selfUserId: 'self',
          selfMember: self,
          isOwner: true,
          onMemberAction: _noopAction,
        ),
      ),
    );
    expect(find.text('踢出'), findsNWidgets(2)); // 两个远端成员各一行
    expect(find.text('转让房主'), findsNWidgets(2));
    expect(
      actionButtons(tester, '踢出').first.variant,
      GlassButtonVariant.ghost, // `.btn.btn-ghost`
    );
  });

  testWidgets('房主操作：非房主 / 自己行都不渲染操作行（tsx 139）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(700, 620));
    await tester.pumpWidget(
      host(
        const AylaVoiceChannelPanel(
          channelName: '深夜电台',
          members: <AylaVoicePanelMember>[elysia],
          selfUserId: 'self',
          selfMember: self,
          isOwner: false,
        ),
      ),
    );
    expect(find.text('踢出'), findsNothing);
  });

  testWidgets('房主操作：只有自己时也没有操作行（tsx 139 的 `!== 自己`）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(700, 620));
    await tester.pumpWidget(
      host(
        const AylaVoiceChannelPanel(
          channelName: '深夜电台',
          members: <AylaVoicePanelMember>[self],
          selfUserId: 'self',
          isOwner: true,
          onMemberAction: _noopAction,
        ),
      ),
    );
    expect(find.text('踢出'), findsNothing); // 只有自己 ⇒ 无操作行
  });

  testWidgets('busy：点击后两个按钮一起禁用 + 当前行「处理中…」→ 完成后恢复',
      (WidgetTester tester) async {
    setViewport(tester, const Size(700, 620));
    final Completer<void> gate = Completer<void>();
    final List<(String, AylaVoiceMemberAction)> calls =
        <(String, AylaVoiceMemberAction)>[];
    await tester.pumpWidget(
      host(
        AylaVoiceChannelPanel(
          channelName: '深夜电台',
          members: const <AylaVoicePanelMember>[elysia, other],
          selfUserId: 'self',
          selfMember: self,
          isOwner: true,
          onMemberAction: (String id, AylaVoiceMemberAction a) async {
            calls.add((id, a));
            await gate.future;
          },
        ),
      ),
    );

    await tester.tap(find.text('踢出').first);
    await tester.pump();

    expect(calls, <(String, AylaVoiceMemberAction)>[('u2', AylaVoiceMemberAction.kick)]);
    expect(actionButtons(tester, '处理中…').single.onPressed, isNull); // 当前行文案
    expect(
      actionButtons(tester, '转让房主').every((GlassButton b) => b.onPressed == null),
      isTrue,
      reason: 'busy 期间两个按钮一起禁用',
    );
    // busy 期间重复点击被守卫吃掉（tsx 102）
    await tester.tap(find.text('处理中…'), warnIfMissed: false);
    await tester.pump();
    expect(calls.length, 1);

    gate.complete();
    await settle(tester);
    expect(
      actionButtons(tester, '踢出').every((GlassButton b) => b.onPressed != null),
      isTrue,
    );
    expect(find.text('处理中…'), findsNothing);
  });

  testWidgets('失败静默：onMemberAction 抛错 → busy 复位、无错误 UI（tsx 108–110）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(700, 620));
    await tester.pumpWidget(
      host(
        AylaVoiceChannelPanel(
          channelName: '深夜电台',
          members: const <AylaVoicePanelMember>[elysia],
          selfUserId: 'self',
          isOwner: true,
          onMemberAction: (String id, AylaVoiceMemberAction a) async {
            throw StateError('boom');
          },
        ),
      ),
    );
    await tester.tap(find.text('踢出'));
    await settle(tester);
    expect(find.textContaining('boom'), findsNothing);
    expect(actionButtons(tester, '踢出').first.onPressed, isNotNull); // 已复位
  });

  testWidgets('转让房主：动作类型为 transfer', (WidgetTester tester) async {
    setViewport(tester, const Size(700, 620));
    final List<(String, AylaVoiceMemberAction)> calls =
        <(String, AylaVoiceMemberAction)>[];
    await tester.pumpWidget(
      host(
        AylaVoiceChannelPanel(
          channelName: '深夜电台',
          members: const <AylaVoicePanelMember>[other],
          selfUserId: 'self',
          isOwner: true,
          onMemberAction: (String id, AylaVoiceMemberAction a) async =>
              calls.add((id, a)),
        ),
      ),
    );
    await tester.tap(find.text('转让房主'));
    await settle(tester);
    expect(calls, <(String, AylaVoiceMemberAction)>[('u3', AylaVoiceMemberAction.transfer)]);
  });

  // ======================= 分页 / 控制条 / 滚动档 =======================

  testWidgets('分页：五字段透传 + retainCompletedSpace=false（tsx 149）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(700, 1200));
    int loads = 0;
    await tester.pumpWidget(
      host(
        AylaVoiceChannelPanel(
          channelName: '深夜电台',
          members: const <AylaVoicePanelMember>[elysia],
          page: AylaVoiceMembersPage(
            hasMore: true,
            invalidated: true,
            loadMore: () async => loads++,
            refresh: () async {},
          ),
        ),
      ),
    );
    final AylaDirectoryLoadMore more = tester.widget<AylaDirectoryLoadMore>(
      find.byType(AylaDirectoryLoadMore),
    );
    expect(more.hasMore, isTrue);
    expect(more.invalidated, isTrue);
    expect(more.loading, isFalse);
    expect(more.error, isNull);
    expect(more.retainCompletedSpace, isFalse);
    await more.loadMore();
    expect(loads, 1);
  });

  testWidgets('控制条：showRejoin / onLeave / onRejoin 透传', (WidgetTester tester) async {
    setViewport(tester, const Size(700, 620));
    int leaves = 0;
    int rejoins = 0;
    await tester.pumpWidget(
      host(
        AylaVoiceChannelPanel(
          channelName: '深夜电台',
          members: const <AylaVoicePanelMember>[elysia],
          showRejoin: true,
          onLeave: () => leaves++,
          onRejoin: () => rejoins++,
        ),
      ),
    );
    expect(find.text('离开频道'), findsOneWidget);
    expect(find.text('重新加入'), findsOneWidget); // livekit=failed
    await tester.tap(find.text('离开频道'));
    await tester.tap(find.text('重新加入'));
    await tester.pump();
    expect(leaves, 1);
    expect(rejoins, 1);
  });

  testWidgets('房间上下文档：roomContext=true 时成员列表自己滚动（voice.css 43–48）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(700, 400));
    await tester.pumpWidget(
      hostBounded(
        const AylaVoiceChannelPanel(
          channelName: '深夜电台',
          members: <AylaVoicePanelMember>[elysia, other, self],
          roomContext: true,
          ownMaterial: false,
        ),
        viewport: const Size(700, 400),
      ),
    );
    // 房间上下文：成员列表在滚动视图内；控制条留在列表**之外**（始终可达）
    expect(find.byType(SingleChildScrollView), findsWidgets);
    final Finder scroller = find
        .ancestor(
          of: find.byType(AylaVoiceMemberRow).first,
          matching: find.byType(SingleChildScrollView),
        )
        .first;
    expect(scroller, findsOneWidget);
    expect(
      tester.getRect(find.text('离开频道')).top,
      greaterThan(tester.getRect(scroller).bottom - 1),
    );
  });

  testWidgets('人数：count 为 null 时不渲染人数', (WidgetTester tester) async {
    setViewport(tester, const Size(700, 620));
    await tester.pumpWidget(
      host(
        const AylaVoiceChannelPanel(
          channelName: '深夜电台',
          members: <AylaVoicePanelMember>[elysia],
        ),
      ),
    );
    expect(find.textContaining(' 人'), findsNothing);
    expect(panelOf(tester).count, isNull);
  });
}

/// 空实现的成员操作（只是让按钮可点）。
Future<void> _noopAction(String userId, AylaVoiceMemberAction action) async {}
