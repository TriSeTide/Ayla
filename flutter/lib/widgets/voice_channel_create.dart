/// voice 域第三批（B1-3 第一件）：建语音频道表单。
///
/// ## 事实源（逐条对应 web，禁自由发挥）
/// ```
/// VoiceChannelCreate.tsx 1–80    可见性选择器 + 名称输入 + 「建频道」按钮 + 错误行
/// app.css 2848–2853              .voice-channel-create：flex · align-center · gap sp2 = 8 · wrap
/// app.css 2855–2865              .voice-create-input：flex 1 · min-width 120 · min-height 36 ·
///                                padding 0 sp3 · radius pill（**被 auroraqua 覆写**）·
///                                1px --glass-border · --glass-bg · 13px
/// auroraqua.css 502–512          :is(.field, .voice-create-input, …)：--glass-bg +
///                                1px --glass-border + **--radius-input（12）** +
///                                box-shadow --glass-inset + backdrop blur(24) saturate(1.4)
///                                ⇒ app.css 的 pill 圆角不生效
/// auroraqua.css 513–517          :focus → outline none + border-color --glow-500 +
///                                box-shadow --glow-shadow
/// auroraqua.css 520–522          ::placeholder → --slate-500
/// auroraqua.css 526–531          @supports 无 backdrop-filter → background --surface
/// app.css 2866–2869              .voice-create-error：12px · --destructive
/// private.css 229–231            .create-sheet-card .voice-create-input：
///                                width 100% + margin-bottom sp3
/// private.css 233–236            .create-sheet-card .btn-primary:not(.post-editor-submit)：
///                                width 100% + justify-content center
/// tsx 19–22                      初始可见性：群内 → {group:true} + [groupId]；
///                                一级 → {public:true} + []
/// tsx 29–33                      空名拦截：「频道名称不能为空」，**不发请求**
/// tsx 24/28/34/51                防重入：submitting ref 守卫 + busy 禁用按钮
/// tsx 39                         多选 → 后端单值：public → friends → group
/// tsx 44–53                      成功：清空名称 + onCreated（外层关浮层）；
///                                失败：显示 error 并**保留表单**
/// tsx 59–68                      输入：placeholder「新语音频道名称」· maxLength 64 ·
///                                Enter 提交
/// layout/ChannelSidebar.tsx 543  挂载点 1：CreateSheet(title「创建语音房」)
/// layout/CreateFab.tsx 80        挂载点 2：CreateSheet(title = 动作标签)
///                                ⇒ **两处都在 sheet 内** ⇒ private.css 的两条作用域规则恒生效
/// ```
///
/// ## 与 web 的装配差异（组件不写页面）
/// web 在组件内直接 `voiceApi.createVoiceChannel(...)` + `useVoiceStore.setChannels(...)`
/// （插到列表头、`mine:false`）。Flutter 侧按既有「展示型 + 注入」模式：
/// 组件只负责**校验 / 防重入 / busy / 错误展示 / 成功后清空**，
/// 请求与列表插入由页面层在 [onSubmit] 里完成；成功后回调 [onCreated]（外层关浮层）。
/// 群列表（web `useSocialPage('conversations')`）由页面层经 [groups] 注入。
///
/// ## 两处实现口径（与 web 等价，已在测试里锁住）
/// 1. **64 字符上限用 `inputFormatters`**（`LengthLimitingTextInputFormatter`）而不是
///    `maxLength`：后者会让 Flutter 在字段下方多渲染一个「0/64」计数器，web 没有这个元素；
/// 2. **垂直居中靠 `padding` 补足**：web 是 flex `align-items: center` + `min-height: 36px`，
///    而 Flutter 的 `Container` 没有该语义（子项贴顶）⇒ 传 `vertical: 8`
///    （13px × body 行高 1.55 ≈ 20 ⇒ 8 + 20 + 8 = 36，等效）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show TextInputFormatter, LengthLimitingTextInputFormatter;
import 'package:flutter/widget_previews.dart';

import '../core/models/visibility.dart';
import '../theme/app_theme.dart';
import '../theme/glass.dart';
import '../theme/preview_theme.dart';
import '../theme/tokens.dart';
import 'directory_controls.dart';

/// 建频道请求 —— web `createVoiceChannel(name, group, { visibility, allowed_group_ids })`。
class AylaVoiceChannelCreateRequest {
  const AylaVoiceChannelCreateRequest({
    required this.name,
    required this.visibility,
    required this.allowedGroupIds,
  });

  /// 已 `trim()` 的名称（tsx 29）。
  final String name;

  /// 后端单值可见性：`public` / `friends` / `group`（tsx 39 的多选→单值映射）。
  final AylaPostVisibility visibility;

  /// 白名单群 id（tsx 42）。
  final List<String> allowedGroupIds;
}

/// 建频道失败时由页面层抛出，[AylaVoiceChannelCreate] 直接展示其 [message]
/// （等价 web 的 `e instanceof Error ? e.message : "创建失败"`，tsx 49）。
class AylaVoiceChannelCreateException implements Exception {
  const AylaVoiceChannelCreateException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// `.voice-channel-create` —— 建语音频道表单（`VoiceChannelCreate.tsx`）。
class AylaVoiceChannelCreate extends StatefulWidget {
  const AylaVoiceChannelCreate({
    super.key,
    this.groupId,
    this.groups = const <({String id, String title})>[],
    this.groupsLoading = false,
    this.onSubmit,
    this.onCreated,
  });

  /// 群内创建时归属的群 id（`group?: string | null`）；一级创建为 null。
  final String? groupId;

  /// 可见性选择器的可搜索群列表（页面层注入）。
  final List<({String id, String title})> groups;

  /// 群列表加载中。
  final bool groupsLoading;

  /// 提交（页面层发请求 + 插列表头）；抛 [AylaVoiceChannelCreateException] 显示其文案，
  /// 其他异常显示「创建失败」。**成功返回后**组件会清空名称并回调 [onCreated]。
  final Future<void> Function(AylaVoiceChannelCreateRequest request)? onSubmit;

  /// 创建成功（tsx 47：外层关闭创建浮层）。
  final VoidCallback? onCreated;

  /// tsx 31：空名错误文案。
  static const String emptyNameError = '频道名称不能为空';

  /// 兜底错误文案（tsx 49）。
  static const String fallbackError = '创建失败';

  /// tsx 63：`maxLength={64}`。
  static const int nameMaxLength = 64;

  @override
  State<AylaVoiceChannelCreate> createState() => _AylaVoiceChannelCreateState();
}

class _AylaVoiceChannelCreateState extends State<AylaVoiceChannelCreate> {
  final TextEditingController _name = TextEditingController();
  late VisibilitySelection _visibility;
  late List<String> _selectedGroupIds;
  bool _busy = false;
  String? _error;

  /// tsx 24：`submitting` ref（busy 期间重复提交直接 return）。
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    // tsx 19–22：群内创建默认「群可见 + 本群」；一级创建默认「公开」。
    final String? group = widget.groupId;
    _visibility = group != null
        ? const VisibilitySelection(group: true)
        : const VisibilitySelection(isPublic: true);
    _selectedGroupIds = group != null ? <String>[group] : <String>[];
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  /// tsx 39：多选 → 单值（公开优先、其次好友、否则群）。
  AylaPostVisibility get _backendVisibility => _visibility.isPublic
      ? AylaPostVisibility.public
      : (_visibility.friends ? AylaPostVisibility.friends : AylaPostVisibility.group);

  Future<void> _submit() async {
    if (_submitting) return; // tsx 28
    final String trimmed = _name.text.trim();
    if (trimmed.isEmpty) {
      setState(() => _error = AylaVoiceChannelCreate.emptyNameError);
      return;
    }
    _submitting = true;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onSubmit?.call(
        AylaVoiceChannelCreateRequest(
          name: trimmed,
          visibility: _backendVisibility,
          allowedGroupIds: List<String>.of(_selectedGroupIds),
        ),
      );
      // tsx 46–47：成功才清空名称并通知外层
      _name.clear();
      widget.onCreated?.call();
    } catch (e) {
      // tsx 49：保留表单，展示错误
      setState(() {
        _error = e is AylaVoiceChannelCreateException
            ? e.message
            : AylaVoiceChannelCreate.fallbackError;
      });
    } finally {
      _submitting = false;
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);

    return Column(
      // `.voice-channel-create { display:flex; gap: sp2; flex-wrap: wrap }`
      // —— 两个挂载点都在 sheet 里，而 sheet 作用域把输入与按钮都设为 100% 宽
      //（private.css 229–236）⇒ 实际逐行堆叠，等价 Column（间距仍按 gap 8 表达）。
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        AylaVisibilitySelector(
          value: _visibility,
          onChange: (VisibilitySelection v) => setState(() => _visibility = v),
          selectedGroupIds: _selectedGroupIds,
          onSelectedGroupIdsChange: (List<String> ids) =>
              setState(() => _selectedGroupIds = ids),
          groups: widget.groups,
          groupsLoading: widget.groupsLoading,
          initialGroupId: widget.groupId,
          lockGroup: widget.groupId != null, // tsx 58：`lockGroup={!!group}`
        ),
        const SizedBox(height: AylaSpacing.sp2), // gap: var(--sp-2)
        SizedBox(
          // `.create-sheet-card .voice-create-input { width: 100% }`
          width: double.infinity,
          child: Padding(
            // 同规则的 `margin-bottom: var(--sp-3)`（与容器 gap 8 叠加 = 与按钮 20）
            padding: const EdgeInsets.only(bottom: AylaSpacing.sp3),
            child: GlassInput(
              controller: _name,
              hintText: '新语音频道名称', // tsx 61
              minHeight: 36, // `min-height: 36px`
              // `.voice-create-input { padding: 0 var(--sp-3) }` + 垂直居中补足（见文件头）
              padding: const EdgeInsets.symmetric(
                horizontal: AylaSpacing.sp3,
                vertical: 8,
              ),
              textStyle: t.body.copyWith(fontSize: 13), // `font-size: 13px`
              // ⚠️ GlassInput 的参数名是 **semanticLabel**（单数；库内另有部件用
              //    `semanticsLabel`，两者拼写不同——实测踩过一次）
              semanticLabel: '新语音频道名称',
              inputFormatters: <TextInputFormatter>[
                // tsx 63：`maxLength={64}` —— 用 formatter 表达（`maxLength` 会带计数器）
                LengthLimitingTextInputFormatter(
                  AylaVoiceChannelCreate.nameMaxLength,
                ),
              ],
              onSubmitted: (_) => unawaited(_submit()), // tsx 65–67：Enter 提交
            ),
          ),
        ),
        GlassButton(
          label: '建频道', // tsx 75
          variant: GlassButtonVariant.primary,
          // `.create-sheet-card .btn-primary:not(.post-editor-submit) { width: 100% }`
          expand: true,
          onPressed: _busy ? null : () => unawaited(_submit()), // `disabled={busy}`
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: AylaSpacing.sp2),
            child: Text(
              _error!,
              // `.voice-create-error { font-size: 12px; color: var(--destructive) }`
              style: t.body.copyWith(
                fontSize: 12,
                color: AylaColors.destructive,
              ),
            ),
          ),
      ],
    );
  }
}

// ======================= 预览 =======================

/// 建语音频道表单样张（画布与 @Preview 共用；**可交互**）。
///
/// - 左侧「一级创建」：默认公开；点「建频道」若不填名字 → 出「频道名称不能为空」；
///   填了名字 → 走假提交（1s）→ 清空输入 + 计数；
/// - 右侧「群内创建」：群可见被锁（本群恒勾选、不可取消，其余群仍可多选）；
/// - 第三档：注入一个抛错的提交 → 看错误文案与「表单保留」。
Widget aylaVoiceChannelCreateSamples() => const _VoiceChannelCreateDemo();

class _VoiceChannelCreateDemo extends StatefulWidget {
  const _VoiceChannelCreateDemo();

  @override
  State<_VoiceChannelCreateDemo> createState() =>
      _VoiceChannelCreateDemoState();
}

class _VoiceChannelCreateDemoState extends State<_VoiceChannelCreateDemo> {
  int _created = 0;
  String _lastName = '—';
  bool _failOnce = false;

  static const List<({String id, String title})> _groups =
      <({String id, String title})>[
    (id: 'g1', title: '冰樱研究社'),
    (id: 'g2', title: '深夜电台'),
    (id: 'g3', title: '长名字的群·用于看列表滚动与截断'),
  ];

  Future<void> _fakeSubmit(AylaVoiceChannelCreateRequest req) async {
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (_failOnce) {
      throw const AylaVoiceChannelCreateException('同名频道已存在');
    }
    setState(() {
      _created++;
      _lastName = req.name;
    });
  }

  Widget _sheetMock({required String title, required Widget child}) {
    return SizedBox(
      width: 380,
      child: GlassCard(
        // 模拟 sheet 卡面（真实容器由页面层的 AylaCreateSheet 提供）
        strong: true,
        radius: AylaRadii.rPanel,
        shadow: AylaShadows.modal,
        padding: const EdgeInsets.all(AylaSpacing.sp4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(title, style: const TextStyle(fontSize: 12)),
            const SizedBox(height: AylaSpacing.sp3),
            child,
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AylaSpacing.sp6,
      runSpacing: AylaSpacing.sp6,
      crossAxisAlignment: WrapCrossAlignment.start,
      children: <Widget>[
        _sheetMock(
          title: '一级创建（默认公开）· 已建 $_created 个，最后一次「$_lastName」',
          child: AylaVoiceChannelCreate(
            groups: _groups,
            onSubmit: _fakeSubmit,
            onCreated: () => setState(() {}),
          ),
        ),
        _sheetMock(
          title: '群内创建（group 非空 ⇒ 群可见锁定 + 本群恒勾选）',
          child: AylaVoiceChannelCreate(
            groupId: 'g1',
            groups: _groups,
            onSubmit: _fakeSubmit,
          ),
        ),
        _sheetMock(
          title: '失败态（提交抛错 → 文案保留表单）',
          child: AylaVoiceChannelCreate(
            groups: _groups,
            onSubmit: (AylaVoiceChannelCreateRequest req) async {
              await Future<void>.delayed(const Duration(milliseconds: 300));
              throw const AylaVoiceChannelCreateException('同名频道已存在');
            },
          ),
        ),
        SizedBox(
          width: 380,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            spacing: AylaSpacing.sp2,
            children: <Widget>[
              const Text('开关：让第一个表单的下一次提交失败', style: TextStyle(fontSize: 11)),
              GlassButton(
                label: _failOnce ? '下一次提交：失败' : '下一次提交：成功',
                variant: GlassButtonVariant.ghost,
                minHeight: 32,
                fontSize: 12,
                onPressed: () => setState(() => _failOnce = !_failOnce),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 建语音频道表单（一级 / 群内 / 失败态）—— 可交互。
@Preview(
  group: 'Widgets',
  name: '建语音频道表单（可见性 + 名称 + 建频道）',
  size: Size(1300, 620),
  wrapper: previewTheme,
)
Widget aylaVoiceChannelCreatePreview() => aylaVoiceChannelCreateSamples();
