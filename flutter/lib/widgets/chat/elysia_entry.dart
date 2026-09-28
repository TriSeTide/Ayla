/// 爱莉入口卡（`components/chat/ElysiaEntry.tsx` 的 Flutter 等价）。
///
/// ## 事实源
///
/// | 本文件 | web |
/// |---|---|
/// | [AylaElysiaEntry] | `ElysiaEntry.tsx:11–31` |
/// | 卡片材质/尺寸 | app.css 435–478（`.elysia-entry` 及名/副标题/箭头） |
/// | 窄屏辉光降 30% | app.css 3195–3200（`@media (max-width: 768px)` 里 `.elysia-entry:hover` → `0 0 11px rgba(247,150,255,.32)`） |
///
/// 视觉：樱粉渐变底 + grape 字 + 爱莉专属光环（辉光归属爱莉身份，design.md §2）。
/// `display_name` 仅 UI 展示 —— **前端不生成爱莉的第一人称内容**（AGENTS.md §4.1）。
///
/// ## 公开面
/// `AylaElysiaEntry` · 样张 `aylaElysiaEntrySamples()`

library;

import 'package:flutter/material.dart';

import '../../core/models/elysia_profile.dart';
import '../../theme/tokens.dart';
import '../base/avatar_halo.dart';

/// 会话列表顶部的爱莉入口卡。
class AylaElysiaEntry extends StatefulWidget {
  const AylaElysiaEntry({
    super.key,
    required this.profile,
    required this.onEnter,
  });

  final AylaElysiaProfile profile;

  /// 点击进入与爱莉的私聊会话（导航属页面层，未注入时卡片仍渲染）。
  final VoidCallback? onEnter;

  @override
  State<AylaElysiaEntry> createState() => _AylaElysiaEntryState();
}

class _AylaElysiaEntryState extends State<AylaElysiaEntry> {
  bool _hovered = false;

  /// `.elysia-entry { background: linear-gradient(135deg, --sakura-100, --sakura-300) }`
  /// （app.css 444）。
  static const LinearGradient _background = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: <Color>[AylaColors.sakura100, AylaColors.sakura300],
  );

  /// `.elysia-entry { border: 1px solid rgba(247,150,255,.5) }`（app.css 445）。
  static const Color _borderColor = AylaColors.elysiaBubbleBorder;

  @override
  Widget build(BuildContext context) {
    final bool narrow = MediaQuery.sizeOf(context).width <= 768;
    final String name =
        widget.profile.displayName.trim().isEmpty ? '爱莉' : widget.profile.displayName;
    return GestureDetector(
      onTap: widget.onEnter,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Semantics(
          button: true,
          label: '$name，${widget.profile.enabled ? '在线，与她聊天' : '已停用'}',
          child: AnimatedContainer(
            // web `transition: box-shadow 180ms var(--ease-out)`（app.css 447–449）
            duration: AylaDurations.fast,
            curve: AylaCurves.easeOut,
            width: double.infinity,
            padding: const EdgeInsets.all(AylaSpacing.sp3),
            decoration: BoxDecoration(
              gradient: _background,
              borderRadius: BorderRadius.circular(AylaRadii.rCard),
              border: Border.all(color: _borderColor),
              // hover → `--glow-shadow`；窄屏降 30%（app.css 3195–3200）
              boxShadow: _hovered
                  ? (narrow ? AylaShadows.glowNarrow : AylaShadows.glow)
                  : null,
            ),
            child: Row(
              children: <Widget>[
                AylaAvatarHalo(
                  label: name,
                  size: 40,
                  online: widget.profile.enabled,
                  core: AylaAvatarCore.elysia,
                ),
                const SizedBox(width: AylaSpacing.sp3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        // `.elysia-entry-name`：Fredoka 15/500 + grape-700（app.css 461–466）
                        style: const TextStyle(
                          fontFamily: AylaFonts.display,
                          fontFamilyFallback: AylaFonts.cjkFallback,
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: AylaColors.grape700,
                        ),
                      ),
                      Text(
                        widget.profile.enabled ? '在线 · 与她聊天' : '已停用',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        // `.elysia-entry-sub`：13 + grape-700 + opacity .8（app.css 468–472）
                        style: const TextStyle(
                          fontFamily: AylaFonts.body,
                          fontFamilyFallback: AylaFonts.cjkFallback,
                          fontSize: 13,
                          color: AylaColors.grape700,
                        ).copyWith(
                          color: AylaColors.grape700.withValues(alpha: 0.8),
                        ),
                      ),
                    ],
                  ),
                ),
                // `.elysia-entry-arrow`：margin-left auto + grape-700 + 18px（app.css 474–478）
                const Text(
                  '›',
                  style: TextStyle(
                    fontFamily: AylaFonts.body,
                    fontFamilyFallback: AylaFonts.cjkFallback,
                    fontSize: 18,
                    color: AylaColors.grape700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ======================= 样张 =======================

/// 爱莉入口卡样张：启用 / 停用两态。
Widget aylaElysiaEntrySamples() {
  return Padding(
    padding: const EdgeInsets.all(AylaSpacing.sp6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        AylaElysiaEntry(
          profile: const AylaElysiaProfile(
            id: 1,
            displayName: '爱莉',
            enabled: true,
            userId: 'elysia',
          ),
          onEnter: () {},
        ),
        const SizedBox(height: AylaSpacing.sp4),
        AylaElysiaEntry(
          profile: const AylaElysiaProfile(
            id: 1,
            displayName: '爱莉',
            enabled: false,
            userId: 'elysia',
          ),
          onEnter: () {},
        ),
      ],
    ),
  );
}
