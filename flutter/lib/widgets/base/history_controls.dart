/// history controls（自 `directory_controls.dart` 拆出：一文件一件）。
///
/// 事实源与逐条对照见 `docs/flutter/17-组件文件头归档（整理前原文）.md` 的 `directory_controls.dart` 一节
/// 与各件的 `///` 头注。
///
/// ## 公开面
/// `AylaHistoryControlsData` · `AylaHistoryControls`

library;

import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';
import '../../theme/glass.dart';
import '../../theme/tokens.dart';
import 'pagination_footer.dart';

/// 历史分页投影（[AylaHistoryControls] 的输入；web `HistoryControlsProps`）。
///
/// 各域共用同一形状（voice 房内聊天 / 直播弹幕 / 以后的消息列表…）：数据来自
/// 页面层的 `useCursorHistory` 等价物，组件只负责展示三态与转发回调。
/// 回调为 null 时按「无动作」处理（不是 disabled：web 里这些按钮由
/// `hasMore` / `hasNewer` 决定是否渲染）。
class AylaHistoryControlsData {
  const AylaHistoryControlsData({
    this.loading = false,
    this.error,
    this.hasMore = false,
    this.hasNewer = false,
    this.loadOlder,
    this.returnLatest,
    this.retry,
  });

  /// 加载中（三点 + aria「正在加载历史」）。
  final bool loading;

  /// 错误文案（非 null → 文案 + 「重试」）。
  final String? error;

  /// 还有更早记录。
  final bool hasMore;

  /// 有更新消息（可跳回最新）。
  final bool hasNewer;

  /// 加载更早。
  final Future<void> Function()? loadOlder;

  /// 返回最新。
  final Future<void> Function()? returnLatest;

  /// 重试。
  final Future<void> Function()? retry;

  /// 转成 [AylaHistoryControls]（回调缺省为空实现，与 voice 域既有调用同口径）。
  Widget toControls() => AylaHistoryControls(
    loading: loading,
    error: error,
    hasMore: hasMore,
    hasNewer: hasNewer,
    loadOlder: loadOlder ?? () async {},
    returnLatest: returnLatest ?? () async {},
    retry: retry ?? () async {},
  );
}

/// 历史分页控制（`HistoryControls.tsx`）。
///
/// 同样是「投影边界 + 显式续读/重试」：
/// - `error` → 文案 + 「重试」（loading 时禁用）
/// - `loading` → 三点 + aria「正在加载历史」
/// - `hasMore` → 「加载更早记录」
/// - `hasNewer` → 「返回最新消息」（loading 时禁用）
///
/// `role`：有 error 时 `alert`，否则 `status`；`aria-busy = loading`。
class AylaHistoryControls extends StatelessWidget {
  const AylaHistoryControls({
    super.key,
    required this.loading,
    required this.error,
    required this.hasMore,
    required this.hasNewer,
    required this.loadOlder,
    required this.returnLatest,
    required this.retry,
  });

  /// 是否加载中。
  final bool loading;

  /// 错误文案。
  final String? error;

  /// 是否还有更早的记录。
  final bool hasMore;

  /// 是否有更新的消息（可跳回最新）。
  final bool hasNewer;

  /// 加载更早。
  final Future<void> Function() loadOlder;

  /// 返回最新。
  final Future<void> Function() returnLatest;

  /// 重试。
  final Future<void> Function() retry;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);

    final List<Widget> items = <Widget>[
      if (error != null) ...<Widget>[
        Text(
          error!,
          style: t.body.copyWith(color: AylaColors.destructive),
        ),
        AylaGlassButton(
          label: '重试',
          variant: AylaGlassButtonVariant.ghost,
          onPressed: loading
              ? null
              : () {
                  retry();
                },
        ),
      ],
      if (loading)
        const AylaPaginationLoadingDots(semanticLabel: '正在加载历史')
      else if (hasMore)
        AylaGlassButton(
          label: '加载更早记录',
          variant: AylaGlassButtonVariant.ghost,
          onPressed: () {
            loadOlder();
          },
        ),
      if (hasNewer)
        AylaGlassButton(
          label: '返回最新消息',
          variant: AylaGlassButtonVariant.ghost,
          onPressed: loading
              ? null
              : () {
                  returnLatest();
                },
        ),
    ];

    return AylaStablePaginationFooter(
      child: Semantics(
        liveRegion: error != null, // role=alert
        label: error != null ? '加载出错' : '分页状态',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: AylaSpacing.sp2, // gap: var(--sp-2)
          children: items,
        ),
      ),
    );
  }
}

// ======================= FavoriteButton =======================
