/// B5 group 域第一批（2/2）：群聊申请/加入（GROUP REQUEST）—— 表单主体 + 弹窗形态。
///
/// ⚠️ web 的第三个形态 `GroupApplyGate`（`GroupPage.tsx:398` 的路由守卫卡，非遮罩）**按用户
/// 2026-09-25 裁决不实现**（「也不知道哪里用得到，直接删掉吧」）—— 它属页面层路由守卫，
/// 且 web 的实渲染里 head 无左右 padding（只有 form/actions 各自带），观感不对。
///
/// ## 事实源（逐条对应 web，禁自由发挥）
/// ── GroupApplyDialog.tsx 25–92（GroupApplyForm 主体）：desc + 留言 label + textarea +
/// 错误 + 提交键；成功态替换整个表单区
/// ── search.css 221–226：.group-apply-desc —— margin sp6 0 sp4 · 14px · lh 1.6 · text-primary；
/// 文案两档（公开群「这是一个公开群聊，点击即可直接加入。」/ 申请制
/// 「这是一个申请制群聊，群主或管理员同意后才能入群。」）
/// ── search.css 228–239：.group-apply-label —— 14/w700；内层 span（可选）secondary 400
/// ── search.css 241–246：.group-apply-message —— .field + min-height 104 + resize vertical
/// （tsx 78：maxLength 200）
/// ── search.css 248–252：.group-apply-error —— 13px · destructive
/// ── search.css 254–259：.group-apply-actions —— flex justify-end · gap sp2 · margin-top sp6
/// ── search.css 261–296（成功态）：居中列 gap sp3 · padding sp6 0 sp2；
/// 圆 48 --success 底 + surface 字 + 24px ✓ + --glow-shadow；strong display 20；p 14 secondary
/// ── GroupApplyDialog.tsx 95–137（弹窗形态）：overlay + 卡片 + head + Form
/// ── search.css 180–189：.group-apply-overlay —— fixed inset · z 70 · grid 居中 ·
/// padding sp4 · 遮罩 rgba(70,91,146,.28)（无模糊）
/// ── search.css 190–196 + app.css 230–248：.group-apply-dialog —— width min(440px,100%) ·
/// padding sp6 · blur24 sat1.4 · glass-shadow-modal + .glass-card 基类
/// （glass-bg · radius-card 16 · 1px 边）
/// ── search.css 198–219：.group-apply-head —— flex items-start space-between gap sp3；
/// kicker（utility 11 · ls 1.2 · pink-500 · mb sp1）+ h2（display 22 · text-primary）
/// ── tsx 124：关闭键 = .icon-btn-40 + **文字「×」**（不是图标）
/// ── GroupApplyDialog.tsx 140–171（守卫卡形态）：**本批不实现**（见文件头）；
/// 若页面层日后需要，按 search.css 527–557 复刻，并把 head 的 padding 一并补上
/// ── search.css 527–533：.group-page-guard —— height 100% · flex 居中 · padding 24
/// ── search.css 534–541：.group-apply-gate —— width min(400px,100%) ·
/// max-height min(80vh,620px) · overflow auto · padding 0 0 sp4
/// ── search.css 542–557：gate 内 Form padding 0 sp4 · actions padding sp3 sp4 0 ·
/// 提交键与「返回」键 width 100%；**head 无关闭键**
/// ── tsx 39–55：提交两分支 —— 公开群 accepted + conversation_id → onDone（外层跳转）；
/// 申请制 → sent 成功态；异常 → 文案（兜底「发送入群申请失败」）
///
/// ## 装配口径
/// web 在 Form 内直接调 api.applyToGroup；Flutter 侧注入 [AylaGroupApplyForm.onSubmit]
/// （页面层发请求 + 抛 [AylaGroupApplyException] 显示文案），**未注入时提交键禁用**
/// （不伪造「已发送」）。跳转也归调用方（[onDone] / 弹窗的 [AylaGroupApplyDialog.onJoined]）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show LengthLimitingTextInputFormatter, TextInputFormatter;
import 'package:flutter/widget_previews.dart';

import '../core/models/subgroup.dart';
import '../theme/app_theme.dart';
import '../theme/buttons.dart' show AylaIconButton;
import '../theme/glass.dart';
import '../theme/preview_theme.dart';
import '../theme/tokens.dart';
import 'dialogs.dart' show AylaModalCard, AylaModalOverlay;

/// 申请失败时由页面层抛出，表单直接展示其 [message]
/// （等价 web 的 `e instanceof Error ? e.message : "发送入群申请失败"`，tsx 51）。
class AylaGroupApplyException implements Exception {
  const AylaGroupApplyException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// `GroupApplyForm` —— 申请表单主体（无外壳；由弹窗形态挂载）。
class AylaGroupApplyForm extends StatefulWidget {
  const AylaGroupApplyForm({
    super.key,
    required this.group,
    required this.onDone,
    this.onSubmit,
    this.padding = EdgeInsets.zero,
  });

  /// 群信息（id / 群名 / 入群策略）。
  final AylaGroupApplyData group;

  /// 公开群直接加入成功后的跳转（tsx 45–48 的 `onDone(conversation_id)`）。
  final ValueChanged<String> onDone;

  /// 提交申请（页面层发请求）；返回 [AylaGroupApplyResult] 决定分支。
  final Future<AylaGroupApplyResult> Function(
    AylaGroupApplyData group,
    String message,
  )? onSubmit;

  /// 表单自身内边距（缺省 = 无）。
  final EdgeInsets padding;

  /// tsx 78：`maxLength={200}`。
  static const int messageMaxLength = 200;

  /// tsx 51 兜底文案。
  static const String fallbackError = '发送入群申请失败';

  @override
  State<AylaGroupApplyForm> createState() => _AylaGroupApplyFormState();
}

class _AylaGroupApplyFormState extends State<AylaGroupApplyForm> {
  final TextEditingController _message = TextEditingController();
  bool _busy = false;
  bool _sent = false;
  String? _error;

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  /// tsx 39–55：busy / sent 双守卫（sent 后不再发第二次）。
  Future<void> _submit() async {
    if (_busy || _sent) return;
    final Future<AylaGroupApplyResult> Function(
      AylaGroupApplyData,
      String,
    )? submit = widget.onSubmit;
    if (submit == null) return; // 未注入 ⇒ 不做任何事（不伪造结果）
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final AylaGroupApplyResult result =
          await submit(widget.group, _message.text.trim());
      if (!mounted) return;
      if (result.isAccepted && result.conversationId != null) {
        widget.onDone(result.conversationId!);
        return;
      }
      setState(() => _sent = true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error =
            e is AylaGroupApplyException ? e.message : AylaGroupApplyForm.fallbackError;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final bool isPublic = widget.group.isPublic;

    return Padding(
      padding: widget.padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const SizedBox(height: AylaSpacing.sp6), // desc 的 margin-top
          Text(
            isPublic
                ? '这是一个公开群聊，点击即可直接加入。'
                : '这是一个申请制群聊，群主或管理员同意后才能入群。', // tsx 60
            // `.group-apply-desc { margin: sp6 0 sp4; 14px; lh 1.6 }`
            style: t.body.copyWith(
              fontSize: 14,
              height: 1.6,
              color: AylaColors.textPrimary,
            ),
          ),
          const SizedBox(height: AylaSpacing.sp4), // desc 的 margin-bottom
          if (_sent) _success(t) else ..._fields(t, isPublic),
        ],
      ),
    );
  }

  /// 表单区（未发送）：label + textarea + 错误 + 提交键。
  List<Widget> _fields(AylaTextStyles t, bool isPublic) {
    return <Widget>[
      // `.group-apply-label { margin-bottom: sp2; 14/w700 }`；span（可选）secondary 400
      Padding(
        padding: const EdgeInsets.only(bottom: AylaSpacing.sp2),
        child: RichText(
          text: TextSpan(
            text: '给群主留言 ',
            style: t.body.copyWith(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: AylaColors.textPrimary,
            ),
            children: <TextSpan>[
              TextSpan(
                text: '（可选）',
                style: t.body.copyWith(
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                  color: AylaColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
      GlassInput(
        controller: _message,
        hintText: '简单介绍一下自己吧…', // tsx 80
        semanticLabel: '给群主留言', // tsx 75
        // `.group-apply-message { width: 100%; min-height: 104px; resize: vertical }`
        minHeight: 104,
        // web 的 textarea 是默认 2 行 + min-height 撑到 104；Flutter 用「104 高 + 最多 4 行，
        // 超出内部滚动」表达同一渲染高度（web 输入更多行时会自增高度，属次要差异）。
        maxLines: 4,
        padding: const EdgeInsets.symmetric(
          horizontal: AylaSpacing.sp4,
          vertical: AylaSpacing.sp3,
        ),
        inputFormatters: <TextInputFormatter>[
          // tsx 78：maxLength 200（formatter 表达，计数器不渲染）
          LengthLimitingTextInputFormatter(AylaGroupApplyForm.messageMaxLength),
        ],
        onChanged: (_) => setState(() {}),
      ),
      if ((_error ?? '').isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: AylaSpacing.sp2),
          child: Text(
            _error!,
            // `.group-apply-error { margin: sp2 0 0; 13px; destructive }`
            style: t.body.copyWith(fontSize: 13, color: AylaColors.destructive),
          ),
        ),
      Padding(
        // `.group-apply-actions { margin-top: sp6; justify-content: flex-end; gap sp2 }`
        padding: const EdgeInsets.only(top: AylaSpacing.sp6),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: <Widget>[_submitButton(isPublic)],
        ),
      ),
    ];
  }

  /// 提交键（tsx 84–86）：busy 文案两档；未注入 onSubmit ⇒ 禁用（不伪造结果）。
  Widget _submitButton(bool isPublic) {
    return GlassButton(
      label: _busy
          ? (isPublic ? '加入中…' : '发送中…')
          : (isPublic ? '直接加入' : '发送入群申请'),
      variant: GlassButtonVariant.primary,
      onPressed: (_busy || widget.onSubmit == null) ? null : _submit,
    );
  }

  /// 成功态（tsx 62–67）：圆 48 + 「✓」+ strong + p。
  Widget _success(AylaTextStyles t) {
    return Padding(
      // `.group-apply-success { padding: sp6 0 sp2; gap sp3; 居中 }`
      padding: const EdgeInsets.fromLTRB(0, AylaSpacing.sp6, 0, AylaSpacing.sp2),
      child: Column(
        spacing: AylaSpacing.sp3,
        children: <Widget>[
          Container(
            width: 48,
            height: 48,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AylaColors.success, // --success
              shape: BoxShape.circle,
              boxShadow: AylaShadows.glow, // --glow-shadow
            ),
            child: Text(
              '✓', // tsx 64（aria-hidden 装饰字形）
              style: t.body.copyWith(
                fontSize: 24,
                color: AylaColors.surface,
              ),
            ),
          ),
          Text(
            '申请已发送', // tsx 65
            style: const TextStyle(
              fontFamily: AylaFonts.display,
              fontFamilyFallback: AylaFonts.cjkFallback,
              fontSize: 20,
              color: AylaColors.textPrimary,
            ),
          ),
          Text(
            '等待群主或管理员审核，同意后你就能进入群聊。', // tsx 66
            textAlign: TextAlign.center,
            style: t.body.copyWith(
              fontSize: 14,
              color: AylaColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

/// .group-apply-dialog —— 弹窗形态（分享跳转守卫 / 搜索页）。
class AylaGroupApplyDialog extends StatelessWidget {
  const AylaGroupApplyDialog({
    super.key,
    required this.group,
    required this.onClose,
    this.onJoined,
    this.onSubmit,
  });

  /// 群信息。
  final AylaGroupApplyData group;

  /// 关闭（点遮罩 / 「×」）。
  final VoidCallback onClose;

  /// 公开群直接加入成功后的跳转（缺省 = 由调用方在 [onSubmit] 里自行处理）。
  final ValueChanged<String>? onJoined;

  /// 提交（转交表单；见 [AylaGroupApplyForm.onSubmit]）。
  final Future<AylaGroupApplyResult> Function(AylaGroupApplyData, String)?
      onSubmit;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    return AylaModalOverlay(
      onDismiss: onClose,
      padding: AylaSpacing.sp4, // .group-apply-overlay { padding: var(--sp-4) }
      centerBoth: true, // web 无窄屏媒体查询 ⇒ 窄屏同样居中
      maskColor: const Color(0x47465B92), // rgba(70,91,146,.28)（无模糊）
      child: AylaModalCard(
        cardMaxWidth: 440, // width: min(440px, 100%)
        narrowCentered: true,
        padding: const EdgeInsets.all(AylaSpacing.sp6), // padding: var(--sp-6)
        scrollable: true, // web 未声明 overflow（同子群弹窗的 80vh 兜底）
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _head(t),
            AylaGroupApplyForm(
              group: group,
              onSubmit: onSubmit,
              onDone: (String convId) => onJoined?.call(convId),
            ),
          ],
        ),
      ),
    );
  }

  /// .group-apply-head：kicker + h2 + 「×」关闭键。
  Widget _head(AylaTextStyles t) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start, // align-items: flex-start
      children: <Widget>[
        Expanded(child: groupApplyHeadCopy(group, t)),
        const SizedBox(width: AylaSpacing.sp3), // gap: var(--sp-3)
        AylaIconButton(
          // tsx 124：关闭键是文字「×」（不是图标）
          icon: Text('×', style: t.body),
          onPressed: onClose,
          semanticLabel: '关闭',
        ),
      ],
    );
  }
}

/// GROUP REQUEST 标题块（kicker + h2）—— 弹窗形态的 head（web 里弹窗与守卫卡两处逐字相同；
/// 守卫卡形态按用户 2026-09-25 裁决不实现，见文件头）。
Widget groupApplyHeadCopy(AylaGroupApplyData group, AylaTextStyles t) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      Padding(
        padding: const EdgeInsets.only(bottom: AylaSpacing.sp1), // margin-bottom: sp1
        child: Text(
          'GROUP REQUEST', // tsx 119
          style: TextStyle(
            fontFamily: AylaFonts.utility,
            fontFamilyFallback: AylaFonts.cjkFallback,
            fontSize: 11,
            letterSpacing: 1.2,
            color: AylaColors.pink500, // --pink-500
          ),
        ),
      ),
      Text(
        // tsx 121：「加入」/「申请加入」+ 群名（空则「该群聊」）
        '${(group.isPublic ? '加入' : '申请加入')}「${group.displayTitle}」',
        style: const TextStyle(
          fontFamily: AylaFonts.display,
          fontFamilyFallback: AylaFonts.cjkFallback,
          fontSize: 22, // font-size: 22px
          color: AylaColors.textPrimary,
        ),
      ),
    ],
  );
}

// ======================= 预览 =======================

/// 群聊申请弹窗样张（画布与 @Preview 共用；**可交互**）。
///
/// - 公开群弹窗（宽屏 900）：提交 = 直接加入 → onJoined 记录 conversation_id；
/// - 申请制弹窗（窄屏 375，MediaQuery 覆写）：提交 → 成功态；
/// - 未知 join_policy：按申请制文案与流程；
/// - 顶部开关可切「下一次提交失败」看错误行。
/// - 顶部开关可切「下一次提交失败」看错误行。
Widget aylaGroupApplySamples() => const _GroupApplyDemo();

class _GroupApplyDemo extends StatefulWidget {
  const _GroupApplyDemo();

  @override
  State<_GroupApplyDemo> createState() => _GroupApplyDemoState();
}

class _GroupApplyDemoState extends State<_GroupApplyDemo> {
  String _log = '—';
  bool _failNext = false;

  static const AylaGroupApplyData _public = AylaGroupApplyData(
    id: 'g1',
    title: '冰樱研究社',
    joinPolicy: AylaGroupJoinPolicy.public,
  );
  static const AylaGroupApplyData _applied = AylaGroupApplyData(
    id: 'g2',
    title: '深夜电台',
    joinPolicy: AylaGroupJoinPolicy.application,
  );
  static const AylaGroupApplyData _unknown = AylaGroupApplyData(
    id: 'g3',
    title: '',
  );

  Future<AylaGroupApplyResult> _submit(
    AylaGroupApplyData group,
    String message,
  ) async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (_failNext) {
      throw const AylaGroupApplyException('该群不接受申请');
    }
    return group.isPublic
        ? AylaGroupApplyResult.accepted('${group.id}-conv')
        : const AylaGroupApplyResult.pending();
  }

  Widget _stage(String label, double width, double height, Widget child) {
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        spacing: AylaSpacing.sp2,
        children: <Widget>[
          Text(label, style: const TextStyle(fontSize: 11)),
          SizedBox(
            height: height,
            // 不裁圆角：弹窗样张的遮罩要铺满舞台（否则四角露背景）
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(size: Size(width, height)),
              child: child,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      spacing: AylaSpacing.sp4,
      children: <Widget>[
        Text('最近操作：$_log', style: const TextStyle(fontSize: 12)),
        Row(
          mainAxisSize: MainAxisSize.min,
          spacing: AylaSpacing.sp3,
          children: <Widget>[
            GlassButton(
              label: _failNext ? '下一次提交：失败' : '下一次提交：成功',
              variant: GlassButtonVariant.ghost,
              minHeight: 32,
              fontSize: 12,
              onPressed: () => setState(() => _failNext = !_failNext),
            ),
          ],
        ),
        Wrap(
          spacing: AylaSpacing.sp6,
          runSpacing: AylaSpacing.sp6,
          crossAxisAlignment: WrapCrossAlignment.start,
          children: <Widget>[
            _stage(
              '公开群 · 弹窗（宽屏 900）',
              900,
              520,
              AylaGroupApplyDialog(
                group: _public,
                onClose: () => setState(() => _log = '关闭弹窗'),
                onJoined: (String id) => setState(() => _log = '加入 $id'),
                onSubmit: _submit,
              ),
            ),
            _stage(
              '申请制 · 弹窗（窄屏 375：同样居中 + radius 20 全圆角）',
              375,
              560,
              AylaGroupApplyDialog(
                group: _applied,
                onClose: () => setState(() => _log = '关闭弹窗'),
                onSubmit: _submit,
              ),
            ),
            _stage(
              '未知 join_policy（按申请制文案与流程）· 弹窗',
              700,
              520,
              AylaGroupApplyDialog(
                group: _unknown,
                onClose: () => setState(() => _log = '关闭弹窗'),
                onSubmit: _submit,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 群聊申请（GROUP REQUEST：公开群 / 申请制 / 未知策略）—— 可交互。
@Preview(
  group: 'Widgets',
  name: '群聊申请（GROUP REQUEST：公开群 / 申请制 / 未知策略）',
  size: Size(1500, 1600),
  wrapper: previewTheme,
)
Widget aylaGroupApplyPreview() => aylaGroupApplySamples();
