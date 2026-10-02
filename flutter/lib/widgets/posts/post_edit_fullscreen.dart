/// AylaPostEditFullscreen —— 帖子详情页的**编辑态全屏面板**（覆盖帖子界面整页）。
///
/// ## 事实源（web 逐条，文件:行）
/// 结构与文案 —— `Ayla/web/src/pages/PostDetailPage.tsx:497–599`：
/// - `498` `div.post-edit-fullscreen[role=dialog][aria-modal=true][aria-label=编辑帖子]`；
/// - `499–512` `header.post-edit-head`：`500` `.icon-btn-40` 取消键
///   （`aria-label=取消编辑`、`title=取消`、`disabled={savingEdit}`）+
///   `IconBack` **22** · `503` `span.post-edit-title` 文案「编辑帖子」 ·
///   `504–511` `.btn.btn-primary.post-edit-save`（`507`
///   `disabled={savingEdit || editUploading || !editBody.trim()}`、`510` 文案
///   「保存中…」/「重新发布」）；
/// - `513–597` `div.post-edit-body`：`515–523` 标题 `input.field`
///   （`520` `maxLength={128}`、`521` placeholder「标题（必填）」、
///   `522` `aria-label=帖子标题`）· `524–531` 正文
///   `textarea.field.post-edit-body-input`（`528` `rows={6}`、
///   `529` placeholder「正文（必填）」、`530` `aria-label=帖子正文`）·
///   `533–584` 媒体块 · `586–593` `VisibilitySelector`（**由调用方注入**）·
///   `594`/`595` 两条 `p.post-editor-error[role=alert]`；
/// - `514` `fieldset disabled={savingEdit}`（内联 `display: contents`，不产盒）；
/// - `536–551` `.post-editor-image-btn` 添加键（`536`
///   `aria-label=添加图片或视频`、`537` `IconImage` 18、`538` 文案「添加」、
///   `544` `disabled={savingEdit || editUploading || editImages.length >= 9}`）；
/// - `553–583` 媒体网格（`554` `aria-label=「已添加 {n} 个媒体」`；
///   每格 `556` `.post-editor-image` + `557–570` 媒体元素四分支 +
///   `571–579` `.post-editor-image-remove`（`574` `aria-label=移除媒体`、
///   `575` `disabled={savingEdit || editUploading}`、`578` `×`））。
///
/// 样式 —— `Ayla/web/src/styles/posts.css`：
/// - `806–813` `.post-edit-fullscreen`（`position:absolute; inset:0; z-index:50;`
///   `display:flex; flex-direction:column;` + 入场动画）；
/// - `815–824` `@keyframes post-edit-in`（`opacity 0→1` + `translateY(8px→0)`）；
/// - `915–919` `@media (prefers-reduced-motion: reduce) { .post-edit-fullscreen { animation:none } }`；
/// - `826–836` `.post-edit-head`（`flex:none; display:flex; align-items:center; gap: sp3;`
///   `padding: sp2 sp4;` `background: --glass-bg;`
///   `backdrop-filter: blur(18px) saturate(1.4);`
///   `border-bottom: 1px solid --glass-border`）；
/// - `838–844` `.post-edit-title`（`flex:1;` Display `18px / 600 / --text-primary`）；
/// - `846–849` `.post-edit-save { flex:none; min-width: 72px }`；
/// - `851–863` `.post-edit-body`（`flex:1 1 auto; min-height:0; overflow-y:auto;`
///   `display:flex; flex-direction:column; gap: sp3; padding: sp4;`
///   `width:100%; max-width:680px; margin:0 auto`）；
/// - `865–868` `.post-edit-body .field { width:100%; box-sizing:border-box }`；
/// - `870–873` `.post-edit-body-input { resize: vertical; min-height: 120px }`；
/// - `876–879` `.post-edit-media`（flex column）· `881–886` `-media-head`
///   （center + `justify-content: space-between` + `gap: sp2`）· `888–892`
///   `-media-label`（`13px / 600 / --text-secondary`）· `894–899`
///   `-media-grid`（wrap + `gap: sp2` + `margin-top: sp2`）· `902–907`
///   `.post-edit-media-el`（宽高 100% + `object-fit: cover`）；
/// - `268–284` `.post-editor-image`（`width:128px; aspect-ratio:1; overflow:hidden;`
///   `1px --glass-border;` `background: --glass-bg;` ——
///   `border-radius: var(--radius-md)` 全库无该变量 ⇒ 该声明在 computed-value 阶段失效、
///   回落初始值 **0（方角）**）；
/// - `378–389` `.post-editor-image-remove`（`top/right: sp1;` 28×28、
///   `border-radius: pill`、`background: --glass-bg-strong;` `color: --text-primary`）；
/// - `398–414` `.post-editor-image-btn`（`min-height:40px; inline-flex; align-items:center;`
///   `gap: sp1; padding: 0 sp3;` `1px --glass-border;`
///   `border-radius: --radius-input;` `color: --text-primary;`
///   `:hover, :focus-within` → `border-color: --glow-500` +
///   `box-shadow: --glow-shadow`）；
/// - `373–376` `.post-editor-error { font-size: 13px; color: --destructive }`；
/// - `701–707` `.post-detail { position: relative }`（**面板 absolute 的包含块**）；
/// - `798–801` `.post-detail.is-editing > .post-detail-background
///   { visibility: hidden; pointer-events: none }`。
///
/// 公共件承载的覆写（不在本件重写）：
/// - 取消键 `.icon-btn-40` → `AylaIconButton`（`auroraqua.css:124–166` 材质与 200ms 组）；
/// - 保存键 `.btn.btn-primary` → `AylaGlassButton(variant: primary)`（`app.css:43–46`）；
/// - 添加键 = `.post-editor-image-btn` 的 ghost 档 + `glowHover`（`auroraqua.css:58–139`）；
/// - 标题/正文字段 `.field` → `AylaGlassInput`（`app.css:70–88` + `auroraqua.css:502–518`）；
/// - `title="取消"` → `AylaTooltip`（web 的原生 title 无 CSS 可移植，见该件文件头）；
/// - 入场动画 `post-edit-in` → `AylaRevealItem`（同一「opacity + 位移」配方）。
///
/// ## 公开面
/// `AylaPostEditFullscreen` · 样张 `aylaPostEditFullscreenSamples()`
///
/// ## 与 web 的机制差异（登记）
/// 1. **absolute 面板的包含块**：web 用 `position:absolute; inset:0`（posts.css 807–808），
///    参照系是 `.post-detail{position:relative}`（706–707）⇒ 面板**只在帖子界面内**，
///    不覆盖顶部导航/底栏。Flutter 无 position 体系 ⇒ 本件是**面板本体**，由调用方放进
///    详情壳的 `Stack` 并用 `Positioned.fill` 表达 `inset:0`
///    （= 与 `.post-detail` 同尺寸）；导航/底栏在更外层 ⇒ 语义一致。
///    ⚠️ 内部 `Expanded` 要求宿主给**有界高度**。
/// 2. **`inert` 的 Flutter 等价**：web 编辑时给三个 `.post-detail-background`
///    （head / scroll / composer，tsx `444`/`602`/`710`）加 `inert` +
///    `aria-hidden`，并靠 `.post-detail.is-editing > .post-detail-background
///    { visibility:hidden }` 只透出页面背景。这两件事属**宿主**（库内
///    `AylaPostDetailChrome` 的 `_Background`：`Visibility(maintainSize: true)` +
///    `IgnorePointer` + `ExcludeSemantics`）——本件不含背景层、也不做焦点管理
///    （web 侧同样没有 focus trap）。
/// 3. **`fieldset disabled` 的等价**：web 的 `fieldset disabled={savingEdit}`（514）
///    连同**注入的 VisibilitySelector** 一起禁用 ⇒ 本件自有控件走 `enabled` /
///    回调置 null（与 web 的 `:disabled` 一一对应）；注入槽位无法统一 disable ⇒
///    用 `IgnorePointer(ignoring: saving)` 阻断交互（槽位自身的禁用视觉由调用方决定）。
/// 4. **媒体上传/回收未接线**（属页面接线，见 13 号 §4.3）：web 的选文件（536–551）、
///    三步上传（545–549 `uploadEditImages`）与回收（`removeEditImage` /
///    `cleanupNewEditImages`）都留在页面；本件只提供「添加」键与每格的 `×` 键回调，
///    媒体元素由调用方按自己的数据模型渲染（`mediaChildren`）；元素未接线时按
///    `mediaCount` 渲染**空底格壳** + 禁用移除键（= web 媒体未就绪时的玻璃空方格）。
/// 5. **`resize: vertical` 无等价物**：web textarea 允许用户拖高（870–873），Flutter 无该
///    手柄 ⇒ 固定 `rows={6}`（`minLines/maxLines = 6`）+ `min-height: 120px`
///    （与 `post_editor.dart` 对 `.post-editor-body` 的既有处理一致，登记不做自绘手柄）。
/// 6. **`maxLength` 的计数器**：`AylaGlassInput.maxLength` 会带 Flutter 字符计数器
///    （web 的 `<input maxLength={128}>` 不显示）⇒ 128 上限用
///    `LengthLimitingTextInputFormatter` 表达（与库内 create 表单同一处理）。
/// 7. `AylaGlassSurface` 恒绘 `--glass-inset`（顶沿 1px 内高光），而
///    `.post-edit-head`（826–836）未声明该属性 ⇒ 头部存在 1px 级高光差；为保持
///    「单材料 owner」不另起一套（与 `AylaPostDetailChrome` 对 `.post-detail-head`
///    的处理一致）。
/// 8. 媒体格壳（`.post-editor-image` + `-image-remove`）与 `post_editor.dart`
///    的 `_mediaBlock` **取值逐条一致、代码各一份**：该实现是私有的，本件按数值与结构
///    复刻（方角 128 / 28 圆键 / `--glass-bg-strong`），未做跨件抽公共（组件库改动需另行批准）。
/// 9. 入场动画复用库内唯一 owner `AylaRevealItem`（`Opacity` + `Transform.translate`
///    包住整块面板，含玻璃头）：web 的 keyframes 直接改透明度，Flutter 侧「整层 Opacity
///    套 `BackdropFilter`」在 Windows/Impeller 下有已知限制（另见 `AylaGlassSurface.dimAlpha`
///    的注释）—— 若 Windows 上出现「只位移不淡入」，这是唯一嫌疑点，**不要**在件内
///    自造第二套动画（与 `AylaPostDetailChrome` 头部同一处理）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show LengthLimitingTextInputFormatter, TextInputFormatter;

import '../../core/media/media_signer.dart' show MediaVariant;
import '../../core/models/post.dart' show AylaMediaDescriptor, AylaMediaKind;
import '../../theme/app_icons.dart';
import '../../theme/app_theme.dart';
import '../../theme/buttons.dart' show AylaIconButton;
import '../../theme/glass.dart'
    show
        AylaGlass,
        AylaGlassButton,
        AylaGlassButtonVariant,
        AylaGlassInput,
        AylaGlassSurface;
import '../../theme/sample_media.dart' show aylaEnableSampleMedia;
import '../../theme/tokens.dart';
import '../base/directory_controls.dart'
    show AylaVisibilitySelection, AylaVisibilitySelector;
import '../base/resource_image.dart' show AylaResourceImage;
import '../base/reveal.dart' show AylaRevealItem;
import '../base/tooltip.dart' show AylaTooltip;
import 'post_card.dart' show AylaPostVideoCover;

/// 帖子详情页的编辑态全屏面板。
///
/// **展示型组件**：两个输入控制器、媒体元素、可见性选择器与全部回调都由调用方持有；
/// 保存/取消只回调，不发请求（web 的 `saveEdit` / `cancelEdit` 在页面里）。
class AylaPostEditFullscreen extends StatefulWidget {
  const AylaPostEditFullscreen({
    super.key,
    required this.titleController,
    required this.bodyController,
    required this.onCancel,
    required this.onSave,
    this.saving = false,
    this.uploading = false,
    this.mediaCount,
    this.mediaChildren = const <Widget>[],
    this.onRemoveMedia,
    this.onAddMedia,
    this.visibilitySlot,
    this.mediaError,
    this.actionError,
  });

  /// 标题输入控制器（tsx 518 `value={editTitle}`：受控值由页面持有）。
  final TextEditingController titleController;

  /// 正文输入控制器（tsx 526 `value={editBody}`）。
  ///
  /// 保存键的可用性判定读的就是它（tsx 507 的 `!editBody.trim()`）—— 本件监听该控制器，
  /// 输入即刷新按钮状态，调用方无需为此 rebuild。
  final TextEditingController bodyController;

  /// 取消编辑（tsx 500 `onClick={cancelEdit}`；[saving] 时本件置为 disabled）。
  final VoidCallback onCancel;

  /// 重新发布（tsx 508 `onClick={saveEdit}`；空标题仍可提交，见 [bodyController]）。
  final VoidCallback onSave;

  /// 保存中（tsx 507/510/575：禁用保存键并换文案「保存中…」、禁用字段与移除键；
  /// tsx 500：取消键同样禁用）。
  final bool saving;

  /// 上传中（tsx 507/544/575：禁用保存键、添加键与移除键；**不**禁用字段 ——
  /// web 的 `fieldset disabled` 只看 `savingEdit`）。
  final bool uploading;

  /// 媒体总数 —— web 的三处都用这**同一个** `editImages.length`：`535` 计数文案
  /// 「{n}/9」、`544` 「>= 9」禁用添加键、`553` 「> 0」才渲染网格。
  ///
  /// null = 取 `mediaChildren.length`（已渲染媒体元素的场合无需重复传）。**媒体元素尚未
  /// 接线**（13 号 §4.3 登记项）时只传计数 ⇒ 每格渲染 `.post-editor-image` 的空底格壳
  /// （web 在媒体未就绪时同样是一个玻璃空方格，见 901–907 的注释）+ 禁用移除键。
  final int? mediaCount;

  /// 每格的**媒体元素**（tsx 555–570 的四个分支：新视频 `<video>` / 新图 `<img>` /
  /// 已有视频 `PostVideoCover` / 已有图 `ResourceImage`）——由调用方按其数据模型渲染，
  /// 下标与 [mediaCount] 一一对应；短于 [mediaCount] 的格子只渲染格壳（元素未接线）。
  ///
  /// 本件持有**格壳**（`.post-editor-image`：128 方角 + 亮边 + 右上 28 圆移除键）与
  /// **网格容器**（`.post-edit-media-grid`：wrap + `gap: sp2` + `margin-top: sp2`）；
  /// 元素自身须铺满格子（`.post-edit-media-el` 宽高 100% + `object-fit: cover`，
  /// tsx 902–907）—— 库内 `AylaResourceImage(fit: BoxFit.cover)` /
  /// `AylaPostVideoCover(fit: BoxFit.cover)` 即该档。
  final List<Widget> mediaChildren;

  /// 移除某个媒体（下标从 0 起；tsx 576 `onClick={() => removeEditImage(item)}`）。
  /// null ⇒ 移除键禁用（等价 `disabled`）。回收对象存储的清理属调用方。
  final ValueChanged<int>? onRemoveMedia;

  /// 选择并上传媒体（tsx 536–551 的 `<label>` + 隐藏 `<input type="file">`）。
  /// null ⇒ 添加键禁用；计数（[mediaCount] / `mediaChildren.length`）`>= 9` 或
  /// [saving]/[uploading] 时本件亦禁用。
  final VoidCallback? onAddMedia;

  /// 可见性选择器槽位（tsx 586–593 `VisibilitySelector`；真实调用方传
  /// `AylaVisibilitySelector`）。null ⇒ 该行不渲染。
  final Widget? visibilitySlot;

  /// 媒体错误行（tsx 594，页面 `editMediaError`，如 tsx 323「媒体上传失败，请重试」）。
  final String? mediaError;

  /// 操作错误行（tsx 595，页面 `actionError`，如 tsx 395「保存编辑失败」）。
  final String? actionError;

  @override
  State<AylaPostEditFullscreen> createState() => _AylaPostEditFullscreenState();
}

class _AylaPostEditFullscreenState extends State<AylaPostEditFullscreen> {
  @override
  void initState() {
    super.initState();
    widget.bodyController.addListener(_onBodyChanged);
  }

  @override
  void didUpdateWidget(covariant AylaPostEditFullscreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bodyController != widget.bodyController) {
      oldWidget.bodyController.removeListener(_onBodyChanged);
      widget.bodyController.addListener(_onBodyChanged);
    }
  }

  @override
  void dispose() {
    widget.bodyController.removeListener(_onBodyChanged);
    super.dispose();
  }

  /// tsx 507 的 `!editBody.trim()` 必须随输入即时生效（web 每次 `onChange`
  /// 都会重渲染）⇒ 本件监听正文控制器，而不是要求调用方额外传 `canSave`。
  /// 标题**不参与**该判定（507 里没有标题项 ⇒ 空标题可提交，与 PostEditor 的校验不同）。
  void _onBodyChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final bool reduced = MediaQuery.disableAnimationsOf(context);
    final bool busy = widget.saving || widget.uploading;
    // 535/544/553 读的是同一个计数：显式计数优先，否则由注入的媒体元素数量派生
    final int count = widget.mediaCount ?? widget.mediaChildren.length;
    // tsx 507：`savingEdit || editUploading || !editBody.trim()`
    final bool canSave = !busy && widget.bodyController.text.trim().isNotEmpty;

    // .post-edit-head（posts.css 826–836）
    final Widget head = AylaGlassSurface(
      // background: var(--glass-bg)（默认档，非 strong）
      blur: AylaGlass.blurNav, // backdrop-filter: blur(18px) saturate(1.4)（833–834）
      shadow: const <BoxShadow>[], // 826–836 未声明 box-shadow
      radiusOverride: BorderRadius.zero, // 整宽条、无圆角
      borderOverride: const Border(
        // border-bottom: 1px solid var(--glass-border)（835）
        bottom: BorderSide(color: AylaColors.glassBorder),
      ),
      // padding: var(--sp-2) var(--sp-4)（831）
      padding: const EdgeInsets.symmetric(
        horizontal: AylaSpacing.sp4,
        vertical: AylaSpacing.sp2,
      ),
      child: Row(
        spacing: AylaSpacing.sp3, // gap: var(--sp-3)（830）
        children: <Widget>[
          AylaTooltip(
            message: '取消', // tsx 500 title="取消"（原生提示，无 CSS 可移植）
            child: AylaIconButton(
              // tsx 501：<IconBack width={22} height={22} />
              icon: AylaIcon(aylaIconByName('iconBack')!, size: 22),
              // tsx 500 disabled={savingEdit}
              onPressed: widget.saving ? null : widget.onCancel,
              semanticLabel: '取消编辑', // tsx 500 aria-label="取消编辑"
            ),
          ),
          Expanded(
            // .post-edit-title { flex: 1 }（839）
            child: Text(
              '编辑帖子', // tsx 503
              style: const TextStyle(
                // 838–844：--font-display / 18px / 600 / --text-primary
                fontFamily: AylaFonts.display,
                fontFamilyFallback: AylaFonts.cjkFallback,
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: AylaColors.textPrimary,
              ),
            ),
          ),
          AylaGlassButton(
            // .btn.btn-primary（tsx 506）+ .post-edit-save { min-width: 72px }（846–849）
            label: widget.saving ? '保存中…' : '重新发布', // tsx 510
            minWidth: 72,
            onPressed: canSave ? widget.onSave : null, // tsx 507
          ),
        ],
      ),
    );

    final Widget titleField = AylaGlassInput(
      controller: widget.titleController,
      hintText: '标题（必填）', // tsx 521
      semanticLabel: '帖子标题', // tsx 522 aria-label="帖子标题"
      // tsx 520 maxLength={128}：用 formatter 表达（AylaGlassInput.maxLength 会带计数器）
      inputFormatters: <TextInputFormatter>[
        LengthLimitingTextInputFormatter(128),
      ],
      enabled: !widget.saving, // fieldset disabled={savingEdit}（514）
      // .field 无 font-size 声明 ⇒ 继承 body（t.body 自带 CJK 回退链）
      textStyle: t.body.copyWith(color: AylaColors.textPrimary),
    );

    final Widget bodyField = AylaGlassInput(
      controller: widget.bodyController,
      hintText: '正文（必填）', // tsx 529
      semanticLabel: '帖子正文', // tsx 530 aria-label="帖子正文"
      minHeight: 120, // .post-edit-body-input { min-height: 120px }（872）
      // tsx 528 rows={6}：固定 6 行（web 的 textarea 内容不自动增高，只滚内部）
      minLines: 6,
      maxLines: 6,
      enabled: !widget.saving,
      textStyle: t.body.copyWith(color: AylaColors.textPrimary),
    );

    final List<Widget> rows = <Widget>[
      titleField, // tsx 515–523
      bodyField, // tsx 524–531
      _media(t: t, count: count, busy: busy), // tsx 533–584
      if (widget.visibilitySlot != null)
        // fieldset disabled 对注入槽位的等价物（见文件头差异 3）
        IgnorePointer(
          ignoring: widget.saving,
          child: widget.visibilitySlot!,
        ),
      if (widget.mediaError case final String mediaError)
        _errorRow(t, mediaError), // tsx 594
      if (widget.actionError case final String actionError)
        _errorRow(t, actionError), // tsx 595
    ];

    // .post-edit-body（851–863）：flex 1 1 auto / min-height 0 / overflow-y auto
    final Widget body = Expanded(
      child: SingleChildScrollView(
        // width:100%; max-width:680px; margin:0 auto（859–861）
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: Padding(
              padding: const EdgeInsets.all(AylaSpacing.sp4), // padding: var(--sp-4)（858）
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch, // .field { width:100% }（866）
                spacing: AylaSpacing.sp3, // gap: var(--sp-3)（857）
                children: rows,
              ),
            ),
          ),
        ),
      ),
    );

    return Semantics(
      // role="dialog" aria-modal="true" aria-label="编辑帖子"（tsx 498）
      // ⚠️ Flutter 断言：scopesRoute: true 必须同时 explicitChildNodes: true
      scopesRoute: true,
      namesRoute: true,
      explicitChildNodes: true,
      label: '编辑帖子',
      child: AylaRevealItem(
        fadeGlass: false,
        // animation: post-edit-in var(--dur-fast) var(--ease-out)（812）
        // keyframes 815–824：opacity 0→1 + translateY(8px→0)
        enabled: !reduced, // 915–919：prefers-reduced-motion ⇒ animation: none
        offset: const Offset(0, 8),
        duration: AylaDurations.fast, // --dur-fast 180ms
        curve: AylaCurves.easeOut, // --ease-out cubic-bezier(.22,.61,.36,1)
        child: Column(
          // .post-edit-fullscreen { display:flex; flex-direction:column }（810–811）
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            head, // flex: none（827）
            body, // flex: 1 1 auto（852）
          ],
        ),
      ),
    );
  }

  /// .post-edit-media（876–899）+ .post-editor-image-btn（398–414）。
  Widget _media({
    required AylaTextStyles t,
    required int count,
    required bool busy,
  }) {
    // tsx 544：disabled={savingEdit || editUploading || editImages.length >= 9}
    final VoidCallback? onAdd = (!busy && count < 9) ? widget.onAddMedia : null;
    return Column(
      // .post-edit-media { display:flex; flex-direction:column }（877–878）
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          // .post-edit-media-head：align-items:center + justify-content:space-between
          // + gap: var(--sp-2)（882–885）—— 标签左、添加键右，sp2 为最小间隔
          spacing: AylaSpacing.sp2,
          children: <Widget>[
            Expanded(
              child: Text(
                '图片/视频 $count/9', // tsx 535
                style: t.caption.copyWith(
                  // .post-edit-media-label：13px / 600 / --text-secondary（889–891）
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AylaColors.textSecondary,
                ),
              ),
            ),
            AylaGlassButton(
              label: '添加', // tsx 538
              // tsx 537：<IconImage width={18} height={18} />
              icon: AylaIcon(aylaIconByName('iconImage')!, size: 18),
              variant: AylaGlassButtonVariant.ghost, // .post-editor-image-btn 的玻璃档
              glowHover: true, // 398–414：hover/focus-within → glow 边 + --glow-shadow
              minHeight: 40, // min-height: 40px（399）
              // padding: 0 var(--sp-3)（403）；.btn 的 gap 8 = 图标与文字间距（402）
              padding: const EdgeInsets.symmetric(horizontal: AylaSpacing.sp3),
              onPressed: onAdd,
              semanticLabel: '添加图片或视频', // tsx 536 aria-label="添加图片或视频"
            ),
          ],
        ),
        if (count > 0) // tsx 553：{editImages.length > 0 && …}
          Padding(
            padding: const EdgeInsets.only(top: AylaSpacing.sp2), // margin-top: sp2（898）
            child: Semantics(
              label: '已添加 $count 个媒体', // tsx 554 aria-label（web 模板串）
              container: true,
              child: Wrap(
                // .post-edit-media-grid { flex-wrap: wrap; gap: var(--sp-2) }（895–897）
                spacing: AylaSpacing.sp2,
                runSpacing: AylaSpacing.sp2,
                children: <Widget>[
                  for (int i = 0; i < count; i += 1) _mediaTile(i, busy: busy),
                ],
              ),
            ),
          ),
      ],
    );
  }

  /// 一格媒体：.post-editor-image（268–284）+ .post-editor-image-remove（378–389）。
  ///
  /// 取值与 `post_editor.dart` 的 `_mediaBlock` 逐条一致（见文件头差异 8）。
  Widget _mediaTile(int index, {required bool busy}) {
    return SizedBox(
      width: 128, // width: 128px（271）
      height: 128, // aspect-ratio: 1（272）
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: AylaColors.glassBg, // background: var(--glass-bg)（276）
                border: Border.all(color: AylaColors.glassBorder), // 1px --glass-border（274）
              ),
              // overflow: hidden（273）+ 方角（web 的 --radius-md 未定义 ⇒ 回落 0）。
              // 元素未注入（媒体未接线）时留空底 ⇒ 与 web「媒体未就绪」的空方格同形。
              child: index < widget.mediaChildren.length
                  ? ClipRect(child: widget.mediaChildren[index])
                  : null,
            ),
          ),
          Positioned(
            top: AylaSpacing.sp1, // top: var(--sp-1)（380）
            right: AylaSpacing.sp1, // right: var(--sp-1)（381）
            child: Opacity(
              // base.css 343–346：button:disabled { opacity: .55 }
              opacity: busy ? 0.55 : 1,
              child: Semantics(
                button: true,
                label: '移除媒体', // tsx 574 aria-label="移除媒体"
                // `.post-editor-image-remove` 是 <button>（posts.css:378–389 cursor: pointer）；
                // disabled 档（savingEdit / editUploading）⇒ base.css:343 not-allowed。
                child: MouseRegion(
                  cursor: busy
                      ? SystemMouseCursors.forbidden
                      : SystemMouseCursors.click,
                  child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  // tsx 575：disabled={savingEdit || editUploading}
                  onTap: (busy || widget.onRemoveMedia == null)
                      ? null
                      : () => widget.onRemoveMedia!(index),
                  child: Container(
                    width: 28, // width: 28px（382）
                    height: 28, // height: 28px（383）
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(
                      color: AylaColors.glassBgStrong, // --glass-bg-strong（386）
                      shape: BoxShape.circle, // border-radius: var(--radius-pill)（385）
                    ),
                    child: const Text(
                      '×', // tsx 578
                      style: TextStyle(
                        fontFamily: AylaFonts.body,
                        fontFamilyFallback: AylaFonts.cjkFallback,
                        fontSize: 16,
                        height: 1,
                        color: AylaColors.textPrimary, // color: var(--text-primary)（387）
                      ),
                    ),
                  ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// .post-editor-error（373–376）+ role="alert"（tsx 594/595）。
  Widget _errorRow(AylaTextStyles t, String message) {
    return Semantics(
      liveRegion: true, // role="alert"
      child: Text(
        message,
        style: t.caption.copyWith(
          fontSize: 13, // font-size: 13px（374）
          color: AylaColors.destructive, // color: var(--destructive)（375）
        ),
      ),
    );
  }
}

// ======================= 预览与样张 =======================

/// 全屏编辑面板样张三档（组件**单一来源**）。
///
/// 1. **默认档**：标题 + 正文 + 媒体 2 格（1 图 + 1 视频）+ 可见性选择器；
/// 2. **`saving: true`**：取消键 / 保存键（文案「保存中…」）/ 两个字段 / 添加键 /
///    移除键全部禁用（对照 tsx 500 / 507 / 510 / 514 / 544 / 575）；
/// 3. **失败档**：`mediaError` + `actionError` 两条 `role=alert` 行
///    （文案取自页面：tsx 323 / 395），顺序与 tsx 594–595 一致。
///
/// 样张**可交互**（每档自带「最近操作」日志）：取消 / 保存 / 添加 / 移除都只写日志，
/// **不接上传与请求**；清空正文可看到保存键转禁用（tsx 507 的 `!editBody.trim()`，
/// 空标题仍可提交）。媒体元素按 tsx 557–570 的分支用库内件表达（已有图 =
/// `AylaResourceImage`、已有视频 = `AylaPostVideoCover`）；新上传档的本地文件
/// 预览属调用方数据模型，样张不接。
List<Widget> aylaPostEditFullscreenSamples() {
  // 预览/画布：媒体存储链路未落地，启用程序生成的示例图（生产默认关闭）
  aylaEnableSampleMedia();
  return const <Widget>[
    _PostEditFullscreenSample(
      label: '默认档（舞台 900×620 · 标题 + 正文 + 2 格媒体 + 可见性选择器）',
    ),
    _PostEditFullscreenSample(
      label: '保存中（saving:true · 取消/保存/字段/添加/移除 全禁用 · 保存键「保存中…」）',
      saving: true,
    ),
    _PostEditFullscreenSample(
      label: '失败档（mediaError + actionError 两条 role=alert 行）',
      failing: true,
    ),
  ];
}

/// 单档舞台：标签 + 最近操作日志 + 900×620 的面板宿主。
class _PostEditFullscreenSample extends StatefulWidget {
  const _PostEditFullscreenSample({
    required this.label,
    this.saving = false,
    this.failing = false,
  });

  /// 档位标题。
  final String label;

  /// `saving: true` 档（全档禁用）。
  final bool saving;

  /// 失败档（两条错误行 + 1 格媒体）。
  final bool failing;

  @override
  State<_PostEditFullscreenSample> createState() =>
      _PostEditFullscreenSampleState();
}

class _PostEditFullscreenSampleState extends State<_PostEditFullscreenSample> {
  static const List<({String id, String title})> _groups =
      <({String id, String title})>[
    (id: 'g1', title: '深夜电台'),
    (id: 'g2', title: '星海观测站'),
  ];

  /// tsx 561–562 的「已有视频」分支：descriptor.kind == 'video' → PostVideoCover。
  static const AylaMediaDescriptor _video = AylaMediaDescriptor(
    mediaId: 'v-1',
    kind: AylaMediaKind.video,
    thumbnail: '/api/v1/media/v-1/thumbnail',
  );

  final TextEditingController _title = TextEditingController(text: '今晚的歌单');
  final TextEditingController _body =
      TextEditingController(text: '把今晚想听的歌都写在这里，欢迎点歌。');

  AylaVisibilitySelection _visibility =
      const AylaVisibilitySelection(isPublic: true);
  List<String> _selectedGroupIds = const <String>['g1'];
  String _log = '—';

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  void _say(String what) => setState(() => _log = what);

  @override
  Widget build(BuildContext context) {
    // tsx 564–569：已有图 → ResourceImage（thumbnail 优先 + variant thumb）
    final List<Widget> media = <Widget>[
      const AylaResourceImage(
        src: '/api/v1/media/m-1/thumbnail',
        alt: '',
        variant: MediaVariant.thumb,
        fit: BoxFit.cover,
      ),
      const AylaPostVideoCover(media: _video, fit: BoxFit.cover),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      spacing: AylaSpacing.sp2,
      children: <Widget>[
        Text(widget.label, style: const TextStyle(fontSize: 11)),
        Text('最近操作：$_log', style: const TextStyle(fontSize: 12)),
        SizedBox(
          // 面板是 inset:0 的绝对定位本体（posts.css 806–813）：画布用固定舞台表达
          // 详情页尺寸；真实装配 = 详情壳 Stack 里的 Positioned.fill。
          width: 900,
          height: 620,
          child: AylaPostEditFullscreen(
            titleController: _title,
            bodyController: _body,
            saving: widget.saving,
            // 失败档保留 1 格（计数行读作 1/9），另两档 2 格
            mediaChildren: widget.failing ? media.take(1).toList() : media,
            onRemoveMedia: (int index) {
              final int n = index + 1;
              _say('移除媒体 #$n（样张不接回收）');
            },
            onAddMedia: () => _say('添加媒体（样张不接上传）'),
            visibilitySlot: AylaVisibilitySelector(
              value: _visibility,
              onChange: (AylaVisibilitySelection v) =>
                  setState(() => _visibility = v),
              selectedGroupIds: _selectedGroupIds,
              onSelectedGroupIdsChange: (List<String> ids) =>
                  setState(() => _selectedGroupIds = ids),
              groups: _groups,
            ),
            mediaError: widget.failing ? '媒体上传失败，请重试' : null, // tsx 323
            actionError: widget.failing ? '保存编辑失败' : null, // tsx 395
            onCancel: () => _say('取消编辑'),
            onSave: () {
              final String title = _title.text.trim();
              _say('保存编辑「$title」');
            },
          ),
        ),
      ],
    );
  }
}
