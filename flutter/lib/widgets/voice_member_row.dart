/// voice 域第二批（B1-2）：单个语音成员行（含覆盖式音量条）。
///
/// ## 事实源（逐条对应 web，禁自由发挥）
/// ```
/// VoiceMemberRow.tsx 1–219    行 = 头像 32 + (名称+/我) + 副行(在频道中/已静音) +
///                             操作区(开关钮 + 音量条)；私有 VoiceVolumeMeter 40–90
/// VoiceMemberRow.tsx 56–63    电平映射：levelPct = round(min(1, level^0.4) × 100)
/// VoiceMemberRow.tsx 134–135  说话阈值：level > 0.02
/// VoiceMemberRow.tsx 133      名称兜底：nickname || username || user_id.slice(0, 6)
/// VoiceMemberRow.tsx 171–215  自己 = 麦克风开关 + 本地麦音量；远端 = 喇叭开关 + 播放音量
///                             （locallyMuted 时跳动条归零、speaking=false）
/// app.css 2917–2921           .voice-member-row：flex · align-center · gap sp2 = 8
/// app.css 2923–2936           .voice-member-main（flex 1 / column / min-width 0）
///                             .voice-member-topline（flex / gap sp2 / min-width 0）
/// app.css 2939–2944           .voice-member-actions：flex:none · inline-flex · center · gap 8
/// app.css 2946–2954           .voice-member-name：flex 1 · 13px · w600 · nowrap + ellipsis
/// app.css 2956–2960           .voice-self-tag：margin-left sp1 = 4 · 11px · --indigo-700
/// app.css 2962–2968           .voice-member-sub：11px · --text-secondary · gap 3
/// app.css 2970–2975           .voice-muted-tag：gap 3 · --destructive（IconMic 11 + 已静音）
/// app.css 2981–3005           .voice-meter-toggle：28×28 正圆 · 透明底 · --indigo-700 ·
///                             hover rgba(189,212,233,.35) · .is-off → --text-secondary +
///                             rgba(189,212,233,.25)；图标 15×15（tsx 180/192）
/// auroraqua.css 59/77/89/664  .voice-meter-toggle 属按钮组 ⇒ transition 200ms
///                             --auroraqua-ease + hover 1.02 + active .98（reduced-motion 取消缩放）
/// app.css 3007–3013           .voice-meter：90 × 20 · relative
/// app.css 3015–3032           .voice-meter-track：绝对居中 · 100%×4 · pill ·
///                             linear-gradient(90deg, --indigo-700 0→--fill,
///                             rgba(189,212,233,.55) --fill→100%) · 不吃指针
/// app.css 3034–3046           .voice-meter-fill：绝对居中 · 宽 levelPct% · 4 · pill ·
///                             linear-gradient(90deg, --glow-500, --ice-500) · width 80ms --ease-out
/// app.css 3048–3051           .is-speaking → fill 加 0 0 6px rgba(247,150,255,.55)
/// app.css 3053–3095           slider：绝对 inset 0 · 轨道透明 4px pill ·
///                             把手 14×14 圆 · --indigo-700 · 2px #fff 边 ·
///                             margin-top -5px · 0 1px 4px rgba(70,91,146,.35)
/// ```
///
/// ## 与 web 的装配差异（组件不写页面）
/// web 自取 `useVoiceStore`（`localAudioLevel` / `localVolume` / `micEnabled`）、
/// `usePresenceStore`（在线光环）、`api/users`（昵称/头像懒拉缓存）与 `goUserProfile`。
/// Flutter 侧按既有「展示型 + 注入」模式：
/// - 自己那一行的本地媒体事实由 [AylaVoiceMemberRow.self] 注入（对应 web 的三个 store 读）；
/// - 在线/爱莉判定（[AylaVoiceMemberRow.online] / [AylaVoiceMemberRow.isElysia]）由页面层
///   从 presence 计算（web 的 `presenceOnline(withLiveStatus(...))`，隐身用户强制离线）；
/// - 昵称/头像由页面层从用户缓存给出（[AylaVoiceMemberRow.displayName] /
///   [AylaVoiceMemberRow.avatarUrl]）；**最后一级兜底**（`user_id` 前 6 位）留在行内，
///   与 web tsx 133 一致；
/// - 头像点击 → [AylaVoiceMemberRow.onOpenProfile]（web `goUserProfile`）。
///
/// ## 未完成项（登记，交用户裁决）
/// 开关钮的 `title`（浏览器原生 tooltip）属全库 `Tooltip` 统一项
/// （`13-工作进度与待办.md` §4.2：一次补齐、别只给单个组件加）→ 本件不加。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../theme/app_icons.dart';
import '../theme/app_theme.dart';
import '../theme/buttons.dart';
import '../theme/preview_theme.dart';
import '../theme/tokens.dart';
import 'avatar_halo.dart';

/// 语音成员投影 —— web `stores/voice.ts:20–32` `VoiceMemberState` 中本组件消费的字段。
///
/// 未收录：`joined_at` / `last_seen_at`（不参与渲染）。默认值与 web
/// `VoiceChannelPanel.tsx:62` 的初始行一致（`muted: false, volume: 100,
/// locallyMuted: false, audioLevel: 0`）。
class AylaVoiceMember {
  const AylaVoiceMember({
    required this.userId,
    this.muted = false,
    this.volume = 100,
    this.locallyMuted = false,
    this.audioLevel = 0,
  });

  final String userId;

  /// 应用层静音标记（`voice.state muted`；媒体事实以承载层为准）。
  final bool muted;

  /// 本地播放音量 0~100（本地偏好，不落库）。
  final double volume;

  /// 本地播放静音（喇叭按钮：我听不到该成员；**不改变** [volume] 设定值）。
  final bool locallyMuted;

  /// 远端实时说话音量 0~1（未说话为 0）。
  final double audioLevel;
}

/// 自己那一行的本地媒体事实 —— web 从 `useVoiceStore` 直接读的三个字段。
class AylaVoiceSelfState {
  const AylaVoiceSelfState({
    this.micEnabled = true,
    this.localVolume = 100,
    this.localAudioLevel = 0,
  });

  /// 自己的麦克风是否开启（媒体层事实，麦克风按钮状态）。
  final bool micEnabled;

  /// 自己的麦克风音量设定 0~100（100 = 原始）。
  final double localVolume;

  /// 自己的麦克风实时音量 0~1（未开麦为 0）。
  final double localAudioLevel;
}

/// `.voice-member-row` —— 单个语音成员行（`VoiceMemberRow.tsx:141–218`）。
class AylaVoiceMemberRow extends StatelessWidget {
  const AylaVoiceMemberRow({
    super.key,
    required this.member,
    this.isSelf = false,
    this.isElysia = false,
    this.self,
    this.displayName,
    this.avatarUrl,
    this.online = false,
    this.onVolumeChange,
    this.onLocalVolumeChange,
    this.onToggleMic,
    this.onToggleMemberMuted,
    this.onOpenProfile,
  });

  final AylaVoiceMember member;

  /// 自己那一行（决定用麦克风按钮还是喇叭按钮、读哪一套音量）。
  final bool isSelf;

  /// 爱莉条目（只影响头像光环，tsx 103–104）。
  final bool isElysia;

  /// [isSelf] 为 true 时的本地媒体事实（web 的 `useVoiceStore` 三个读）。
  final AylaVoiceSelfState? self;

  /// 昵称（页面层从用户缓存给出）；null → 回落 `user_id` 前 6 位（tsx 133）。
  final String? displayName;

  /// 头像图 URL（null = 文字首字）。
  final String? avatarUrl;

  /// 在线光环（页面层从 presence 计算；隐身用户强制离线）。
  final bool online;

  /// 远端成员播放音量变化（web `onVolumeChange(userId, volume)`）。
  final void Function(String userId, double volume)? onVolumeChange;

  /// 自己的麦克风音量变化（web `onLocalVolumeChange(volume)`）。
  final ValueChanged<double>? onLocalVolumeChange;

  /// 自己：一键禁音 / 一键恢复（媒体层 toggleMic）。
  final VoidCallback? onToggleMic;

  /// 远端成员：一键静音 / 一键恢复（本地播放 locallyMuted）。
  final ValueChanged<String>? onToggleMemberMuted;

  /// 点头像 → 个人主页（web `goUserProfile`）。
  final VoidCallback? onOpenProfile;

  /// tsx 133 的最后一级兜底：`user_id.slice(0, 6)`。
  String get resolvedName =>
      displayName ?? member.userId.substring(0, math.min(6, member.userId.length));

  /// tsx 134–135：`level > 0.02` 判为说话。
  static const double speakingThreshold = 0.02;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final AylaVoiceSelfState selfState =
        self ?? const AylaVoiceSelfState();
    final bool micEnabled = selfState.micEnabled;
    final double localVolume = selfState.localVolume;
    final double localAudioLevel = selfState.localAudioLevel;

    final double level = isSelf
        ? localAudioLevel
        : (member.locallyMuted ? 0 : member.audioLevel); // tsx 210
    final bool speaking =
        isSelf ? localAudioLevel > speakingThreshold : (!member.locallyMuted && member.audioLevel > speakingThreshold);
    final double volume = isSelf ? localVolume : member.volume;
    final String name = resolvedName;

    final Widget sub = member.muted
        ? Row(
            // `.voice-muted-tag { gap: 3px; color: --destructive }`
            mainAxisSize: MainAxisSize.min,
            spacing: 3,
            children: <Widget>[
              AylaIcon(
                aylaIconByName('iconMic')!,
                size: 11, // tsx 162：`<IconMic width={11} height={11} />`
                color: AylaColors.destructive,
              ),
              // `.voice-muted-tag { color: --destructive }` 挂在 wrapper 上 ⇒ 图标与文字
              // 都取 destructive（图标用 currentColor）
              Text(
                '已静音',
                style: _subStyle.copyWith(color: AylaColors.destructive),
              ),
            ],
          )
        : Text('在频道中', style: _subStyle);

    return Row(
      // `.voice-member-row { display: flex; align-items: center; gap: var(--sp-2) }`
      spacing: AylaSpacing.sp2,
      children: <Widget>[
        AvatarHalo(
          label: name,
          size: 32, // tsx 145：`size={32}`
          online: online,
          core: isElysia ? AvatarCore.elysia : AvatarCore.user,
          resourceUrl: avatarUrl,
          onTap: onOpenProfile,
          semanticLabel: '查看 $name 的个人主页', // tsx 150 aria-label
        ),
        Expanded(
          // `.voice-member-main { flex: 1; flex-direction: column; min-width: 0 }`
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              // `.voice-member-topline`
              Row(
                spacing: AylaSpacing.sp2,
                children: <Widget>[
                  Expanded(
                    // `.voice-member-name { flex:1; min-width:0; 13px/600; nowrap+ellipsis }`
                    // 自己那行的「我」在 web 里是**名字 span 内部**的子元素（tsx 154–157）
                    // ⇒ 用 WidgetSpan 让它参与同一条省略号行（`margin-left: sp1` = 4）。
                    child: Text.rich(
                      TextSpan(
                        text: name,
                        children: <InlineSpan>[
                          if (isSelf)
                            WidgetSpan(
                              alignment: PlaceholderAlignment.baseline,
                              baseline: TextBaseline.alphabetic,
                              child: Padding(
                                padding: const EdgeInsets.only(
                                  left: AylaSpacing.sp1,
                                ),
                                child: Text('我', style: _selfTagStyle),
                              ),
                            ),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.body.copyWith(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              // `.voice-member-sub`
              sub,
            ],
          ),
        ),
        // `.voice-member-actions`：flex:none ⇒ 不参与收缩
        Row(
          mainAxisSize: MainAxisSize.min,
          spacing: AylaSpacing.sp2,
          children: <Widget>[
            _MeterToggle(
              off: isSelf ? !micEnabled : member.locallyMuted,
              icon: isSelf
                  ? (micEnabled ? 'iconMic' : 'iconMicOff')
                  : (member.locallyMuted ? 'iconSpeakerOff' : 'iconSpeaker'),
              semanticLabel: isSelf
                  ? (micEnabled ? '一键禁音' : '一键恢复') // tsx 177
                  : '$name ${member.locallyMuted ? '恢复声音' : '静音'}', // tsx 188
              // aria-pressed **逐行不同**：自己行 = micEnabled（tsx 176）
              // 远端行 = locallyMuted（tsx 187）——两处语义不同，别合并成一个 bool
              pressed: isSelf ? micEnabled : member.locallyMuted,
              onPressed: isSelf
                  ? onToggleMic
                  : () => onToggleMemberMuted?.call(member.userId),
            ),
            _VoiceVolumeMeter(
              volume: volume,
              level: level,
              speaking: speaking,
              ariaLabel: isSelf ? '我的麦克风音量' : '$name 的音量', // tsx 203 / 212
              onVolumeChange: isSelf
                  ? (double v) => onLocalVolumeChange?.call(v)
                  : (double v) => onVolumeChange?.call(member.userId, v),
            ),
          ],
        ),
      ],
    );
  }

  /// `.voice-self-tag`：11px · `--indigo-700`。
  static const TextStyle _selfTagStyle = TextStyle(
    fontFamily: AylaFonts.body,
    fontFamilyFallback: AylaFonts.cjkFallback,
    fontSize: 11,
    color: AylaColors.indigo700,
  );

  /// `.voice-member-sub` / `.voice-muted-tag`：11px（后者用 `--destructive`，见调用处）。
  static const TextStyle _subStyle = TextStyle(
    fontFamily: AylaFonts.body,
    fontFamilyFallback: AylaFonts.cjkFallback,
    fontSize: 11,
    color: AylaColors.textSecondary,
  );
}

/// `.voice-meter-toggle` —— 行尾开关钮（自己 = 麦克风；远端 = 喇叭）。
///
/// 在 auroraqua 按钮组内 ⇒ 200ms `--auroraqua-ease` + hover 1.02 + active .98
/// （`auroraqua.css:59/77/89`；reduced-motion 段 `:664` 取消缩放）。
class _MeterToggle extends StatefulWidget {
  const _MeterToggle({
    required this.off,
    required this.icon,
    required this.semanticLabel,
    required this.pressed,
    this.onPressed,
  });

  /// `.is-off`（禁音 / 已本地静音）。
  final bool off;

  /// `kAylaIcons` 里的图标名。
  final String icon;

  final String semanticLabel;

  /// `aria-pressed`。
  final bool pressed;

  final VoidCallback? onPressed;

  @override
  State<_MeterToggle> createState() => _MeterToggleState();
}

class _MeterToggleState extends State<_MeterToggle> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    // `.voice-meter-toggle:hover { background: rgba(189,212,233,.35) }`
    // `.is-off { color: --text-secondary; background: rgba(189,212,233,.25) }`
    final Color background = widget.off
        ? _offBg
        : (_hovered ? _hoverBg : Colors.transparent);
    final Color foreground =
        widget.off ? AylaColors.textSecondary : AylaColors.indigo700;

    // `aria-pressed` 与 aria-label 必须落在**同一个**语义节点上（web 是同一个 button）
    // ⇒ 用 MergeSemantics 合并，而不是叠两层 Semantics。
    return MergeSemantics(
      child: Semantics(
        toggled: widget.pressed, // aria-pressed
        child: AylaPressScale(
        // 按钮组档：hover 1.02 + active .98（200ms，由 AylaPressScale 提供）
        onTap: widget.onPressed,
        semanticLabel: widget.semanticLabel,
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: AnimatedContainer(
            // auroraqua 按钮组：全组 200ms `--auroraqua-ease`
            //（覆盖 app.css:2992–2993 的 `background/color 120ms --ease-out`）
            duration: AylaDurations.button,
            curve: AylaCurves.auroraqua,
            width: 28, // `.voice-meter-toggle { width/height: 28px }`
            height: 28,
            decoration: BoxDecoration(
              color: background,
              shape: BoxShape.circle, // border-radius: 50%
            ),
            child: Center(
              child: AylaIcon(
                aylaIconByName(widget.icon)!,
                size: 15, // tsx 180/192：`width={15} height={15}`
                color: foreground,
              ),
            ),
          ),
        ),
        ),
      ),
    );
  }

  /// `rgba(189,212,233,.35)` / `rgba(189,212,233,.25)`（= ice-300 的两个透明度档）。
  static final Color _hoverBg = AylaColors.ice300.withValues(alpha: 0.35);
  static final Color _offBg = AylaColors.ice300.withValues(alpha: 0.25);
}

/// 覆盖式音量条（`VoiceMemberRow.tsx:40–90`，web 里是**文件内私有**函数 ⇒ 这里同样私有）。
///
/// 三层（下 → 上）：轨道（双色）→ 跳动条（覆盖其上）→ slider（透明轨道 + 圆把手）。
class _VoiceVolumeMeter extends StatelessWidget {
  const _VoiceVolumeMeter({
    required this.volume,
    required this.level,
    required this.speaking,
    required this.ariaLabel,
    required this.onVolumeChange,
  });

  /// 设定音量 0~100（滑块位置 + 轨道左侧填充宽度）。
  final double volume;

  /// 实时说话音量 0~1（跳动条宽度）。
  final double level;

  final bool speaking;
  final String ariaLabel;
  final ValueChanged<double> onVolumeChange;

  /// `.voice-meter { width: 90px; height: 20px }`。
  static const double width = 90;
  static const double height = 20;

  /// 轨道/跳动条高度。
  ///
  /// ⚠️ **用户 2026-09-21 实机校准：4 → 5**（偏离 web 的 `height: 4px`，勿改回）。
  /// 原因：web 的端帽用的是 `border-radius: var(--radius-pill)`，浏览器会把它夹到
  /// `条高 / 2` —— 4px 条上 **R = 2 已是上限（半圆）**，再写大也不会更圆。
  /// 用户要求「加大 R 角」⇒ 唯一可行做法是把条加厚：5px ⇒ R = 2.5。
  static const double barHeight = 5;

  /// 端帽半径 = 条高 / 2（显式写出来，不依赖 `999` 被夹的隐式行为；
  /// 语义与 web 的 `--radius-pill` 在被夹之后完全一致）。
  static final BorderRadius capRadius =
      BorderRadius.all(Radius.circular(barHeight / 2));

  /// tsx 56–59：显示映射指数 0.4（放大低音量敏感度）。
  static const double displayExp = 0.4;

  /// tsx 60–62：`levelPct = round(min(1, clamp(level)^0.4) × 100)`。
  static int levelPercent(double level) {
    final double clamped = level.clamp(0.0, 1.0);
    return (math.min(1, math.pow(clamped, displayExp)) * 100).round();
  }

  /// tsx 63：`volumePct = round(clamp(volume, 0, 100))`。
  static int volumePercent(double volume) => volume.clamp(0, 100).round();

  @override
  Widget build(BuildContext context) {
    final double fill = volumePercent(volume) / 100;
    final double levelFraction = levelPercent(level) / 100;

    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        children: <Widget>[
          // ---- 底层轨道：双色填充（滑块左边 indigo = 设定音量，右边 ice 浅色）----
          Positioned(
            left: 0,
            right: 0,
            top: (height - barHeight) / 2,
            child: IgnorePointer(
              child: SizedBox(
                height: barHeight,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: capRadius,
                    gradient: LinearGradient(
                      // linear-gradient(90deg, indigo-700 0→fill, ice-300@.55 fill→100)
                      colors: <Color>[
                        AylaColors.indigo700,
                        AylaColors.indigo700,
                        AylaColors.ice300.withValues(alpha: 0.55),
                        AylaColors.ice300.withValues(alpha: 0.55),
                      ],
                      stops: <double>[0, fill, fill, 1],
                    ),
                  ),
                ),
              ),
            ),
          ),
          // ---- 中层跳动条：覆盖在轨道上方，宽度随实时音量伸缩 ----
          Positioned(
            left: 0,
            top: (height - barHeight) / 2,
            child: IgnorePointer(
              child: AnimatedContainer(
                // `transition: width 80ms ease-out`（app.css:3045）
                duration: const Duration(milliseconds: 80),
                curve: AylaCurves.easeOut,
                width: width * levelFraction,
                height: barHeight,
                decoration: BoxDecoration(
                  borderRadius: capRadius,
                  // linear-gradient(90deg, --glow-500, --ice-500)
                  gradient: const LinearGradient(
                    colors: <Color>[AylaColors.glow500, AylaColors.ice500],
                  ),
                  // `.is-speaking` → `box-shadow: 0 0 6px rgba(247,150,255,.55)`
                  // （填充是不透明渐变 ⇒ 裸 BoxShadow 与「只画形状之外」等价，
                  //  阴影被自身不透明面盖住，不需要 AylaGlassShadow.ring）
                  boxShadow: speaking
                      ? const <BoxShadow>[
                          BoxShadow(
                            color: Color(0x8CF796FF), // rgba(247,150,255,.55)
                            blurRadius: 6,
                          ),
                        ]
                      : null,
                ),
              ),
            ),
          ),
          // ---- 上层 slider：轨道透明（不遮跳动条）+ 可见圆把手 ----
          Positioned.fill(
            child: MergeSemantics(
              child: Semantics(
                label: ariaLabel, // aria-label（tsx 85 / 203 / 212）
                child: SliderTheme(
              data: SliderThemeData(
                trackHeight: barHeight, // 4px
                // `::-webkit-slider-runnable-track { background: transparent }`
                activeTrackColor: Colors.transparent,
                inactiveTrackColor: Colors.transparent,
                disabledActiveTrackColor: Colors.transparent,
                disabledInactiveTrackColor: Colors.transparent,
                tickMarkShape: SliderTickMarkShape.noTickMark,
                // 原生 range 没有 hover 光晕
                overlayShape: SliderComponentShape.noOverlay,
                thumbShape: const _MeterThumbShape(),
              ),
              child: Slider(
                value: volume.clamp(0, 100).toDouble(),
                min: 0,
                max: 100,
                // ⚠️ **不要传 `divisions`**（用户 2026-09-21 实报「拖动时后面的音量条有延迟」）：
                //    `divisions != null` ⇒ `isDiscrete` ⇒ Slider 用
                //    `positionController.animateTo(convertedValue, curve: easeInOut)`
                //    动画拇指位置（`slider.dart:1292–1300`，时长
                //    `_positionAnimationDuration = 75ms`）⇒ 拇指**追不上指针**；
                //    而轨道是即时重建的 ⇒ 看起来「条子跟手、滑块拖沓/错位」。
                //    web 的 `input[type=range]` 是跟手即时；`step=1` 的整数语义改在
                //    `onChanged` 里取整表达。
                label: null,
                onChanged: (double v) => onVolumeChange(v.roundToDouble()),
              ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 音量条圆把手（`app.css:3077–3095`）：
/// 14×14 圆 · `--indigo-700` 底 · **2px `#fff` 边** · `0 1px 4px rgba(70,91,146,.35)`。
///
/// 为什么自绘：Flutter 的 `RoundSliderThumbShape` 只能给纯色圆，画不出这圈 2px 白边
/// （用户 2026-09-21 拍板：用 `Slider` + 自绘 thumb，保住原生拖动/键盘/无障碍语义）。
class _MeterThumbShape extends SliderComponentShape {
  const _MeterThumbShape();

  /// `.voice-meter-slider::-webkit-slider-thumb { width/height: 14px }`。
  static const double diameter = 14;
  static const double borderWidth = 2;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) =>
      const Size(diameter, diameter);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final Canvas canvas = context.canvas;
    const double r = diameter / 2; // 7
    // 把手阴影：`0 1px 4px rgba(70,91,146,.35)`（offset 0/1、blur 4）
    canvas.drawCircle(
      center + const Offset(0, 1),
      r,
      Paint()
        ..color = const Color(0x59465B92)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
    // 2px 白边 → 内层 indigo 实心（web 的 border 由内缩后的底色呈现）
    canvas.drawCircle(center, r, Paint()..color = AylaColors.surface);
    canvas.drawCircle(
      center,
      r - borderWidth,
      Paint()..color = AylaColors.indigo700,
    );
  }
}

// ======================= 预览 =======================

/// 语音成员行样张（画布与 @Preview 共用；**可交互**）。
///
/// - 自己那行：麦克风开关（点一下切 is-off + `--text-secondary`）+ 本地麦音量条；
/// - 远端三行：喇叭开关（切 locallyMuted：跳动条归零、speaking 辉光消失、aria 变「恢复声音」）、
///   `muted` 行显示「已静音」（`--destructive` + IconMic 11）、爱莉条目走 `AvatarCore.elysia` 光环；
/// - 拖动任意滑块改设定音量（轨道左侧 indigo 宽度跟着变）；
/// - 「模拟说话电平」滑块驱动 `audioLevel` → 看跳动条按 `level^0.4` 放大 + 说话辉光。
Widget aylaVoiceMemberSamples() => const _VoiceMemberDemo();

class _VoiceMemberDemo extends StatefulWidget {
  const _VoiceMemberDemo();

  @override
  State<_VoiceMemberDemo> createState() => _VoiceMemberDemoState();
}

class _VoiceMemberDemoState extends State<_VoiceMemberDemo> {
  double _level = 0.15;
  double _localVolume = 80;
  bool _micEnabled = true;

  final Map<String, double> _remoteVolumes = <String, double>{
    'u2': 100,
    'u3': 60,
  };
  final Set<String> _locallyMuted = <String>{'u3'};

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AylaSpacing.sp6,
      runSpacing: AylaSpacing.sp6,
      crossAxisAlignment: WrapCrossAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 460,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            spacing: AylaSpacing.sp4,
            children: <Widget>[
              const Text('成员行（宽 460）', style: TextStyle(fontSize: 12)),
              // 自己那行
              AylaVoiceMemberRow(
                member: const AylaVoiceMember(userId: 'self-1'),
                isSelf: true,
                displayName: '汐汐',
                online: true,
                self: AylaVoiceSelfState(
                  micEnabled: _micEnabled,
                  localVolume: _localVolume,
                  localAudioLevel: _level,
                ),
                onToggleMic: () => setState(() => _micEnabled = !_micEnabled),
                onLocalVolumeChange: (double v) =>
                    setState(() => _localVolume = v),
              ),
              // 远端：常规
              AylaVoiceMemberRow(
                member: AylaVoiceMember(
                  userId: 'u2',
                  volume: _remoteVolumes['u2']!,
                  audioLevel: _level * 0.6,
                ),
                displayName: '爱莉',
                isElysia: true,
                online: true,
                onVolumeChange: (String id, double v) =>
                    setState(() => _remoteVolumes[id] = v),
                onToggleMemberMuted: (String id) => setState(() {
                  _locallyMuted.contains(id)
                      ? _locallyMuted.remove(id)
                      : _locallyMuted.add(id);
                }),
              ),
              // 远端：本地已静音（跳动条归零 + 辉光消失 + 喇叭划斜线）
              AylaVoiceMemberRow(
                member: AylaVoiceMember(
                  userId: 'u3',
                  volume: _remoteVolumes['u3']!,
                  audioLevel: _level,
                  locallyMuted: _locallyMuted.contains('u3'),
                ),
                displayName: '小满',
                online: true,
                onVolumeChange: (String id, double v) =>
                    setState(() => _remoteVolumes[id] = v),
                onToggleMemberMuted: (String id) => setState(() {
                  _locallyMuted.contains(id)
                      ? _locallyMuted.remove(id)
                      : _locallyMuted.add(id);
                }),
              ),
              // 远端：应用层已静音（副行「已静音」）
              const AylaVoiceMemberRow(
                member: AylaVoiceMember(
                  userId: 'u4',
                  muted: true,
                  volume: 100,
                  audioLevel: 0,
                ),
                displayName: '很久以前的一个很长的成员昵称会被省略号截断',
                online: false,
              ),
              // 远端：无昵称（回落 user_id 前 6 位）
              const AylaVoiceMemberRow(
                member: AylaVoiceMember(userId: 'abcdef123456'),
              ),
            ],
          ),
        ),
        SizedBox(
          width: 300,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            spacing: AylaSpacing.sp3,
            children: <Widget>[
              const Text('模拟驱动（拖动看跳动条 / 辉光）', style: TextStyle(fontSize: 12)),
              Text('说话电平 = ${_level.toStringAsFixed(2)} '
                  '→ 跳动条 ${_VoiceVolumeMeter.levelPercent(_level)}%'
                  '（level^0.4 映射，阈值 ${AylaVoiceMemberRow.speakingThreshold}）',
                  style: const TextStyle(fontSize: 11)),
              Slider(
                value: _level,
                onChanged: (double v) => setState(() => _level = v),
              ),
              Text('自己麦克风音量 = ${_localVolume.round()}',
                  style: const TextStyle(fontSize: 11)),
              const Text(
                '映射对照：0.02→21% · 0.2→53% · 0.5→76% · 1.0→100%',
                style: TextStyle(fontSize: 11),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 语音成员行（自己 / 远端 / 已静音 / 爱莉 / 无昵称）—— 可交互。
@Preview(
  group: 'Widgets',
  name: '语音成员行（含覆盖式音量条）',
  size: Size(900, 460),
  wrapper: previewTheme,
)
Widget aylaVoiceMemberPreview() => aylaVoiceMemberSamples();
