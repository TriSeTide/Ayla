/// 登录凭据与「记住密码 / 自动登录」偏好（**新增功能，web 无对应**）。
///
/// ## 用户需求（2026-10-01）
/// - 勾「记住密码」⇒ 每次打开 App **不必再输账号密码**，直接点登录即可；
/// - 勾「自动登录」⇒ 每次打开 App **先到登录页、看见它自动登录**（不是静默跳过登录页）；
/// - 「自动登录」**必然连带「记住密码」**（两个一定同时开）。
///
/// ## 与 web 的关系（有意新增，不是复刻）
/// web 登录页（`web/src/pages/LoginPage.tsx`，95 行）只有用户名/密码两个字段，**没有**这两个开关；
/// 它的会话恢复是 `stores/auth.ts` 的 `restoreSession()` —— refresh token 存 **sessionStorage**、
/// 关标签页即失效，且 refresh 失效就回登录页。用户明确要求 Flutter 侧补上这两个开关，故本件是功能增量。
///
/// ## 存储选择（工程约束）
/// 要保存的是**可还原的明文口令**（自动登录必须用原始凭据调 `POST /auth/login/`，
/// 而 access/refresh 令牌无法反推口令）⇒ 必须落**平台安全存储**，不能沿用库内
/// `state/home_prefs.dart` / `state/chat_drafts.dart` 的明文 JSON 文件手法。
/// 依赖 `flutter_secure_storage`：Windows = DPAPI 加密文件、Android = KeyStore
/// （RSA-OAEP 包密钥 + AES-GCM 存值）、iOS/macOS = Keychain、Linux = libsecret。
///
/// ## 失败语义
/// 存储不可用（KeyStore 被重置、凭据损坏、平台不支持）一律**静默回落「未保存」**，
/// 但把原因留在 [AylaAuthPrefs.lastError] 里供调用方打日志 —— 不把失败伪装成「用户没勾过」，
/// 也不因为读不出凭据而让 App 起不来。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 安全存储的最小契约（**注入点**：测试用内存实现，生产用 [AylaFlutterSecureStore]）。
abstract interface class AylaSecureStore {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

/// `flutter_secure_storage` 的生产实现。
class AylaFlutterSecureStore implements AylaSecureStore {
  const AylaFlutterSecureStore([this._storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// 凭据 + 开关的只读快照。
@immutable
class AylaAuthPrefs {
  const AylaAuthPrefs({
    required this.rememberPassword,
    required this.autoLogin,
    required this.username,
    required this.password,
    this.lastError,
  });

  /// 什么都没有（未勾选 / 存储不可用 / 首次安装）。
  static const AylaAuthPrefs empty = AylaAuthPrefs(
    rememberPassword: false,
    autoLogin: false,
    username: '',
    password: '',
  );

  /// 「记住密码」勾选态。
  final bool rememberPassword;

  /// 「自动登录」勾选态（恒蕴含 [rememberPassword]，见 [AylaAuthPrefs.fromRaw]）。
  final bool autoLogin;

  /// 已保存的账号（未保存时为空串）。
  final String username;

  /// 已保存的密码（未保存时为空串）。**只用于回填表单与自动登录**，不得打日志。
  final String password;

  /// 读盘失败原因（null = 读取正常）。仅用于诊断，不参与判定。
  final String? lastError;

  /// 是否已有可用凭据（登录页据此回填账号密码）。
  bool get hasCredentials =>
      rememberPassword && username.isNotEmpty && password.isNotEmpty;

  /// 是否满足自动登录条件（勾了自动登录 + 有完整凭据）。
  bool get canAutoLogin =>
      autoLogin && rememberPassword && username.isNotEmpty && password.isNotEmpty;

  /// 从存储原始串归一（缺失键 ⇒ null）。
  ///
  /// 归一规则：「自动登录」蕴含「记住密码」——即使存储里出现了 `auto=1` 而 `remember=0`
  /// 这种被外部改坏的状态，也按「两个都开」解释（两个一定同时开是不可违反的不变量）。
  factory AylaAuthPrefs.fromRaw({
    required String? remember,
    required String? auto,
    required String? username,
    required String? password,
    String? lastError,
  }) {
    final bool autoOn = auto == '1';
    return AylaAuthPrefs(
      rememberPassword: remember == '1' || autoOn,
      autoLogin: autoOn,
      username: username ?? '',
      password: password ?? '',
      lastError: lastError,
    );
  }
}

/// 凭据仓库：读写安全存储里的 4 个键。
///
/// 键名与库内其它偏好一致走 `ayla.*` 命名空间；与 `state/home_prefs.dart` 的区别只在
/// **存储介质**（那里是明文 JSON，这里是平台安全存储），语义与失败策略同源（失败静默回落）。
class AylaAuthPrefsStore {
  AylaAuthPrefsStore({AylaSecureStore? store})
      : _store = store ?? const AylaFlutterSecureStore();

  /// 账号键。
  static const String keyUsername = 'ayla.auth.username';

  /// 密码键。
  static const String keyPassword = 'ayla.auth.password';

  /// 「记住密码」键（值 `'1'` / 键不存在）。
  static const String keyRemember = 'ayla.auth.remember_password';

  /// 「自动登录」键（值 `'1'` / 键不存在）。
  static const String keyAutoLogin = 'ayla.auth.auto_login';

  final AylaSecureStore _store;

  /// 读全部偏好（**不抛异常**：失败返回 [AylaAuthPrefs.empty] 并把原因写进 `lastError`）。
  Future<AylaAuthPrefs> load() async {
    try {
      final List<String?> raw = await Future.wait<String?>(<Future<String?>>[
        _store.read(keyRemember),
        _store.read(keyAutoLogin),
        _store.read(keyUsername),
        _store.read(keyPassword),
      ]);
      return AylaAuthPrefs.fromRaw(
        remember: raw[0],
        auto: raw[1],
        username: raw[2],
        password: raw[3],
      );
    } catch (err) {
      debugPrint('[AylaAuth] 凭据读取失败（按未保存处理）：$err');
      return AylaAuthPrefs.empty.copyWithError(err.toString());
    }
  }

  /// 写偏好并持久化。
  ///
  /// - `rememberPassword == false` ⇒ **清空全部 4 个键**（含旧账号密码，避免取消勾选后仍留凭据）；
  /// - `autoLogin == true` ⇒ 强制把 `rememberPassword` 也置真（两个一定同时开）。
  ///
  /// 返回真正落盘的偏快照（归一后的值），供调用方回填 UI。
  Future<AylaAuthPrefs> save({
    required bool rememberPassword,
    required bool autoLogin,
    required String username,
    required String password,
  }) async {
    final bool auto = autoLogin; // 「自动登录」本身就是「两个都开」的请求
    final bool remember = rememberPassword || auto; // 归一：auto ⇒ remember
    if (!remember) {
      await clear();
      return AylaAuthPrefs.empty;
    }
    try {
      await _store.write(keyRemember, '1');
      await _store.write(keyAutoLogin, auto ? '1' : '0');
      await _store.write(keyUsername, username);
      await _store.write(keyPassword, password);
      return AylaAuthPrefs(
        rememberPassword: true,
        autoLogin: auto,
        username: username,
        password: password,
      );
    } catch (err) {
      debugPrint('[AylaAuth] 凭据写入失败（本次不生效）：$err');
      return AylaAuthPrefs(
        rememberPassword: remember,
        autoLogin: auto,
        username: username,
        password: password,
        lastError: err.toString(),
      );
    }
  }

  /// 删除全部 4 个键（登出清除 / 取消勾选）。
  Future<void> clear() async {
    for (final String key in <String>[
      keyRemember,
      keyAutoLogin,
      keyUsername,
      keyPassword,
    ]) {
      try {
        await _store.delete(key);
      } catch (err) {
        debugPrint('[AylaAuth] 凭据删除失败 key=$key：$err');
      }
    }
  }
}

/// [AylaAuthPrefs.empty] 的带错误版本（`copyWith` 在本件只为一处服务，不开放公开 copyWith）。
extension on AylaAuthPrefs {
  AylaAuthPrefs copyWithError(String error) => AylaAuthPrefs(
        rememberPassword: rememberPassword,
        autoLogin: autoLogin,
        username: username,
        password: password,
        lastError: error,
      );
}
