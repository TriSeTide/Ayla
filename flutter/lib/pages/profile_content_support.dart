/// 个人主页「内容分区」的三条数据源（web `ProfileContentSections.tsx:63–105`）——
/// `/profile`（本人）与 `/user/:id`（他人）共用的页面级装载。
///
/// ## 为什么是页面级模块
/// web 把取数与渲染放在**同一个组件**里（组件内 `useEffect` + 三个独立 `setState`）；
/// Flutter 的视觉件 `AylaProfileContentSections`（`widgets/base/profile_content_sections.dart`）
/// **不自持请求**（数据与跳转全部由调用方注入，见其文件头「装配口径」）⇒ 取数落在页面层。
/// 两个页面的三条规则逐字相同，只在「owner 是谁」与 `mine` 上不同 ⇒ 抽本文件共用
/// （同 `profile_support.dart` 的页面级定位；那份只管布局几何，这份只管取数，互不重叠）。
///
/// ## 逐条对应（web tsx 行号）
/// - **正在直播（最多 1 个）**：`owner.is_live && owner.live_room_id != null` ⇒
///   `GET /live/channels/<live_room_id>/`（73–79）；**403（can_view 不可见）静默不展示**；
/// - **正在语音（最多 1 个）**：`owner.is_in_voice && owner.voice_room_id != null` ⇒
///   `GET /voice/channels/<voice_room_id>/`（81–87）；403 同上；
/// - **帖子（取前 3 条）**：`mine ? { scope: "mine", limit: 3 } : { owner: owner.id, limit: 3 }`
///   （89–101）——取数期间 `postsLoading = true`（骨架），失败 → `e.message`
///   （非 Error 兜底「帖子加载失败」，tsx 99）；
/// - **正在玩的桌游** = 组件内的占位（web 同）——不在本文件。
///
/// ## 与 web 的机制差异（逐条登记）
/// 1. web 的 `cancelled` 闭包标志（tsx 71/102）⇒ [AylaProfileContentLoad.cancel]
///    （换 owner / 卸载后丢弃在途结果）；
/// 2. web 的 `useEffect` 依赖数组（tsx 103）⇒ [AylaProfileContentTarget] 的**相等性**：
///    `owner.id` / `is_live` / `live_room_id` / `is_in_voice` / `voice_room_id` / `mine`
///    任一变化即重装（等价 web 的 `key={owner.id}` + 依赖数组）；
/// 3. **直播 / 语音的非 403 失败**：web 的 `.catch` 把**一切**失败整条吞掉（76/84）；
///    本实现按「失败不得静默」（AGENTS.md $8）把非 403 失败并入组件的**唯一**错误位
///    （`AylaProfileContentSections.postsError`，渲染为帖子卡内的 `.profile-content-empty`），
///    并带来源前缀（「直播间加载失败：…」）以免与帖子失败混淆。组件没有第二个错误位
///    ⇒ 当直播/语音失败而帖子成功时，错误文案会占住帖子卡的位置（登记为待裁决项）；
/// 4. web 的 `posts.length > 0` 才渲染「更多帖子」= 组件自身行为（tsx 178–196），本文件不参与。
///
/// ## 公开面
/// [AylaProfileContentTarget] · [AylaProfileContentState] · [AylaProfileContentLoad] ·
/// [AylaProfileContentFetchers] · [aylaLoadProfileContent] ·
/// [aylaFetchProfileLive] / [aylaFetchProfileVoice] / [aylaFetchProfilePosts] ·
/// [aylaProfilePostsQuery] · [aylaProfileLivePath] / [aylaProfileVoicePath] /
/// [aylaProfilePostPath] / [aylaProfileMorePostsPath]
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../core/api/directory_page.dart';
import '../core/api/live_api.dart';
import '../core/api/posts_api.dart';
import '../core/api/voice_api.dart';
import '../core/models/post.dart';
import '../core/net/dio_client.dart';
import '../widgets/base/profile_content_sections.dart';
import '../widgets/live/live_channel_snapshot.dart';

/// 帖子卡取前 3 条（web tsx:91 的 `limit: 3`）。
const int kAylaProfilePostsLimit = 3;

/// 帖子失败兜底文案（web tsx:99 原文 `"帖子加载失败"`）。
const String kAylaProfilePostsErrorFallback = '帖子加载失败';

/// 直播卡失败文案前缀（组件没有第二个错误位 ⇒ 前缀用于区分来源，见文件头差异 3）。
const String kAylaProfileLiveErrorLabel = '直播间加载失败';

/// 语音卡失败文案前缀（同上）。
const String kAylaProfileVoiceErrorLabel = '语音房加载失败';

/// 直播详情取数（默认 = `GET /live/channels/<id>/`）。
typedef AylaProfileLiveFetcher = Future<AylaProfileLiveData> Function(
  String roomId,
);

/// 语音房详情取数（默认 = `GET /voice/channels/<id>/`）。
typedef AylaProfileVoiceFetcher = Future<AylaProfileVoiceData> Function(
  String roomId,
);

/// 帖子取数（默认 = `GET /posts/`，`mine` 决定 `scope=mine` 还是 `owner=<id>`）。
typedef AylaProfilePostsFetcher = Future<List<AylaProfilePostItem>> Function(
  String ownerId,
  bool mine,
);

/// 内容分区的三条取数：生产默认值 = 真实 API；测试传替身（两个页面都用它注入）。
class AylaProfileContentFetchers {
  const AylaProfileContentFetchers({
    this.live = aylaFetchProfileLive,
    this.voice = aylaFetchProfileVoice,
    this.posts = aylaFetchProfilePosts,
  });

  /// 直播卡取数（tsx 73–79）。
  final AylaProfileLiveFetcher live;

  /// 语音卡取数（tsx 81–87）。
  final AylaProfileVoiceFetcher voice;

  /// 帖子取数（tsx 89–101）。
  final AylaProfilePostsFetcher posts;
}

/// 直播详情 → 直播卡投影（web tsx 119–132 消费 id / title / cover / owner_nickname）。
Future<AylaProfileLiveData> aylaFetchProfileLive(String roomId) async {
  final AylaLiveChannelSnapshot channel = await AylaLiveApi.getLiveChannel(roomId);
  return AylaProfileLiveData(
    id: channel.id,
    title: channel.title,
    cover: channel.cover,
    ownerNickname: channel.ownerNickname,
  );
}

/// 语音房详情 → 语音卡投影（web tsx 145–154 消费 id / name / owner_nickname / member_count）。
Future<AylaProfileVoiceData> aylaFetchProfileVoice(String roomId) async {
  final AylaVoiceChannelSnapshot channel =
      await AylaVoiceApi.getVoiceChannel(roomId);
  return AylaProfileVoiceData(
    id: channel.id,
    // web 取 `voiceChannel.name`（不是 `name || room_name` 兜底口径）。
    name: channel.name,
    ownerNickname: channel.ownerNickname,
    // web：`member_count > 0` 才出「N 人在麦」徽标 ⇒ 后端未给（null）按 0 处理
    // （不出徽标，**不伪造成 0 人在麦**）。
    memberCount: channel.memberCount ?? 0,
  );
}

/// 帖子取数参数（web tsx:91 的三元）：mine ⇒ `scope=mine`；他人 ⇒ `owner=<id>`。
({String? scope, String? owner}) aylaProfilePostsQuery({
  required String ownerId,
  required bool mine,
}) =>
    mine ? (scope: 'mine', owner: null) : (scope: null, owner: ownerId);

/// 帖子前 3 条 → 帖子行投影（web tsx 180–189 消费 title / body / created_at）。
Future<List<AylaProfilePostItem>> aylaFetchProfilePosts(
  String ownerId,
  bool mine,
) async {
  final ({String? scope, String? owner}) query =
      aylaProfilePostsQuery(ownerId: ownerId, mine: mine);
  final AylaDirectoryPage<AylaPost> page = await AylaPostsApi.listPosts(
    scope: query.scope,
    owner: query.owner,
    limit: kAylaProfilePostsLimit,
  );
  return <AylaProfilePostItem>[
    for (final AylaPost post in page.results)
      AylaProfilePostItem(
        // 组件用字符串 id（web 的 `Post.id` 是数字，`Link` 直接插值 ⇒ 这里同义转换）。
        id: '${post.id}',
        title: post.title,
        body: post.body,
        createdAt: post.createdAt,
      ),
  ];
}

// ======================= 跳转目标（web 的 Link to） =======================

/// 直播卡行 → `/live/<id>`（tsx 119）。
String aylaProfileLivePath(String channelId) => '/live/$channelId';

/// 语音卡行 → `/voice/<id>`（tsx 145）。
String aylaProfileVoicePath(String channelId) => '/voice/$channelId';

/// 帖子行 → `/posts/<id>`（tsx 181）。
String aylaProfilePostPath(String postId) => '/posts/$postId';

/// 「更多帖子」→ `mine ? "/posts/mine" : "/user/<id>/posts"`（tsx 105 逐字）。
String aylaProfileMorePostsPath({required bool mine, required String ownerId}) =>
    mine ? '/posts/mine' : '/user/${Uri.encodeComponent(ownerId)}/posts';

// ======================= 装载 =======================

/// 一次装载的**依赖**（web `useEffect` 依赖数组 tsx:103 + `key={owner.id}`）：
/// 六个字段任一变化 ⇒ 重新装载（旧的在途结果作废）。
@immutable
class AylaProfileContentTarget {
  const AylaProfileContentTarget({
    required this.ownerId,
    required this.mine,
    this.isLive = false,
    this.liveRoomId,
    this.isInVoice = false,
    this.voiceRoomId,
  });

  /// `owner.id`（本人页 = auth store 的 currentUser.id）。
  final String ownerId;

  /// 是否本人（决定帖子取数口径与空态文案）。
  final bool mine;

  /// `owner.is_live`。
  final bool isLive;

  /// `owner.live_room_id`（null = 没在播）。
  final String? liveRoomId;

  /// `owner.is_in_voice`。
  final bool isInVoice;

  /// `owner.voice_room_id`（null = 不在语音）。
  final String? voiceRoomId;

  @override
  bool operator ==(Object other) =>
      other is AylaProfileContentTarget &&
      other.ownerId == ownerId &&
      other.mine == mine &&
      other.isLive == isLive &&
      other.liveRoomId == liveRoomId &&
      other.isInVoice == isInVoice &&
      other.voiceRoomId == voiceRoomId;

  @override
  int get hashCode =>
      Object.hash(ownerId, mine, isLive, liveRoomId, isInVoice, voiceRoomId);
}

/// 内容分区的装载快照（字段与 [AylaProfileContentSections] 的数据入参一一对应）。
@immutable
class AylaProfileContentState {
  const AylaProfileContentState({
    this.live,
    this.voice,
    this.posts = const <AylaProfilePostItem>[],
    this.postsLoading = true,
    this.error,
  });

  /// 正在直播（null = 没在播 / 不可见（403）/ 还没取到 —— 三种都**不渲染该卡**）。
  final AylaProfileLiveData? live;

  /// 正在语音（同上）。
  final AylaProfileVoiceData? voice;

  /// 帖子（最多 [kAylaProfilePostsLimit] 条）。
  final List<AylaProfilePostItem> posts;

  /// 帖子在途（web `postsLoading` 初值 true，tsx 67）⇒ 组件渲染 3 条高 44 骨架。
  final bool postsLoading;

  /// 组件的**唯一**错误位（渲染为帖子卡内的 `.profile-content-empty`）：
  /// 帖子失败按 web 口径给 `e.message`；直播 / 语音的非 403 失败带来源前缀并入
  /// （见文件头差异 3）。null = 无错误。
  final String? error;

  /// 只覆盖给定字段（未给 = 保留原值）。
  AylaProfileContentState copyWith({
    AylaProfileLiveData? live,
    AylaProfileVoiceData? voice,
    List<AylaProfilePostItem>? posts,
    bool? postsLoading,
    String? error,
  }) =>
      AylaProfileContentState(
        live: live ?? this.live,
        voice: voice ?? this.voice,
        posts: posts ?? this.posts,
        postsLoading: postsLoading ?? this.postsLoading,
        error: error ?? this.error,
      );
}

/// 一次装载的句柄（web 的 `cancelled` 标志 + 三个独立 `setState`）。
///
/// 三个源**并发**发起（web 三条 promise 链同时起、互不等待），各自解析后**立即**回调一次
/// ⇒ 直播卡一到就出现，帖子卡先骨架后列表（与 web 相同的分部渲染）。
class AylaProfileContentLoad {
  AylaProfileContentLoad._(this._target, this._fetchers, this._onUpdate);

  final AylaProfileContentTarget _target;
  final AylaProfileContentFetchers _fetchers;
  final ValueChanged<AylaProfileContentState> _onUpdate;

  AylaProfileContentState _state = const AylaProfileContentState();
  bool _cancelled = false;

  /// 在途结果作废（web cleanup 的 `cancelled = true`，tsx 102）：换 owner / 卸载时调用。
  ///
  /// **不推进状态**：作废后到达的结果既不写状态也不回调（等价 web 的 `if (cancelled) return`）。
  void cancel() => _cancelled = true;

  void _emit(AylaProfileContentState next) {
    if (_cancelled) return;
    _state = next;
    _onUpdate(_state);
  }

  /// 正在直播（tsx 72–79）：`is_live && live_room_id != null` 才请求，否则**不展示该卡**。
  ///
  /// ⚠️ `_emit`（进而调用方的 `setState`）一律放在 **try 之外**：视图回调抛错是调用方
  /// 的问题，不能被误记成「直播间加载失败」，也不该被数据源的 catch 吞掉。
  Future<void> _loadLive() async {
    final AylaProfileContentTarget target = _target;
    final String roomId = target.liveRoomId ?? '';
    if (!target.isLive || roomId.isEmpty) return;
    AylaProfileLiveData? live;
    Object? error;
    try {
      live = await _fetchers.live(roomId);
    } catch (caught) {
      error = caught;
    }
    if (error != null) {
      _recordMediaFailure(kAylaProfileLiveErrorLabel, error);
      return;
    }
    _emit(_state.copyWith(live: live));
  }

  /// 正在语音（tsx 81–87）：规则与直播同。
  Future<void> _loadVoice() async {
    final AylaProfileContentTarget target = _target;
    final String roomId = target.voiceRoomId ?? '';
    if (!target.isInVoice || roomId.isEmpty) return;
    AylaProfileVoiceData? voice;
    Object? error;
    try {
      voice = await _fetchers.voice(roomId);
    } catch (caught) {
      error = caught;
    }
    if (error != null) {
      _recordMediaFailure(kAylaProfileVoiceErrorLabel, error);
      return;
    }
    _emit(_state.copyWith(voice: voice));
  }

  /// 帖子（tsx 89–101）：**总是**请求（与 live/voice 不同，帖子卡不依赖 owner 的实时标志）。
  Future<void> _loadPosts() async {
    final AylaProfileContentTarget target = _target;
    List<AylaProfilePostItem>? posts;
    Object? error;
    try {
      posts = await _fetchers.posts(target.ownerId, target.mine);
    } catch (caught) {
      error = caught;
    }
    if (error == null) {
      _emit(_state.copyWith(posts: posts, postsLoading: false));
      return;
    }
    // web 口径（tsx 99）：`e instanceof Error ? e.message : "帖子加载失败"`。
    final String message = error is ApiException
        ? error.message
        : kAylaProfilePostsErrorFallback;
    _emit(_state.copyWith(
      postsLoading: false,
      error: _joinError(_state.error, message),
    ));
  }

  /// 直播 / 语音失败：**403 = can_view 不可见 ⇒ 静默不展示该卡**（web tsx 76/84 同）；
  /// 其余（网络失败 status 0 / 5xx / 404 / 非 [ApiException]）并入错误位（见文件头差异 3）。
  void _recordMediaFailure(String label, Object error) {
    if (error is ApiException && error.status == 403) return;
    final String detail = error is ApiException ? error.message : '';
    _emit(_state.copyWith(
      error: _joinError(
        _state.error,
        detail.isEmpty ? label : '$label：$detail',
      ),
    ));
  }

  /// 多个来源同时失败时逐行列出（组件用单个 `Text` 渲染，换行即分条）。
  static String _joinError(String? head, String line) =>
      (head == null || head.isEmpty) ? line : '$head\n$line';

  /// 三个源并发跑完（由 [aylaLoadProfileContent] 在 microtask 里发起）。
  ///
  /// 私有：[aylaLoadProfileContent] 保证只发起一次（重复发起会重复写状态）。
  Future<void> _run() => Future.wait(<Future<void>>[
        _loadLive(),
        _loadVoice(),
        _loadPosts(),
      ]);
}

/// 启动一次装载（web `useEffect` 的函数体，tsx 70–103）。
///
/// 每个源解析后通过 [onUpdate] 回调**完整快照**（等价 web 的三次 `setState`）；
/// 换 owner / 卸载时调用 [AylaProfileContentLoad.cancel]。
///
/// ⚠️ 发起被推到 **microtask**：调用方（页面）是在 `build` 里按依赖变化开启装载的，
/// 那一刻同步发请求既不利于可观测性，也让「首个回调必定晚于本次 build」这条不变量
/// 依赖 `await` 的实现细节。推到 microtask 后，`onUpdate` **一定**不在 build 期间触发。
AylaProfileContentLoad aylaLoadProfileContent({
  required AylaProfileContentTarget target,
  required ValueChanged<AylaProfileContentState> onUpdate,
  AylaProfileContentFetchers fetchers = const AylaProfileContentFetchers(),
}) {
  final AylaProfileContentLoad load =
      AylaProfileContentLoad._(target, fetchers, onUpdate);
  scheduleMicrotask(() => unawaited(load._run()));
  return load;
}
