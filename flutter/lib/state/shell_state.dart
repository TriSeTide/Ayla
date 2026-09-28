/// shell 全局状态（web `stores/shell.ts` 38 行的等价物）。
///
/// - [ShellUiState.bottomTabsLeaving]：窄屏直播间进房动画 —— 底栏**下滑走**
///   （translateY 0→100%，200ms ease-in）；由直播间页进房置 true、退房复位，
///   AppShell 读它驱动 BottomTabs 的 transform。
/// - [ShellUiState.quickMessagesOpen]：红点快捷消息栏（`QuickMessagesSheet`）开关。
///   存全局而不是 QuickMessageFab 内部（web 注释里的 R-QM bug）：快捷栏打开后
///   红点归零（打开会话标已读）会让 Fab 因 `messageBadge > 0` 被卸载，若 open
///   状态在其内部则快捷栏被连带关闭；提升到全局后只随手动关闭卸载。
/// - [ShellUiState.refreshCallback]：当前页「刷新」回调（RefreshFAB 复用 PullToRefresh 通道）。
///   有刷新能力的页在 mount 时注册，cleanup 用**引用守卫**注销（仅当仍是自己时才清空），
///   避免转场期间旧页 cleanup 覆盖掉新页注册的回调。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 壳层 UI 状态快照。
class ShellUiState {
  const ShellUiState({
    this.bottomTabsLeaving = false,
    this.quickMessagesOpen = false,
    this.refreshCallback,
  });

  /// 窄屏底栏是否正在离场（下滑走）。
  final bool bottomTabsLeaving;

  /// 快捷消息栏是否打开。
  final bool quickMessagesOpen;

  /// 当前页注册的刷新回调（null = 无可刷新能力）。
  ///
  /// ⚠️ 类型是 `Future<void> Function()` 而不是 `void Function()`：web 的签名是
  /// `() => void | Promise<void>`，而 RefreshFAB 在等它完成期间显示旋转态
  /// （`AylaRefreshFab.onRefresh` 同类型）⇒ 用 `void` 会丢掉「刷新中」这一档。
  final Future<void> Function()? refreshCallback;

  ShellUiState copyWith({
    bool? bottomTabsLeaving,
    bool? quickMessagesOpen,
    Future<void> Function()? refreshCallback,
    bool clearRefresh = false,
  }) {
    return ShellUiState(
      bottomTabsLeaving: bottomTabsLeaving ?? this.bottomTabsLeaving,
      quickMessagesOpen: quickMessagesOpen ?? this.quickMessagesOpen,
      refreshCallback:
          clearRefresh ? null : (refreshCallback ?? this.refreshCallback),
    );
  }
}

/// shell 状态 Notifier（唯一真源）。
class ShellUiNotifier extends Notifier<ShellUiState> {
  @override
  ShellUiState build() => const ShellUiState();

  void setBottomTabsLeaving(bool leaving) {
    if (state.bottomTabsLeaving == leaving) return;
    state = state.copyWith(bottomTabsLeaving: leaving);
  }

  void setQuickMessagesOpen(bool open) {
    if (state.quickMessagesOpen == open) return;
    state = state.copyWith(quickMessagesOpen: open);
  }

  /// 注册刷新回调（传 null = 注销）。
  void registerRefresh(Future<void> Function()? fn) {
    state = fn == null
        ? state.copyWith(clearRefresh: true)
        : state.copyWith(refreshCallback: fn);
  }

  /// 引用守卫注销：仅当当前注册者仍是 [fn] 时才清空。
  void unregisterRefresh(Future<void> Function() fn) {
    if (identical(state.refreshCallback, fn)) {
      state = state.copyWith(clearRefresh: true);
    }
  }
}

final shellUiProvider = NotifierProvider<ShellUiNotifier, ShellUiState>(
  ShellUiNotifier.new,
);