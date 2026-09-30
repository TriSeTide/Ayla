/// 应用初始化门（web `src/appInit.ts` 等价物）。
///
/// 状态机：idle（未触发）→ loading（预加载中）→ ready（完成，幂等短路）。
/// 登录成功后 `run()`，全屏加载完成后才进入页面；登出后 `reset()` 回 idle，
/// 下一位用户登录时重新预加载（数据按用户隔离）。
///
/// 覆盖范围（与 web 一致）：群列表、语音/直播/游戏目录、帖子信息流、私聊列表 ——
/// 真实实现见 `state/app_preload.dart`（经 [aylaCoreDataLoader] 注入，见下）。
/// 20s 硬上限与状态机为 web INIT_TIMEOUT_MS=20000 语义。
library;

import 'package:flutter/foundation.dart';

/// 预加载硬上限：正常等待全部完成；个别请求挂起时不能永远卡在全屏加载界面。
const int kAppInitTimeoutMs = 20000;

/// 预加载门状态。
enum AppInitStatus { idle, loading, ready }

/// 核心数据预加载实现类型（web `loadCoreData`，`appInit.ts:31–46`）。
///
/// 参数为当前用户 id（进 web `directoryKey` 的 user 段；登录 / 会话恢复后由调用方给出）。
typedef AylaCoreDataLoader = Future<void> Function(String? userId);

/// 预加载实现注入点。
///
/// web 的 `appInit.ts` 直接 import 各 store；Flutter 侧 `lib/core/` 不依赖 `lib/state/`
/// （依赖方向 core ← state）⇒ 由 `state/app_preload.dart` 经 `aylaRegisterCoreDataLoader()`
/// 在 `main.dart` 启动时注入。**未接线时保持空行为**（门控状态机照常工作）。
AylaCoreDataLoader? aylaCoreDataLoader;

/// 跑核心数据预加载（web `loadCoreData`）。
///
/// 失败不阻断流程（web `appInit.ts:43–45` 的 catch 语义由注入实现承担，
/// 用户访问对应页面时会重试）。
Future<void> loadCoreData(String? userId) async {
  final AylaCoreDataLoader? loader = aylaCoreDataLoader;
  if (loader == null) return;
  await loader(userId);
}

/// 应用初始化门单例（ChangeNotifier，router/App 订阅）。
class AppInit extends ChangeNotifier {
  AppInit._();

  static final AppInit instance = AppInit._();

  AppInitStatus _status = AppInitStatus.idle;
  Future<void>? _promise;

  AppInitStatus get status => _status;

  /// 幂等：ready 或已有在途 promise 时直接复用；否则启动预加载。
  ///
  /// [userId] 传给预加载实现（进目录 record 的 key 段，web `directoryKey` 同）。
  Future<void> run({String? userId}) {
    final Future<void>? current = _promise;
    if (current != null) return current;
    if (_status == AppInitStatus.ready) return Future<void>.value();
    _status = AppInitStatus.loading;
    notifyListeners();
    // race 语义：loadCoreData 与 20s 硬上限先完成者定状态（web Promise.race
    // 等价物；超时后 loadCoreData 继续后台跑，页面进入后自行重试）
    _promise = loadCoreData(userId)
        .timeout(
          const Duration(milliseconds: kAppInitTimeoutMs),
          onTimeout: () {},
        )
        .whenComplete(() {
      _status = AppInitStatus.ready;
      notifyListeners();
    });
    return _promise!;
  }

  /// 登出后重置：下一位用户登录时重新预加载。
  void reset() {
    if (_status == AppInitStatus.idle) return;
    _status = AppInitStatus.idle;
    _promise = null;
    notifyListeners();
  }
}
