/// badges 全局状态 —— web `stores/badges.ts`（68 行）的 Flutter 等价物。
///
/// - [badges] 为 null = **尚未取到**（不伪造 0；web 同：`badges: null`）；
/// - 展示层用 [requestBadge] / [messageBadge] 取数 —— 与 web 一样在 null 时回落 0
///   （红点无法表达「未知」）；
/// - [fetch] 用**序号守卫**：并发 fetch 乱序返回时只应用最后一次的结果
///   （web `badges.ts:31–48` 的 `fetchSeq`）。
library;

import 'package:flutter/foundation.dart';

import '../core/api/accounts_api.dart';

/// 全局未读聚合控制器。
class AylaBadgesController extends ChangeNotifier {
  AylaAccountBadges? _badges;
  int _fetchSeq = 0;
  bool _disposed = false;

  /// 最近一次**成功**的聚合计数（null = 从未取到）。
  AylaAccountBadges? get badges => _badges;

  /// 认证消息红点（`badges.ts:62–65`；null ⇒ 0）。
  int get requestBadge => _badges?.requestBadge ?? 0;

  /// 消息入口红点（`AppShell.tsx:93–95` 的口径；null ⇒ 0）。
  int get messageBadge => _badges?.messageBadge ?? 0;

  /// 拉取计数。失败**保持上一版**（下次再试），不伪造清零。
  Future<void> fetch() async {
    final int seq = ++_fetchSeq;
    try {
      final AylaAccountBadges next = await AylaAccountsApi.getBadges();
      if (_disposed || seq != _fetchSeq) return;
      _badges = next;
      notifyListeners();
    } catch (_) {
      // 失败保持上一版计数（web 同）。
    }
  }

  void reset() {
    _badges = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
