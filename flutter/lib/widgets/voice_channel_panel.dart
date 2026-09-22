/// voice 域第四批（B1-4）：当前频道面板（成员列表 + 控制条）。
///
/// ## 事实源（逐条对应 web，禁自由发挥）
/// ```
/// VoiceChannelPanel.tsx 115–157  section.voice-panel = head(标题+人数) +
///                                .voice-member-list(成员行 + 房主操作 + 分页) + VoiceControls
/// VoiceChannelPanel.tsx 65–72    自己兜底：store 有自己但分页列表没有 ⇒ 置顶插入
/// VoiceChannelPanel.tsx 139–144  房主且非自己 ⇒ 行下插 .voice-owner-member-actions
///                                （两个 `.btn.btn-ghost`：「踢出」/「转让房主」）
/// VoiceChannelPanel.tsx 101–113  成员操作：busy 期间两个按钮都 disabled、
///                                当前行文案「处理中…」、失败**静默**
/// VoiceChannelPanel.tsx 119      人数：当前频道 → store 成员数；否则 → 分页 total
/// VoiceChannelPanel.tsx 149      DirectoryLoadMore（invalidated / refresh /
///                                retainCompletedSpace={false}）
/// app.css 2873–2886              .voice-panel：flex column · gap sp3 = 12 ·
///                                max-width 560 · padding sp4 = 16 · radius 16 ·
///                                --glass-bg · 1px --glass-border · blur(24) sat(1.4) ·
///                                --glass-shadow
/// app.css 2888–2892              .voice-panel-head：flex · **align-items: baseline** ·
///                                justify-content: space-between
/// app.css 2894–2897 + base.css 316  .voice-panel-title：16px（`h3` 的 `font-weight: bold`
///                                未被重置 ⇒ **700**；base.css 只重置 margin/padding）
/// app.css 2899–2902              .voice-panel-count：12px · --text-secondary
/// app.css 2904–2908              .voice-member-list：flex column · gap sp2 = 8
/// app.css 2910–2915              .voice-list-empty：padding sp4 · 13px · secondary · 居中
/// voice.css 32–56                `.voice-room-body .voice-panel { flex:1; min-height:0;
///                                margin:0; width:100%; max-width:none }`；
///                                成员列表 `flex:1; min-height:0; overflow-y:auto`；
///                                其余子项 `flex-shrink:0`
/// voice.css 377–381              窄屏 `.voice-room-voice-card .voice-panel`：100% 宽 + 保留自身材质
/// auroraqua.css 584–610          窄屏：外层 `.voice-room-voice-card` 透明（材质归面板）；
///                                宽屏：`.voice-room-voice-card > .voice-panel` 透明
///                                （材质归外层卡）⇒ 材质归属**按断点切换**
/// ```
///
/// ## 与 web 的装配差异（组件不写页面）
/// web 面板自拉分页（`usePagedMediaList`）、自订阅 `voiceWS` 帧（`joined`/`left` ⇒ 失效 +
/// 移除行）、自己调 `actionVoiceMember`，并从 auth/presence/用户缓存取展示信息。
/// Flutter 侧按既有「展示型 + 注入」模式：
/// - 成员事实 + 展示投影（昵称/头像/在线）由页面层装进 [AylaVoicePanelMember]；
/// - 分页状态装进 [AylaVoiceMembersPage]（逐字段对应 [AylaDirectoryLoadMore]）；
/// - `voiceWS` 的失效信号由页面层转成 [AylaVoiceMembersPage.invalidated]；
/// - 成员操作（踢出/转让房主）走注入的 [AylaVoiceChannelPanel.onMemberAction]，
///   成功后的刷新由页面层在该回调内完成（web 是回调后 `refresh()`）；
/// - **面板内只保留两条纯列表规则**：自己置顶兜底（tsx 65–72）、房主操作行的 busy 管理
///   （tsx 101–113，含失败静默）。
///
/// ## 两处等价说明（web 无声明值，已在测试里锁住）
/// 1. `.voice-owner-member-actions` 在 CSS 里**没有任何规则**，两个按钮的 4px 间距来自
///    JSX 换行产生的空白 ⇒ Flutter 侧用 `Row(spacing: 4)` 等价表达；
/// 2. `.voice-member-list` 在房间上下文里是**滚动容器**（`flex:1; overflow-y:auto`）⇒
///    由 [AylaVoiceChannelPanel.scrollMembers] 档表达（`Expanded` + 可滚动列表）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../theme/app_theme.dart';
import '../theme/glass.dart';
import '../theme/preview_theme.dart';
import '../theme/tokens.dart';
import 'directory_controls.dart';
import 'voice_channels.dart';
import 'voice_member_row.dart';

/// 房主对成员的操作（web `actionVoiceMember(channelId, userId, action)`）。
enum AylaVoiceMemberAction {
  /// `"kick"` —— 踢出。
  kick,

  /// `"transfer"` —— 转让房主。
  transfer,
}

/// 面板的一行 = 媒体/音量事实（[AylaVoiceMember]）+ 展示投影。
///
/// web 的 `VoiceMemberRow` 自己从 store/用户缓存读昵称、头像、在线与爱莉判定；
/// Flutter 侧这些由页面层装好注入（缺失就是缺失，不给默认值）。
class AylaVoicePanelMember {
  const AylaVoicePanelMember({
    required this.member,
    this.displayName,
    this.avatarUrl,
    this.online = false,
  });

  /// 媒体与音量事实（含 `userId`）。
  final AylaVoiceMember member;

  /// 昵称（null → 行内回落 `user_id` 前 6 位）。
  final String? displayName;

  /// 头像图 URL。
  final String? avatarUrl;

  /// 在线光环（页面层从 presence 计算，隐身强制离线）。
  final bool online;
}

/// 成员分页状态（web `usePagedMediaList` 投影，逐字段对应 [AylaDirectoryLoadMore]）。
class AylaVoiceMembersPage {
  const AylaVoiceMembersPage({
    this.loading = false,
    this.error,
    this.hasMore = false,
    this.invalidated = false,
    this.loadMore,
    this.refresh,
  });

  final bool loading;

  /// 错误文案（非 null 时 [AylaDirectoryLoadMore] 不渲染）。
  final String? error;

  final bool hasMore;

  /// 加载过程中数据被更新（`voiceWS` 的 joined/left 帧 ⇒ 页面层置位）。
  final bool invalidated;

  final Future<void> Function()? loadMore;
  final Future<void> Function()? refresh;
}

/// `.voice-panel` —— 当前频道面板（`VoiceChannelPanel.tsx:115–157`）。
class AylaVoiceChannelPanel extends StatefulWidget {
  const AylaVoiceChannelPanel({
    super.key,
    required this.channelName,
    this.members = const <AylaVoicePanelMember>[],
    this.selfUserId,
    this.selfMember,
    this.elysiaUserId,
    this.count,
    this.isOwner = false,
    this.self,
    this.page = const AylaVoiceMembersPage(),
    this.ownMaterial = true,
    this.roomContext = false,
    this.showRejoin = false,
    this.onToggleMic,
    this.onLocalVolumeChange,
    this.onVolumeChange,
    this.onToggleMemberMuted,
    this.onLeave,
    this.onRejoin,
    this.onMemberAction,
  });

  /// 频道名（head 左侧）。
  final String channelName;

  /// 已装配的成员列表（不含自己兜底 —— 那一步在面板内做，与 tsx 65–72 一致）。
  final List<AylaVoicePanelMember> members;

  /// 自己的 user id（判定 `isSelf`）。
  final String? selfUserId;

  /// store 对账里的自己（tsx 69：`members[selfId]`）；列表里没有自己时置顶插入。
  final AylaVoicePanelMember? selfMember;

  /// 爱莉的 user id（判定 `isElysia`，只影响头像光环）。
  final String? elysiaUserId;

  /// head 右侧人数。
  ///
  /// web（tsx 119）：**当前频道** → `Object.keys(members).length`（store 成员数）；
  /// 否则 → 分页 `total`。两条取值都由页面层决定后注入（面板不重复该判断）。
  final int? count;

  /// 是否房主（决定是否渲染成员操作行，tsx 139）。
  final bool isOwner;

  /// 自己那一行的本地媒体事实（透传给 [AylaVoiceMemberRow.self]）。
  final AylaVoiceSelfState? self;

  /// 成员分页状态。
  final AylaVoiceMembersPage page;

  /// **材质归属档**：true = 面板自带玻璃材质（默认，含窄屏房间）；
  /// false = 透明（宽屏 `.voice-room-voice-card > .voice-panel` 把材质交给外层卡，
  /// `auroraqua.css:594–606`）。
  final bool ownMaterial;

  /// **房间上下文档**（`.voice-room-body .voice-panel`，`voice.css:32–38 / 43–48`）：
  /// true ⇒ `width: 100%` + **`max-width: none`**（覆盖 app.css 的 560）、
  /// 成员列表 `flex:1; min-height:0` **自己滚动**、其余子项不收缩；
  /// false ⇒ 保留 app.css 的 `max-width: 560px` 与自然高度（面板独立使用/测试档）。
  final bool roomContext;

  /// 媒体断线（`livekit === "failed"`）⇒ 控制条显示「重新加入」。
  final bool showRejoin;

  final VoidCallback? onToggleMic;
  final ValueChanged<double>? onLocalVolumeChange;
  final void Function(String userId, double volume)? onVolumeChange;
  final ValueChanged<String>? onToggleMemberMuted;
  final VoidCallback? onLeave;
  final VoidCallback? onRejoin;

  /// 房主操作（页面层调 API + 成功刷新）；抛异常 = 失败（面板静默，tsx 108–110）。
  final Future<void> Function(String userId, AylaVoiceMemberAction action)?
      onMemberAction;

  /// `.voice-list-empty` 文案（tsx 123）。
  static const String emptyText = '当前还没有成员';

  /// `.voice-owner-member-actions` 两个按钮的间距（web 无 CSS，来自 JSX 空白 ≈4px）。
  static const double ownerActionGap = 4;

  @override
  State<AylaVoiceChannelPanel> createState() => _AylaVoiceChannelPanelState();
}

class _AylaVoiceChannelPanelState extends State<AylaVoiceChannelPanel> {
  /// tsx 79：busy 中的成员 id（两个按钮一起 disabled）。
  String? _busyUserId;

  Future<void> _memberAction(String userId, AylaVoiceMemberAction action) async {
    final Future<void> Function(String, AylaVoiceMemberAction)? run =
        widget.onMemberAction;
    if (run == null || _busyUserId != null) return; // tsx 102
    setState(() => _busyUserId = userId);
    try {
      await run(userId, action);
    } catch (_) {
      // tsx 108–110：成员操作失败静默
    } finally {
      if (mounted) setState(() => _busyUserId = null);
    }
  }

  /// tsx 65–72：store 有自己、分页列表没有 ⇒ 置顶。
  List<AylaVoicePanelMember> get _rows {
    final AylaVoicePanelMember? selfMember = widget.selfMember;
    final String? selfId = widget.selfUserId;
    final List<AylaVoicePanelMember> list = widget.members;
    final bool selfInList =
        list.any((AylaVoicePanelMember m) => m.member.userId == selfId);
    if (selfMember != null && selfId != null && !selfInList) {
      return <AylaVoicePanelMember>[selfMember, ...list];
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final List<AylaVoicePanelMember> rows = _rows;

    final Widget list = Column(
      // `.voice-member-list { flex-direction: column; gap: var(--sp-2) }`
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: widget.roomContext ? MainAxisSize.max : MainAxisSize.min,
      spacing: AylaSpacing.sp2,
      children: <Widget>[
        if (rows.isEmpty)
          // tsx 122–123：仅当**不在加载中、也没有错误**时才显示空态
          if (!widget.page.loading && widget.page.error == null)
            Padding(
              padding: const EdgeInsets.all(AylaSpacing.sp4),
              child: Text(
                AylaVoiceChannelPanel.emptyText,
                textAlign: TextAlign.center,
                style: t.body.copyWith(
                  fontSize: 13,
                  color: AylaColors.textSecondary,
                ),
              ),
            ),
        for (final AylaVoicePanelMember m in rows) ...<Widget>[
          AylaVoiceMemberRow(
            member: m.member,
            isSelf: m.member.userId == widget.selfUserId,
            isElysia: widget.elysiaUserId != null &&
                m.member.userId == widget.elysiaUserId,
            self: widget.self,
            displayName: m.displayName,
            avatarUrl: m.avatarUrl,
            online: m.online,
            onVolumeChange: widget.onVolumeChange,
            onLocalVolumeChange: widget.onLocalVolumeChange,
            onToggleMic: widget.onToggleMic,
            onToggleMemberMuted: widget.onToggleMemberMuted,
          ),
          // tsx 139：房主且**不是自己**才有操作行
          if (widget.isOwner && m.member.userId != widget.selfUserId)
            Row(
              // `.voice-owner-member-actions` 无 CSS ⇒ 间距来自 JSX 空白（≈4px）
              spacing: AylaVoiceChannelPanel.ownerActionGap,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                GlassButton(
                  label: _busyUserId == m.member.userId ? '处理中…' : '踢出',
                  variant: GlassButtonVariant.ghost,
                  // tsx 141–142：busy 期间**两个按钮一起** disabled（= onPressed null）
                  onPressed: _busyUserId != null
                      ? null
                      : () => unawaited(_memberAction(
                            m.member.userId,
                            AylaVoiceMemberAction.kick,
                          )),
                ),
                GlassButton(
                  label: '转让房主',
                  variant: GlassButtonVariant.ghost,
                  onPressed: _busyUserId != null
                      ? null
                      : () => unawaited(_memberAction(
                            m.member.userId,
                            AylaVoiceMemberAction.transfer,
                          )),
                ),
              ],
            ),
        ],
        // tsx 149：`<DirectoryLoadMore {...pages} retainCompletedSpace={false} />`
        // —— 错误态由该组件自己渲染（web 同），这里不做条件过滤
        AylaDirectoryLoadMore(
            loading: widget.page.loading,
            error: widget.page.error,
            hasMore: widget.page.hasMore,
            invalidated: widget.page.invalidated,
            loadMore: widget.page.loadMore ?? () async {},
            refresh: widget.page.refresh ?? () async {},
          retainCompletedSpace: false,
        ),
      ],
    );

    final Widget body = Column(
      // `.voice-panel { flex-direction: column; gap: var(--sp-3) }`
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: widget.roomContext ? MainAxisSize.max : MainAxisSize.min,
      spacing: AylaSpacing.sp3,
      children: <Widget>[
        // `.voice-panel-head { display:flex; align-items: baseline; justify-content: space-between }`
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: <Widget>[
            Expanded(
              child: Text(
                widget.channelName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                // `.voice-panel-title { font-size: 16px }` + `h3` 默认 700（base.css 未重置字重）
                style: t.body.copyWith(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AylaColors.textPrimary,
                ),
              ),
            ),
            if (widget.count != null)
              Text(
                '${widget.count} 人',
                // `.voice-panel-count { font-size: 12px; color: var(--text-secondary) }`
                style: t.body.copyWith(
                  fontSize: 12,
                  color: AylaColors.textSecondary,
                ),
              ),
          ],
        ),
        if (widget.roomContext)
          Expanded(
            // `voice.css:43–48`：房间上下文里成员列表自己滚动，其余子项不收缩
            child: SingleChildScrollView(child: list),
          )
        else
          list,
        AylaVoiceControls(
          showRejoin: widget.showRejoin,
          onLeave: widget.onLeave,
          onRejoin: widget.onRejoin,
        ),
      ],
    );

    // `.voice-panel` 的盒模型 + 材质；`ownMaterial: false` 时材质交给外层卡（宽屏房间）
    final Widget panel = widget.ownMaterial
        ? GlassSurface(
            // radius 16 + --glass-bg + 1px 亮边 + blur(24) sat(1.4) + --glass-shadow
            radiusOverride: BorderRadius.all(Radius.circular(AylaRadii.rCard)),
            blur: AylaGlass.blurCard,
            shadow: AylaShadows.glass,
            padding: const EdgeInsets.all(AylaSpacing.sp4), // padding: var(--sp-4)
            child: body,
          )
        : body;

    // `max-width: 560px`（app.css:2877）—— 房间上下文里被 `voice.css:32–38` 覆写为 none
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: widget.roomContext ? double.infinity : 560,
      ),
      child: panel,
    );
  }
}

// ======================= 预览 =======================

/// 语音频道面板样张（画布与 @Preview 共用；**可交互**）。
///
/// - 普通档：3 名成员 + 分页页脚 + 控制条；点喇叭/麦克风/拖音量条都有效；
/// - 房主档：「踢出 / 转让房主」行可见，点一下进入「处理中…」并把两个按钮一起禁用；
/// - 房间上下文档：`roomContext: true` + `ownMaterial: false`（固定高 420、成员列表自带滚动、
///   面板透明浮在页面背景上）——**不要给它加卡片底**：web 的 `.voice-room-voice-card` 自身
///   没有材质声明，宽屏时内外两层都透明；窄屏则是外层透明、材质归面板（= 默认档）。
Widget aylaVoiceChannelPanelSamples() => const _VoicePanelDemo();

class _VoicePanelDemo extends StatefulWidget {
  const _VoicePanelDemo();

  @override
  State<_VoicePanelDemo> createState() => _VoicePanelDemoState();
}

class _VoicePanelDemoState extends State<_VoicePanelDemo> {
  final Map<String, double> _volumes = <String, double>{'u2': 80, 'u3': 100};
  final Set<String> _locallyMuted = <String>{};
  bool _micEnabled = true;
  double _localVolume = 100;
  int _kickCount = 0;

  static const List<AylaVoicePanelMember> _members = <AylaVoicePanelMember>[
    AylaVoicePanelMember(
      member: AylaVoiceMember(userId: 'u2', audioLevel: 0.25),
      displayName: '爱莉',
      online: true,
    ),
    AylaVoicePanelMember(
      member: AylaVoiceMember(userId: 'u3', muted: true),
      displayName: '小满',
      online: true,
    ),
    AylaVoicePanelMember(
      member: AylaVoiceMember(userId: 'u4'),
      displayName: '很久以前的一个很长的成员昵称会被省略号截断',
    ),
  ];

  List<AylaVoicePanelMember> get _rows => <AylaVoicePanelMember>[
        for (final AylaVoicePanelMember m in _members)
          AylaVoicePanelMember(
            member: AylaVoiceMember(
              userId: m.member.userId,
              muted: m.member.muted,
              audioLevel: m.member.audioLevel,
              volume: _volumes[m.member.userId] ?? 100,
              locallyMuted: _locallyMuted.contains(m.member.userId),
            ),
            displayName: m.displayName,
            online: m.online,
          ),
      ];

  AylaVoiceChannelPanel _panel({bool owner = false, bool embedded = false}) {
    return AylaVoiceChannelPanel(
      channelName: embedded ? '深夜电台（房间上下文）' : '深夜电台',
      members: _rows,
      selfUserId: 'self',
      selfMember: const AylaVoicePanelMember(
        member: AylaVoiceMember(userId: 'self'),
        displayName: '汐汐',
        online: true,
      ),
      elysiaUserId: 'u2',
      count: _rows.length + 1,
      isOwner: owner,
      self: AylaVoiceSelfState(
        micEnabled: _micEnabled,
        localVolume: _localVolume,
      ),
      ownMaterial: !embedded,
      roomContext: embedded,
      page: const AylaVoiceMembersPage(hasMore: true),
      onToggleMic: () => setState(() => _micEnabled = !_micEnabled),
      onLocalVolumeChange: (double v) => setState(() => _localVolume = v),
      onVolumeChange: (String id, double v) => setState(() => _volumes[id] = v),
      onToggleMemberMuted: (String id) => setState(() {
        _locallyMuted.contains(id)
            ? _locallyMuted.remove(id)
            : _locallyMuted.add(id);
      }),
      onLeave: () {},
      onMemberAction: (String id, AylaVoiceMemberAction action) async {
        await Future<void>.delayed(const Duration(milliseconds: 600));
        setState(() => _kickCount++);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AylaSpacing.sp6,
      runSpacing: AylaSpacing.sp6,
      crossAxisAlignment: WrapCrossAlignment.start,
      children: <Widget>[
        SizedBox(width: 560, child: _panel()),
        SizedBox(
          width: 560,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Text('房主档（踢出 / 转让房主；点一下看处理中…）',
                  style: TextStyle(fontSize: 11)),
              const SizedBox(height: AylaSpacing.sp2),
              _panel(owner: true),
              const SizedBox(height: AylaSpacing.sp2),
              Text('成员操作已触发 $_kickCount 次', style: const TextStyle(fontSize: 11)),
            ],
          ),
        ),
        SizedBox(
          width: 560,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Text(
                '房间上下文档（固定高 420）：面板透明 + 成员列表自带滚动；'
                'web 的 `.voice-room-voice-card` 自身**没有材质声明**（只有 @supports 兜底给 --surface），'
                '宽屏时它内部的 `.voice-panel` 也是透明 ⇒ 整列直接浮在极光背景上（窄屏反过来：材质归面板）',
                style: TextStyle(fontSize: 11),
              ),
              const SizedBox(height: AylaSpacing.sp2),
              // ⚠️ 这里**不能**再自造一层卡片底：本档的语义就是「透明，浮在页面背景上」
              SizedBox(height: 420, child: _panel(embedded: true)),
            ],
          ),
        ),
      ],
    );
  }
}

/// 语音频道面板（普通 / 房主 / 房间上下文）—— 可交互。
@Preview(
  group: 'Widgets',
  name: '语音频道面板（成员列表 + 控制条）',
  size: Size(1800, 560),
  wrapper: previewTheme,
)
Widget aylaVoiceChannelPanelPreview() => aylaVoiceChannelPanelSamples();
