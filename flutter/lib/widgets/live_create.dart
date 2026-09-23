/// live 域第五批（B2-5）之一：建直播间表单 + 推流指引一次性回显。
///
/// ## 事实源（逐条对应 web，禁自由发挥）
/// ```
/// components/live/LiveCreate.tsx 189 行
/// tsx 88            .live-create —— 类名**零 CSS 命中**（无样式）
/// tsx 89–143        .live-create-form：app.css 3401–3404 `flex` + `gap sp2`，
///                   **被 live.css 32 后加载覆写**为 `flex-direction: column` + `align-items: stretch`
/// tsx 90–99         标题：placeholder「给直播间起个标题」· maxLength 128
/// tsx 100–109       介绍：placeholder「告诉观众这场直播聊什么（可选）」· maxLength 2000 ·
///                   `.live-create-textarea { min-height: 72px; resize: vertical }`（live.css 165）
/// tsx 110–110       <VisibilitySelector>（群内默认勾本群但**不锁定**；群外默认公开）
/// tsx 111–134       封面字段：`.live-cover-field`（flex column · gap sp1）+ `.live-cover-picker`
///                   （**96 宽 / 16:9 / flex-shrink 0 / 1px dashed --ice-500 / radius-input /
///                   --glass-bg / text-secondary / overflow hidden**；≤768 → **88 宽**，live.css 249）
///                   + 隐藏 file input；`validateImageFile` 不通过 ⇒ 只报错、不接受文件
/// tsx 135–142       提交键 `.btn.btn-glow`：「开播」→「准备中…」（**不是**「创建中…」）
/// tsx 45–75         提交：`title.trim()` 空 ⇒ 「标题不能为空」**不发请求**；先传封面
///                   （`uploadMediaFile(file,"image")` → `mediaContentUrl(media_id)`）；
///                   成功 ⇒ `setCreated` + 清空标题 + `onCreated(channel)`；失败 ⇒ `message` / 「创建失败」
/// tsx 146–186       推流指引 `.live-create-guide`（app.css 3421–3442：margin-top sp3 · padding sp3 ·
///                   **--glass-bg-strong** · 1px 亮边 · radius-card 16 · column gap sp2）+
///                   `.live-create-guide-title`（**Fredoka / text-primary，无 font-size ⇒ 继承 body 15px**）
///                   + `.live-create-guide-notice`（**--warning 13px**）
///                   + 两行 `.live-copy-row`（**基础档**：--ice-100 + radius-sm 8）
///                   + `.live-guide-dismiss { align-self: flex-end }`（app.css 3469）「我已保存，关闭」
/// app.css 3406–3419 .live-create-input（flex 1 · padding sp2 sp3 · 1px 亮边 · radius-input ·
///                   --glass-bg · body 字）；`:focus { box-shadow: var(--focus-ring) }`
///                   ⚠️ **该声明无效**：`--focus-ring` = `2px solid #f796ff`，`solid` 在 box-shadow 里非法
///                   ⇒ 浏览器丢弃；实际生效的是 auroraqua 513–517（outline none +
///                   border-color --glow-500 + box-shadow --glow-shadow）
/// auroraqua 502–531 字段族：--glass-bg + 1px 亮边 + radius-input + **--glass-inset** + blur24 sat1.4；
///                   ::placeholder → **--slate-500**
/// live.css 33       .live-create-input { width: 100%; box-sizing: border-box }
/// ```
///
/// ## ⚠️ 挂载点事实（照实登记，勿当成漏项）
/// web 全仓 **`<LiveCreate>` 零命中**（`grep -rn "<LiveCreate"` 无结果），vitest 也无它的用例：
/// 真实建播流程走 `ChannelSidebar.handleCreateNewLive` → `createLiveChannel("新直播间")` 后直接进控制台。
/// 本件属**孤儿件**（与 B1-4 `ElysiaVoicePanel` 同款），**组件画布是它唯一的视觉验收面**。
///
/// ## 与 web 的装配差异（组件不写页面）
/// - 上传与建频道由页面注入（[AylaLiveCreate.onCreate]）：web 在组件内直接调 `uploadMediaFile` +
///   `liveApi.createLiveChannel`，网络层不进 `lib/widgets`；
/// - 选图默认走 `AylaMediaActions.pickImage()`（内部已含 `validateImageFile` 校验，失败抛
///   `AylaUploadException(文案)` —— 与 web「只报错、不接受文件」同语义）；
/// - 用户 2026-09-22 裁决：封面预览**按 web 本意**用 `BoxFit.cover`（web 的 `<img>` 漏了
///   `live-cover-preview-img` 类名 ⇒ live.css 174 的 object-fit 是死规则，属 web 的 bug）。
library;

import 'dart:async';
import 'dart:io' show File;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter/widget_previews.dart';

import '../core/media/media_actions.dart';
import '../core/media/media_picker.dart' show AylaPickedFile;
import '../core/media/media_upload.dart' show AylaUploadException;
import '../theme/app_theme.dart';
import '../theme/buttons.dart';
import '../theme/glass.dart';
import '../theme/preview_theme.dart';
import '../theme/sample_media.dart' show aylaEnableSampleMedia;
import '../theme/tokens.dart';
import 'dashed_border.dart';
import 'directory_controls.dart' show AylaVisibilitySelector, VisibilitySelection;
import 'live_channel_snapshot.dart';
import 'live_hall.dart' show AylaLiveStatus;
import 'live_studio.dart' show AylaLiveCopyRow, obsServerFromRtmpUrl;

/// 提交建播请求的载荷（web `createLiveChannel(title, group, options)` 的三参）。
class AylaLiveCreateRequest {
  const AylaLiveCreateRequest({
    required this.title,
    required this.description,
    required this.visibility,
    required this.allowedGroupIds,
    this.coverFile,
    this.group,
  });

  final String title;
  final String description;

  /// 待上传的封面文件（web `coverFile`，tsx 55–58 先 `uploadMediaFile` 再取 `mediaContentUrl`）；
  /// null = 没换封面。**内容只在内存**，由页面注入的 [AylaLiveCreate.onCreate] 负责上传。
  final AylaPickedFile? coverFile;

  /// 后端单值：`public` / `friends` / `group`（tsx 60 的三元链）。
  final String visibility;
  final List<String> allowedGroupIds;
  final String? group;
}

/// 建直播间表单 + 推流指引（`LiveCreate.tsx` 189 行）。
///
/// **群内创建**（[group] 非空）初值为「仅本群可见」且自动勾选本群（**不锁定**，本群可取消）；
/// 群外初值为「公开」。
class AylaLiveCreate extends StatefulWidget {
  const AylaLiveCreate({
    super.key,
    required this.onCreate,
    this.onCreated,
    this.group,
    this.pickCover,
    this.onCopy,
    this.autoDismissGuide = false,
  });

  /// 建频道（页面实现：先上传封面再调 API）；抛错 = 失败（文案照 web 显示）。
  final Future<AylaLiveChannelSnapshot> Function(AylaLiveCreateRequest request)
      onCreate;

  /// 创建成功回调（web `onCreated(channel)`）。
  final ValueChanged<AylaLiveChannelSnapshot>? onCreated;

  /// 群内创建时的归属群 id（tsx 25；一级 tab 为 null）。
  final String? group;

  /// 选封面（默认 `AylaMediaActions.pickImage()`；null = 用户取消）。
  final Future<AylaPickedFile?> Function()? pickCover;

  /// 复制实现（默认系统剪贴板）。
  final Future<bool> Function(String text)? onCopy;

  /// 创建成功后自动收起指引（页面层可选用法；web 靠用户点「我已保存，关闭」）。
  final bool autoDismissGuide;

  @override
  State<AylaLiveCreate> createState() => _AylaLiveCreateState();
}

class _AylaLiveCreateState extends State<AylaLiveCreate> {
  final TextEditingController _title = TextEditingController();
  final TextEditingController _description = TextEditingController();

  late VisibilitySelection _visibility;
  late List<String> _selectedGroupIds;

  /// 待上传的封面文件（web `coverFile`；**内容只在内存**，交给页面注入的 onCreate 上传）。
  AylaPickedFile? _coverFile;
  String? _coverPreview;
  bool _creating = false;
  String? _error;
  AylaLiveChannelSnapshot? _created;
  String? _copied;

  @override
  void initState() {
    super.initState();
    // tsx 32–35：群内 → {group: true} + [group]；群外 → {public: true} + []
    final String? group = widget.group;
    _visibility = group != null
        ? const VisibilitySelection(isPublic: false, friends: false, group: true)
        : const VisibilitySelection(isPublic: true, friends: false, group: false);
    _selectedGroupIds = group != null ? <String>[group] : <String>[];
  }

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _pickCover() async {
    try {
      final AylaPickedFile? file = await (widget.pickCover?.call() ??
          AylaMediaActions.pickImage());
      if (!mounted || file == null) return; // 取消不是错误
      setState(() {
        _error = null;
        _coverFile = file;
        _coverPreview = file.path;
      });
    } on AylaUploadException catch (e) {
      // tsx 124–127：校验不通过 ⇒ 只报错、**不接受文件**
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _submit() async {
    final String trimmed = _title.text.trim();
    if (trimmed.isEmpty) {
      setState(() => _error = '标题不能为空'); // tsx 47–50：不发请求
      return;
    }
    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      final AylaLiveChannelSnapshot created = await widget.onCreate(
        AylaLiveCreateRequest(
          title: trimmed,
          description: _description.text.trim(),
          coverFile: _coverFile,
          // tsx 60：多选 → 后端单值（public → friends → group）
          visibility: _visibility.isPublic
              ? 'public'
              : (_visibility.friends ? 'friends' : 'group'),
          allowedGroupIds: _selectedGroupIds,
          group: widget.group,
        ),
      );
      if (!mounted) return;
      setState(() {
        _created = created;
        _title.clear(); // tsx 68
      });
      widget.onCreated?.call(created);
    } on Object catch (e) {
      if (mounted) {
        setState(() => _error = e is AylaUploadException ? e.message : '创建失败');
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _copy(String text, String which) async {
    final bool ok = await (widget.onCopy?.call(text) ?? _clipboard(text));
    if (!mounted) return;
    if (!ok) {
      setState(() => _error = '复制失败，请手动选择复制'); // tsx 83
      return;
    }
    setState(() {
      _copied = which;
      _error = null;
    });
    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 1500), () {
        if (mounted) setState(() => _copied = null);
      }),
    );
  }

  Future<bool> _clipboard(String text) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
      return true;
    } on Object {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _form(),
        if (_error case final String message) _errorBox(message),
        if (_created case final AylaLiveChannelSnapshot created) _guide(created),
      ],
    );
  }

  /// `.live-create-form`（live.css 32 覆盖 app.css 3401）。
  Widget _form() {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final bool narrow = Breakpoint.isNarrow(MediaQuery.sizeOf(context).width);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch, // align-items: stretch
      mainAxisSize: MainAxisSize.min,
      spacing: AylaSpacing.sp2, // app.css 的 gap: var(--sp-2) 保留
      children: <Widget>[
        _Labelled(
          label: '标题',
          child: _Field(
            controller: _title,
            placeholder: '给直播间起个标题', // tsx 94
            maxLength: 128, // tsx 96
          ),
        ),
        _Labelled(
          label: '介绍',
          child: _Field(
            controller: _description,
            placeholder: '告诉观众这场直播聊什么（可选）', // tsx 104
            maxLength: 2000, // tsx 106
            textarea: true,
          ),
        ),
        AylaVisibilitySelector(
          value: _visibility,
          onChange: (VisibilitySelection next) =>
              setState(() => _visibility = next),
          selectedGroupIds: _selectedGroupIds,
          onSelectedGroupIdsChange: (List<String> ids) =>
              setState(() => _selectedGroupIds = ids),
          initialGroupId: widget.group, // tsx 110 `initialGroupId={group}`
        ),
        _coverField(t, narrow),
        GlassButton(
          label: _creating ? '准备中…' : '开播', // tsx 141
          variant: GlassButtonVariant.glow,
          expand: true, // private.css 235：卡片作用域内 width 100%
          onPressed: _creating ? null : () => unawaited(_submit()),
        ),
      ],
    );
  }

  /// `.live-cover-field`（tsx 111–134 + live.css 166/173/249）。
  Widget _coverField(AylaTextStyles t, bool narrow) {
    final String? preview = _coverPreview;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      spacing: AylaSpacing.sp1, // gap: var(--sp-1)
      children: <Widget>[
        Text(
          '封面',
          style: t.body.copyWith(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: AylaColors.textPrimary,
          ),
        ),
        // `.live-cover-picker` 在 auroraqua **按钮组**内（57/75/87）⇒ 组过渡 200ms + hover 1.02 +
        // active .98 ⇒ 用库内 `AylaPressScale` 表达（与其它组成员一致）。
        AylaPressScale(
          semanticLabel: '选择封面',
          onTap: () => unawaited(_pickCover()),
          child: SizedBox(
            width: narrow ? 88 : 96, // ≤768 → 88（live.css 249）
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AylaRadii.rInput),
                child: AylaDashedBorder(
                  radius: AylaRadii.rInput,
                  color: AylaColors.ice500, // `1px dashed var(--ice-500)`
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: AylaColors.glassBg,
                      borderRadius: BorderRadius.circular(AylaRadii.rInput),
                    ),
                    child: Center(
                      child: preview == null
                          // ⚠️ tsx 114 的 `<span>` **没有** `.live-cover-empty` 类 ⇒ 12px 规则不生效，
                          // 文字继承面板字号（body 15px）——照实渲染。
                          ? Text(
                              '选择 16:9 封面图片',
                              textAlign: TextAlign.center,
                              style: t.body.copyWith(
                                fontSize: 15,
                                color: AylaColors.textSecondary,
                              ),
                            )
                          : Image.file(
                              // 用户 2026-09-22 裁决：按 web **本意**用 cover（web 的 img 漏类名，
                              // live.css 174 的 object-fit 是死规则 ⇒ 属 web 的 bug）
                              File(preview),
                              fit: BoxFit.cover,
                              width: double.infinity,
                              height: double.infinity,
                              errorBuilder: (_, _, _) => const SizedBox.shrink(),
                            ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// `.live-form-error`（app.css 3473–3477）。
  Widget _errorBox(String message) {
    return Padding(
      padding: const EdgeInsets.only(top: AylaSpacing.sp2),
      child: Text(
        message,
        style: AylaTextStyles.of(context).body.copyWith(
          fontSize: 13,
          color: AylaColors.destructive,
        ),
      ),
    );
  }

  /// `.live-create-guide`（tsx 146–186 + app.css 3421–3442）。
  Widget _guide(AylaLiveChannelSnapshot created) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final String? rtmp = created.rtmpUrl;
    final String? key = created.streamKey;
    // tsx 146：`created.stream_key && created.rtmp_url` 才渲染
    if (rtmp == null || rtmp.isEmpty || key == null || key.isEmpty) {
      return const SizedBox.shrink();
    }
    return Container(
      margin: const EdgeInsets.only(top: AylaSpacing.sp3),
      padding: const EdgeInsets.all(AylaSpacing.sp3),
      decoration: BoxDecoration(
        color: AylaColors.glassBgStrong, // --glass-bg-strong
        border: Border.all(color: AylaColors.glassBorder),
        borderRadius: BorderRadius.circular(AylaRadii.rCard),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        spacing: AylaSpacing.sp2, // gap: var(--sp-2)
        children: <Widget>[
          Text(
            '直播间「${created.title}」已创建', // tsx 149
            style: TextStyle(
              fontFamily: AylaFonts.display,
              fontFamilyFallback: AylaFonts.cjkFallback,
              fontSize: 15, // 无 font-size ⇒ 继承 body（base.css 31 `font-size: 15px`）
              color: AylaColors.textPrimary,
            ),
          ),
          Text(
            '推流信息仅本次显示，请立即复制到 OBS（此后可在直播间详情页查看）。', // tsx 152
            style: t.body.copyWith(
              fontSize: 13,
              color: AylaColors.warning, // `.live-create-guide-notice { color: var(--warning) }`
            ),
          ),
          // 两行复制：指引卡内**没有** `.live-studio-stream` 的覆写 ⇒ 基础档（ice-100 + radius-sm 8）
          AylaLiveCopyRow(
            label: '服务器',
            value: obsServerFromRtmpUrl(rtmp),
            copied: _copied == 'server',
            onCopy: () => unawaited(_copy(obsServerFromRtmpUrl(rtmp), 'server')),
          ),
          AylaLiveCopyRow(
            label: '串流密钥',
            value: key,
            copied: _copied == 'key',
            onCopy: () => unawaited(_copy(key, 'key')),
          ),
          Align(
            // `.live-guide-dismiss { align-self: flex-end }`
            alignment: Alignment.centerRight,
            child: AylaMsgActionButton(
              label: '我已保存，关闭', // tsx 183
              onPressed: () => setState(() => _created = null),
            ),
          ),
        ],
      ),
    );
  }
}

/// `.live-field-label`（live.css 164）：flex column / gap sp1 / 13px / w700。
class _Labelled extends StatelessWidget {
  const _Labelled({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      spacing: AylaSpacing.sp1,
      children: <Widget>[
        Text(
          label,
          style: AylaTextStyles.of(context).body.copyWith(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: AylaColors.textPrimary,
          ),
        ),
        child,
      ],
    );
  }
}

/// `.live-create-input`（app.css 3406–3419 + live.css 33 + auroraqua 502–517）。
///
/// 库内**没有**共享字段件（语音建频道也是各自内联，见 `voice_channel_create.dart` 的同一段事实源），
/// 故此处内联实现、不新造跨组件件。
class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.placeholder,
    required this.maxLength,
    this.textarea = false,
  });

  final TextEditingController controller;
  final String placeholder;
  final int maxLength;

  /// 介绍字段（`.live-create-textarea { min-height: 72px }`，live.css 165）。
  final bool textarea;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: textarea ? 72 : 36),
      child: TextField(
        controller: controller,
        maxLines: textarea ? 3 : 1,
        // ⚠️ Flutter 没有 CSS 的 `resize: vertical` 手柄；登记差异，不做自绘手柄
        maxLength: maxLength,
        style: t.body.copyWith(color: AylaColors.textPrimary),
        cursorColor: AylaColors.glow500,
        decoration: InputDecoration(
          isDense: true,
          counterText: '', // web 不显示计数（只截断）
          hintText: placeholder,
          hintStyle: t.body.copyWith(color: AylaColors.slate500), // ::placeholder
          filled: true,
          fillColor: AylaColors.glassBg,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: AylaSpacing.sp3, // padding sp2 sp3
            vertical: AylaSpacing.sp2,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AylaRadii.rInput),
            borderSide: const BorderSide(color: AylaColors.glassBorder),
          ),
          // auroraqua 513–517：focus → border glow-500 + glow-shadow（app.css 的
          // `box-shadow: var(--focus-ring)` 是**无效声明**，见文件头）
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AylaRadii.rInput),
            borderSide: const BorderSide(color: AylaColors.glow500),
          ),
          focusColor: AylaColors.glow500,
        ),
      ),
    );
  }
}

// ======================= 预览样张 =======================

/// 建直播间表单 + 推流指引样张（可交互：填标题「开播」看指引；点复制/关闭）。
Widget aylaLiveCreateSamples() {
  aylaEnableSampleMedia();
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      _Stage(
        viewport: const Size(520, 700),
        label:
            '建直播间表单（`LiveCreate`）· 字段族（--glass-bg + radius-input + 内高光 + focus glow）/ 标题 128 · 介绍 2000 + min-height 72 / 可见范围（复用 AylaVisibilitySelector；群内默认勾本群不锁定）/ 封面 96×16:9 虚线冰蓝（≤768 → 88）· 可交互：填标题后点「开播」',
        child: const _LiveCreateDemo(group: null),
      ),
      const SizedBox(height: AylaSpacing.sp6),
      _Stage(
        viewport: const Size(520, 940),
        label:
            '建播成功 → 推流指引（`.live-create-guide`：--glass-bg-strong + radius 16 + 标题 Fredoka 15 / notice `--warning` 13 / 两行复制**基础档** ice-100 + radius-sm 8 / 「我已保存，关闭」右对齐）',
        child: const _LiveCreateGuideDemo(),
      ),
      const SizedBox(height: AylaSpacing.sp6),
      _Stage(
        viewport: const Size(420, 760),
        label: '窄屏档（≤768）：封面 88 · 字段与可见范围同宽',
        child: const _LiveCreateDemo(group: null),
      ),
      const SizedBox(height: AylaSpacing.sp6),
      _Stage(
        viewport: const Size(520, 700),
        label: '群内创建（`group` 非空）→ 可见范围初值「仅本群可见 + 勾选本群」；空标题点开播 → 「标题不能为空」且不发请求',
        child: const _LiveCreateDemo(group: 'g1'),
      ),
    ],
  );
}

class _LiveCreateDemo extends StatefulWidget {
  const _LiveCreateDemo({required this.group});

  final String? group;

  @override
  State<_LiveCreateDemo> createState() => _LiveCreateDemoState();
}

class _LiveCreateDemoState extends State<_LiveCreateDemo> {
  int _created = 0;

  @override
  Widget build(BuildContext context) {
    return AylaLiveCreate(
      group: widget.group,
      onCreate: (AylaLiveCreateRequest request) async {
        setState(() => _created += 1);
        return AylaLiveChannelSnapshot(
          id: 'lc-new',
          title: request.title,
          description: request.description,
          // 样张不真上传：有选图就借样本图（`aylaSampleImage` 是预览专用），否则无封面
          cover: request.coverFile == null ? null : 'sample://cover',
          status: AylaLiveStatus.idle,
          visibility: request.visibility,
          allowedGroupIds: request.allowedGroupIds,
          group: request.group,
          rtmpUrl: 'rtmp://live.elysium.local/app/stream-9f2c',
          streamKey: 'sk_live_9f2c4a7b1e',
          flvUrl: 'http://live.elysium.local/live/stream-9f2c.flv',
        );
      },
      onCopy: (String text) async => true, // 样张不碰真剪贴板
    );
  }
}

class _LiveCreateGuideDemo extends StatefulWidget {
  const _LiveCreateGuideDemo();

  @override
  State<_LiveCreateGuideDemo> createState() => _LiveCreateGuideDemoState();
}

class _LiveCreateGuideDemoState extends State<_LiveCreateGuideDemo> {
  @override
  Widget build(BuildContext context) {
    // 直接展示指引：建播成功那一帧（表单在上方，指引随 _created 出现）
    return AylaLiveCreate(
      onCreate: (AylaLiveCreateRequest request) async => AylaLiveChannelSnapshot(
        id: 'lc-new',
        title: request.title.isEmpty ? '深夜电台' : request.title,
        status: AylaLiveStatus.idle,
        rtmpUrl: 'rtmp://live.elysium.local/app/stream-9f2c',
        streamKey: 'sk_live_9f2c4a7b1e',
      ),
      onCopy: (String text) async => true,
      autoDismissGuide: false,
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

/// 建直播间表单 + 推流指引。
@Preview(
  group: 'Widgets',
  name: '建直播间表单 + 推流指引',
  size: Size(560, 2000),
  wrapper: previewTheme,
)
Widget aylaLiveCreatePreview() => aylaLiveCreateSamples();
