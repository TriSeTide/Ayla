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

class AuthApi {
  const AuthApi._();

  /// POST /auth/login/ —— 登录（测试账号 123/12345678）。
  static Future<TokenPair> login(String username, String password) async {
    final Map<String, dynamic> resp =
        await DioClient.instance.post<Map<String, dynamic>>(
      '/auth/login/',
      body: <String, String>{'username': username, 'password': password},
    );
    return TokenPair.fromJson(resp);
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
