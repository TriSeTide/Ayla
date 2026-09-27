/// CreateSheet —— FAB 创建浮层（`layout/CreateSheet.tsx` 1–61 + `private.css` 185–275）。
///
/// ## 事实源
/// ```
/// tsx:39–44   .create-sheet-overlay { position:fixed; inset:0; z-index:70;
///               display:flex; align-items:center; justify-content:center;
///               padding: var(--sp-4); background: rgba(70,91,146,.25) }
/// …（逐条 CSS 对照 / 层叠推导**原文**见 `docs/flutter/17-组件文件头归档（整理前原文）.md` 的 `widgets/shell/create_sheet.dart` 一节）
/// ```
///
/// ## 复用（材质与交互一件都不新写）
/// - 容器：[AylaModalOverlay]（遮罩 + 居中/贴底定位）+ [AylaModalCard]
///   （`--glass-bg-strong` / blur24 sat1.4 / 1px 亮边 / radius-panel / modal 阴影 /
///   窄屏上滑 250ms / reduced-motion）；
/// - 标题行：[AylaSheetHead]（与 [AylaConfirmDialog] 同规格，web 两处 head 完全一致）；
/// - 关闭钮：[AylaIconButton]（= `.icon-btn-40`）；
/// - ESC：`Shortcuts + Actions(DismissIntent) + FocusScope(autofocus)` ——
///   范本 = `share.dart` 的 [AylaShareSheet]（同族 portal 弹层，写法照抄）。
///
/// ## `className` 的等价映射（tsx:26–27）
/// web 的 `className?: string` 追加到卡片根类名，供调用方覆盖尺寸/内部滚动；
/// 唯一用例是 `live.css:1214–1221 / 1315–1325` 的 `.live-viewer-sheet-card`
/// （窄屏 60vh 名单弹层：`flex column` + head `flex:none` + body 自滚）。
/// Flutter 没有 CSS 类名 → 用 [maxHeight] / [narrowHeightFactor] / [scrollable] /
/// [narrowRadius] 透传到 [AylaModalCard] 的**既有**参数，表达同一件事。
///
/// ## 不在本件范围（登记，避免被当成漏项）
/// - `private.css:229–238` 是**卡片作用域内的表单样式**
///   （`.create-sheet-card .voice-create-input` / `.game-room-create .field` 宽 100% +
///   `margin-bottom: sp3`；`.create-sheet-card .btn-primary:not(.post-editor-submit)`
///   宽 100% 居中）→ 归属**表单组件自身**（VoiceChannelCreate=B1、GameRoomCreate=B4
///   待做）。Flutter 没有后代选择器，本容器也不该替它们定宽；
/// - `z-index: 70`：Flutter 侧层级由 Overlay / Stack 的**插入顺序**决定
///   （web 注释：抽屉层 70–80 低于 `.create-sheet-overlay(70)`，二次确认要盖在其上
///   —— 见 `group.css:2134`）。页面层接线时按该顺序插入；
/// - 同容器的 `GroupCreateDialog`（`.group-create-dialog`，B6 待做）可直接复用本件
///   的 head / overlay / card 三件。
///
/// ## 公开面
/// `AylaCreateSheet`

library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;

import '../../theme/tokens.dart';
import '../base/dialogs.dart';

/// FAB 创建浮层容器（`layout/CreateSheet.tsx`）。
///
/// 只负责「遮罩 + 卡片 + 标题行 + 关闭语义」；`child` 由调用方给出对应场景的创建表单
/// （web `CreateFab.tsx:75–114`：建群走 GroupCreateDialog 自带浮层，语音/直播/发帖/桌游
/// 才包在本浮层里）。
///
/// **无状态**：web 本件也没有内部状态（仅一条 `useEffect` 挂 ESC 监听），
/// 开合由调用方的 `open` 状态控制。
class AylaCreateSheet extends StatelessWidget {
  const AylaCreateSheet({
    super.key,
    required this.title,
    required this.onClose,
    required this.child,
    this.maxHeight,
    this.narrowHeightFactor,
    this.scrollable = true,
    this.narrowRadius = 24,
  });

  /// 标题（= web `action.label`，如 `shellConfig.ts:256` 的「发帖」）。
  final String title;

  /// 关闭回调（ESC / 遮罩 / 关闭钮三条路径都走它）。
  final VoidCallback onClose;

  /// 表单内容（web `{children}`）。
  final Widget child;

  /// 宽屏最大高度，默认 `80vh`（`.create-sheet-card { max-height: 80vh }`）。
  final double? maxHeight;

  /// 窄屏按视口比例取高（web `className` 覆写档，如名单弹层 0.6 = 60vh）；
  /// null = 与宽屏一样用 [maxHeight]。
  final double? narrowHeightFactor;

  /// 内容整体是否可滚（`.create-sheet-card { overflow-y: auto }` → true；
  /// className 档里 head 固定、body 自滚的形态传 false）。
  final bool scrollable;

  /// 窄屏顶部圆角（`.create-sheet-card` 窄屏 = `24px 24px 0 0`）。
  final double narrowRadius;

  @override
  Widget build(BuildContext context) {
    final Size vp = MediaQuery.of(context).size;
    return Shortcuts(
      // web `document.addEventListener("keydown")`：ESC → onClose
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          DismissIntent: CallbackAction<DismissIntent>(
            onInvoke: (DismissIntent intent) {
              onClose();
              return null;
            },
          ),
        },
        // 让 ESC 作用于弹层自身（`autofocus` 把焦点收进本作用域）
        child: FocusScope(
          autofocus: true,
          child: Semantics(
            // tsx:47–48 `role="dialog" aria-label={title}`
            scopesRoute: true,
            explicitChildNodes: true,
            label: title,
            child: AylaModalOverlay(
              // 点遮罩关闭（卡内点击由 AylaModalOverlay 拦住，等价 tsx:41–43）
              onDismiss: onClose,
              // `.create-sheet-overlay { padding: var(--sp-4) }` = 16px
              // ⚠️ 必须显式传：AylaModalOverlay 的默认值是 24（privacy 那一档）
              padding: AylaSpacing.sp4,
              child: AylaModalCard(
                // `.create-sheet-card { max-height: 80vh }`
                maxHeight: maxHeight ?? vp.height * 0.8,
                narrowHeightFactor: narrowHeightFactor,
                narrowRadius: narrowRadius,
                // `.create-sheet-card { overflow-y: auto }`
                scrollable: scrollable,
                // `.create-sheet-card { padding: var(--sp-4) }`
                // 窄屏 `padding-bottom: calc(var(--sp-4) + env(safe-area-inset-bottom))`
                padding: EdgeInsets.fromLTRB(
                  AylaSpacing.sp4,
                  AylaSpacing.sp4,
                  AylaSpacing.sp4,
                  AylaSpacing.sp4 + MediaQuery.of(context).padding.bottom,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    AylaSheetHead(
                      title: title,
                      onClose: onClose,
                      // `CreateSheet.tsx:53`：`<IconClose width={20} height={20} />`
                      closeIconSize: 20,
                    ),
                    child,
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
