/// 认证状态（Riverpod Notifier）：access/refresh 双令牌 + 当前用户 + 登出清态。
///
/// M0：纯内存态（web 端 localStorage 的等价物留 M1 会话恢复——
/// 06 §4 M1 认证：refresh token secure storage 持久化）。
/// 本类同时实现 `AuthTokenStore` 契约，供 DioClient wiring。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/net/dio_client.dart';

/// 当前登录用户（照 `backend/apps/accounts/serializers.py` UserPublicSerializer + email）。
class AuthUser {
  final String id;
  final String username;
  final String nickname;
  final String avatar;
  final String signature;
  final String status;
  final bool online;
  final String displayStatus;
  final String dateJoined;
  final bool isInVoice;
  final String? voiceRoomId;
  final bool isLive;
  final String? liveRoomId;
  final bool showContent;
  final String email;

  const AuthUser({
    required this.id,
    required this.username,
    required this.nickname,
    required this.avatar,
    required this.signature,
    required this.status,
    required this.online,
    required this.displayStatus,
    required this.dateJoined,
    required this.isInVoice,
    required this.voiceRoomId,
    required this.isLive,
    required this.liveRoomId,
    required this.showContent,
    required this.email,
  });

  factory AuthUser.fromJson(Map<String, dynamic> json) {
    String s(Object? v) => v?.toString() ?? '';
    return AuthUser(
      id: s(json['id']),
      username: s(json['username']),
      nickname: s(json['nickname']),
      avatar: s(json['avatar']),
      signature: s(json['signature']),
      status: s(json['status']),
      online: json['online'] == true,
      displayStatus: s(json['display_status']),
      dateJoined: s(json['date_joined']),
      isInVoice: json['is_in_voice'] == true,
      voiceRoomId: json['voice_room_id']?.toString(),
      isLive: json['is_live'] == true,
      liveRoomId: json['live_room_id']?.toString(),
      showContent: json['show_content'] == true,
      email: s(json['email']),
    );
  }
}

/// 认证状态快照。
class AuthState {
  final String? accessToken;
  final String? refreshToken;
  final AuthUser? user;

  const AuthState({this.accessToken, this.refreshToken, this.user});

  bool get isAuthenticated => accessToken != null && accessToken!.isNotEmpty;

  AuthState copyWith({
    String? accessToken,
    String? refreshToken,
    AuthUser? user,
    bool clearTokens = false,
  }) {
    return AuthState(
      accessToken: clearTokens ? null : (accessToken ?? this.accessToken),
      refreshToken: clearTokens ? null : (refreshToken ?? this.refreshToken),
      user: clearTokens ? null : (user ?? this.user),
    );
  }
}

/// 认证 Notifier：登录/刷新/登出的唯一真源；实现 AuthTokenStore 供 DioClient 注入。
class AuthNotifier extends Notifier<AuthState> implements AuthTokenStore {
  @override
  AuthState build() => const AuthState();

  @override
  String? get accessToken => state.accessToken;

  @override
  String? get refreshToken => state.refreshToken;

  /// 登录成功 / 刷新成功后的令牌写入（web auth store setTokens）。
  @override
  void setTokens(String access, String? refresh) {
    state = state.copyWith(accessToken: access, refreshToken: refresh);
  }

  /// 设置当前用户（GET /me/ 结果）。
  void setUser(AuthUser user) {
    state = state.copyWith(user: user);
  }

  /// 登出：清令牌与用户（web auth store logout；WS 断开由调用方负责）。
  @override
  void clear() {
    state = state.copyWith(clearTokens: true);
  }
}

final authNotifierProvider = NotifierProvider<AuthNotifier, AuthState>(
  AuthNotifier.new,
);
