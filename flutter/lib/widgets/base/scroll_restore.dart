/// AylaScrollRestore —— 列表返回滚动位置恢复（web `hooks/useScrollRestore.ts`，105 行）。
///
/// ## 为什么需要它
/// web 全站在 9 个页面用 `useScrollRestore` 做「进详情 → 返回列表，停在原位」：
/// `SearchPage.tsx:118` · `PostDetailPage.tsx:135` · `PostsHubPage.tsx:119` ·
/// `MyPostsPage.tsx:75` · `FavoritesPage.tsx:157` · `GamesHubPage.tsx:83` ·
/// `VoiceHubPage.tsx:88` · `LiveHubPage.tsx:76` · `group/GroupPosts.tsx:366`。
/// Flutter 侧此前**全站未实现**（各页文件头自登记）—— 本件是它的等价物。
///
/// ## 逐条对应（web 事实源）
/// | web | 行 | 本件 |
/// |---|---|---|
/// | `const scrollMemory = new Map<string, number>()` | 18 | [AylaScrollMemory] 模块级记忆（key 隔离） |
/// | `clearScrollMemory()` | 21–23 | [AylaScrollMemory.clear] |
/// | `saveScrollPosition(key, el)` | 31–34 | [AylaScrollMemory.save]（`el == null` ⇒ 不写） |
/// | `active` / `ready` 两个门 | 36–41 / 53–54 | [active] / [ready]（缺省均 true） |
/// | `useLayoutEffect` 主体：不 active ⇒ 直接返回 | 60–64 | [update] / [_reconcile] |
/// | `restoring = scrollMemory.has(key)`（**即使 ready=false 也置位**） | 65–68 | 同 |
/// | `if (!ready || !hasSavedPosition || saved <= 0) return` | 69 | 同 |
/// | `el.scrollTop = saved` | 73 | `controller.jumpTo(saved)` |
/// | 下一帧再补一次（瀑布流列高落定晚于首次赋值） | 75–79 | `SchedulerBinding.scheduleFrameCallback` 再 jump 一次 |
/// | 卸载/失活时**绝不回写** scrollTop（退出动画期间已归零会覆盖正确位置） | 97–101 | [detach] 只卸监听、不写记忆 |
///
/// ## 口径差异（登记）
/// 1. **写入沿**：web 在 `scroll` 事件里写 `el.scrollTop`；Flutter 的等价物是
///    `ScrollController.addListener`（`ScrollController.attach` 给每个 position 挂
///    `notifyListeners`，见 `widgets/scroll_controller.dart:253`）—— 语义同：
///    每次真实滚动写一次当前 offset；[active] 为 false 时不写（web 的
///    `useEffect(... active ...)` 在失活时卸载监听，同义）。
/// 2. **`scrollTop=0` 的 restoring**：web 用 `scrollMemory.has(key)` 表达「命中过历史记录
///    （含 0）」，Flutter 侧同用 [hasSavedPosition]（`saved <= 0` 仍置 `restoring = true`，
///    只是不执行 jump）—— 调用方据此禁 reveal stagger。
/// 3. **`requestAnimationFrame`**：Flutter 无 rAF，用
///    `SchedulerBinding.scheduleFrameCallback`（同为「下一帧」语义）。
/// 4. **`useLayoutEffect` 的时机**：Flutter 的 build 阶段即「布局前」，与 web 的
///    layout effect 同档 —— 但**必须由调用方在 `build()` 里调 [update]**（页面每帧都调，
///    值没变时是空操作）。页面也可以在任何时刻**主动**再调一次 [update] 强制重新对账
///    （位置刚出现、或列表内容刚就绪时）。
///    ⚠️ 不能挂在 `ScrollController.onAttach` 上：`onAttach` 是 **final** 字段
///    （`widgets/scroll_controller.dart:133`）⇒ 只能构造时传，不能事后链。
///
/// ## 公开面
/// `AylaScrollMemory` · `AylaScrollRestore`
library;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// 模块级滚动位置记忆（web `scrollMemory`，`useScrollRestore.ts:18`）。
///
/// key 隔离：各页用**自己的列表键**（`search:{scope}`、`post-comments:{id}`、
/// `group-posts:{group}` …），互不串味。
class AylaScrollMemory {
  AylaScrollMemory._();

  static final Map<String, double> _memory = <String, double>{};

  /// 该 key 是否命中过历史记录（**含 0**；web `scrollMemory.has(key)`）。
  static bool has(String key) => _memory.containsKey(key);

  /// 取记录（未命中 = null；不伪造 0）。
  static double? get(String key) => _memory[key];

  /// 显式保存当前位置（web `saveScrollPosition`，:31–34）。
  ///
  /// 详情入口在滚动容器仍存在时调用它，保证「以用户点击瞬间的位置为权威记录」。
  static void save(String key, ScrollController? controller) {
    if (controller == null) return;
    if (!controller.hasClients) return;
    _memory[key] = controller.offset;
  }

  /// 直接写入一个位置（测试与「已知位置」场景用；生产路径走 [save]）。
  static void put(String key, double offset) {
    _memory[key] = offset;
  }

  /// 删一条（测试隔离用）。
  static void remove(String key) {
    _memory.remove(key);
  }

  /// 清空全部（登出 / 测试隔离；web `clearScrollMemory()`，:21–23）。
  static void clear() => _memory.clear();
}

/// 单个列表的滚动恢复控制器（web `useScrollRestore` 的等价物）。
///
/// 用法（页面持有，不随 body 分支重建）：先 `attach()`，随列表生命周期调
/// `update(active: ..., ready: ...)`，页面 dispose 时 `dispose()`。
class AylaScrollRestore {
  AylaScrollRestore({
    required this.key,
    required this.controller,
    bool active = true,
    bool ready = true,
  })  : _active = active,
        _ready = ready;

  /// 列表唯一键（web `key`）。
  final String key;

  /// 滚动容器控制器（web 的 `ref`）。
  final ScrollController controller;

  bool _active;
  bool _ready;

  /// 当前是否渲染列表滚动容器（web `active`；详情分支传 false）。
  bool get active => _active;

  /// 列表内容是否已就绪并形成可恢复高度（web `ready`）。
  bool get ready => _ready;

  bool _restoring = false;
  bool _hasSaved = false;
  bool _attached = false;
  bool _disposed = false;
  int? _rafId;

  /// 恢复落位在途（从 `jumpTo` 起到补跳帧结束）。
  ///
  /// ⚠️ **必须有这道闸**：Flutter 的 `ScrollController.jumpTo` **同步**触发
  /// `notifyListeners`（`scroll_controller.dart:253` 把 position 的 listener 转成控制器的），
  /// 而首帧内容尚未铺开时 `maxScrollExtent == 0` ⇒ 落位会被 clamp 成 0、并以「一次真实滚动」
  /// 的形态回写记忆 —— 正好是 web 警告过的「退出阶段把正确位置覆盖成 0」。
  /// 浏览器里 `scrollTop` 赋值触发的是**异步** scroll 事件（写回的是同一个值），
  /// 没有这一档；Flutter 需要显式表达同一保护。
  bool _restoreInFlight = false;

  /// 已排了一次「位置尚未创建」的下一帧重试（避免每帧空转）。
  bool _retryScheduled = false;

  /// 本次列表激活是否命中历史记录（**含 scrollTop=0**）。
  /// 调用方据此禁 reveal stagger（web 返回的 `restoring`）。
  bool get restoring => _restoring;

  /// 记忆里是否存在本 key 的记录（web `scrollMemory.has(key)`）。
  bool get hasSavedPosition => _hasSaved;

  /// 挂监听并做首次对账（web `useLayoutEffect` 的首次执行）。
  void attach() {
    if (_disposed || _attached) return;
    _attached = true;
    controller.addListener(_onScroll);
    _reconcile();
  }

  /// 更新两个门并重新对账（web `useLayoutEffect` deps `[active, key, ready, ref]`）。
  ///
  /// 幂等；两个门都未变时是**空操作**（不重排帧回调）。调用方可以在 `build()` 里
  /// 每帧调用它 —— 这就是 web「每次 render 都会跑一遍 layout effect」的等价时机。
  void update({bool? active, bool? ready}) {
    if (_disposed) return;
    final bool nextActive = active ?? _active;
    final bool nextReady = ready ?? _ready;
    final bool changed = nextActive != _active || nextReady != _ready;
    _active = nextActive;
    _ready = nextReady;
    if (!changed) return;
    _reconcile();
  }

  /// 解绑（页面 dispose 调用）。
  ///
  /// ⚠️ **只卸监听，不写记忆** —— web 原话（:97–101）：路由/退出阶段可能比显式保存更晚，
  /// 「在这里写回 latestTopRef」反而会把正确位置覆盖成退出动画中的 0。
  void detach() {
    if (!_attached) return;
    _attached = false;
    controller.removeListener(_onScroll);
    _cancelRaf();
  }

  /// 彻底释放（幂等）。
  void dispose() {
    if (_disposed) return;
    detach();
    _disposed = true;
    _restoring = false;
  }

  /// 滚动时实时写记忆（web `el.addEventListener("scroll", onScroll)`，:93–95）。
  void _onScroll() {
    if (_disposed || !_active) return;
    // 落位在途：位置变化来自本件自己的 jumpTo，不是用户滚动 ⇒ 不回写（见 [_restoreInFlight]）。
    if (_restoreInFlight) return;
    if (!controller.hasClients) return;
    AylaScrollMemory.put(key, controller.offset);
  }

  void _reconcile() {
    _cancelRaf();
    if (!_active) {
      _restoring = false;
      return;
    }
    _hasSaved = AylaScrollMemory.has(key);
    // scrollTop=0 也代表一次真实的详情返回，调用方仍须跳过 reveal stagger。
    _restoring = _hasSaved;
    if (!_ready || !_hasSaved) return;
    final double saved = AylaScrollMemory.get(key) ?? 0;
    if (saved <= 0) return;
    if (!controller.hasClients) {
      // 位置尚未创建：页面还在骨架分支，或列表刚换容器。
      // web 的 layout effect 在 commit 后跑，容器必然已存在；Flutter 的 build 早于
      // 子级挂载 ⇒ 这里补一次「下一帧重试」（与 :75–79 的补跳同一手法）。
      _scheduleRetry();
      return;
    }
    _restoreInFlight = true;
    controller.jumpTo(saved);
    // 下一帧再补一次：同一提交中的瀑布流/列表列高可能在首帧赋值后才最终落定。
    _rafId = SchedulerBinding.instance.scheduleFrameCallback((Duration _) {
      _rafId = null;
      if (_disposed || !_active || !controller.hasClients) {
        _restoreInFlight = false;
        return;
      }
      controller.jumpTo(saved);
      _restoreInFlight = false;
    });
  }

  /// 下一帧重试一次对账（容器迟到时用；每轮生命周期只排一次）。
  void _scheduleRetry() {
    if (_retryScheduled) return;
    _retryScheduled = true;
    _rafId = SchedulerBinding.instance.scheduleFrameCallback((Duration _) {
      _rafId = null;
      _retryScheduled = false;
      if (_disposed) return;
      _reconcile();
    });
  }

  void _cancelRaf() {
    _retryScheduled = false;
    final int? id = _rafId;
    if (id == null) return;
    _rafId = null;
    _restoreInFlight = false;
    SchedulerBinding.instance.cancelFrameCallbackWithId(id);
  }
}
