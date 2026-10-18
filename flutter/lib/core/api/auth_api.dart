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
        await DioClient.instance.postAuth<Map<String, dynamic>>(
      '/auth/send-email-code/',
      body: <String, String>{'email': email}, // web `api/auth.ts:23 noRetry401`
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
    // web `api/auth.ts:49 noRetry401`：注册/登录的 401/400 是业务错误，原样展示
    final Map<String, dynamic> resp =
        await DioClient.instance.postAuth<Map<String, dynamic>>(
      '/auth/register/',
      body: body,
    );
    return RegisterResult.fromJson(resp);
  }

  /// POST /auth/login/ —— 登录（测试账号 123/12345678）。
  static Future<TokenPair> login(String username, String password) async {
    final Map<String, dynamic> resp =
        await DioClient.instance.postAuth<Map<String, dynamic>>(
      '/auth/login/',
      // ⚠️ 与 web `api/auth.ts:58` 逐条一致：**登录的 401 是业务结果**
      //（账号或密码错误），不得触发「刷新 + 重放」或会话过期登出链 ——
      // 自动登录用旧口令时尤其明显：否则一次失败会把整条登出链跑一遍。
      body: <String, String>{'username': username, 'password': password},
    );
    return TokenPair.fromJson(resp);
  }

  /// POST /auth/change-password/ —— 改密（JWT：邮箱验证码 + 新密码）。
  ///
  /// web `api/auth.ts:28–33` —— body 就两个键 `{code, new_password}`，
  /// 响应 `{detail}`（后端 `ChangePasswordView`）。401/400 是业务结果，
  /// 走 [DioClient.postAuth]（与 web 的 `noRetry401` 同义，见 `api/auth.ts:30`）。
  static Future<String> changePassword({
    required String code,
    required String newPassword,
  }) async {
    final Map<String, dynamic> resp =
        await DioClient.instance.postAuth<Map<String, dynamic>>(
      '/auth/change-password/',
      body: <String, dynamic>{
        // web `types.ts:57–60` `ChangePasswordPayload { code; new_password }`
        'code': code,
        'new_password': newPassword,
      },
    );
    return resp['detail']?.toString() ?? '';
  }

  /// POST /auth/change-email/ —— 换绑邮箱（JWT：当前邮箱码 + 新邮箱 + 新邮箱码）。
  ///
  /// web `api/auth.ts:36–41` —— body 三个键 `{current_code, new_email, new_code}`，
  /// 响应 `{detail, email}`。⚠️ 未绑定邮箱时 `current_code` 照传空串
  /// （web `PrivacySheet.tsx:137` `boundEmail ? curCode.trim() : ""`）。
  static Future<String> changeEmail({
    required String currentCode,
    required String newEmail,
    required String newCode,
  }) async {
    final Map<String, dynamic> resp =
        await DioClient.instance.postAuth<Map<String, dynamic>>(
      '/auth/change-email/',
      body: <String, dynamic>{
        // web `types.ts:63–67` `ChangeEmailPayload`
        'current_code': currentCode,
        'new_email': newEmail,
        'new_code': newCode,
      },
    );
    // 后端回 `email` = 换绑后的新邮箱（UI 用它刷新 AuthUser，见 profile_page）。
    return resp['email']?.toString() ?? newEmail;
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
  ///
  /// [accessToken] 用于**冷启动自动登录**：那条链刚拿到令牌、尚未写进 `AuthNotifier`
  /// 时就要拉一次 `/me/`（见 `state/auth_bootstrap.dart:aylaApplyLoginSession`）。
  /// 显式带上它可避免"先写令牌再拉"的时序耦合；不传则照旧走全局存取器。
  static Future<AuthUser> me({String? accessToken}) async {
    final Map<String, dynamic> resp =
        accessToken == null || accessToken.isEmpty
            ? await DioClient.instance.get<Map<String, dynamic>>('/me/')
            : await DioClient.instance
                .getWithBearer<Map<String, dynamic>>('/me/', accessToken);
    return AuthUser.fromJson(resp);
  }

  /// POST /auth/refresh/ —— 静默续期（互斥锁 + 轮换）。
  /// 供 401 拦截器与 WS 重连前共用（DioClient 内部实现）。
  static Future<bool> refresh() => DioClient.instance.refreshAccessToken();
}
