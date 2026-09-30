/// 登录路由（web `pages/LoginPage.tsx` + `hooks/useAuth.ts` 的等价物）。
///
/// 视觉本体是既有 [LoginPage]（纯视觉 + 注入式回调，`login_page.dart`）；本件只负责接线：
/// 1. **表单**：`AuthApi.login` → 写令牌 → `GET /me/` → 写用户；
/// 2. **登录后副作用**（web `useAuth.login`）：`presenceClient.connect()` + `chatWS.connect()`
///    ⇒ Flutter 侧是 `wsManager.connectAll()`；再 `AppInit.instance.run()`（全屏预加载门）；
/// 3. **`?next=` 回跳**：⚠️ **用户指示的有意偏离** —— web 的 `ProtectedRoute` 只 `Navigate to="/login"`、
///    登录成功恒 `navigate("/group")`（`App.tsx:94` / `LoginPage.tsx:19/28`），**没有**回跳；
///    Flutter 侧按用户要求把原目标编码进 `?next=` 并在登录后回原地。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api/auth_api.dart';
import '../core/app_init.dart';
import '../core/net/dio_client.dart';
import '../core/ws/ws_manager.dart';
import '../state/auth_state.dart';
import '../state/chat_providers.dart';
import '../state/presence_providers.dart';
import 'login_page.dart';

class LoginRoute extends ConsumerStatefulWidget {
  const LoginRoute({super.key, this.next});

  /// 守卫写入的回跳目标（`/login?next=...`，已 URL 编码）。
  final String? next;

  @override
  ConsumerState<LoginRoute> createState() => _LoginRouteState();
}

class _LoginRouteState extends ConsumerState<LoginRoute> {
  bool _submitting = false;
  String? _error;

  /// 回跳目标的合法化：只接受站内绝对路径，且不能是登录/注册页自身
  /// （否则登录成功会再跳回登录页，形成循环）。
  String get _target {
    final String? raw = widget.next;
    if (raw == null || raw.isEmpty) return '/group';
    // ⚠️ **不要再 decodeComponent**：go_router 的 `queryParameters` 已按 Uri 解过码，
    // 再解一次会把路径里合法的 `%20` 还原成空格（双重解码）。
    final String path = raw;
    if (!path.startsWith('/')) return '/group';
    if (path == '/login' || path.startsWith('/login?') ||
        path == '/register' || path.startsWith('/register?')) {
      return '/group';
    }
    return path;
  }

  Future<void> _submit(String username, String password) async {
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final TokenPair pair = await AuthApi.login(username, password);
      final AuthNotifier auth = ref.read(authNotifierProvider.notifier);
      auth.setTokens(pair.access, pair.refresh);
      auth.setUser(await AuthApi.me());
      // web `useAuth.login`：connect 两条 WS + 跑预加载门。
      wsManager?.connectAll();
      // chat 通道 owner（`core/ws/chat_ws.dart`）：绑定通道 + 连接 + 登记订阅。
      aylaStartChatWs(ref);
      // presence 通道 owner（`core/ws/presence_ws.dart`）：绑定通道 + 连接（幂等）。
      aylaStartPresenceWs(ref);
      unawaited(ref.read(badgesProvider).fetch());
      // userId 进目录 record 的 key 段（web `directoryKey` 读 currentUser.id）。
      unawaited(
        AppInit.instance.run(
          userId: ref.read(authNotifierProvider).user?.id,
        ),
      );
      if (!mounted) return;
      context.go(_target);
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _error = err is ApiException ? err.message : '登录失败，请稍后重试';
      });
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return LoginPage(
      onSubmit: _submit,
      errorText: _error,
      submitting: _submitting,
      onGoRegister: () => context.go('/register'),
    );
  }
}