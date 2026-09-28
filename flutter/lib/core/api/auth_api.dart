/// 认证 API（M0 冒烟三接口：login / refresh / me）。
///
/// 真实契约（`backend/apps/accounts/urls.py` + `serializers.py` + `views.py`）：
/// - POST /auth/login/  （TokenObtainPairView）{username, password} → {access, refresh}
/// - POST /auth/refresh/（TokenRefreshView）{refresh} → {access, refresh?}
///   （ROTATE_REFRESH_TOKENS=True：refresh 也轮换）
/// - GET  /me/          （MeView）→ UserPublicSerializer + email
library;

import '../net/dio_client.dart';
import '../../state/auth_state.dart';

/// JWT 令牌对。
class TokenPair {
  final String access;
  final String? refresh;

  const TokenPair({required this.access, this.refresh});

  factory TokenPair.fromJson(Map<String, dynamic> json) {
    return TokenPair(
      access: json['access']?.toString() ?? '',
      refresh: json['refresh']?.toString(),
    );
  }
}

/// `POST /auth/send-email-code/` 的返回（web `api/types.ts:51–54`）。
class SendEmailCodeResult {
  const SendEmailCodeResult({required this.detail, required this.code});

  /// 后端文案。
  final String detail;

  /// `email_code_sent` / `email_code_failed`。
  final String code;

  factory SendEmailCodeResult.fromJson(Map<String, dynamic> json) {
    return SendEmailCodeResult(
      detail: json['detail']?.toString() ?? '',
      code: json['code']?.toString() ?? '',
    );
  }
}

/// `POST /auth/register/` 的返回（web `api/types.ts:82–86`：user + 双令牌）。
class RegisterResult {
  const RegisterResult({
    required this.user,
    required this.access,
    required this.refresh,
  });

  final AuthUser user;
  final String access;
  final String refresh;

  factory RegisterResult.fromJson(Map<String, dynamic> json) {
    return RegisterResult(
      user: AuthUser.fromJson(
        (json['user'] as Map?)?.cast<String, dynamic>() ??
            const <String, dynamic>{},
      ),
      access: json['access']?.toString() ?? '',
      refresh: json['refresh']?.toString() ?? '',
    );
  }
}

class AuthApi {
  const AuthApi._();

  /// POST /auth/send-email-code/ —— 发送注册邮箱验证码（**未登录可用**）。
  ///
  /// web `api/auth.ts:19–25` 带 `noRetry401`（401 是业务结果、不触发刷新重放）；
  /// dio 侧的等价物在 [DioClient] 的 401 拦截器里按 `auth/` 前缀豁免。
  static Future<SendEmailCodeResult> sendEmailCode(String email) async {
    final Map<String, dynamic> resp =
        await DioClient.instance.post<Map<String, dynamic>>(
      '/auth/send-email-code/',
      body: <String, String>{'email': email},
    );
    return SendEmailCodeResult.fromJson(resp);
  }

  /// POST /auth/register/ —— 注册（成功后直接拿到双令牌与用户，等价 web `authApi.register`）。
  ///
  /// ⚠️ `nickname` 为空时**整键省略**（web `RegisterPage.tsx:79` 的
  /// `nickname.trim() || undefined`）——不能传空串（后端会把它当成显式昵称）。
  static Future<RegisterResult> register({
    required String username,
    required String email,
    required String password,
    String? nickname,
    required String code,
  }) async {
    final Map<String, dynamic> body = <String, dynamic>{
      'username': username,
      'email': email,
      'password': password,
      'code': code,
    };
    if (nickname != null && nickname.isNotEmpty) body['nickname'] = nickname;
    final Map<String, dynamic> resp =
        await DioClient.instance.post<Map<String, dynamic>>(
      '/auth/register/',
      body: body,
    );
    return RegisterResult.fromJson(resp);
  }

  /// POST /auth/login/ —— 登录（测试账号 123/12345678）。
  static Future<TokenPair> login(String username, String password) async {
    final Map<String, dynamic> resp =
        await DioClient.instance.post<Map<String, dynamic>>(
      '/auth/login/',
      body: <String, String>{'username': username, 'password': password},
    );
    return TokenPair.fromJson(resp);
  }

  /// PATCH /me/profile/ —— 昵称 / 签名 / 在线状态 / 展示开关 / 头像
  /// （web `api/auth.ts:77–82`：`ProfileUpdatePayload` → `UserPublic`）。
  ///
  /// ⚠️ 三处**逐条照 web**（`ProfilePage.tsx:119–125`）：
  /// · `nickname` = `nickname.trim() || undefined` ⇒ 修剪后为空则**整键省略**；
  /// · `signature` = `signature.trim()`（空串照传，允许清空签名）；
  /// · `avatar` = 上传后的 content URL，**没有新头像时不传该键**。
  static Future<AuthUser> updateProfile({
    String? nickname,
    required String signature,
    required String status,
    required bool showContent,
    String? avatar,
  }) async {
    final Map<String, dynamic> body = <String, dynamic>{
      'signature': signature,
      'status': status,
      'show_content': showContent,
    };
    if (nickname != null && nickname.isNotEmpty) body['nickname'] = nickname;
    if (avatar != null && avatar.isNotEmpty) body['avatar'] = avatar;
    final Map<String, dynamic> resp =
        await DioClient.instance.patch<Map<String, dynamic>>(
      '/me/profile/',
      body: body,
    );
    return AuthUser.fromJson(resp);
  }

  /// GET /me/ —— 当前登录用户信息（含 email）。
  static Future<AuthUser> me() async {
    final Map<String, dynamic> resp =
        await DioClient.instance.get<Map<String, dynamic>>('/me/');
    return AuthUser.fromJson(resp);
  }

  /// POST /auth/refresh/ —— 静默续期（互斥锁 + 轮换）。
  /// 供 401 拦截器与 WS 重连前共用（DioClient 内部实现）。
  static Future<bool> refresh() => DioClient.instance.refreshAccessToken();
}
