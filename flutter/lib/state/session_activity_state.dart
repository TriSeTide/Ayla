/// 跨页面活动态（会话活动索引）—— web `stores/sessionActivity.ts`（72 行）的等价物。
///
/// ## 是什么
/// 「媒体连接的**导航投影**」：只保存可恢复的会话身份与连接状态，**不复制**成员、消息或
/// 媒体凭据（web 文件头原话）。`SessionActivityIndicator` 据此渲染跨页面悬浮球；
/// 直播小窗（[AylaLiveState.miniPlayer]）、voice/live 各自的媒体 owner 都不受影响。
///
/// ## 逐字段对应（web `ActivitySession`）
/// | 本类 | web | 口径 |
/// |---|---|---|
/// | [AylaActivityRecord.sessionId] | `sessionId` | 频道 id（字符串传输以对齐 Flutter 链路） |
/// | [AylaActivityRecord.sourceRoute] | `sourceRoute` | 点悬浮球回房的**目标路由** |
/// | [AylaActivityRecord.title] | `title` | 球的 hover 提示（语音房 / 直播间名） |
/// | [AylaActivityRecord.owner] | `owner` | 频道 owner 的 user id |
/// | [AylaActivityRecord.status] | `status` | 连接状态断面 |
/// | [AylaActivityRecord.lastError] | `lastError` | 失败原因（`setStatus` 覆盖写） |
/// | [AylaActivityRecord.updatedAt] | `updatedAt` | 每次写入的时间戳 |
///
/// ## ⚠️ 后四个字段当前**没有渲染消费点** —— 这是 web 的真实口径，不是漏做
/// `grep` 全 web 源码确认：`ActivitySession` 的**唯一**消费点是
/// `SessionActivityIndicator.tsx:41–68 / 148–161`，它只读 `sessionId` / `sourceRoute` /
/// `title`（`voice/live` 的其余字段只参与本地投影对象的构造，不参与任何渲染分支或样式）。
/// 本类仍完整实现它们，理由是它们**参与状态机语义**：`clear(kind)` 与 `clear(kind, "idle")`
/// 的区别、`setStatus` 的 `lastError` 覆盖写、`upsert` 整体替换而非合并——
/// 这些是 web 的完整协议面，缺字段会让后续接线（例如未来把状态接到球的视觉）无从对齐。
///
/// ## 为什么是模块级单例（而不是 `state/` 里常见的「provider 内实例」）
/// web 的 zustand store 就是模块级单例；且它有三条**无容器**的访问路径：
/// `useVoiceChannel` 的 resetLocal/join/leave（可能在页面卸载后由心跳回调触发）、
/// `liveSessionRuntime.leave`、以及 `auth.logout` 的 `reset()`。
/// Flutter 侧会话层（`pages/voice_support.dart` / `pages/live_support.dart`）同样是
/// **不持有 ref** 的 ChangeNotifier ⇒ 与既有的 `aylaMiniPlayerOwner`（模块级注册表）
/// 同一口径：索引本体模块级持有，展示层通过 provider 订阅同一个对象。
library;

import 'package:flutter/foundation.dart';

/// 活动态会话类型（web `ActivityKind`）。
enum AylaActivityKind {
  /// 语音房（心跳 + WS 音频中继）。
  voice,

  /// 直播间（HLS + 弹幕 WS）。
  live,
}

/// 连接状态断面（web `ActivityStatus` 的七个取值，顺序一致）。
///
/// ⚠️ 本枚举当前**无渲染消费点**（见文件头）；保留完整取值以对齐 web 的状态机调用语义
/// （`connecting` / `connected` / `ended` / `failed` / `idle` 在本项目里被真实写入）。
enum AylaActivityStatus {
  idle,
  connecting,
  connected,
  reconnecting,
  leaving,
  ended,
  failed,
}

/// 单条活动态会话（web `ActivitySession`）。
@immutable
class AylaActivityRecord {
  const AylaActivityRecord({
    required this.kind,
    required this.sessionId,
    required this.sourceRoute,
    required this.title,
    this.owner,
    this.status = AylaActivityStatus.connecting,
    this.lastError,
    this.updatedAt,
  });

  /// 会话类型（web `kind`）。
  final AylaActivityKind kind;

  /// 频道 id。
  final String sessionId;

  /// 点悬浮球回房的目标路由。
  final String sourceRoute;

  /// 频道名（球的 hover 提示；取不到时上游写「语音房 / 直播间」兜底）。
  final String title;

  /// 频道 owner 的 user id（web `owner: string | null`）。
  final String? owner;

  /// 连接状态断面。
  final AylaActivityStatus status;

  /// 最近一次失败原因（web `lastError: string | null`；`setStatus` **覆盖写**）。
  final String? lastError;

  /// 写入时间（web `updatedAt: string` 的 ISO 串；`upsert` 未给时由 store 补当前时间）。
  final DateTime? updatedAt;

  /// 哨兵：区分「不传」与「显式传 null」（`lastError` / `owner` 都要能被清空）。
  static const Object _unset = Object();

  AylaActivityRecord copyWith({
    String? sessionId,
    String? sourceRoute,
    String? title,
    Object? owner = _unset,
    AylaActivityStatus? status,
    Object? lastError = _unset,
    Object? updatedAt = _unset,
  }) =>
      AylaActivityRecord(
        kind: kind,
        sessionId: sessionId ?? this.sessionId,
        sourceRoute: sourceRoute ?? this.sourceRoute,
        title: title ?? this.title,
        owner: identical(owner, _unset) ? this.owner : owner as String?,
        status: status ?? this.status,
        lastError:
            identical(lastError, _unset) ? this.lastError : lastError as String?,
        updatedAt: identical(updatedAt, _unset)
            ? this.updatedAt
            : updatedAt as DateTime?,
      );
}

/// 会话活动索引（web `stores/sessionActivity.ts` 的 `useSessionActivityStore`）。
///
/// 四个方法逐条对齐 web 的 `upsert` / `setStatus` / `clear` / `reset`：
/// - `upsert`：**整体替换**该 kind 的记录（不合并旧值），`updatedAt` 缺省补当前时间；
/// - `setStatus`：无该 kind 记录时**静默返回**；`lastError` 缺省即清空（覆盖写）；
/// - `clear`：无记录时静默返回；`status == idle` ⇒ **置 null**（真删除），
///   其余取值 ⇒ **保留记录并改写状态**（web 原话：`status === "idle" ? null : {...}`）；
/// - `reset`：两条记录一起清空（登出走 `auth.logout` → `reset()`）。
class AylaSessionActivityStore extends ChangeNotifier {
  AylaActivityRecord? _voiceSession;
  AylaActivityRecord? _liveSession;

  /// 进行中的语音会话（null = 无）。
  AylaActivityRecord? get voiceSession => _voiceSession;

  /// 进行中的直播会话（null = 无）。
  AylaActivityRecord? get liveSession => _liveSession;

  /// 按 kind 取记录（web 的 `state[kind === "voice" ? "voiceSession" : "liveSession"]`）。
  AylaActivityRecord? sessionOf(AylaActivityKind kind) =>
      kind == AylaActivityKind.voice ? _voiceSession : _liveSession;

  /// 写入 / 替换一条活动态会话（web `upsert`）。
  void upsert(AylaActivityRecord session) {
    final AylaActivityRecord next = session.updatedAt == null
        ? session.copyWith(updatedAt: DateTime.now())
        : session;
    // ⚠️ web 的 key 由 `session.kind` 决定（不是入参单独给的 kind）。
    if (session.kind == AylaActivityKind.voice) {
      _voiceSession = next;
    } else {
      _liveSession = next;
    }
    notifyListeners();
  }

  /// 改写连接状态（web `setStatus`）；无该 kind 记录时**静默返回**。
  ///
  /// `lastError` 缺省为 null ⇒ **每一次调用都会清空上一次的错误**（web 同款覆盖写）。
  void setStatus(
    AylaActivityKind kind,
    AylaActivityStatus status, {
    String? lastError,
  }) {
    final AylaActivityRecord? current = sessionOf(kind);
    if (current == null) return; // web: if (!current) return state;
    final AylaActivityRecord next = current.copyWith(
      status: status,
      lastError: lastError,
      updatedAt: DateTime.now(),
    );
    if (kind == AylaActivityKind.voice) {
      _voiceSession = next;
    } else {
      _liveSession = next;
    }
    notifyListeners();
  }

  /// 清除活动态（web `clear(kind, status = "ended")`）；无记录时静默返回。
  ///
  /// [status] 为 [AylaActivityStatus.idle] ⇒ 记录**整条置空**；
  /// 其余取值 ⇒ 保留记录、只改写状态（web 用它表达「已结束但留痕」）。
  void clear(
    AylaActivityKind kind, [
    AylaActivityStatus status = AylaActivityStatus.ended,
  ]) {
    final AylaActivityRecord? current = sessionOf(kind);
    if (current == null) return; // web: if (!current) return state;
    final AylaActivityRecord? next = status == AylaActivityStatus.idle
        ? null
        : current.copyWith(status: status, updatedAt: DateTime.now());
    if (kind == AylaActivityKind.voice) {
      _voiceSession = next;
    } else {
      _liveSession = next;
    }
    notifyListeners();
  }

  /// 全部清空（web `reset`；登出链 `auth.logout` 调用）。
  void reset() {
    _voiceSession = null;
    _liveSession = null;
    notifyListeners();
  }
}

/// 会话活动索引的**模块级单例**（见文件头「为什么是模块级单例」）。
///
/// 与 `pages/live_support.dart` 的 `aylaMiniPlayerOwner` 同口径：
/// 索引本体模块级持有（会话层不持有 ref 也能写），展示层订阅同一个对象。
final AylaSessionActivityStore aylaSessionActivity =
    AylaSessionActivityStore();
