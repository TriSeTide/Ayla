/// live 域第四批（B2-4）：在看观众条 + 在看名单弹层。
///
/// ## 事实源（逐条对应 web，禁自由发挥）
/// ```
/// components/live/LiveViewerStrip.tsx  85 行（整排按钮 / 人数圆 / 头像排 / 更多圆点 / 未知态）
/// components/live/LiveViewerSheet.tsx 147 行（CreateSheet 配方 + 名单行 / 骨架 / 三态 / 60vh）
/// live.css 1095–1183  .live-viewer-strip：min-height 44 · padding sp1 sp3 · 1px 亮边 ·
///                     radius-input · --glass-bg + blur18 sat1.4 · --glass-shadow-compact ·
///                     hover rgba(255,250,251,.72) · focus-visible 环；
///                     .live-viewer-strip-count（min-width 32 / h32 / padding 0 6 / pill /
///                     --ice-300 底 + --indigo-700 字 / gap 2）；-num（utility 12 / ls .3 / lh 1）；
///                     is-unknown（`–` + --ice-100 + secondary，尺寸不变）；
///                     -avatars（gap sp1 / flex 1 / overflow hidden）；-more（26×26 / pill /
///                     1px 亮边 / --ice-100 底 / IconDots 14）
/// live.css 1186–1210  落位：窄屏 swipe-item 内 margin-top sp2；宽屏非控制台 margin-top 0；
///                     控制台 sp2；群内窄屏 sp2（**落位由调用方 Stack/Column 决定**）
/// live.css 1212–1226  .live-viewer-sheet-card：flex column；head flex:none（标题不随名单滚）；
///                     body flex 1 / min-height 0 / overflow-y auto / overscroll contain
/// live.css 1237–1316  .live-viewer-row（min-height 48 / padding sp1 sp2 / radius-input /
///                     透明底 / hover --glass-bg / focus ring）/ -row-name（15 / w600 / 1.4 单行省略）/
///                     骨架（头像 41×41 pill + 名字 40%×14 pill，尺寸与真行一致）
/// live.css 1298–1316  .live-viewer-sheet-state（sp4 0 / center / 14 secondary）+
///                     -sheet-error（text-primary）/ -sheet-hint（「仅显示前 N 位」13 secondary）
/// live.css 1318–1325  （≤768）`.live-viewer-sheet-card { height: 60vh; max-height: 60vh }`
/// vitest/live-viewers.test.tsx 161–256  官方用例（整排可点 / 未知不冒充 0 / 0 是真实读数 /
///                     纯展示不拉数据 / 行跳个人主页后关闭 / 截断提示 / 503 明示 + 重试 / portal）
/// ```
///
/// ## 与 web 的装配差异（组件不写页面）
/// - **数据全部由页面注入**（[AylaLiveViewerSheetData]）：web 在弹层内部 `getLiveChannelViewers`
///   拉取 + `getElysiaProfile` 判爱莉，网络层不进 `lib/widgets`；
/// - **弹层宿主改为插 root Overlay**（[aylaOverlayEntry]，等价 web `createPortal(document.body)`；
///   官方用例 248–256 明确「侧栏 backdrop-filter 不裁剪弹层」）——库内先例 = 弹幕图片查看器宿主；
/// - 落位（`margin-top` 与所属分区）由调用方决定，组件自身不带 margin。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../theme/app_icons.dart';
import '../theme/app_theme.dart';
import '../theme/glass.dart';
import '../theme/preview_theme.dart';
import '../theme/tokens.dart';
import 'avatar_halo.dart';
import 'create_sheet.dart';
import 'loading.dart' show AylaSkeleton;
import 'overlays.dart';

/// 头像条一次最多渲染几位（tsx 27 `MAX_PREVIEW = 12`，与后端 WS 预览上限一致）。
const int kAylaLiveViewerPreviewMax = 12;

/// 一位在看观众（web `LiveViewerItem`）。
class AylaLiveViewerItem {
  const AylaLiveViewerItem({
    required this.userId,
    this.nickname = '',
    this.avatar = '',
  });

  final String userId;
  final String nickname;
  final String avatar;
}

/// 名单弹层的数据投影（web 弹层内部拉取的等价物 —— 由页面给出）。
class AylaLiveViewerSheetData {
  const AylaLiveViewerSheetData({
    this.viewers,
    this.count,
    this.hasMore = false,
    this.error,
    this.elysiaUserId,
    this.onRetry,
    this.onOpenProfile,
  });

  /// 权威名单；**null = 尚未到达**（骨架态）；空列表 = 真的没人看（空态）。
  final List<AylaLiveViewerItem>? viewers;

  /// 权威人数；null = 未知（标题退化为「正在观看」）。
  final int? count;

  /// 名单被后端上限截断（tsx 128 → 「仅显示前 N 位」）。
  final bool hasMore;

  /// 读取失败文案（tsx 56–60；**不回落空名单冒充没人看**）。
  final String? error;

  /// 爱莉 user id（名单里标注爱莉光环）；null = 不标注。
  final String? elysiaUserId;

  /// 「重试」回调（tsx 97）。
  final VoidCallback? onRetry;

  /// 点名单行（web `goUserProfile(me, user_id)`：自己 → 个人页 / 他人 → 用户页）。
  final ValueChanged<AylaLiveViewerItem>? onOpenProfile;
}

/// `.live-viewer-strip` —— 视频下方的「在看观众条」（`LiveViewerStrip.tsx` 85 行）。
///
/// **纯展示**：人数与预览由调用方给（进房快照 + 弹幕 WS 的 `viewers` 帧写进 store）；
/// 组件自身不拉数据。整排是按钮，点击打开名单弹层（见 [AylaLiveViewerSheet]）。
class AylaLiveViewerStrip extends StatefulWidget {
  const AylaLiveViewerStrip({
    super.key,
    required this.count,
    this.viewers = const <AylaLiveViewerItem>[],
    this.sheet = const AylaLiveViewerSheetData(),
  });

  /// 当前在看人数；**null = 未知**（人数位显示 `–`，不写 0 冒充）。
  final int? count;

  /// 预览名单（最近活跃优先；超过 [kAylaLiveViewerPreviewMax] 只渲染前 12 位）。
  final List<AylaLiveViewerItem> viewers;

  /// 名单弹层的数据与动作（打开时读取；默认空投影 = 骨架态）。
  final AylaLiveViewerSheetData sheet;

  @override
  State<AylaLiveViewerStrip> createState() => _AylaLiveViewerStripState();
}

class _AylaLiveViewerStripState extends State<AylaLiveViewerStrip> {
  /// 弹层打开时插到 root Overlay 的 entry（等价 web portal 到 body）。
  OverlayEntry? _sheetEntry;

  /// 弹层数据的活引用：entry 是独立子树，靠它把 `widget.sheet` 的更新送进去。
  final ValueNotifier<AylaLiveViewerSheetData> _sheetData =
      ValueNotifier<AylaLiveViewerSheetData>(const AylaLiveViewerSheetData());

  @override
  void didUpdateWidget(covariant AylaLiveViewerStrip old) {
    super.didUpdateWidget(old);
    _sheetData.value = widget.sheet;
  }

  @override
  void dispose() {
    _closeSheet();
    _sheetData.dispose();
    super.dispose();
  }

  void _openSheet() {
    if (_sheetEntry != null) return;
    _sheetData.value = widget.sheet;
    final OverlayEntry entry = aylaOverlayEntry(
      builder: (BuildContext ctx) => ValueListenableBuilder<AylaLiveViewerSheetData>(
        valueListenable: _sheetData,
        builder: (BuildContext ctx, AylaLiveViewerSheetData data, Widget? _) =>
            AylaLiveViewerSheet(
          // 预览打底（tsx 81）：权威名单未到且无错时先用 WS 预览
          preview: widget.viewers,
          data: data,
          onClose: _closeSheet,
        ),
      ),
    );
    _sheetEntry = entry;
    // 库内统一写法（danmaku.dart 的查看器宿主 / conversation_more_menu）：root overlay 直插
    Overlay.of(context, rootOverlay: true).insert(entry);
  }

  void _closeSheet() {
    _sheetEntry?.remove();
    _sheetEntry = null;
  }

  @override
  Widget build(BuildContext context) {
    final bool known = widget.count != null;
    final List<AylaLiveViewerItem> shown = widget.viewers
        .take(kAylaLiveViewerPreviewMax)
        .toList();
    // 人数圆：已知 --ice-300 底 + --indigo-700 字；未知 --ice-100 + secondary（尺寸不变）
    final Color countBg = known ? AylaColors.ice300 : AylaColors.ice100;
    final Color countFg = known
        ? AylaColors.indigo700
        : AylaColors.textSecondary;

    // 整排是按钮：复用 `AylaCardInteraction`（focus 环画在形状之外 + Enter/Space 可达），
    // ⚠️ `interactive: false` —— `.live-viewer-strip` **不在** auroraqua 的卡片/按钮 :is() 组里
    //    （已 grep 确认无命中）⇒ 无 hover 1.02、无 active .98、无扫光；
    // 环色用 `--focus-ring`（tokens.css:86 `2px solid #f796ff` = glow-500），
    // 与卡片族的 ice-500 不同档；半径跟自身 radius-input 12。
    return AylaCardInteraction(
      onTap: _openSheet,
      interactive: false,
      focusRingColor: AylaColors.glow500,
      focusRingRadius: BorderRadius.circular(AylaRadii.rInput),
      semanticLabel: known
          ? '正在观看 ${widget.count} 人，查看完整名单'
          : '正在观看人数未知，查看名单', // tsx 53
      builder: (BuildContext context, bool hovered) {
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Container(
              // `.live-viewer-strip`：min-height 44（§10 触达下限）/ padding sp1 sp3 /
              // 1px 亮边 / radius-input / --glass-bg + blur18 sat1.4 / compact 阴影
              constraints: const BoxConstraints(minHeight: 44),
              padding: const EdgeInsets.symmetric(
                horizontal: AylaSpacing.sp3,
                vertical: AylaSpacing.sp1,
              ),
              decoration: BoxDecoration(
                color: hovered
                    ? const Color(0xB8FFFAFB) // hover rgba(255,250,251,.72)
                    : AylaColors.glassBg,
                borderRadius: BorderRadius.circular(AylaRadii.rInput),
                border: Border.all(color: AylaColors.glassBorder),
              ),
              child: Row(
                spacing: AylaSpacing.sp2, // gap: var(--sp-2)
                children: <Widget>[
                  _countCircle(known, countBg, countFg),
                  // `.live-viewer-strip-avatars`：flex 1 / min-width 0 / overflow hidden
                  Expanded(
                    child: ClipRect(
                      child: Row(
                        spacing: AylaSpacing.sp1, // gap: var(--sp-1)
                        children: <Widget>[
                          for (final AylaLiveViewerItem viewer in shown)
                            AvatarHalo(
                              label: viewer.nickname,
                              size: 26, // tsx 64：`size={26}`
                              // tsx 66：预览头像恒 `online`（这份名单就是「正在看」的人）
                              online: true,
                              resourceUrl: viewer.avatar.isEmpty
                                  ? null
                                  : viewer.avatar,
                            ),
                        ],
                      ),
                    ),
                  ),
                  _more(),
                ],
              ),
            ),
        );
      },
    );
  }

  /// `.live-viewer-strip-count`：人数圆（1–2 位正圆 32、3 位以上自然长成胶囊）。
  Widget _countCircle(bool known, Color bg, Color fg) {
    return Container(
      constraints: const BoxConstraints(minWidth: 32),
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(color: bg, borderRadius: AylaRadii.pill),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 2, // gap: 2px
        children: <Widget>[
          AylaIcon(
            aylaIconByName('iconUsers')!,
            size: 14, // tsx 57
            color: fg,
          ),
          Text(
            known ? '${widget.count}' : '–', // 未知显示 `–`，不冒充 0
            style: TextStyle(
              fontFamily: AylaFonts.utility, // utility 12 / ls .3 / lh 1
              fontFamilyFallback: AylaFonts.cjkFallback,
              fontSize: 12,
              letterSpacing: 0.3,
              height: 1,
              color: fg,
            ),
          ),
        ],
      ),
    );
  }

  /// `.live-viewer-strip-more`：经典三圆点（非文本省略号）。
  Widget _more() {
    return Container(
      width: 26,
      height: 26,
      decoration: BoxDecoration(
        color: AylaColors.ice100, // --ice-100
        borderRadius: AylaRadii.pill,
        border: Border.all(color: AylaColors.glassBorder),
      ),
      alignment: Alignment.center,
      child: AylaIcon(
        aylaIconByName('iconDots')!,
        size: 14, // tsx 73
        color: AylaColors.textSecondary,
      ),
    );
  }
}

/// `.live-viewer-sheet-card` —— 在看名单弹层（`LiveViewerSheet.tsx` 147 行）。
///
/// 复用 [AylaCreateSheet] 的配方（遮罩 / 材料 / radius panel / 窄屏上滑 250ms），
/// 并通过 `narrowHeightFactor: 0.6` 表达窄屏 **60vh**；标题行固定、**只有名单自身滚动**
/// （web `.live-viewer-sheet-card .create-sheet-head { flex: none }` + body `overflow-y:auto`）。
class AylaLiveViewerSheet extends StatelessWidget {
  const AylaLiveViewerSheet({
    super.key,
    required this.preview,
    required this.data,
    required this.onClose,
    this.titleOverride,
  });

  /// 弹幕 WS 的预览名单（权威名单未到时打底，tsx 81）。
  final List<AylaLiveViewerItem> preview;

  /// 权威名单与动作（页面注入）。
  final AylaLiveViewerSheetData data;

  /// 关闭（标题关闭键 / ESC / 点遮罩）。
  final VoidCallback onClose;

  /// 标题覆盖（默认按 tsx 83–86 推导）。
  final String? titleOverride;

  /// 骨架行数（tsx 24 `ROW_SKELETON_COUNT = 6`）。
  static const int skeletonRows = 6;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    // `rows = viewers ?? (error ? [] : preview)`（tsx 81）
    final List<AylaLiveViewerItem> rows =
        data.viewers ?? (data.error != null ? const <AylaLiveViewerItem>[] : preview);
    // `total = count ?? rows.length`（tsx 82）
    final int total = data.count ?? rows.length;
    // `count === null && error ? '正在观看' : '正在观看 · N 人'`（tsx 83–86）
    final String title =
        titleOverride ??
        ((data.count == null && data.error != null)
            ? '正在观看'
            : '正在观看 · $total 人');

    final Size vp = MediaQuery.sizeOf(context);
    final bool narrow = vp.width <= 768;
    final double safeBottom = MediaQuery.paddingOf(context).bottom;
    // 卡片上限：宽屏 80vh（`.create-sheet-card { max-height: 80vh }`）、窄屏 60vh（1318–1325）
    final double cardMax = narrow ? vp.height * 0.6 : vp.height * 0.8;
    // body 可用高 = 卡上限 − 卡片 padding sp4×2 − 安全区 − head 高（标题行固定，不参与滚动）
    final double bodyMax = math.max(
      0,
      cardMax -
          AylaSpacing.sp4 * 2 -
          safeBottom -
          AylaLiveViewerSheet.headHeight,
    );

    return AylaCreateSheet(
      title: title,
      onClose: onClose,
      // 窄屏 60vh（web `className="live-viewer-sheet-card"` 的媒体查询档）
      narrowHeightFactor: 0.6,
      // 滚动交给 body 自身（head 固定）——不让整张卡滚，标题与关闭键才不会被名单带走
      scrollable: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: bodyMax),
        child: SingleChildScrollView(
          // `overscroll-behavior: contain`
          physics: const ClampingScrollPhysics(),
          child: _body(context, t, rows),
        ),
      ),
    );
  }

  /// `.create-sheet-head` 的高度：关闭钮 `.icon-btn-40`（40）+ `margin-bottom: var(--sp-3)`。
  static const double headHeight = 40 + AylaSpacing.sp3;

  Widget _body(
    BuildContext context,
    AylaTextStyles t,
    List<AylaLiveViewerItem> rows,
  ) {
    if (data.error case final String message) {
      // tsx 91–100：`role=alert` + 错误文案 + 「重试」（`.btn.btn-ghost`）
      return Semantics(
        liveRegion: true,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AylaSpacing.sp4),
              child: Text(
                message,
                textAlign: TextAlign.center,
                style: t.body.copyWith(
                  fontSize: 14,
                  color: AylaColors.textPrimary, // `.live-viewer-sheet-error`
                ),
              ),
            ),
            GlassButton(
              label: '重试',
              variant: GlassButtonVariant.ghost,
              onPressed: data.onRetry,
            ),
          ],
        ),
      );
    }
    // 骨架：`viewers === null && rows.length === 0`（tsx 100–107）
    if (data.viewers == null && rows.isEmpty) {
      return ExcludeSemantics(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: AylaSpacing.sp1, // gap: var(--sp-1)
          children: <Widget>[
            for (int i = 0; i < skeletonRows; i += 1) const _SkeletonRow(),
          ],
        ),
      );
    }
    if (rows.isEmpty) {
      // tsx 109：空态
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AylaSpacing.sp4),
        child: Text(
          '还没有人在看',
          textAlign: TextAlign.center,
          style: t.body.copyWith(
            fontSize: 14,
            color: AylaColors.textSecondary, // `.live-viewer-sheet-state`
          ),
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: AylaSpacing.sp1, // `.live-viewer-list { gap: var(--sp-1) }`
      children: <Widget>[
        for (final AylaLiveViewerItem viewer in rows)
          _ViewerRow(
            viewer: viewer,
            isElysia:
                data.elysiaUserId != null &&
                viewer.userId == data.elysiaUserId,
            onTap: () {
              data.onOpenProfile?.call(viewer);
              onClose(); // tsx 122–124：跳转后关闭弹层
            },
          ),
        if (data.hasMore)
          Padding(
            padding: const EdgeInsets.only(top: AylaSpacing.sp2),
            child: Text(
              '仅显示前 ${rows.length} 位', // tsx 129
              textAlign: TextAlign.center,
              style: t.body.copyWith(
                fontSize: 13,
                color: AylaColors.textSecondary,
              ),
            ),
          ),
      ],
    );
  }
}

/// `.live-viewer-row`（tsx 111–126 + live.css 1237–1265）。
class _ViewerRow extends StatefulWidget {
  const _ViewerRow({
    required this.viewer,
    required this.isElysia,
    required this.onTap,
  });

  final AylaLiveViewerItem viewer;
  final bool isElysia;
  final VoidCallback onTap;

  @override
  State<_ViewerRow> createState() => _ViewerRowState();
}

class _ViewerRowState extends State<_ViewerRow> {
  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final String name = widget.viewer.nickname.isEmpty
        ? '用户'
        : widget.viewer.nickname; // tsx 118/125：空昵称回落「用户」
    // `.live-viewer-row:focus-visible { outline: var(--focus-ring); outline-offset: 2px }`
    return AylaCardInteraction(
      onTap: widget.onTap,
      interactive: false, // 名单行没有卡片族动效（web 只有背景过渡）
      focusRingColor: AylaColors.glow500,
      focusRingRadius: BorderRadius.circular(AylaRadii.rInput),
      semanticLabel: '查看 $name 的个人主页', // tsx 122
      builder: (BuildContext context, bool hovered) {
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Container(
            constraints: const BoxConstraints(minHeight: 48), // min-height: 48px
            padding: const EdgeInsets.symmetric(
              horizontal: AylaSpacing.sp2,
              vertical: AylaSpacing.sp1,
            ),
            decoration: BoxDecoration(
              color: hovered
                  ? AylaColors.glassBg // hover → var(--glass-bg)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(AylaRadii.rInput),
              border: Border.all(
                color: Colors.transparent, // `border: 1px solid transparent`
              ),
            ),
            child: Row(
              spacing: AylaSpacing.sp2, // gap: var(--sp-2)
              children: <Widget>[
                AvatarHalo(
                  label: name,
                  size: 36, // tsx 115：`size={36}`
                  online: true,
                  core: widget.isElysia ? AvatarCore.elysia : AvatarCore.user,
                  resourceUrl: widget.viewer.avatar.isEmpty
                      ? null
                      : widget.viewer.avatar,
                ),
                Expanded(
                  child: Text(
                    name,
                    // `.live-viewer-row-name`：15 / w600 / 1.4 / 单行省略
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.body.copyWith(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      height: 1.4,
                      color: AylaColors.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 骨架行：尺寸与真实行一致（头像 41×41 pill + 名字 40%×14 pill），就绪时不跳动。
class _SkeletonRow extends StatelessWidget {
  const _SkeletonRow();

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 48),
      padding: const EdgeInsets.symmetric(
        horizontal: AylaSpacing.sp2,
        vertical: AylaSpacing.sp1,
      ),
      child: Row(
        spacing: AylaSpacing.sp2,
        children: <Widget>[
          // `.live-viewer-skeleton-avatar { width: 41px; height: 41px }`（头像 36 + 光环 2.5×2）
          const AylaSkeleton(width: 41, height: 41, radius: AylaRadii.rPill),
          Expanded(
            child: FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: 0.4, // `.live-viewer-skeleton-name { width: 40% }`
              child: const AylaSkeleton(height: 14, radius: AylaRadii.rPill),
            ),
          ),
        ],
      ),
    );
  }
}

// ======================= 预览样张 =======================

/// 在看观众条 + 名单弹层样张（可交互：点整排开名单 / 点行跳主页）。
Widget aylaLiveViewersSamples() {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      _Stage(
        viewport: const Size(560, 220),
        label:
            '在看观众条（`LiveViewerStrip`）· 三态：已知 / 未知（`–` 占位、尺寸不变）/ 0 人（真实读数）· 可交互：点整排打开名单弹层',
        child: const _ViewerStripDemo(),
      ),
      const SizedBox(height: AylaSpacing.sp6),
      _Stage(
        viewport: const Size(900, 520),
        label:
            '名单弹层（`LiveViewerSheet`）· 宽屏居中 + 标题「正在观看 · N 人」+ head 固定/名单内滚 · 行点后关闭并回调',
        child: const _ViewerSheetDemo(),
      ),
      const SizedBox(height: AylaSpacing.sp6),
      _Stage(
        viewport: const Size(420, 560),
        label: '名单弹层 · 窄屏档（≤768 → **60vh 贴底上滑**）· 同一样张在 ≤768 视口下的形态',
        child: const _ViewerSheetDemo(narrow: true),
      ),
      const SizedBox(height: AylaSpacing.sp6),
      _Stage(
        viewport: const Size(900, 420),
        label: '名单弹层 · 骨架（`viewers == null`，6 行）/ 空态（「还没有人在看」）/ 503（role=alert + 重试）',
        child: const _ViewerSheetStatesDemo(),
      ),
    ],
  );
}

class _ViewerStripDemo extends StatefulWidget {
  const _ViewerStripDemo();

  @override
  State<_ViewerStripDemo> createState() => _ViewerStripDemoState();
}

class _ViewerStripDemoState extends State<_ViewerStripDemo> {
  int _opened = 0;

  static const List<AylaLiveViewerItem> _viewers = <AylaLiveViewerItem>[
    AylaLiveViewerItem(userId: 'u1', nickname: '小樱'),
    AylaLiveViewerItem(userId: 'u2', nickname: '爱莉'),
    AylaLiveViewerItem(userId: 'u3', nickname: '汐汐'),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: AylaSpacing.sp3,
      children: <Widget>[
        AylaLiveViewerStrip(
          count: 3,
          viewers: _viewers,
          sheet: AylaLiveViewerSheetData(
            viewers: _viewers,
            count: 12,
            hasMore: true,
            onOpenProfile: (AylaLiveViewerItem v) =>
                setState(() => _opened += 1),
          ),
        ),
        AylaLiveViewerStrip(count: null), // 未知：`–` 占位
        const AylaLiveViewerStrip(count: 0), // 0 是真实读数
        Text('打开名单 $_opened 次', style: const TextStyle(fontSize: 11)),
      ],
    );
  }
}

class _ViewerSheetDemo extends StatefulWidget {
  const _ViewerSheetDemo({this.narrow = false});

  final bool narrow;

  @override
  State<_ViewerSheetDemo> createState() => _ViewerSheetDemoState();
}

class _ViewerSheetDemoState extends State<_ViewerSheetDemo> {
  bool _open = true;
  String? _picked;

  static const List<AylaLiveViewerItem> _viewers = <AylaLiveViewerItem>[
    AylaLiveViewerItem(userId: 'u1', nickname: '小樱'),
    AylaLiveViewerItem(userId: 'u2', nickname: '爱莉'),
    AylaLiveViewerItem(userId: 'u3', nickname: '汐汐'),
    AylaLiveViewerItem(userId: 'u4', nickname: '观众甲'),
    AylaLiveViewerItem(userId: 'u5', nickname: '观众乙'),
  ];

  @override
  Widget build(BuildContext context) {
    if (!_open) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: AylaSpacing.sp2,
          children: <Widget>[
            GlassButton(
              label: '重新打开名单',
              variant: GlassButtonVariant.ghost,
              onPressed: () => setState(() => _open = true),
            ),
            if (_picked != null)
              Text('已点：$_picked', style: const TextStyle(fontSize: 11)),
          ],
        ),
      );
    }
    return AylaLiveViewerSheet(
      preview: _viewers,
      data: AylaLiveViewerSheetData(
        viewers: _viewers,
        count: 5,
        hasMore: true,
        elysiaUserId: 'u2',
        onRetry: () {},
        onOpenProfile: (AylaLiveViewerItem v) =>
            setState(() => _picked = v.nickname),
      ),
      onClose: () => setState(() => _open = false),
    );
  }
}

class _ViewerSheetStatesDemo extends StatefulWidget {
  const _ViewerSheetStatesDemo();

  @override
  State<_ViewerSheetStatesDemo> createState() => _ViewerSheetStatesDemoState();
}

class _ViewerSheetStatesDemoState extends State<_ViewerSheetStatesDemo> {
  bool _open = true;
  int _which = 0;
  static const List<String> _names = <String>['骨架', '空态', '503'];

  @override
  Widget build(BuildContext context) {
    if (!_open) {
      return Center(
        child: GlassButton(
          label: '重新打开',
          variant: GlassButtonVariant.ghost,
          onPressed: () => setState(() => _open = true),
        ),
      );
    }
    final AylaLiveViewerSheetData data = switch (_which) {
      0 => const AylaLiveViewerSheetData(), // 骨架
      1 => const AylaLiveViewerSheetData(
        viewers: <AylaLiveViewerItem>[],
        count: 0,
      ), // 空态
      _ => const AylaLiveViewerSheetData(error: '暂时读不到在看名单'), // 503
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          spacing: AylaSpacing.sp2,
          children: <Widget>[
            for (int i = 0; i < _names.length; i += 1)
              GlassButton(
                label: _names[i],
                variant: i == _which
                    ? GlassButtonVariant.glow
                    : GlassButtonVariant.ghost,
                onPressed: () => setState(() => _which = i),
              ),
          ],
        ),
        const SizedBox(height: AylaSpacing.sp2),
        Expanded(
          child: AylaLiveViewerSheet(
            preview: const <AylaLiveViewerItem>[],
            data: data,
            onClose: () => setState(() => _open = false),
            titleOverride: switch (_which) {
              0 => '正在观看 · 5 人',
              1 => '正在观看 · 0 人',
              _ => '正在观看',
            },
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

/// 在看观众条 + 名单弹层。
@Preview(
  group: 'Widgets',
  name: '在看观众条 + 名单弹层',
  size: Size(960, 1900),
  wrapper: previewTheme,
)
Widget aylaLiveViewersPreview() => aylaLiveViewersSamples();
