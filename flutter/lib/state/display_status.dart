/// 在线状态显示规则 —— web `utils/displayStatus.ts`（101 行）的 Flutter 等价物。
///
/// ## 三层数据源（web 文件头原话）
/// - `User.status`（用户选择的模式：auto/dnd/away/invisible，**REST 快照**）；
/// - 实时在线（Redis presence：WS `presence.update` 增量 + REST `online` 快照）；
/// - 实时模式（WS `presence.status` 增量：保存勿扰/离开/隐身/自动时后端广播）。
///
/// 显示 = f(实时模式, 实时在线)：auto 跟随实时，dnd/away/invisible 固定文案。
/// 后端 `UserPublicSerializer.display_status` 是权威快照；本件用于 presence 实时事件
/// 到达时合并各层，避免各组件复制规则。
///
/// ## 逐条口径（`utils/displayStatus.ts:17–69`）
/// - [displayStatusOf]：`dnd → 勿扰` / `away → 离开` / `invisible → 离线` /
///   其余（auto、未知旧值）跟随实时在线；
/// - [presenceOnline]：presence store 已知状态优先（WS 增量权威），无记录时回退
///   REST 快照 `user.online`；**隐身用户强制离线** —— 运行中切换隐身不产生 WS 事件，
///   旧「online」记录必须不泄漏；
/// - [presenceStatus]：`presence.status` 增量优先（WS 权威），无记录回退 REST `user.status`；
/// - [withLiveStatus]：用实时模式覆盖 `user.status`，供前两者消费。
///
/// ## 与 web 的类型差异（登记，语义等价）
/// - web 用 `Pick<UserPublic, …>` 结构化类型 ⇒ Dart 无结构化类型，本件只收
///   `AylaUserPublic`（`core/models/user_public.dart`）。帖子域的 `AylaPostAuthor`
///   是同一契约的另一个投影，本轮**不接线**（帖子域调用点不动）；
/// - web 的 [presenceStatus] 返回 `string`，但 `statuses[id] ?? user.status` 在
///   `user.status` 缺失时实际是 `undefined`（下游 switch 落 default）⇒
///   Dart 侧类型如实写 `String?`（null = 无值），下游行为逐条相同。
library;

import '../core/models/user_public.dart';

/// 纯规则：给定模式与实时在线布尔，返回对外显示文案。
///
/// web `utils/displayStatus.ts:17–32` `displayStatusOf`（逐字对应）。
String displayStatusOf(AylaUserPublic? user, bool online) => switch (user?.status) {
      'dnd' => '勿扰',
      'away' => '离开',
      'invisible' => '离线',
      // auto（及未知旧值兜底）：跟随实时在线
      _ => online ? '在线' : '离线',
    };

/// 纯规则：实时在线判定。
///
/// web `utils/displayStatus.ts:40–48` `presenceOnline`（逐字对应）：
/// store 已知状态优先（WS 增量权威），无记录回退 REST 快照 `user.online`；
/// 隐身用户强制离线（旧记录不泄漏）。
bool presenceOnline(Map<String, String> users, AylaUserPublic? user) {
  if (user == null) return false;
  if (user.status == 'invisible') return false;
  final String? known = users[user.id];
  if (known != null) return known == 'online';
  return user.online;
}

/// 纯规则：实时模式判定。
///
/// web `utils/displayStatus.ts:54–60` `presenceStatus`（逐字对应）：
/// `presence.status` 增量优先（WS 权威），无记录回退 REST 快照 `user.status`。
String? presenceStatus(Map<String, String> statuses, AylaUserPublic? user) {
  if (user == null) return 'auto';
  return statuses[user.id] ?? user.status;
}

/// 用实时模式覆盖 `user.status`（供 [presenceOnline] / [displayStatusOf] 消费）。
///
/// web `utils/displayStatus.ts:63–69` `withLiveStatus`：`user` 为 null 时**原样返回**
/// （不造用户），否则返回 `{ ...user, status: presenceStatus(...) }` 的等价副本。
AylaUserPublic? withLiveStatus(
  Map<String, String> statuses,
  AylaUserPublic? user,
) {
  if (user == null) return null;
  return user.withStatus(presenceStatus(statuses, user));
}
