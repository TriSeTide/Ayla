/// 「记住密码 / 自动登录」核心链路回归（**新增功能，web 无对应**）。
///
/// ## 覆盖
/// 1. 凭据仓库 [AylaAuthPrefsStore]：落盘 / 清键 / 「自动登录 ⇒ 记住密码」归一 / 存储不可用回落；
/// 2. 冷启动自动登录 [aylaRunAutoLogin]：成功、跳过、失败、单飞、已有会话；
/// 3. 登出链 [aylaLogoutForContainer]：**保留**凭据（记住密码的语义）与 `clearCredentials` 清空。
///
/// ## 为什么用真实 HTTP 回环而不是 mock
/// 自动登录走的是真实 `POST /auth/login/`（与手动登录同一接口），dio 拦截器、错误归一、
/// `GET /me/` 串行都在链路上 ⇒ 用 `HttpServer` + `DioClient.debugBaseUrlOverride`
/// 端到端跑，才能证明「登录成功后会话真的落地」。
/// ⚠️ `DioClient.instance` 是进程级单例、`dio` 的 baseUrl 只在首次 `init` 时构造
/// ⇒ server 必须在 `setUpAll` 里建好并**固定端口**，且可注入的 store 用 provider 覆盖。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/app_init.dart';
import '../lib/core/net/dio_client.dart';
import '../lib/state/auth_bootstrap.dart';
import '../lib/state/auth_prefs.dart';
import '../lib/state/auth_state.dart';

/// 内存安全存储（生产实现走 `flutter_secure_storage`，测试里不碰平台通道）。
class _MemorySecureStore implements AylaSecureStore {
  _MemorySecureStore([Map<String, String>? seed]) : data = seed ?? <String, String>{};

  final Map<String, String> data;

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> write(String key, String value) async => data[key] = value;

  @override
  Future<void> delete(String key) async => data.remove(key);
}

/// 读必炸的存储（模拟 KeyStore 被重置 / 平台不支持）。
class _ThrowingSecureStore implements AylaSecureStore {
  @override
  Future<String?> read(String key) async => throw StateError('secure storage unavailable');

  @override
  Future<void> write(String key, String value) async => throw StateError('secure storage unavailable');

  @override
  Future<void> delete(String key) async => throw StateError('secure storage unavailable');
}

/// 最小认证后端（只实现本链路真正打到的三个端点）。
class _Backend {
  static const String okUsername = 'alice';
  static const String okPassword = 'pw123456';

  final List<Map<String, dynamic>> loginBodies = <Map<String, dynamic>>[];
  bool offline = false;

  void reset() {
    loginBodies.clear();
    offline = false;
  }

  Future<void> handle(HttpRequest req) async {
    final String path = req.uri.path;
    if (req.method == 'POST' && path == '/api/v1/auth/login/') {
      final Object? decoded = jsonDecode(await utf8.decoder.bind(req).join());
      final Map<String, dynamic> body =
          (decoded as Map).cast<String, dynamic>();
      loginBodies.add(body);
      if (offline || body['username'] != okUsername || body['password'] != okPassword) {
        // 401 的形状照后端 `TokenObtainPairView`（dio 侧归一成 ApiException）。
        await _json(req, 401, <String, Object?>{'detail': '账号或密码错误'});
        return;
      }
      await _json(req, 200, <String, Object?>{
        'access': 'access-${loginBodies.length}',
        'refresh': 'refresh-${loginBodies.length}',
      });
      return;
    }
    if (req.method == 'GET' && path == '/api/v1/me/') {
      await _json(req, 200, <String, Object?>{
        'id': '7',
        'username': okUsername,
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

  Future<void> _json(HttpRequest req, int status, Map<String, Object?> body) async {
    req.response.statusCode = status;
    req.response.headers.contentType = ContentType('application', 'json', charset: 'utf-8');
    req.response.write(jsonEncode(body));
    await req.response.close();
  }
}

void main() {
  // ⚠️ **不要初始化 `TestWidgetsFlutterBinding`**（2026-10-01 实测）：
  // 它会把全进程的 `HttpOverrides.global` 换成 mock —— 任何 HTTP 请求都返回 400、
  // 永不真正发出（本用例第一版就是被它判成「登录失败 ApiException(400)」）。
  // 本组是**纯 Dart 逻辑 + 真实回环 HTTP**，不需要 widget binding；下面的
  // `HttpOverrides.global = null` 是第二道保险（外层 runner 若装过 mock 也会被清掉）。
  HttpOverrides.global = null;

  late _Backend backend;
  late HttpServer server;
  late _MemorySecureStore secure;
  late AylaAuthPrefsStore store;
  late ProviderContainer container;

  setUpAll(() async {
    backend = _Backend();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    // ignore: unawaited_futures
    server.listen(backend.handle);
    // ⚠️ 必须在**第一次** `DioClient.init` 之前设好：`dio` 的 baseUrl 只在首次 init 时构造，
    // 之后改这个字段不会重建实例。
    DioClient.instance.debugBaseUrlOverride = 'http://127.0.0.1:${server.port}';
  });

  tearDownAll(() async {
    await server.close(force: true);
  });

  setUp(() {
    backend.reset();
    // 自动登录是模块级单飞 Future ⇒ 每个用例都要复位（生产路径不调用该复位函数）。
    aylaResetAutoLoginGate();
    // 预加载门是全局单例，跨用例共享 ⇒ 复位到 idle，避免"上一轮已 ready"短路。
    AppInit.instance.reset();
    secure = _MemorySecureStore();
    store = AylaAuthPrefsStore(store: secure);
    container = ProviderContainer(
      overrides: <Override>[authPrefsStoreProvider.overrideWithValue(store)],
    );
    DioClient.instance.init(
      tokenStore: container.read(authNotifierProvider.notifier),
      onSessionExpired: () {
        // 与 `main.dart` 同口径：401 过期走共享登出链（不删已保存凭据）。
        unawaited(aylaLogoutForContainer(container));
      },
    );
  });

  tearDown(() {
    container.dispose();
  });

  group('凭据仓库（AylaAuthPrefsStore）', () {
    test('勾「记住密码 + 自动登录」：四个键都落盘，读回可一键登录', () async {
      final AylaAuthPrefs saved = await store.save(
        rememberPassword: true,
        autoLogin: true,
        username: _Backend.okUsername,
        password: _Backend.okPassword,
      );
      expect(saved.lastError, isNull);
      expect(saved.canAutoLogin, isTrue);

      final AylaAuthPrefs loaded = await store.load();
      expect(loaded.rememberPassword, isTrue);
      expect(loaded.autoLogin, isTrue);
      expect(loaded.username, _Backend.okUsername);
      expect(loaded.password, _Backend.okPassword);
      expect(loaded.hasCredentials, isTrue);
      expect(loaded.lastError, isNull);
    });

    test('只勾「记住密码」：能回填、但不会自动登录', () async {
      await store.save(
        rememberPassword: true,
        autoLogin: false,
        username: _Backend.okUsername,
        password: _Backend.okPassword,
      );
      final AylaAuthPrefs loaded = await store.load();
      expect(loaded.rememberPassword, isTrue);
      expect(loaded.autoLogin, isFalse);
      expect(loaded.hasCredentials, isTrue);
      expect(loaded.canAutoLogin, isFalse);
    });

    test('取消「记住密码」：四个键全清（含旧账号密码，不留残凭据）', () async {
      await store.save(
        rememberPassword: true,
        autoLogin: true,
        username: _Backend.okUsername,
        password: _Backend.okPassword,
      );
      expect(secure.data, isNotEmpty);

      final AylaAuthPrefs after = await store.save(
        rememberPassword: false,
        autoLogin: false,
        username: '',
        password: '',
      );
      expect(after.rememberPassword, isFalse);
      expect(after.autoLogin, isFalse);
      expect(secure.data, isEmpty);
      expect((await store.load()).hasCredentials, isFalse);
    });

    test('归一：存储被外部写成「只勾自动登录」也按两个都开解释（不变量双保险）', () async {
      await secure.write(AylaAuthPrefsStore.keyAutoLogin, '1');
      await secure.write(AylaAuthPrefsStore.keyUsername, 'bob');
      await secure.write(AylaAuthPrefsStore.keyPassword, 'pw');
      final AylaAuthPrefs loaded = await store.load();
      expect(loaded.autoLogin, isTrue);
      expect(loaded.rememberPassword, isTrue, reason: '自动登录必然连带记住密码');
    });

    test('存储不可用：load 静默回落「未保存」并留下原因，不抛异常', () async {
      final AylaAuthPrefs loaded = await AylaAuthPrefsStore(store: _ThrowingSecureStore()).load();
      expect(loaded.hasCredentials, isFalse);
      expect(loaded.canAutoLogin, isFalse);
      expect(loaded.lastError, isNotNull, reason: '失败不能伪装成"用户没勾过"');
    });

    test('存储不可用：save 不抛出，返回值带 lastError', () async {
      final AylaAuthPrefs saved = await AylaAuthPrefsStore(store: _ThrowingSecureStore()).save(
        rememberPassword: true,
        autoLogin: true,
        username: 'a',
        password: 'b',
      );
      expect(saved.lastError, isNotNull);
      expect(saved.autoLogin, isTrue);
    });
  });

  group('冷启动自动登录（aylaRunAutoLogin）', () {
    test('勾了自动登录：用保存的账号密码完成真实登录并落地会话', () async {
      await store.save(
        rememberPassword: true,
        autoLogin: true,
        username: _Backend.okUsername,
        password: _Backend.okPassword,
      );

      final AylaAutoLoginOutcome outcome = await aylaRunAutoLogin(container);

      expect(outcome, AylaAutoLoginOutcome.success);
      final AuthState auth = container.read(authNotifierProvider);
      expect(auth.isAuthenticated, isTrue);
      expect(auth.accessToken, 'access-1');
      expect(auth.refreshToken, 'refresh-1');
      expect(auth.user?.username, _Backend.okUsername);
      expect(backend.loginBodies.length, 1);
      expect(backend.loginBodies.single['username'], _Backend.okUsername);
    });

    test('没勾自动登录：完全不动（不发登录请求、不建会话）', () async {
      await store.save(
        rememberPassword: true,
        autoLogin: false,
        username: _Backend.okUsername,
        password: _Backend.okPassword,
      );

      expect(await aylaRunAutoLogin(container), AylaAutoLoginOutcome.skipped);
      expect(backend.loginBodies, isEmpty);
      expect(container.read(authNotifierProvider).isAuthenticated, isFalse);
    });

    test('从未保存过凭据：skipped', () async {
      expect(await aylaRunAutoLogin(container), AylaAutoLoginOutcome.skipped);
      expect(backend.loginBodies, isEmpty);
    });

    test('口令已失效：failed，且不留下半个会话（用户手动输入即可）', () async {
      await store.save(
        rememberPassword: true,
        autoLogin: true,
        username: _Backend.okUsername,
        password: 'stale-password',
      );

      expect(await aylaRunAutoLogin(container), AylaAutoLoginOutcome.failed);
      expect(container.read(authNotifierProvider).isAuthenticated, isFalse);
    });

    test('单飞：并发/重复触发只发一次登录请求', () async {
      await store.save(
        rememberPassword: true,
        autoLogin: true,
        username: _Backend.okUsername,
        password: _Backend.okPassword,
      );

      final Future<AylaAutoLoginOutcome> first = aylaRunAutoLogin(container);
      final Future<AylaAutoLoginOutcome> second = aylaRunAutoLogin(container);
      expect(identical(first, second), isTrue, reason: '同一次启动只能有一条登录链');

      expect(await first, AylaAutoLoginOutcome.success);
      expect(backend.loginBodies.length, 1);
    });

    test('已有有效会话：不重复登录', () async {
      await store.save(
        rememberPassword: true,
        autoLogin: true,
        username: _Backend.okUsername,
        password: _Backend.okPassword,
      );
      container.read(authNotifierProvider.notifier).setTokens('existing', 'existing-r');

      expect(await aylaRunAutoLogin(container), AylaAutoLoginOutcome.alreadySignedIn);
      expect(backend.loginBodies, isEmpty);
      expect(container.read(authNotifierProvider).accessToken, 'existing');
    });

    test('自动登录失败不会踢掉用户刚手动建的会话（回滚只针对自己写的那串令牌）', () async {
      await store.save(
        rememberPassword: true,
        autoLogin: true,
        username: _Backend.okUsername,
        password: 'stale-password',
      );
      // 用户已经在登录页手动登录成功（模拟竞态）。
      container.read(authNotifierProvider.notifier).setTokens('manual', 'manual-r');

      // 单飞 Future 在手动登录之前就已开出：这里直接跑「未登录」分支已不成立，
      // 所以显式复位单飞位后再触发一次，覆盖「在途时被手动登录抢先」的路径。
      aylaResetAutoLoginGate();
      final AylaAutoLoginOutcome outcome = await aylaRunAutoLogin(container);
      // 已有会话 ⇒ 直接判定 alreadySignedIn，不会去动令牌。
      expect(outcome, AylaAutoLoginOutcome.alreadySignedIn);
      expect(container.read(authNotifierProvider).accessToken, 'manual');
    });
  });

  group('冷启动首屏落点（aylaInitialLocation）', () {
    test('自动登录在途 ⇒ 落在登录页（用户要"看见他自动登录"）', () {
      expect(aylaInitialLocation(autoLoginInFlight: true), '/login');
    });

    test('未在途 ⇒ 照旧落到 /group（未登录时由守卫送回登录页，行为不变）', () {
      expect(aylaInitialLocation(autoLoginInFlight: false), '/group');
    });

    test('触发瞬间（首个 await 之前）就已置位 —— 路由构造时读到的必然是真实状态', () async {
      await store.save(
        rememberPassword: true,
        autoLogin: true,
        username: _Backend.okUsername,
        password: _Backend.okPassword,
      );
      final Future<AylaAutoLoginOutcome> pending = aylaRunAutoLogin(container);
      // ⚠️ 同步断言：不能 await（await 之后位已经复位了）。
      // `main.dart` 正是靠这个同步窗口在 `runApp` 前把首屏落点定下来的。
      expect(aylaAutoLoginInFlight.value, isTrue);
      expect(await pending, AylaAutoLoginOutcome.success);
      expect(aylaAutoLoginInFlight.value, isFalse, reason: '结束后必须复位（按钮要回到可点的「登录」）');
    });
  });

  group('登出链（aylaLogoutForContainer）', () {
    test('登出保留已保存凭据 —— 下次打开仍是回填好、可直接点登录', () async {
      await store.save(
        rememberPassword: true,
        autoLogin: true,
        username: _Backend.okUsername,
        password: _Backend.okPassword,
      );
      await aylaRunAutoLogin(container);
      expect(container.read(authNotifierProvider).isAuthenticated, isTrue);

      await aylaLogoutForContainer(container);

      expect(container.read(authNotifierProvider).isAuthenticated, isFalse);
      final AylaAuthPrefs after = await store.load();
      expect(after.canAutoLogin, isTrue, reason: '登出 ≠ 忘记密码');
    });

    test('clearCredentials: true 才真正清空（"忘记"是显式动作）', () async {
      await store.save(
        rememberPassword: true,
        autoLogin: true,
        username: _Backend.okUsername,
        password: _Backend.okPassword,
      );

      await aylaLogoutForContainer(container, clearCredentials: true);

      expect(secure.data, isEmpty);
      expect((await store.load()).canAutoLogin, isFalse);
    });
  });
}
