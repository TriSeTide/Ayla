/// 应用初始化门（web `src/appInit.ts` 等价物）。
///
/// 状态机：idle（未触发）→ loading（预加载中）→ ready（完成，幂等短路）。
/// 登录成功后 `run()`，全屏加载完成后才进入页面；登出后 `reset()` 回 idle，
/// 下一位用户登录时重新预加载（数据按用户隔离）。
///
/// 覆盖范围（与 web 一致）：群列表、语音/直播/游戏目录、帖子信息流、
/// 私聊列表。M0 骨架：预加载函数体为占位（真实数据加载 M2+ 接入），
/// 20s 硬上限与状态机完整实现（web INIT_TIMEOUT_MS=20000 语义）。
library;

import 'package:flutter/foundation.dart';

/// 预加载硬上限：正常等待全部完成；个别请求挂起时不能永远卡在全屏加载界面。
const int kAppInitTimeoutMs = 20000;

/// 预加载门状态。
enum AppInitStatus { idle, loading, ready }

/// 核心数据预加载（web loadCoreData 等价物）。
/// M0 骨架：返回 Future.value 占位；M2+ 接入群列表 + voice/live/game 目录 +
/// 帖子流 + 私聊列表（loadSocial/loadDirectory/listPosts 等价物）。
/// 失败不阻断流程（catch 后 resolve，用户访问对应页面时会重试）。
Future<void> loadCoreData() async {
  // M0：无真实数据加载（群列表/目录 API 属 M2）；预留接口与超时语义
  await Future<void>.value();
}

/// 应用初始化门单例（ChangeNotifier，router/App 订阅）。
class AppInit extends ChangeNotifier {
  AppInit._();

  static final AppInit instance = AppInit._();

  AppInitStatus _status = AppInitStatus.idle;
  Future<void>? _promise;

  AppInitStatus get status => _status;

  /// 幂等：ready 或已有在途 promise 时直接复用；否则启动预加载。
  Future<void> run() {
    final Future<void>? current = _promise;
    if (current != null) return current;
    if (_status == AppInitStatus.ready) return Future<void>.value();
    _status = AppInitStatus.loading;
    notifyListeners();
    // race 语义：loadCoreData 与 20s 硬上限先完成者定状态（web Promise.race
    // 等价物；超时后 loadCoreData 继续后台跑，页面进入后自行重试）
    _promise = loadCoreData()
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
