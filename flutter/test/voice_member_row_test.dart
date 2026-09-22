/// B1-2：语音成员行（含覆盖式音量条）定向测试 —— 逐条对照
/// `VoiceMemberRow.tsx`(219) 与 `app.css:2917–3095`、`auroraqua.css:59/77/89/664`。
///
/// 覆盖：结构 / 尺寸 / 三层音量条的几何与配色 / `level^0.4` 映射 / 说话阈值与辉光 /
/// 远端本地静音归零 / 应用层静音副行 / 自己行麦克风开关与本地音量 / 名称兜底 /
/// 「我」标签 / 头像 32 与光环 / 回调目标（自己 vs 远端）/ 语义（aria-pressed、aria-label）/
/// 滑块行为与 step。
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/app_icons.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/avatar_halo.dart';
import '../lib/widgets/voice_member_row.dart';

const Key _rowKey = Key('voice-member-row-probe');

void main() {
  Widget host(Widget child, {Size viewport = const Size(700, 500)}) {
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

  void setViewport(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Finder meterBox() => find.byWidgetPredicate(
        (Widget w) => w is SizedBox && w.width == 90 && w.height == 20,
      );

  /// ⚠️ `AnimatedContainer` **没有** width/height getter：构造参数被折进 `constraints`
  /// （与 A5 同一坑，`13-*` §6.21）。统一从这里取尺寸。
  double boxWidth(AnimatedContainer w) => w.constraints!.maxWidth;
  double boxHeight(AnimatedContainer w) => w.constraints!.maxHeight;

  /// 跳动条（唯一的 4px 高 `AnimatedContainer`）。
  AnimatedContainer fill(WidgetTester tester) =>
      tester.widget<AnimatedContainer>(
        find.byWidgetPredicate(
          (Widget w) => w is AnimatedContainer && w.constraints?.maxHeight == 5,
        ),
      );

  /// 轨道：唯一「4 个 stops 的线性渐变」（跳动条是 2 个色标；
  /// 注意 `AnimatedContainer` 内部也会渲染一层 `DecoratedBox`，只按类型取会 "Too many elements"）。
  DecoratedBox track(WidgetTester tester) => tester.widget<DecoratedBox>(
        find.byWidgetPredicate(
          (Widget w) =>
              w is DecoratedBox &&
              w.decoration is BoxDecoration &&
              (w.decoration as BoxDecoration).gradient is LinearGradient &&
              ((w.decoration as BoxDecoration).gradient! as LinearGradient)
                      .stops
                      ?.length ==
                  4,
        ),
      );

  Finder toggleBox() => find.byWidgetPredicate(
        (Widget w) =>
            w is AnimatedContainer &&
            w.constraints?.maxWidth == 28 &&
            w.constraints?.maxHeight == 28,
      );

  Color toggleBg(WidgetTester tester) =>
      (tester.widget<AnimatedContainer>(toggleBox()).decoration!
          as BoxDecoration)
          .color!;

  /// 抓 RepaintBoundary 的像素（渲染类断言必须验像素，不能只看布局矩形）。
  Future<(ByteData, int, Offset)> capture(WidgetTester tester) async {
    final RenderRepaintBoundary boundary =
        tester.renderObject<RenderRepaintBoundary>(find.byKey(_rowKey));
    late ByteData data;
    late int width;
    await tester.runAsync(() async {
      final ui.Image image = await boundary.toImage(pixelRatio: 1);
      width = image.width;
      data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    });
    return (data, width, tester.getRect(find.byKey(_rowKey)).topLeft);
  }

  /// 真实语义树里的全部节点（标签 + toggled 标志）。
  Map<String, bool?> semanticsNodes(WidgetTester tester) {
    // ignore: deprecated_member_use
    final SemanticsOwner? owner = tester.binding.pipelineOwner.semanticsOwner;
    final Map<String, bool?> out = <String, bool?>{};
    void walk(SemanticsNode node) {
      if (node.label.isNotEmpty) {
        out[node.label] = node.flagsCollection.isToggled.toBoolOrNull();
      }
      node.visitChildren((SemanticsNode child) {
        walk(child);
        return true;
      });
    }

    final SemanticsNode? root = owner?.rootSemanticsNode;
    if (root != null) walk(root);
    return out;
  }

  // ======================= 结构与尺寸 =======================

  testWidgets('行结构：头像 32 → 名称(+我) → 副行 → 操作区(开关 + 音量条)',
      (WidgetTester tester) async {
    setViewport(tester, const Size(700, 500));
    await tester.pumpWidget(
      host(
        const AylaVoiceMemberRow(
          member: AylaVoiceMember(userId: 'u2'),
          displayName: '爱莉',
          online: true,
        ),
      ),
    );

    expect(find.byType(AvatarHalo), findsOneWidget);
    expect(find.text('爱莉'), findsOneWidget);
    expect(find.text('在频道中'), findsOneWidget); // 未静音 → 副行文案
    expect(meterBox(), findsOneWidget);
    expect(toggleBox(), findsOneWidget);
    // 操作区在行尾：开关与音量条都在名称右侧
    expect(tester.getRect(toggleBox()).left, greaterThan(tester.getRect(find.text('爱莉')).right));
  });

  testWidgets('尺寸：音条 90×20、轨道/跳动条 5px（校准值）、开关钮 28 正圆、图标 15',
      (WidgetTester tester) async {
    setViewport(tester, const Size(700, 500));
    await tester.pumpWidget(
      host(
        const AylaVoiceMemberRow(
          member: AylaVoiceMember(userId: 'u2'),
          displayName: '爱莉',
        ),
      ),
    );
    expect(tester.getSize(meterBox()), const Size(90, 20));
    expect(tester.getSize(toggleBox()), const Size(28, 28));
    expect(
      (tester.widget<AnimatedContainer>(toggleBox()).decoration!
          as BoxDecoration)
          .shape,
      BoxShape.circle, // border-radius: 50%
    );
    // 条高 5 / 端帽 R=2.5：用户 2026-09-21 实机校准（web 原值 4，见 13 号 §6.3）
    expect(boxHeight(fill(tester)), 5);
    final AylaIcon toggleIcon = tester.widget<AylaIcon>(
      find.descendant(of: toggleBox(), matching: find.byType(AylaIcon)),
    );
    expect(toggleIcon.size, 15); // tsx 180/192
  });

  testWidgets('头像：size 32 + 在线/爱莉光环 + aria-label + 点击回调',
      (WidgetTester tester) async {
    setViewport(tester, const Size(700, 500));
    int opened = 0;
    await tester.pumpWidget(
      host(
        AylaVoiceMemberRow(
          member: const AylaVoiceMember(userId: 'u2'),
          displayName: '爱莉',
          isElysia: true,
          online: true,
          onOpenProfile: () => opened++,
        ),
      ),
    );
    final AvatarHalo halo = tester.widget<AvatarHalo>(find.byType(AvatarHalo));
    expect(halo.size, 32);
    expect(halo.online, isTrue);
    expect(halo.core, AvatarCore.elysia); // tsx 147：爱莉条目光环
    expect(halo.semanticLabel, '查看 爱莉 的个人主页'); // tsx 150
    await tester.tap(find.byType(AvatarHalo));
    await tester.pump();
    expect(opened, 1);
  });

  // ======================= 名称 / 副行 / 我标签 =======================

  testWidgets('名称：13px / w600 / 单行省略；无昵称回落 user_id 前 6 位（tsx 133）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(700, 500));
    await tester.pumpWidget(
      host(
        const AylaVoiceMemberRow(
          member: AylaVoiceMember(userId: 'abcdef123456'),
        ),
      ),
    );
    expect(find.text('abcdef'), findsOneWidget); // slice(0, 6)
    final Text name = tester.widget<Text>(find.text('abcdef'));
    expect(name.maxLines, 1);
    expect(name.overflow, TextOverflow.ellipsis);
    expect(name.style!.fontSize, 13);
    expect(name.style!.fontWeight, FontWeight.w600);
  });

  testWidgets('「我」标签：仅自己行出现，11px / --indigo-700（app.css 2956–2960）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(700, 500));
    await tester.pumpWidget(
      host(
        const AylaVoiceMemberRow(
          member: AylaVoiceMember(userId: 'self'),
          displayName: '汐汐',
          isSelf: true,
        ),
      ),
    );
    final Text tag = tester.widget<Text>(find.text('我'));
    expect(tag.style!.fontSize, 11);
    expect(tag.style!.color, AylaColors.indigo700);
    // 「我」在名称的 `Text.rich` 里（web：`<span class="voice-member-name">` 内的子 span）
    final Text name = tester.widget<Text>(find.byWidgetPredicate(
      (Widget w) => w is Text && w.textSpan != null,
    ));
    expect(name.maxLines, 1);
    expect(name.overflow, TextOverflow.ellipsis);
  });

  testWidgets('副行：未静音「在频道中」11px secondary；静音「已静音」+ IconMic 11 + destructive',
      (WidgetTester tester) async {
    setViewport(tester, const Size(700, 500));
    bool muted = false;
    late StateSetter setter;
    await tester.pumpWidget(
      host(
        StatefulBuilder(
          builder: (BuildContext context, StateSetter s) {
            setter = s;
            return AylaVoiceMemberRow(
              member: AylaVoiceMember(userId: 'u2', muted: muted),
              displayName: '爱莉',
            );
          },
        ),
      ),
    );
    final Text sub = tester.widget<Text>(find.text('在频道中'));
    expect(sub.style!.fontSize, 11);
    expect(sub.style!.color, AylaColors.textSecondary);

    setter(() => muted = true);
    await tester.pump();
    expect(find.text('在频道中'), findsNothing);
    final Text mutedTag = tester.widget<Text>(find.text('已静音'));
    expect(mutedTag.style!.fontSize, 11);
    expect(mutedTag.style!.color, AylaColors.destructive);
    final AylaIcon mic = tester.widget<AylaIcon>(
      find.byWidgetPredicate(
        (Widget w) => w is AylaIcon && w.icon.name == 'iconMic',
      ),
    );
    expect(mic.size, 11); // tsx 162
    expect(mic.color, AylaColors.destructive);
  });

  // ======================= 电平映射（tsx 56–63） =======================

  /// 独立复算 tsx 60–62（**不调用实现**，避免拿实现当基准）。
  int expectLevelPct(double level) {
    final double clamped = level.clamp(0.0, 1.0);
    return (math.min(1, math.pow(clamped, 0.4)) * 100).round();
  }

  test('电平映射：level^0.4 ×100 取整（tsx 56–62）', () {
    expect(AylaVoiceMemberRow.speakingThreshold, 0.02);
    expect(expectLevelPct(0.02), 21);
    expect(expectLevelPct(0.2), 53);
    expect(expectLevelPct(0.5), 76);
    expect(expectLevelPct(1), 100);
    expect(expectLevelPct(0), 0);
    expect(expectLevelPct(-1), 0); // clamp 下界
    expect(expectLevelPct(3), 100); // clamp 上界
    // 音量取整与夹取（tsx 63）
    expect(79.6.clamp(0, 100).round(), 80);
    expect((-5).clamp(0, 100).round(), 0);
    expect(120.clamp(0, 100).round(), 100);
  });

  testWidgets('跳动条宽度端到端：level 0.2 → 47.7px、0.5 → 68.4px（90 × pct/100）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(700, 500));
    double level = 0.2;
    late StateSetter setter;
    await tester.pumpWidget(
      host(
        StatefulBuilder(
          builder: (BuildContext context, StateSetter s) {
            setter = s;
            return AylaVoiceMemberRow(
              member: AylaVoiceMember(userId: 'u2', audioLevel: level),
              displayName: '爱莉',
            );
          },
        ),
      ),
    );
    expect(
      boxWidth(fill(tester)),
      closeTo(90 * expectLevelPct(0.2) / 100, 0.01),
    );

    setter(() => level = 0.5);
    await tester.pump();
    expect(
      boxWidth(fill(tester)),
      closeTo(90 * expectLevelPct(0.5) / 100, 0.01),
    );
  });

  testWidgets('跳动条宽度 = 90 × levelPct/100；渐变 glow-500 → ice-500；80ms --ease-out',
      (WidgetTester tester) async {
    setViewport(tester, const Size(700, 500));
    await tester.pumpWidget(
      host(
        const AylaVoiceMemberRow(
          member: AylaVoiceMember(userId: 'u2', audioLevel: 0.2),
          displayName: '爱莉',
        ),
      ),
    );
    final AnimatedContainer f = fill(tester);
    expect(boxWidth(f), closeTo(90 * 0.53, 0.01)); // levelPct(0.2) = 53
    expect(f.duration, const Duration(milliseconds: 80)); // app.css 3045
    expect(f.curve, AylaCurves.easeOut);
    final LinearGradient g =
        (f.decoration! as BoxDecoration).gradient! as LinearGradient;
    expect(g.colors, <Color>[AylaColors.glow500, AylaColors.ice500]);
  });

  testWidgets('轨道：双色 stops = [0, fill, fill, 1]，左 indigo-700 / 右 ice-300@.55（app.css 3015–3032）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(700, 500));
    await tester.pumpWidget(
      host(
        const AylaVoiceMemberRow(
          member: AylaVoiceMember(userId: 'u2', volume: 40, audioLevel: 0),
          displayName: '爱莉',
        ),
      ),
    );
    final LinearGradient g =
        (track(tester).decoration as BoxDecoration).gradient! as LinearGradient;
    expect(g.stops, <double>[0, 0.4, 0.4, 1]); // --fill = 40%
    expect(g.colors.first, AylaColors.indigo700);
    expect(g.colors.last, AylaColors.ice300.withValues(alpha: 0.55));
  });

  testWidgets('说话辉光：level > 0.02 才给跳动条 0 0 6px rgba(247,150,255,.55)（app.css 3048–3051）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(700, 500));
    double level = 0.02;
    late StateSetter setter;
    await tester.pumpWidget(
      host(
        StatefulBuilder(
          builder: (BuildContext context, StateSetter s) {
            setter = s;
            return AylaVoiceMemberRow(
              member: AylaVoiceMember(userId: 'u2', audioLevel: level),
              displayName: '爱莉',
            );
          },
        ),
      ),
    );
    expect((fill(tester).decoration! as BoxDecoration).boxShadow, isNull);

    setter(() => level = 0.021);
    await tester.pump();
    final List<BoxShadow> shadow =
        (fill(tester).decoration! as BoxDecoration).boxShadow!;
    expect(shadow.single.blurRadius, 6);
    expect(shadow.single.color, const Color(0x8CF796FF));
  });

  testWidgets('远端 locallyMuted：跳动条归零 + 辉光消失（tsx 209–211）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(700, 500));
    await tester.pumpWidget(
      host(
        const AylaVoiceMemberRow(
          member: AylaVoiceMember(
            userId: 'u2',
            locallyMuted: true,
            audioLevel: 0.8,
          ),
          displayName: '爱莉',
        ),
      ),
    );
    expect(boxWidth(fill(tester)), 0);
    expect((fill(tester).decoration! as BoxDecoration).boxShadow, isNull);
  });

  // ======================= 开关钮（自己 / 远端） =======================

  testWidgets('自己行：麦克风开 → iconMic / 「一键禁音」/ pressed=true / 透明底',
      (WidgetTester tester) async {
    setViewport(tester, const Size(700, 500));
    await tester.pumpWidget(
      host(
        const AylaVoiceMemberRow(
          member: AylaVoiceMember(userId: 'self'),
          isSelf: true,
          displayName: '汐汐',
          self: AylaVoiceSelfState(micEnabled: true),
        ),
      ),
    );
    final AylaIcon icon = tester.widget<AylaIcon>(
      find.descendant(of: toggleBox(), matching: find.byType(AylaIcon)),
    );
    expect(icon.icon.name, 'iconMic');
    expect(icon.color, AylaColors.indigo700);
    expect(toggleBg(tester), Colors.transparent);
  });

  testWidgets('自己行：麦克风关 → iconMicOff / 「一键恢复」/ is-off 灰底 + text-secondary',
      (WidgetTester tester) async {
    setViewport(tester, const Size(700, 500));
    await tester.pumpWidget(
      host(
        const AylaVoiceMemberRow(
          member: AylaVoiceMember(userId: 'self'),
          isSelf: true,
          displayName: '汐汐',
          self: AylaVoiceSelfState(micEnabled: false),
        ),
      ),
    );
    final AylaIcon icon = tester.widget<AylaIcon>(
      find.descendant(of: toggleBox(), matching: find.byType(AylaIcon)),
    );
    expect(icon.icon.name, 'iconMicOff');
    expect(icon.color, AylaColors.textSecondary); // `.is-off { color: --text-secondary }`
    expect(toggleBg(tester), AylaColors.ice300.withValues(alpha: 0.25));
  });

  testWidgets('远端行：喇叭图标 / 「X 静音」；locallyMuted → iconSpeakerOff +「X 恢复声音」',
      (WidgetTester tester) async {
    setViewport(tester, const Size(700, 500));
    bool locallyMuted = false;
    late StateSetter setter;
    await tester.pumpWidget(
      host(
        StatefulBuilder(
          builder: (BuildContext context, StateSetter s) {
            setter = s;
            return AylaVoiceMemberRow(
              member: AylaVoiceMember(userId: 'u2', locallyMuted: locallyMuted),
              displayName: '爱莉',
            );
          },
        ),
      ),
    );
    expect(
      tester
          .widget<AylaIcon>(
            find.descendant(of: toggleBox(), matching: find.byType(AylaIcon)),
          )
          .icon
          .name,
      'iconSpeaker',
    );

    setter(() => locallyMuted = true);
    await tester.pump();
    expect(
      tester
          .widget<AylaIcon>(
            find.descendant(of: toggleBox(), matching: find.byType(AylaIcon)),
          )
          .icon
          .name,
      'iconSpeakerOff',
    );
  });

  testWidgets('开关 hover：底色 rgba(189,212,233,.35)（app.css 2996–2999）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(700, 500));
    await tester.pumpWidget(
      host(
        const AylaVoiceMemberRow(
          member: AylaVoiceMember(userId: 'u2'),
          displayName: '爱莉',
        ),
      ),
    );
    expect(toggleBg(tester), Colors.transparent);

    final TestGesture mouse =
        await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(toggleBox()));
    await tester.pump();

    expect(toggleBg(tester), AylaColors.ice300.withValues(alpha: 0.35));
  });

  testWidgets('开关点击回调：自己 → onToggleMic；远端 → onToggleMemberMuted(userId)',
      (WidgetTester tester) async {
    setViewport(tester, const Size(700, 500));
    int mic = 0;
    final List<String> muted = <String>[];
    bool self = true;
    late StateSetter setter;

    await tester.pumpWidget(
      host(
        StatefulBuilder(
          builder: (BuildContext context, StateSetter s) {
            setter = s;
            return self
                ? AylaVoiceMemberRow(
                    member: const AylaVoiceMember(userId: 'self'),
                    isSelf: true,
                    displayName: '汐汐',
                    onToggleMic: () => mic++,
                  )
                : AylaVoiceMemberRow(
                    member: const AylaVoiceMember(userId: 'u2'),
                    displayName: '爱莉',
                    onToggleMemberMuted: muted.add,
                  );
          },
        ),
      ),
    );
    await tester.tap(toggleBox());
    await tester.pump();
    expect(mic, 1);

    setter(() => self = false);
    await tester.pump();
    await tester.tap(toggleBox());
    await tester.pump();
    expect(muted, <String>['u2']);
  });

  // ======================= 音量条滑块 =======================

  testWidgets('滑块：value=设定音量、0~100、step=1（divisions 100）、轨道透明',
      (WidgetTester tester) async {
    setViewport(tester, const Size(700, 500));
    await tester.pumpWidget(
      host(
        const AylaVoiceMemberRow(
          member: AylaVoiceMember(userId: 'u2', volume: 40),
          displayName: '爱莉',
        ),
      ),
    );
    final Slider slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.value, 40);
    expect(slider.min, 0);
    expect(slider.max, 100);
    // ⚠️ 必须为 null（不传 `divisions`）：传了会让 Slider 用
    // `animateTo(easeInOut, 75ms)` 动画拇指（slider.dart:1292–1300）⇒ 拖动不跟手
    expect(slider.divisions, isNull);
    // step=1 的整数语义改由 onChanged 取整表达（web 原生 range 的默认 step）
    expect(slider.min, 0);
    expect(slider.max, 100);

    final SliderTheme theme = tester.widget<SliderTheme>(
      find.ancestor(of: find.byType(Slider), matching: find.byType(SliderTheme)),
    );
    expect(theme.data.activeTrackColor, Colors.transparent);
    expect(theme.data.inactiveTrackColor, Colors.transparent);
    expect(theme.data.trackHeight, 5); // 校准值（web 4，见 13 号 §6.3）
    expect(theme.data.overlayShape, SliderComponentShape.noOverlay);
    // 把手 14×14（app.css 3077–3095）
    expect(
      theme.data.thumbShape!.getPreferredSize(true, true),
      const Size(14, 14),
    );
  });

  testWidgets('滑块回调目标：自己 → onLocalVolumeChange；远端 → onVolumeChange(userId)',
      (WidgetTester tester) async {
    setViewport(tester, const Size(700, 500));
    final List<double> local = <double>[];
    final List<(String, double)> remote = <(String, double)>[];
    bool self = true;
    late StateSetter setter;

    await tester.pumpWidget(
      host(
        StatefulBuilder(
          builder: (BuildContext context, StateSetter s) {
            setter = s;
            return self
                ? AylaVoiceMemberRow(
                    member: const AylaVoiceMember(userId: 'self'),
                    isSelf: true,
                    displayName: '汐汐',
                    onLocalVolumeChange: local.add,
                  )
                : AylaVoiceMemberRow(
                    member: const AylaVoiceMember(userId: 'u2'),
                    displayName: '爱莉',
                    onVolumeChange: (String id, double v) => remote.add((id, v)),
                  );
          },
        ),
      ),
    );
    tester.widget<Slider>(find.byType(Slider)).onChanged!(75);
    await tester.pump();
    expect(local, <double>[75]);
    expect(remote, isEmpty);

    setter(() => self = false);
    await tester.pump();
    tester.widget<Slider>(find.byType(Slider)).onChanged!(30);
    await tester.pump();
    expect(remote, <(String, double)>[('u2', 30)]);
  });

  testWidgets('滑块拖动真的改值（原生拖动语义由 Slider 提供）', (WidgetTester tester) async {
    setViewport(tester, const Size(700, 500));
    final List<double> values = <double>[];
    await tester.pumpWidget(
      host(
        AylaVoiceMemberRow(
          member: const AylaVoiceMember(userId: 'u2', volume: 0),
          displayName: '爱莉',
          onVolumeChange: (String id, double v) => values.add(v),
        ),
      ),
    );
    await tester.drag(find.byType(Slider), const Offset(30, 0));
    await tester.pump();
    expect(values, isNotEmpty);
    expect(values.last, greaterThan(0)); // 向右拖 → 变大
  });

  testWidgets('拖动跟手：一帧内拇指环到达目标位置（像素级；divisions=null 才有此性质）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(700, 500));
    double volume = 0;
    late StateSetter setter;
    await tester.pumpWidget(
      host(
        RepaintBoundary(
          key: _rowKey,
          child: StatefulBuilder(
            builder: (BuildContext context, StateSetter s) {
              setter = s;
              return AylaVoiceMemberRow(
                member: AylaVoiceMember(userId: 'u2', volume: volume),
                displayName: '爱莉',
                onVolumeChange: (String id, double v) {
                  setter(() => volume = v);
                },
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();

    final Rect m = tester.getRect(meterBox());
    final TestGesture gesture =
        await tester.startGesture(tester.getCenter(find.byType(Slider)));
    await gesture.moveBy(const Offset(35, 0));
    await tester.pump(); // **只推进一帧**

    final double value = tester.widget<Slider>(find.byType(Slider)).value;
    final (ByteData data, int w, Offset origin) = await capture(tester);
    final int scanY = (m.top + 10 - origin.dy).round();
    // 拇指的白色外环是唯一近白元素 ⇒ 取其质心即拇指中心
    double sum = 0;
    int n = 0;
    for (int dx = 0; dx < 90; dx++) {
      final int i = (scanY * w + (m.left + dx - origin.dx).round()) * 4;
      if (data.getUint8(i) > 235 &&
          data.getUint8(i + 1) > 235 &&
          data.getUint8(i + 2) > 235) {
        sum += dx;
        n++;
      }
    }
    expect(n, greaterThan(0), reason: '没扫到拇指白环 ⇒ 像素口径失效');
    final double measured = sum / n;
    final double expected = 7 + (value / 100) * (90 - 14); // thumb/2 + 比例 × (轨道- thumb)
    expect(
      (measured - expected).abs(),
      lessThan(2.0),
      reason: '一帧内拇指应跟手（measured=$measured expected=$expected）',
    );
    await gesture.up();
  });

  testWidgets('端帽是半圆（R = 条高/2）：左端覆盖率轮廓对称且中心行最高',
      (WidgetTester tester) async {
    setViewport(tester, const Size(700, 500));
    await tester.pumpWidget(
      host(
        RepaintBoundary(
          key: _rowKey,
          child: const AylaVoiceMemberRow(
            member: AylaVoiceMember(userId: 'u2', volume: 100),
            displayName: '爱莉',
          ),
        ),
      ),
    );
    await tester.pump();

    final Rect m = tester.getRect(meterBox());
    final (ByteData data, int w, Offset origin) = await capture(tester);
    // 条垂直居中：y = m.top+7 .. m.top+12（条高 5）
    final List<int> alphas = <int>[
      for (int dy = 7; dy <= 12; dy++)
        data.getUint8(
          (((m.top + dy - origin.dy).round()) * w +
                  (m.left + 0 - origin.dx).round()) *
              4 +
              3,
        ),
    ];
    // 圆帽的判据：最左列上/下缘行**覆盖率明显低于内侧行**（方角端会四行相等）；
    // 条本身落在半像素上 ⇒ 不做严格对称断言（那会因亚像素偏移而脆）。
    expect(alphas[0], lessThan(alphas[1]), reason: '上缘行应比内侧行窄（圆帽）');
    expect(alphas[5], lessThan(alphas[4]), reason: '下缘行应比内侧行窄（圆帽）');
    expect(alphas[2], greaterThan(200), reason: '中心行应几乎铺满');
    expect(alphas[0], lessThan(alphas[2]));
    expect(alphas[5], lessThan(alphas[2]));
  });

  // ======================= 语义（aria-pressed / aria-label） =======================

  testWidgets('语义：开关 = 同一节点上的 label + toggled；滑块节点带 aria-label',
      (WidgetTester tester) async {
    setViewport(tester, const Size(700, 500));
    await tester.pumpWidget(
      host(
        const AylaVoiceMemberRow(
          member: AylaVoiceMember(userId: 'u2'),
          displayName: '爱莉',
        ),
      ),
    );
    final SemanticsHandle handle = tester.ensureSemantics();
    await tester.pump();

    final Map<String, bool?> nodes = semanticsNodes(tester);
    expect(nodes, isNotEmpty, reason: '语义树观测口径失效');
    expect(nodes['爱莉 静音'], isFalse, reason: '远端 aria-pressed = locallyMuted（tsx 187）');
    expect(nodes.containsKey('爱莉 的音量'), isTrue); // slider 的 aria-label

    handle.dispose();
  });

  testWidgets('语义：自己行 micEnabled 决定「一键禁音 / 一键恢复」与 pressed',
      (WidgetTester tester) async {
    setViewport(tester, const Size(700, 500));
    await tester.pumpWidget(
      host(
        const AylaVoiceMemberRow(
          member: AylaVoiceMember(userId: 'self'),
          isSelf: true,
          displayName: '汐汐',
          self: AylaVoiceSelfState(micEnabled: false),
        ),
      ),
    );
    final SemanticsHandle handle = tester.ensureSemantics();
    await tester.pump();
    final Map<String, bool?> nodes = semanticsNodes(tester);
    expect(nodes['一键恢复'], isFalse);
    // ⚠️ 用 `containsKey` 判断存在：map 的值是 **toggled 标志**
    // （滑块不是 toggle 节点 ⇒ 值为 null，用 `isNotNull` 会误判成「不存在」）
    expect(nodes.containsKey('我的麦克风音量'), isTrue);
    handle.dispose();
  });
}
