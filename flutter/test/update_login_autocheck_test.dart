/// 「登录后自动检查更新并弹窗」的**接线回归锁**（电脑端 + 手机端）。
///
/// ## 为什么必须有这条文件（2026-11-05 用户实报）
/// 用户要求「电脑端 + 手机端的登录自动检查更新并弹窗」。链路上的组件其实都在
/// （`core/update/*` + `AylaUpdateDialog` + `AylaUpdateHost`），但：
///
/// 1. **冷启动主路径根本没调检查**：`_restoreSessionWithToken` 里手写了一份登录收尾，
///    漏掉 `checkOnLogin()` —— 而电脑端每次开 App、手机端切后台被回收后回来，走的
///    都是这条 refresh 静默续期路径 ⇒ 更新弹窗几乎永远不会出现；
/// 2. **按会话而不是按进程计次**：`_loginCheckDone` 从不清零 ⇒「登出 → 换号登录」
///    之后再也不会弹更新；
/// 3. **手机端返回键会绕过强制更新**：更新弹窗不是路由，`aylaBackActionFor` 没有这一档
///    ⇒ 按返回落到 `homeExit`，「再按一次退出应用」直接退出 App。
///
/// 本文件锁三件事：
/// ① 会话恢复路径**真的**会发起更新检查（有更新 ⇒ 打开弹窗；失败 ⇒ 不影响登录）；
/// ② 换登录会话（登出）后复位，下一次登录会再检查；
/// ③ 返回键分档：有更新弹窗 ⇒ 走 `updateDialog` 档（绝不落到退出 App）。
///
/// ⚠️ 全程共用一个 `ProviderContainer`：`_restartRealtimeBridges` 会把监听挂到
/// **模块级** store 上，每用例换容器会让上一轮的监听指向已 dispose 的容器
/// （`Bad state: Tried to read a provider from a ProviderContainer that was already
/// disposed`）—— 那是测试夹具问题，不是产品缺陷。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/app_init.dart';
import '../lib/core/net/dio_client.dart';
import '../lib/core/update/app_version.dart';
import '../lib/core/update/update_api.dart';
import '../lib/core/update/update_applier.dart';
import '../lib/core/update/update_controller.dart';
import '../lib/core/update/update_downloader.dart';
import '../lib/layout/app_back.dart' show AylaBackAction, aylaBackActionFor;
import '../lib/state/auth_bootstrap.dart';
import '../lib/state/auth_prefs.dart';
import '../lib/state/auth_state.dart';
import '../lib/state/update_providers.dart';

const String _sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

/// 内存安全存储（生产走 flutter_secure_storage；这里不碰平台通道）。
class _MemorySecureStore implements AylaSecureStore {
  _MemorySecureStore([Map<String, String>? seed])
      : data = seed ?? <String, String>{};

  final Map<String, String> data;

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> write(String key, String value) async => data[key] = value;

  @override
  Future<void> delete(String key) async => data.remove(key);
}

/// 可切换结果 / 可计数的更新 API 替身（不真的发请求）。
class _RecordingUpdateApi extends AylaUpdateApi {
  AylaUpdateCheck Function() result = _availableCheck;
  bool fail = false;
  int calls = 0;

  @override
  Future<AylaUpdateCheck> check({
    required AylaAppVersion version,
    String channel = AylaUpdateApi.defaultChannel,
    String? platform,
    String? arch,
  }) async {
    calls++;
    if (fail) throw const AylaUpdateException('network');
    return result();
  }
}

/// 最小认证后端：只实现本链路打到的端点（refresh / me / badges）。
class _Backend {
  bool refreshOk = true;

  Future<void> handle(HttpRequest req) async {
    final String path = req.uri.path;
    if (req.method == 'POST' && path == '/api/v1/auth/refresh/') {
      if (!refreshOk) {
        await _json(req, 401, <String, Object?>{'detail': '令牌无效'});
        return;
      }
      await _json(req, 200, <String, Object?>{
        'access': 'access-restored',
        'refresh': 'refresh-rotated',
      });
      return;
    }
    if (req.method == 'GET' && path == '/api/v1/me/') {
      await _json(req, 200, <String, Object?>{
        'id': '7',
        'username': 'alice',
        'nickname': 'Alice',
      });
      return;
    }
    if (req.method == 'GET' && path == '/api/v1/me/badges/') {
      await _json(req, 200, <String, Object?>{
        'request_badge': 0,
        'message_badge': 0,
      });
      return;
    }
    await _json(req, 404, <String, Object?>{'detail': 'not found'});
  }

  Future<void> _json(
    HttpRequest req,
    int status,
    Map<String, Object?> body,
  ) async {
    req.response.statusCode = status;
    req.response.headers.contentType =
        ContentType('application', 'json', charset: 'utf-8');
    req.response.write(jsonEncode(body));
    await req.response.close();
  }
}

AylaUpdateCheck _availableCheck() => const AylaUpdateCheck(
      channel: 'stable',
      updateAvailable: true,
      mandatory: false,
      degraded: false,
      reason: 'update_available',
      latest: AylaUpdateRelease(
        releaseId: 'stable-1.1.2-56',
        version: '1.1.2',
        build: 56,
        publishedAt: '2026-11-04T13:11:05+00:00',
        notes: '修复直播全屏标题栏',
        minSupportedBuild: 0,
      ),
      download: AylaUpdateDownload(
        kind: 'zip',
        url: 'https://example.com/a.zip',
        fileName: 'a.zip',
        size: 1024,
        sha256: _sha,
      ),
      currentVersion: '1.0.0',
      currentBuild: 1,
    );

AylaUpdateCheck _upToDateCheck() => const AylaUpdateCheck(
      channel: 'stable',
      updateAvailable: false,
      mandatory: false,
      degraded: false,
      reason: 'up_to_date',
      latest: null,
      download: null,
      currentVersion: '1.1.2',
      currentBuild: 56,
    );

void main() {
  // ⚠️ 不要初始化 TestWidgetsFlutterBinding：它会把全进程 HttpOverrides 换成 mock，
  // 任何 dart:io HTTP 都返回 400（本组要跑真实回环请求，见 auth_remember_test.dart）。
  HttpOverrides.global = null;

  late _Backend backend;
  late HttpServer server;
  late _MemorySecureStore secure;
  late ProviderContainer container;
  late _RecordingUpdateApi api;
  late AylaUpdateController controller;

  setUpAll(() async {
    backend = _Backend();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    // ignore: unawaited_futures
    server.listen(backend.handle);
    // 必须在**第一次** DioClient.init 之前设好（dio 的 baseUrl 只在 init 时构造）。
    DioClient.instance.debugBaseUrlOverride =
        'http://127.0.0.1:${server.port}';

    secure = _MemorySecureStore(<String, String>{
      AylaSessionTokenStore.keyRefreshToken: 'refresh-stored',
    });
    api = _RecordingUpdateApi();
    container = ProviderContainer(
      overrides: <Override>[
        authPrefsStoreProvider
            .overrideWithValue(AylaAuthPrefsStore(store: secure)),
        sessionTokenStoreProvider
            .overrideWithValue(AylaSessionTokenStore(store: secure)),
        updateControllerProvider.overrideWithValue(
          AylaUpdateController(
            api: api,
            downloader: AylaUpdateDownloader(),
            applier: AylaUpdateApplier(),
            versionLoader: () async =>
                const AylaAppVersion(version: '1.0.0', build: 1),
            // 关键：不真的退出进程（Windows 覆盖安装路径会 exit）。
            requestExit: (int code) {},
          ),
        ),
      ],
    );
    controller = container.read(updateControllerProvider);
    DioClient.instance.init(
      tokenStore: container.read(authNotifierProvider.notifier),
      onSessionExpired: () {},
    );
  });

  tearDownAll(() async {
    container.dispose();
    await server.close(force: true);
  });

  setUp(() {
    api.calls = 0;
    api.fail = false;
    api.result = _availableCheck;
    backend.refreshOk = true;
    AppInit.instance.reset();
    aylaResetAutoLoginGate();
    controller.resetForNewSession();
    container.read(authNotifierProvider.notifier).clear();
    secure.data[AylaSessionTokenStore.keyRefreshToken] = 'refresh-stored';
  });

  /// 等「不 await 的更新检查」跑完（`checkOnLogin` 刻意不阻塞登录链）。
  ///
  /// 不能用 `pumpAndSettle`（纯 Dart 测试无 widget）；这里让事件循环转几圈，
  /// 直到 api 被调用或达到上限 —— 上限是「真的没发起检查」的判据。
  Future<void> settleCheck({int expected = 1}) async {
    for (int i = 0; i < 200; i++) {
      if (api.calls >= expected) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  group('① 会话恢复（冷启动主路径）必须发起更新检查', () {
    test('refresh 续期成功后自动检查一次，并打开更新弹窗', () async {
      final AylaSessionRestoreOutcome outcome =
          await aylaRestoreSession(container);
      expect(outcome, AylaSessionRestoreOutcome.success);
      await settleCheck();
      expect(api.calls, 1, reason: '恢复路径必须调用 checkOnLogin');
      expect(controller.activeSession, isNotNull, reason: '有更新 ⇒ 打开弹窗会话');
      expect(controller.activeSession!.state.release.build, 56);
    });

    test('已是最新：照样检查，但不弹窗', () async {
      api.result = _upToDateCheck;
      final AylaSessionRestoreOutcome outcome =
          await aylaRestoreSession(container);
      expect(outcome, AylaSessionRestoreOutcome.success);
      await settleCheck();
      expect(api.calls, 1, reason: '已是最新也必须真的问过服务端');
      expect(controller.activeSession, isNull, reason: '没有更新就不该弹窗');
    });

    test('检查失败不打扰登录：恢复仍成功、无弹窗', () async {
      api.fail = true;
      final AylaSessionRestoreOutcome outcome =
          await aylaRestoreSession(container);
      expect(outcome, AylaSessionRestoreOutcome.success,
          reason: '更新检查失败不影响登录');
      await settleCheck();
      expect(api.calls, 1);
      expect(controller.activeSession, isNull, reason: '失败不弹错误弹窗');
    });

    test('没有 refresh 令牌 ⇒ 不走恢复、也不该误报已检查', () async {
      secure.data.remove(AylaSessionTokenStore.keyRefreshToken);
      final AylaSessionRestoreOutcome outcome =
          await aylaRestoreSession(container);
      expect(outcome, AylaSessionRestoreOutcome.noToken);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(api.calls, 0, reason: '没登录就不检查更新');
      expect(controller.loginCheckDone, isFalse);
    });
  });

  group('② 换登录会话（登出）后复位自动检查位', () {
    test('同一会话只检查一次；登出复位后下一次登录会再检查', () async {
      await controller.checkOnLogin();
      await controller.checkOnLogin();
      expect(api.calls, 1, reason: '同一登录会话只自动检查一次');
      expect(controller.activeSession, isNotNull);

      controller.resetForNewSession();
      expect(controller.loginCheckDone, isFalse, reason: '登出必须复位');
      expect(controller.activeSession, isNull, reason: '登出必须丢弃在途弹窗');

      await controller.checkOnLogin();
      expect(api.calls, 2, reason: '换会话后重新登录应当再检查一次');
    });

    test('aylaLogoutForContainer 会调用复位（换号登录仍弹更新）', () async {
      await controller.checkOnLogin();
      expect(controller.loginCheckDone, isTrue);
      await aylaLogoutForContainer(container);
      expect(controller.loginCheckDone, isFalse,
          reason: '登出链必须复位更新检查位');
      expect(controller.activeSession, isNull);
    });
  });

  group('③ 返回键分档：更新弹窗优先，绝不退出 App', () {
    test('有更新弹窗 ⇒ updateDialog 档（排在所有档之前）', () {
      expect(
        aylaBackActionFor(
          canPop: true,
          pathname: '/group',
          hasUpdateDialog: true,
        ),
        AylaBackAction.updateDialog,
      );
      // 强制更新 + 主页 + 栈空：修复前会落到 homeExit（= 再按一次退出应用）。
      expect(
        aylaBackActionFor(
          canPop: false,
          pathname: '/group',
          hasUpdateDialog: true,
        ),
        AylaBackAction.updateDialog,
      );
      // 群场景里也必须先给弹窗（群页三级兜底不能把弹窗顶掉）。
      expect(
        aylaBackActionFor(
          canPop: false,
          pathname: '/group/g1/chat',
          hasUpdateDialog: true,
        ),
        AylaBackAction.updateDialog,
      );
      // 直播全屏与更新弹窗同时存在：更新弹窗更靠前（模态优先）。
      expect(
        aylaBackActionFor(
          canPop: true,
          pathname: '/live/9',
          hasUpdateDialog: true,
          hasLiveFullscreen: true,
        ),
        AylaBackAction.updateDialog,
      );
    });

    test('没有弹窗时既有分档不受影响', () {
      expect(
        aylaBackActionFor(canPop: true, pathname: '/favorites'),
        AylaBackAction.popRoute,
      );
      expect(
        aylaBackActionFor(canPop: false, pathname: '/group'),
        AylaBackAction.homeExit,
      );
      expect(
        aylaBackActionFor(
          canPop: true,
          pathname: '/live/9',
          hasLiveFullscreen: true,
        ),
        AylaBackAction.liveFullscreen,
      );
    });
  });

  group('④ 接线点存在（「组件写完 ≠ 出现在运行时」的最小锁）', () {
    test('壳层仍挂 AylaUpdateHost；弹窗宿主仍挂根 Overlay', () {
      final String shell = _readSource('lib/layout/app_shell.dart');
      expect(shell.contains('AylaUpdateHost()'), isTrue,
          reason: 'layout/app_shell.dart 必须挂 AylaUpdateHost');
      final String host = _readSource('lib/state/update_providers.dart');
      expect(host.contains('AylaRootOverlay'), isTrue,
          reason: '更新弹窗必须挂根 Overlay（否则顶栏/标题栏不被压暗）');
      expect(host.contains('aylaUpdateDialogBackHandler'), isTrue,
          reason: '弹窗必须登记返回键处理器');
    });

    test('两条登录路径都走同一个收尾（含更新检查）', () {
      final String src = _readSource('lib/state/auth_bootstrap.dart');
      expect('_finishSignIn('.allMatches(src).length, greaterThanOrEqualTo(3),
          reason: '定义 1 处 + 两条登录路径各调 1 处');
      expect(src.contains('checkOnLogin()'), isTrue);
    });
  });
}

/// 读源码（结构性接线断言的辅助；工作目录 = `Ayla/flutter`）。
String _readSource(String path) {
  final File file = File(path);
  return file.existsSync() ? file.readAsStringSync() : '';
}
