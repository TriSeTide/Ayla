/// live 域第四批（B2-4）：主播头像 + 推流地址复制区。
///
/// ## 事实源（逐条对应 web，禁自由发挥）
/// ```
/// components/live/LiveHostAvatar.tsx      52 行（主播头像：资料懒拉 + 回退首字符光环）
/// components/live/LiveStreamAddresses.tsx 72 行（服务器 / 串流密钥 / FLV 三行 + 复制）
/// components/live/LiveCreate.tsx:15–18    obsServerFromRtmpUrl（取最后一个 `/` 之前）
/// live.css 206–229    .live-studio-stream：column · gap sp2 · width min(100%, 960px) ·
///                     padding sp3 · --glass-bg · 1px 亮边 · radius 16 · --glass-shadow ·
///                     blur24 sat1.4；卡内 .live-copy-value 覆写为
///                     （--glass-bg + 1px 亮边 + radius-input + --glass-inset）
/// live.css 249–257    （≤768）`.live-copy-row { align-items: flex-start; flex-wrap: wrap }`
///                     + `.live-copy-value { min-width: 0 }`
/// app.css 3443–3467   .live-copy-row（flex center · gap sp2）· -label（width 64 · flex-shrink 0 ·
///                     secondary · 12px）· -value（flex 1 · 省略号 · nowrap · padding sp1 sp2 ·
///                     --ice-100 底 · radius-sm 8 · utility 12 · text-primary）
/// app.css 3473–3477   .live-form-error（destructive · 13px · margin-top sp2）
/// ```
///
/// ## 与 web 的装配差异（组件不写页面）
/// - `LiveHostAvatar` 在 web 里是**数据壳**（`ensureUser` 懒拉 + 缓存）：昵称/头像/在线全部
///   由页面注入（网络层不进 `lib/widgets`）；label 回退链与 aria 文案是**组件语义**，照实现；
/// - `ensureUser` 的懒拉、`goUserProfile` 的跳转由页面持（[AylaLiveHostAvatar.onOpenProfile]）；
/// - 复制走 `Clipboard.setData`（web 是 `navigator.clipboard.writeText`），可注入替身便于测试。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter/widget_previews.dart';

import '../theme/app_theme.dart';
import '../theme/buttons.dart';
import '../theme/glass.dart';
import '../theme/preview_theme.dart';
import '../theme/tokens.dart';
import 'avatar_halo.dart';

/// `obsServerFromRtmpUrl`（`LiveCreate.tsx:15–18`）：推流服务器 = rtmp 地址**最后一个 `/` 之前**。
///
/// ```js
/// const idx = rtmpUrl.lastIndexOf("/");
/// return idx > 0 ? rtmpUrl.slice(0, idx) : rtmpUrl;
/// ```
String obsServerFromRtmpUrl(String rtmpUrl) {
  final int idx = rtmpUrl.lastIndexOf('/');
  return idx > 0 ? rtmpUrl.substring(0, idx) : rtmpUrl;
}

/// 直播间主播头像（`LiveHostAvatar.tsx` 52 行）。
///
/// label 回退链：`host.nickname || host.username || owner_nickname || '主播'`；
/// 在线由页面按 presence 规则算好（`status === "invisible"` → 恒离线）。
class AylaLiveHostAvatar extends StatelessWidget {
  const AylaLiveHostAvatar({
    super.key,
    this.hostNickname,
    this.hostUsername,
    this.ownerNickname,
    this.avatarUrl,
    this.online = false,
    this.size = 36,
    this.onOpenProfile,
  });

  /// 已拉到的用户资料昵称（web `host.nickname`）。
  final String? hostNickname;

  /// 已拉到的用户名（web `host.username`，第二兜底）。
  final String? hostUsername;

  /// 频道描述符上的主播昵称（web `owner_nickname`，第三兜底）。
  final String? ownerNickname;

  /// 头像地址（web `host.avatar`；空 = 首字符光环）。
  final String? avatarUrl;

  /// 是否在线（页面按 presence 判定：隐身恒离线）。
  final bool online;

  /// 头像边长（tsx 18 `size = 36`）。
  final double size;

  /// 点击 → 主播个人主页（web `goUserProfile(null, ownerId)`；ownerId 为空时不跳）。
  final VoidCallback? onOpenProfile;

  /// label 回退链（tsx 40）。
  String get label {
    for (final String? candidate in <String?>[
      hostNickname,
      hostUsername,
      ownerNickname,
    ]) {
      if (candidate != null && candidate.isNotEmpty) return candidate;
    }
    return '主播';
  }

  @override
  Widget build(BuildContext context) {
    final String name = label;
    return AvatarHalo(
      label: name,
      size: size,
      online: online,
      resourceUrl: (avatarUrl == null || avatarUrl!.isEmpty) ? null : avatarUrl,
      onTap: onOpenProfile,
      // tsx 50：`ariaLabel={`查看主播 ${label} 的个人主页`}`
      semanticLabel: '查看主播 $name 的个人主页',
    );
  }
}

/// 推流地址复制区（`LiveStreamAddresses.tsx` 72 行）。
///
/// 开播控制台放在直播视频下方，**仅 owner 且持有推流信息时渲染**（缺 `rtmp_url` / `stream_key`
/// 时整个组件不渲染，tsx 19）。
///
/// ⚠️ `stream_key` 是推流指纹：**不打日志、不持久化、仅内存展示**（tsx 5）。
class AylaLiveStreamAddresses extends StatefulWidget {
  const AylaLiveStreamAddresses({
    super.key,
    required this.rtmpUrl,
    required this.streamKey,
    this.flvUrl,
    this.onCopy,
  });

  /// 推流地址（服务器行由 [obsServerFromRtmpUrl] 推导）。
  final String? rtmpUrl;

  /// 串流密钥（指纹，勿落日志）。
  final String? streamKey;

  /// FLV 播放地址。
  final String? flvUrl;

  /// 复制实现（默认 `Clipboard.setData`）；注入替身便于测试与自定义失败文案。
  final Future<bool> Function(String text)? onCopy;

  /// 已复制提示的保持时长（tsx 29：`setTimeout(..., 1500)`）。
  static const Duration copiedHold = Duration(milliseconds: 1500);

  @override
  State<AylaLiveStreamAddresses> createState() =>
      _AylaLiveStreamAddressesState();
}

class _AylaLiveStreamAddressesState extends State<AylaLiveStreamAddresses> {
  /// 当前处于「已复制」的那一行（web `copied: string | null`）。
  String? _copied;

  /// 复制失败文案（web `error`）。
  String? _error;

  Timer? _resetTimer;

  @override
  void dispose() {
    _resetTimer?.cancel();
    super.dispose();
  }

  Future<void> _copy(String text, String which) async {
    final bool ok = await (widget.onCopy?.call(text) ?? _defaultCopy(text));
    if (!mounted) return;
    if (!ok) {
      // tsx 30：`catch { setError("复制失败，请手动选择复制") }`
      setState(() => _error = '复制失败，请手动选择复制');
      return;
    }
    setState(() {
      _copied = which;
      _error = null;
    });
    _resetTimer?.cancel();
    _resetTimer = Timer(AylaLiveStreamAddresses.copiedHold, () {
      if (mounted) setState(() => _copied = null);
    });
  }

  Future<bool> _defaultCopy(String text) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
      return true;
    } on Object {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final String? rtmp = widget.rtmpUrl;
    final String? key = widget.streamKey;
    // tsx 19：`if (!channel.rtmp_url || !channel.stream_key) return null`
    if (rtmp == null || rtmp.isEmpty || key == null || key.isEmpty) {
      return const SizedBox.shrink();
    }
    final String server = obsServerFromRtmpUrl(rtmp);
    final String? flv = widget.flvUrl;

    // `.live-studio-stream { width: min(100%, 960px) }`
    // ⚠️ `ConstrainedBox(maxWidth:)` 走的是 `constraints.enforce`——**父级给紧约束时会被夹回父级值**
    //    （与 `SizedBox(width:)` 同一个坑，实测 1200 宿主里 960 变 1200）⇒ 先用 Align 松掉横向紧约束。
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 960),
      child: GlassSurface(
        // `--glass-bg` + blur24 sat1.4 + 1px 亮边 + radius 16 + --glass-shadow
        radiusOverride: BorderRadius.all(Radius.circular(AylaRadii.rCard)),
        blur: AylaGlass.blurCard,
        shadow: AylaShadows.glass,
        padding: const EdgeInsets.all(AylaSpacing.sp3), // padding: var(--sp-3)
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          spacing: AylaSpacing.sp2, // gap: var(--sp-2)
          children: <Widget>[
            _row(label: '服务器', value: server, which: 'server'),
            _row(label: '串流密钥', value: key, which: 'key'),
            _row(label: 'FLV 地址', value: flv ?? '', which: 'flv'),
            if (_error case final String message)
              Padding(
                padding: const EdgeInsets.only(top: AylaSpacing.sp2),
                child: Text(
                  message, // `.live-form-error`
                  style: AylaTextStyles.of(context).body.copyWith(
                    fontSize: 13,
                    color: AylaColors.destructive,
                  ),
                ),
              ),
          ],
        ),
      ),
      ),
    );
  }

  /// `.live-copy-row`（app.css 3443–3467）——**共享复制行**，两件共用。
  ///
  /// 档位（[AylaLiveCopyRowVariant]）：`.live-studio-stream` 卡内被覆写成玻璃底 +
  /// radius-input + `--glass-inset`；`.live-create-guide` 里仍是**基础档**（`--ice-100` + radius-sm 8）。
  Widget _row({
    required String label,
    required String value,
    required String which,
  }) {
    return AylaLiveCopyRow(
      label: label,
      value: value,
      variant: AylaLiveCopyRowVariant.studioStream, // 卡内覆写档
      copied: _copied == which,
      onCopy: () => unawaited(_copy(value, which)),
    );
  }
}

/// 复制行档位（web：`.live-copy-value` 基础档 vs `.live-studio-stream` 卡内覆写档）。
enum AylaLiveCopyRowVariant {
  /// 基础档（app.css 3456–3467）：`--ice-100` 底 + `radius-sm 8`，无边框。
  ///
  /// 用于 `.live-create-guide`（指引卡内**没有**覆写规则）。
  base,

  /// `.live-studio-stream .live-copy-value`（live.css 224–229）：玻璃底 + 1px 亮边 +
  /// `radius-input 12` + `--glass-inset` 顶沿内高光。
  studioStream,
}

/// `.live-copy-row`：标签（64 / secondary 12）+ 值（utility 12 / 单行省略）+ 复制键。
///
/// 2026-09-22 用户拍板抽成共享件：`LiveStreamAddresses`（推流卡）与 `LiveCreate`（建播指引）
/// 在 web 里是同一套行结构与 `.msg-action-btn` 复制逻辑，只是「已复制」状态各持一份。
class AylaLiveCopyRow extends StatelessWidget {
  const AylaLiveCopyRow({
    super.key,
    required this.label,
    required this.value,
    required this.copied,
    required this.onCopy,
    this.variant = AylaLiveCopyRowVariant.base,
  });

  /// 行标签（「服务器」/「串流密钥」/「FLV 地址」）。
  final String label;

  /// 值文本（推流地址 / 密钥 / FLV）。
  final String value;

  /// 是否处于「已复制」态（tsx 44/55/66 的 `copied === which`）。
  final bool copied;

  /// 复制动作（已复制的 1.5s 复位由持有方管理，web 亦然）。
  final VoidCallback onCopy;

  /// 值框档位。
  final AylaLiveCopyRowVariant variant;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final bool narrow = Breakpoint.isNarrow(MediaQuery.sizeOf(context).width);
    final bool studio = variant == AylaLiveCopyRowVariant.studioStream;
    return Row(
      // 窄屏 `align-items: flex-start`（live.css 255）。⚠️ 同档的 `flex-wrap: wrap`
      // **没有渲染面**：同行还有 `.live-copy-value { min-width: 0 }`，值可压到 0 ⇒ 永不换行，
      // 故 Flutter 侧只表达交叉轴对齐，不做换行（照实渲染，勿加多余行为）。
      crossAxisAlignment: narrow
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.center,
      spacing: AylaSpacing.sp2, // gap: var(--sp-2)
      children: <Widget>[
        SizedBox(
          // `.live-copy-label { width: 64px; flex-shrink: 0 }`
          width: 64,
          child: Text(
            label,
            style: t.body.copyWith(
              fontSize: 12,
              color: AylaColors.textSecondary,
            ),
          ),
        ),
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AylaSpacing.sp2,
              vertical: AylaSpacing.sp1,
            ),
            decoration: BoxDecoration(
              color: studio
                  ? AylaColors.glassBg // 覆写档：--glass-bg
                  : AylaColors.ice100, // 基础档：--ice-100
              borderRadius: BorderRadius.circular(
                studio ? AylaRadii.rInput : AylaRadii.rSm, // 12 / 8
              ),
              border: studio
                  ? Border.all(color: AylaColors.glassBorder)
                  : null,
            ),
            child: AylaGlassInset.over(
              radius: BorderRadius.circular(
                studio ? AylaRadii.rInput : AylaRadii.rSm,
              ),
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis, // ellipsis + nowrap
                softWrap: false,
                style: TextStyle(
                  fontFamily: AylaFonts.utility, // --font-utility 12
                  fontFamilyFallback: AylaFonts.cjkFallback,
                  fontSize: 12,
                  color: AylaColors.textPrimary,
                ),
              ),
            ),
          ),
        ),
        AylaMsgActionButton(
          label: copied ? '已复制' : '复制', // tsx 44/55/66
          onPressed: onCopy,
        ),
      ],
    );
  }
}

// ======================= 预览样张 =======================

/// 主播头像 + 推流地址区样张（可交互：点复制看「已复制」/ 失败态）。
Widget aylaLiveStudioSamples() {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      _Stage(
        viewport: const Size(520, 200),
        label:
            '主播头像（`LiveHostAvatar`）· label 回退链：资料昵称 → 用户名 → `owner_nickname` → 「主播」；尺寸 36（同尺寸 28 / 52 各一格）· 有头像/无头像、在线/离线',
        child: const _HostAvatarDemo(),
      ),
      const SizedBox(height: AylaSpacing.sp6),
      _Stage(
        viewport: const Size(1000, 240),
        label:
            '推流地址区（`LiveStreamAddresses`）· 卡 `width: min(100%, 960px)` + padding sp3 · 三行（标签 64 / 值 utility 12 · 卡内覆写玻璃底 + radius-input + 内高光 / 复制键 `.msg-action-btn`）· 可交互：点复制 → 「已复制」1.5s（失败 → destructive 文案）',
        child: const _StreamAddressesDemo(),
      ),
      const SizedBox(height: AylaSpacing.sp6),
      _Stage(
        viewport: const Size(420, 320),
        label: '窄屏档（≤768）：`align-items: flex-start` + 值 `min-width: 0`（同档 `flex-wrap` 无渲染面）',
        child: const _StreamAddressesDemo(),
      ),
      const SizedBox(height: AylaSpacing.sp6),
      _Stage(
        viewport: const Size(520, 160),
        label: '缺 `rtmp_url` / `stream_key` → **整个组件不渲染**（tsx 19）· 右格为空',
        child: const _StreamAddressesAbsentDemo(),
      ),
    ],
  );
}

class _HostAvatarDemo extends StatelessWidget {
  const _HostAvatarDemo();

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AylaSpacing.sp4,
      runSpacing: AylaSpacing.sp3,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        const AylaLiveHostAvatar(
          hostNickname: '爱莉',
          hostUsername: 'elysia',
          ownerNickname: '主播昵称',
          online: true,
        ),
        const AylaLiveHostAvatar(hostUsername: 'elysia', online: true),
        const AylaLiveHostAvatar(
          ownerNickname: '频道上的昵称',
          online: false,
        ),
        const AylaLiveHostAvatar(hostNickname: '', hostUsername: '', size: 28),
        const AylaLiveHostAvatar(
          hostNickname: '大一位',
          size: 52,
          online: true,
        ),
      ],
    );
  }
}

class _StreamAddressesDemo extends StatefulWidget {
  const _StreamAddressesDemo();

  @override
  State<_StreamAddressesDemo> createState() => _StreamAddressesDemoState();
}

class _StreamAddressesDemoState extends State<_StreamAddressesDemo> {
  int _copies = 0;
  bool _fail = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      spacing: AylaSpacing.sp2,
      children: <Widget>[
        AylaLiveStreamAddresses(
          rtmpUrl: 'rtmp://live.elysium.local/app/stream-9f2c',
          streamKey: 'sk_live_9f2c4a7b1e',
          flvUrl: 'http://live.elysium.local/live/stream-9f2c.flv',
          onCopy: (String text) async {
            setState(() => _copies += 1);
            return !_fail; // 用开关演示失败态
          },
        ),
        Row(
          spacing: AylaSpacing.sp2,
          children: <Widget>[
            Text('已触发复制 $_copies 次', style: const TextStyle(fontSize: 11)),
            GlassButton(
              label: _fail ? '失败态：开' : '失败态：关',
              variant: GlassButtonVariant.ghost,
              onPressed: () => setState(() => _fail = !_fail),
            ),
          ],
        ),
      ],
    );
  }
}

class _StreamAddressesAbsentDemo extends StatelessWidget {
  const _StreamAddressesAbsentDemo();

  @override
  Widget build(BuildContext context) {
    return Row(
      spacing: AylaSpacing.sp4,
      children: <Widget>[
        const Expanded(
          child: AylaLiveStreamAddresses(
            rtmpUrl: null,
            streamKey: 'sk_live_9f2c',
          ),
        ),
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '（左侧应完全为空）',
              style: TextStyle(fontSize: 11, color: AylaColors.textSecondary),
            ),
          ),
        ),
      ],
    );
  }
}

/// 固定视口的样张舞台。
class _Stage extends StatelessWidget {
  const _Stage({
    required this.viewport,
    required this.label,
    required this.child,
  });

  final Size viewport;
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SizedBox(
          width: viewport.width,
          height: viewport.height,
          child: Builder(
            builder: (BuildContext inner) => MediaQuery(
              data: MediaQuery.of(inner).copyWith(size: viewport),
              child: child,
            ),
          ),
        ),
        const SizedBox(height: AylaSpacing.sp1),
        SizedBox(
          width: viewport.width,
          child: Text(label, style: const TextStyle(fontSize: 11)),
        ),
      ],
    );
  }
}

/// 主播头像 + 推流地址区。
@Preview(
  group: 'Widgets',
  name: '主播头像 + 推流地址',
  size: Size(1060, 1300),
  wrapper: previewTheme,
)
Widget aylaLiveStudioPreview() => aylaLiveStudioSamples();
