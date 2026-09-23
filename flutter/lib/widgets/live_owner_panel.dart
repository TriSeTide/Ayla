/// live 域第五批（B2-5）之二：开播控制台资料与开播区。
///
/// ## 事实源（逐条对应 web，禁自由发挥）
/// ```
/// components/live/LiveOwnerPanel.tsx 217 行
/// app.css 3831–3843  .live-owner-panel：padding sp4 · --glass-bg · 1px 亮边 · radius-card 16 ·
///                    --glass-shadow · **column flex + gap sp3** · blur24 sat1.4 ·
///                    transition（box-shadow/border-color/translate 500ms auroraqua-duration）
/// live.css 168      .live-owner-panel { padding: var(--sp-3) }  ← **后加载覆写 padding sp4 ⇒ 实为 sp3**
/// live.css 169      .live-owner-settings：flex · align-items center · gap sp2
/// live.css 170      .live-owner-fields：flex 1 · min-width 0 · flex · align-items center · gap sp2
/// live.css 171      .live-title-input：min-height 32 · **width 200** · flex-shrink 0 · padding-block sp1
/// live.css 172      .live-desc-input：min-height 32 · flex 1 · padding-block sp1
/// live.css 176/177  .live-owner-start（column · stretch · center · gap sp1 · flex-shrink 0 ·
///                    **min-width 96**）/ -start-btn（width 100% · min-height 40 · padding-block sp1）
/// live.css 179–187  .live-owner-visibility：column · gap sp1 · width 100% · min-width 0 ·
///                    **padding sp3** · **border-top 1px --glass-border** · 透明底 · radius-input
/// live.css 190–192  （≤768）.live-owner-visibility { padding: sp2 }
/// live.css 241–257  （≤768）settings flex-wrap + gap sp2 · fields `1 1 calc(100% - 88px - sp2)`
///                    + column + gap sp2 · title/desc width 100% + flex none · start row +
///                    `flex-basis: 100%` + min-width 0 · start-btn `flex: 1`
/// live.css 260–269  （769–1100）settings flex-wrap + align-items flex-start · fields `1 1 180px`
///                    + column · title/desc width 100% · start `flex: 1 1 100%` + row ·
///                    start-btn `flex: 1` + min-width 0
/// live.css 173–174  .live-cover-picker（与 LiveCreate 共用：96 → ≤768 88 / 1px dashed ice-500 /
///                    radius-input / --glass-bg / overflow hidden）+ **`.live-cover-preview-img`
///                    { width/height 100% · object-fit: cover }**（本件 **确实带类名** ⇒ cover 生效）
/// live.css 175      .live-cover-empty { font-size: 12px }
/// app.css 3473–3477 .live-form-error：destructive 13 + margin-top sp2
/// auroraqua 57/75/87  .live-cover-picker 在**按钮组**内 ⇒ 组过渡 200ms + hover 1.02 + active .98
/// tsx 22–38         状态初值：title/description/cover 来自 channel；
///                   可见性 = 后端单值 + `allowed_group_ids.length > 0` ⇒ group 勾选
/// tsx 74–114        保存：`title.trim()` 空 ⇒ 「标题不能为空」；换封面则先上传；
///                   成功后**用后端回显**刷新封面与可见范围（后端可能规范化 allowed_group_ids）
/// tsx 40–72/173–191 开播/下播：busy 期禁用；失败文案「操作失败」；store/会话活动同步属页面
/// tsx 195/207       「保存」在 `savingSettings || busy` 时禁用；文案「保存中…」
/// ```
///
/// ## 挂载点（与 LiveCreate 不同，本件是**真实挂载**的）
/// `LiveRoomBody.tsx:498–520` 在 `showOwnerPanel` 时渲染本件（宽屏主区顶部 / 窄屏控制台流内）。
///
/// ## 与 web 的装配差异（组件不写页面）
/// - `run(action)` 里的 store 同步（`setCurrentChannel` / `setMediaActivity` / 会话活动
///   upsert/clear / `upsertChannel`）属数据层 ⇒ 只暴露 [onStart] / [onStop]；
/// - 上传与 `updateLiveChannel` 由页面注入（[onSave]）：组件把编辑态打包成请求，页面回传
///   **后端快照**，组件据此刷新封面与可见范围（对齐 tsx 100–108 的回显语义）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../core/media/media_actions.dart';
import '../core/media/media_picker.dart' show AylaPickedFile;
import '../core/media/media_upload.dart' show AylaUploadException;
import '../theme/app_theme.dart';
import '../theme/buttons.dart';
import '../theme/glass.dart';
import '../theme/preview_theme.dart';
import '../theme/tokens.dart';
import 'dashed_border.dart';
import 'directory_controls.dart' show AylaVisibilitySelector, VisibilitySelection;
import 'live_channel_snapshot.dart';
import 'live_hall.dart' show AylaLiveStatus;
import 'resource_image.dart';

/// 保存资料请求（web `updateLiveChannel(id, {...})` 的正文）。
class AylaLiveOwnerSaveRequest {
  const AylaLiveOwnerSaveRequest({
    required this.title,
    required this.description,
    required this.visibility,
    required this.allowedGroupIds,
    this.coverFile,
  });

  final String title;
  final String description;

  /// 后端单值：`public` / `friends` / `group`（tsx 89）。
  final String visibility;
  final List<String> allowedGroupIds;

  /// 换封面时的待上传文件（null = 不改封面，沿用现值）。
  final AylaPickedFile? coverFile;
}

/// 开播控制台资料与开播区（`LiveOwnerPanel.tsx` 217 行）。
class AylaLiveOwnerPanel extends StatefulWidget {
  const AylaLiveOwnerPanel({
    super.key,
    required this.channel,
    this.onStart,
    this.onStop,
    this.onSave,
    this.pickCover,
    this.groups = const <({String id, String title})>[],
    this.groupsLoading = false,
  });

  /// 当前频道快照（页面持；保存成功后由页面更新并回传后端快照）。
  final AylaLiveChannelSnapshot channel;

  /// 开播（web `startLiveChannel`；store 同步由页面做）。
  final Future<void> Function()? onStart;

  /// 下播（web `stopLiveChannel`）。
  final Future<void> Function()? onStop;

  /// 保存资料：页面负责上传封面 + 调 `updateLiveChannel`，**返回后端快照**用于回显。
  final Future<AylaLiveChannelSnapshot?> Function(
    AylaLiveOwnerSaveRequest request,
  )? onSave;

  /// 选封面（默认 `AylaMediaActions.pickImage()`；null = 用户取消）。
  final Future<AylaPickedFile?> Function()? pickCover;

  /// 可见范围用的群列表（透传 [AylaVisibilitySelector]）。
  final List<({String id, String title})> groups;

  /// 群列表是否加载中。
  final bool groupsLoading;

  @override
  State<AylaLiveOwnerPanel> createState() => _AylaLiveOwnerPanelState();
}

class _AylaLiveOwnerPanelState extends State<AylaLiveOwnerPanel> {
  late TextEditingController _title;
  late TextEditingController _description;

  AylaPickedFile? _coverFile;
  String? _coverPreview;
  late VisibilitySelection _visibility;
  late List<String> _selectedGroupIds;

  bool _saving = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.channel.title);
    _description = TextEditingController(text: widget.channel.description);
    _coverPreview = widget.channel.cover;
    _resetVisibilityFrom(widget.channel);
  }

  @override
  void didUpdateWidget(covariant AylaLiveOwnerPanel old) {
    super.didUpdateWidget(old);
    // 频道切换（切台）：整块表单按新频道重置（web 里组件随 channel 重挂载）
    if (old.channel.id != widget.channel.id) {
      _title.text = widget.channel.title;
      _description.text = widget.channel.description;
      _coverFile = null;
      _coverPreview = widget.channel.cover;
      _resetVisibilityFrom(widget.channel);
      _error = null;
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    super.dispose();
  }

  /// tsx 30–37 / 102–108：后端单值 + 白名单群 ⇒ 多选档。
  void _resetVisibilityFrom(AylaLiveChannelSnapshot channel) {
    final bool hasGroups = channel.allowedGroupIds.isNotEmpty;
    _visibility = VisibilitySelection(
      isPublic: channel.visibility == 'public',
      friends: channel.visibility == 'friends',
      group: hasGroups,
    );
    _selectedGroupIds = List<String>.of(channel.allowedGroupIds);
  }

  Future<void> _pickCover() async {
    try {
      final AylaPickedFile? file =
          await (widget.pickCover?.call() ?? AylaMediaActions.pickImage());
      if (!mounted || file == null) return;
      setState(() {
        _error = null;
        _coverFile = file;
        _coverPreview = file.path;
      });
    } on AylaUploadException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  /// 开播 / 下播（tsx 40–72）：busy 期禁用，失败「操作失败」。
  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on Object {
      if (mounted) setState(() => _error = '操作失败');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 保存资料（tsx 74–114）。
  Future<void> _save() async {
    final String next = _title.text.trim();
    if (next.isEmpty) {
      setState(() => _error = '标题不能为空'); // tsx 76–79
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final AylaLiveChannelSnapshot? updated = await widget.onSave?.call(
        AylaLiveOwnerSaveRequest(
          title: next,
          description: _description.text.trim(),
          visibility: _visibility.isPublic
              ? 'public'
              : (_visibility.friends ? 'friends' : 'group'),
          allowedGroupIds: _selectedGroupIds,
          coverFile: _coverFile,
        ),
      );
      if (!mounted) return;
      setState(() {
        _coverFile = null;
        if (updated != null) {
          // tsx 99–108：用后端回显刷新封面与可见范围（后端可能规范化 allowed_group_ids）
          _coverPreview = updated.cover;
          _resetVisibilityFrom(updated);
        }
      });
    } on Object catch (e) {
      if (mounted) {
        setState(() => _error = e is AylaUploadException
            ? e.message
            : '保存直播间资料失败');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final double width = MediaQuery.sizeOf(context).width;
    final bool narrow = width <= 768;

    return Container(
      // `.live-owner-panel`：padding **sp3**（live.css 168 覆写 app.css 的 sp4）·
      // --glass-bg + blur24 sat1.4 · 1px 亮边 · radius 16 · --glass-shadow · column gap sp3
      padding: const EdgeInsets.all(AylaSpacing.sp3),
      decoration: BoxDecoration(
        color: AylaColors.glassBg,
        border: Border.all(color: AylaColors.glassBorder),
        borderRadius: BorderRadius.circular(AylaRadii.rCard),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        spacing: AylaSpacing.sp3, // gap: var(--sp-3)
        children: <Widget>[
          _settings(narrow: narrow),
          _visibilityBlock(narrow: narrow),
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
    );
  }

  /// `.live-owner-settings` —— 封面 | 字段 | 开播与保存。
  ///
  /// ⚠️ **用户 2026-09-22 定稿版式（有意偏离 web）**：web 是三档断点各一套（宽屏三件一行、
  /// ≤768/769–1100 用 `flex-wrap` + `flex-basis: 100%` 把按钮另起一行铺满）。用户逐轮看画布后给定：
  /// - **开播键移到「标题输入框下面的空位」**（不再与保存堆在右列）；
  /// - **封面等比加宽**（96 → 160，16:9 ⇒ 高 90），"把右边的元素挤一点过去"；
  /// - 右侧只剩**保存键并铺满整列高**（= 标题 68 + gap sp1 + 开播 40 = 112）；
  /// - 宽屏/中屏同构；**窄屏（≤768）保持原堆叠**（封面 88 + 字段成列 + 右列两键竖排），
  ///   因为 160 宽的封面在 420 视口里会把字段挤没。
  Widget _settings({required bool narrow}) {
    if (narrow) {
      return Row(
        spacing: AylaSpacing.sp2,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _coverPicker(narrow: true),
          Expanded(child: _fieldsStacked()),
          _startColumn(),
        ],
      );
    }
    final Widget startKey = _startButton(); // 开播/下播（96×40）
    return Row(
      spacing: AylaSpacing.sp2, // gap: var(--sp-2)
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _coverPicker(narrow: false), // 160 × 90（16:9 等比加宽）
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            spacing: AylaSpacing.sp1, // gap: var(--sp-1)
            children: <Widget>[
              // 第一行：标题（固定宽，按内容自然高）+ 介绍（吃满剩余，高 68 可换行）
              Row(
                spacing: AylaSpacing.sp2,
                crossAxisAlignment: CrossAxisAlignment.start, // 标题与介绍**上沿对齐**
                // ⚠️ 介绍自带 `Expanded`（`.live-desc-input { flex: 1 }`）——不要再包一层
                //（双 Expanded 会触发 ParentDataWidget 断言，实测）
                children: <Widget>[_titleField(), _descField()],
              ),
              // 第二行：**标题输入框下面的空位** = 开播键（与标题**同宽同左缘**）
              SizedBox(width: _titleWidth, child: startKey),
            ],
          ),
        ),
        // 右列：保存键铺满整列高（用户 2026-09-22）
        SizedBox(
          width: _keyWidth,
          child: _saveButton(minHeight: _rightColumnHeight),
        ),
      ],
    );
  }

  // ======================= 尺寸常量（含用户 2026-09-22 校准） =======================

  /// 宽/中屏字段高度（**用户三轮校准定稿 = 铺满整行**）。
  ///
  /// web 原值：`.live-title-input` / `.live-desc-input { min-height: 32px }`。
  /// 用户依次要求「改高一些、对齐」（40）→ 54（封面高）→「**加高啊，铺满啊**」（画框下沿落在行底）
  /// ⇒ 定稿为**字段列第一行的高**：标题/介绍都取 68（= 开播 40 + `gap sp1` + 保存 24 的自然高）。
  /// 窄屏档仍按 web 的 32（用户明确「仅宽屏的」）。
  static const double _wideFieldHeight = _startBlockHeight;

  /// 窄屏档右列两键的自然高（开播 40 + `gap sp1` + 保存 24）= 68；也是宽屏字段高的来源。
  static const double _startBlockHeight = 40 + AylaSpacing.sp1 + 24;

  /// 宽/中屏**右列「保存」铺满**的高度 = 字段列总高：标题 68 + `gap sp1` 4 + 开播 40 = **112**。
  static const double _rightColumnHeight = 68 + AylaSpacing.sp1 + 40;

  /// 开播/保存两键的宽度（`.live-owner-start { min-width: 96px }` 的实值）。
  static const double _keyWidth = 96;

  /// 标题输入框宽度（`.live-title-input { width: 200px }`）。
  /// 用户 2026-09-22 定稿：**开播键与标题同宽同左缘**（画框指定，解决「按钮歪了、小了」）。
  static const double _titleWidth = 200;

  /// 宽/中屏封面宽度：96 → **160**（用户 2026-09-22：「等比例拉啊，加宽呗，把右边的元素挤一点过去」），
  /// 16:9 ⇒ 高 90。窄屏档仍 88（live.css 249）。
  static const double _coverWidthWide = 160;

  /// `.live-cover-picker`（live.css 173–175；按钮组成员 ⇒ hover 1.02 / active .98）。
  Widget _coverPicker({required bool narrow}) {
    final String? preview = _coverPreview;
    return AylaPressScale(
      semanticLabel: preview == null ? '设置直播间封面' : '更换直播间封面', // tsx 124
      onTap: () => unawaited(_pickCover()),
      child: SizedBox(
        // 窄屏 88（live.css 249）；宽/中屏 **160**（用户 2026-09-22 等比加宽）
        width: narrow ? 88 : _coverWidthWide,
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AylaRadii.rInput),
            child: AylaDashedBorder(
              radius: AylaRadii.rInput,
              color: AylaColors.ice500, // `border: 1px dashed var(--ice-500)`
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: AylaColors.glassBg,
                  borderRadius: BorderRadius.circular(AylaRadii.rInput),
                ),
                child: preview == null
                    ? Center(
                        child: Text(
                          '封面', // tsx 129
                          style: AylaTextStyles.of(context).body.copyWith(
                            fontSize: 12, // `.live-cover-empty { font-size: 12px }`
                            color: AylaColors.textSecondary,
                          ),
                        ),
                      )
                    // ⚠️ 本件 tsx 127 **确实**带 `live-cover-preview-img` 类 ⇒
                    // live.css 174 的 `object-fit: cover` 生效（与 LiveCreate 的死规则不同）
                    : ResourceImage(
                        src: preview,
                        alt: '当前直播间封面', // tsx 127
                        fit: BoxFit.cover,
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 标题输入（宽屏：固定 200 宽 × 68 高；窄屏：100% 宽 × 32 高）。
  Widget _titleField() => _input(
    controller: _title,
    placeholder: '直播间标题', // tsx 156
    ariaLabel: '直播间标题',
    maxLength: 128,
    width: _titleWidth, // `.live-title-input { width: 200px; flex-shrink: 0 }`
    expandInRow: false,
    height: _wideFieldHeight,
  );

  /// 介绍输入（**多行**，用户 2026-09-22：「标题仍然单行，介绍支持换行」）。
  Widget _descField() => _input(
    controller: _description,
    placeholder: '直播间介绍（可选）', // tsx 165
    ariaLabel: '直播间介绍',
    maxLength: 2000,
    width: null,
    expandInRow: true, // `.live-desc-input { flex: 1 }`
    height: _wideFieldHeight,
    multiline: true,
  );

  /// 窄屏（≤768）档：字段成列（web `flex-direction: column` + `width: 100%; flex: none`）。
  Widget _fieldsStacked() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    spacing: AylaSpacing.sp2,
    children: <Widget>[
      _input(
        controller: _title,
        placeholder: '直播间标题',
        ariaLabel: '直播间标题',
        maxLength: 128,
        width: null,
        expandInRow: false,
        height: 32, // web `.live-title-input { min-height: 32px }`
      ),
      _input(
        controller: _description,
        placeholder: '直播间介绍（可选）',
        ariaLabel: '直播间介绍',
        maxLength: 2000,
        width: null,
        expandInRow: false,
        height: 32,
        multiline: true,
      ),
    ],
  );

  /// `.field` 族输入（auroraqua 502–517 同一族；本件两个输入都在 `.live-owner-fields` 内）。
  ///
  /// [height]：**只对多行（介绍）生效** —— 用户 2026-09-22 定稿：介绍要是「很高的输入框」且可换行
  /// （默认 68）；**标题保持单行按内容自然高**（≈ web `.live-title-input` 的 `min-height: 32px`，
  /// 用户随后要求「标题输入框还原」）。
  Widget _input({
    required TextEditingController controller,
    required String placeholder,
    required String ariaLabel,
    required int maxLength,
    required double? width,
    required bool expandInRow,
    double height = 68,
    /// 是否多行（用户 2026-09-22：「标题仍然单行，介绍支持换行」）。
    bool multiline = false,
  }) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    // 高度：`null` = **按内容自然高**（web `.live-title-input { min-height: 32px }` 的实渲染，
    // 文字 22.5 + `padding-block: sp1` + 1px 边 ≈ 32）——用户 2026-09-22：「**标题输入框还原**」。
    // ⚠️ 不要给单行框硬塞 `SizedBox(height: 68)`：`InputDecorator` 会按内容自算高度并在盒子里
    //    **顶部收起/裁切**提示文字（实测：盒子 68、填充块 ~30，用户截图里标题被裁坏）；
    //    想给死高就必须把垂直内沿算成 `(h - lineHeight) / 2`，而那样单行的观感也不对。
    final Widget textField = TextField(
      controller: controller,
      // 单行（标题）：内容垂直居中（等价 web 的 `align-items: center`）；
      // 多行（介绍）：内容**顶对齐**并允许换行 —— 用户 2026-09-22 明确
      // 「标题仍然单行，介绍支持换行」（web 那边两个都是单行 `<input>`，属用户裁决的偏离）。
      textAlignVertical: multiline
          ? TextAlignVertical.top
          : TextAlignVertical.center,
      maxLines: multiline ? null : 1,
      minLines: multiline ? 3 : 1,
      keyboardType: multiline ? TextInputType.multiline : TextInputType.text,
      maxLength: maxLength,
      style: t.body.copyWith(color: AylaColors.textPrimary),
      cursorColor: AylaColors.glow500,
      decoration: InputDecoration(
        isDense: true,
        counterText: '',
        hintText: placeholder,
        hintStyle: t.body.copyWith(color: AylaColors.slate500), // ::placeholder
        filled: true,
        fillColor: AylaColors.glassBg,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AylaSpacing.sp3, // 同字段族 padding sp2 sp3 的横向（sp3）
          vertical: AylaSpacing.sp1, // `padding-block: var(--sp-1)`
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AylaRadii.rInput),
          borderSide: const BorderSide(color: AylaColors.glassBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AylaRadii.rInput),
          borderSide: const BorderSide(color: AylaColors.glow500),
        ),
      ),
    );
    // 高度：多行（介绍）给**固定高**（默认 68，用户 2026-09-22「很高的输入框」+ 可换行）；
    // 单行（标题）**不给高度** ⇒ 按内容自然高（web `.live-title-input { min-height: 32px }`）。
    final Widget field = multiline
        ? SizedBox(height: height, child: textField)
        : textField;
    final Widget labelled = Semantics(label: ariaLabel, child: field);
    if (width != null) {
      return SizedBox(width: width, child: labelled); // `.live-title-input { width: 200px }`
    }
    // ⚠️ 两条实测坑：
    // ① `Semantics(child: Expanded(...))` 会触发 ParentDataWidget 断言（Expanded 必须直接在 Flex 下）；
    // ② 只有**宽屏行内**才用 `Expanded`——窄屏/中屏那档字段改列（纵向无界）⇒ 用 Expanded 会报
    //    「non-zero flex but incoming height constraints are unbounded」。
    return expandInRow ? Expanded(child: labelled) : labelled;
  }

  /// 开播/下播主键（`.live-owner-start-btn`：`.btn` 基础度量 + glow/ghost）。
  Widget _startButton() {
    final bool live = widget.channel.status == AylaLiveStatus.live;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 40), // `.live-owner-start-btn { min-height: 40px }`
      child: GlassButton(
        label: live ? '下播' : '开播', // tsx 180/189
        // tsx 176/185：开播 = `.btn.btn-glow`；下播 = **裸 `.btn`**。
        // ⚠️ web 的裸 `.btn`（app.css 21–34）只有盒模型/字体，**没有任何底/边/阴影**（仅 ::after 扫光）
        // —— 用户 2026-09-22 裁决「**当 web 的 bug**」⇒ 用库内 `ghost` 档给回玻璃面。
        variant: live ? GlassButtonVariant.ghost : GlassButtonVariant.glow,
        expand: true,
        onPressed: _busy
            ? null
            : (live
                  ? (widget.onStop == null
                        ? null
                        : () => unawaited(_run(widget.onStop!)))
                  : (widget.onStart == null
                        ? null
                        : () => unawaited(_run(widget.onStart!)))),
      ),
    );
  }

  /// 保存键（`.msg-action-btn`）。宽屏/中屏铺满整列高（用户 2026-09-22 校准）。
  Widget _saveButton({double? minHeight}) => AylaMsgActionButton(
    label: _saving ? '保存中…' : '保存', // tsx 198
    // 用户校准：宽度与开播键对齐（96）；宽/中屏再铺满整列高
    minWidth: _keyWidth,
    minHeight: minHeight,
    onPressed: (_saving || _busy) ? null : () => unawaited(_save()),
  );

  /// 窄屏档的右列：开播 + 保存竖排（96 宽；web ≤768 的 `flex-direction: column` 档）。
  Widget _startColumn() => SizedBox(
    width: _keyWidth,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      spacing: AylaSpacing.sp1, // gap: var(--sp-1)
      children: <Widget>[_startButton(), _saveButton()],
    ),
  );

  /// `.live-owner-visibility`（live.css 179–187 + ≤768 padding sp2）。
  Widget _visibilityBlock({required bool narrow}) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(
        narrow ? AylaSpacing.sp2 : AylaSpacing.sp3, // ≤768 → sp2
      ),
      decoration: BoxDecoration(
        color: Colors.transparent,
        border: const Border(
          top: BorderSide(color: AylaColors.glassBorder), // border-top 1px
        ),
        borderRadius: BorderRadius.circular(AylaRadii.rInput),
      ),
      child: AylaVisibilitySelector(
        value: _visibility,
        onChange: (VisibilitySelection next) =>
            setState(() => _visibility = next),
        selectedGroupIds: _selectedGroupIds,
        onSelectedGroupIdsChange: (List<String> ids) =>
            setState(() => _selectedGroupIds = ids),
        groups: widget.groups,
        groupsLoading: widget.groupsLoading,
        initialGroupId: widget.channel.group, // tsx 210 `initialGroupId={channel.group}`
      ),
    );
  }
}

// ======================= 预览样张 =======================

/// 控制台资料栏样张（可交互：改标题/介绍、切可见范围、「保存」看回显、开播/下播切换）。
Widget aylaLiveOwnerPanelSamples() {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      _Stage(
        viewport: const Size(1240, 480),
        label:
            '控制台资料栏（`LiveOwnerPanel`，**非换行档 >1100**）· 卡 padding **sp3**（live.css 168 覆写 app.css 的 sp4）+ --glass-bg + blur24 + radius 16 + gap sp3 · 行 = 封面 96×16:9（虚线冰蓝，本件**带** preview 类 ⇒ cover 生效）| 标题 200 固定 + 介绍 flex 1 | 开播(glow)+保存 竖排 min-width 96 · 可见范围块（padding sp3 + 上边框）· 可交互：改标题后「保存」→ 回显',
        child: const _OwnerPanelDemo(),
      ),
      const SizedBox(height: AylaSpacing.sp6),
      _Stage(
        viewport: const Size(900, 480),
        label: '中屏档（**769–1100**，侧栏会压缩控制台余宽）：与宽屏同构——封面 | 字段（改列）| 按钮 96 宽竖排，**按钮不另起一行**（用户 2026-09-22 裁决）· 在播态：主键变「下播」（**无辉光** `.btn`）· 可见范围初值由频道快照推导（public/friends + 白名单群）',
        child: const _OwnerPanelDemo(live: true),
      ),
      const SizedBox(height: AylaSpacing.sp6),
      _Stage(
        viewport: const Size(420, 560),
        label: '窄屏档（≤768）：封面 88 + 字段改列 + 按钮仍 96 宽竖排同行 · 可见范围 padding sp2',
        child: const _OwnerPanelDemo(),
      ),
      const SizedBox(height: AylaSpacing.sp6),
      _Stage(
        viewport: const Size(1240, 480),
        label: '空标题点「保存」→ 「标题不能为空」（destructive 13 + margin-top sp2）；保存中 → 「保存中…」且禁用',
        child: const _OwnerPanelDemo(emptyTitle: true),
      ),
    ],
  );
}

class _OwnerPanelDemo extends StatefulWidget {
  const _OwnerPanelDemo({this.live = false, this.emptyTitle = false});

  final bool live;
  final bool emptyTitle;

  @override
  State<_OwnerPanelDemo> createState() => _OwnerPanelDemoState();
}

class _OwnerPanelDemoState extends State<_OwnerPanelDemo> {
  late AylaLiveChannelSnapshot _channel = AylaLiveChannelSnapshot(
    id: 'lc1',
    title: widget.emptyTitle ? '' : '深夜电台 · 爱莉陪你写代码',
    description: '聊聊今天的实现细节',
    cover: 'sample://cover',
    status: widget.live ? AylaLiveStatus.live : AylaLiveStatus.idle,
    visibility: 'friends',
    allowedGroupIds: const <String>['g1'],
    group: 'g1',
  );
  @override
  Widget build(BuildContext context) {
    return AylaLiveOwnerPanel(
      channel: _channel,
      onStart: () async => setState(
        () => _channel = _copyWith(status: AylaLiveStatus.live),
      ),
      onStop: () async => setState(
        () => _channel = _copyWith(status: AylaLiveStatus.idle),
      ),
      onSave: (AylaLiveOwnerSaveRequest request) async {
        // 样张：延迟 600ms 让「保存中…」可见（真实由组件内部态驱动）
        await Future<void>.delayed(const Duration(milliseconds: 600));
        if (!mounted) return null;
        final AylaLiveChannelSnapshot updated = AylaLiveChannelSnapshot(
          id: _channel.id,
          title: request.title,
          description: request.description,
          cover: _channel.cover,
          status: _channel.status,
          visibility: request.visibility,
          allowedGroupIds: request.allowedGroupIds,
          group: _channel.group,
        );
        setState(() => _channel = updated);
        // 让「保存中…」可见：返回前先渲染一帧 busy 态
        return updated;
      },
      groups: const <({String id, String title})>[
        (id: 'g1', title: '爱莉的群'),
        (id: 'g2', title: '第二个群'),
      ],
    );
  }

  AylaLiveChannelSnapshot _copyWith({AylaLiveStatus? status}) =>
      AylaLiveChannelSnapshot(
        id: _channel.id,
        title: _channel.title,
        description: _channel.description,
        cover: _channel.cover,
        status: status ?? _channel.status,
        visibility: _channel.visibility,
        allowedGroupIds: _channel.allowedGroupIds,
        group: _channel.group,
      );
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

/// 控制台资料栏。
@Preview(
  group: 'Widgets',
  name: '控制台资料栏',
  size: Size(960, 1300),
  wrapper: previewTheme,
)
Widget aylaLiveOwnerPanelPreview() => aylaLiveOwnerPanelSamples();
