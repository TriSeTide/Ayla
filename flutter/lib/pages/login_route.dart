/// 登录路由（web `pages/LoginPage.tsx` + `hooks/useAuth.ts` 的等价物 + 本项目的两个开关）。
///
/// 视觉本体是既有 [LoginPage]（纯视觉 + 注入式回调，`login_page.dart`）；本件只负责接线：
/// 1. **表单**：`AuthApi.login` → 写令牌 → `GET /me/` → 写用户；
/// 2. **登录后副作用**：`state/auth_bootstrap.dart:aylaApplyLoginSession`（与**冷启动自动登录**
///    共用同一份实现 —— 两条路径必须逐条等价，复制一份必然漂移）；
/// 3. **记住密码 / 自动登录**（**新增功能，web 无对应**，用户 2026-10-01 要求）：
///    - 勾「记住密码」⇒ 凭据进平台安全存储，下次打开回填表单、直接点登录即可；
///    - 勾「自动登录」⇒ 下次打开**先到本页**，由 `main.dart` 的冷启动链自动登录
///      （`aylaRunAutoLogin`），本页只负责把 `submitting` 档显示出来让用户看得见；
///    - 两个开关一定同时开：UI 侧由 `LoginPage` 保证，落盘侧由 `AylaAuthPrefsStore.save`
///      再归一一次（双保险，防止外部写坏存储）。
/// 4. **`?next=` 回跳**：⚠️ **用户指示的有意偏离** —— web 的 `ProtectedRoute` 只 `Navigate to="/login"`、
///    登录成功恒 `navigate("/group")`（`App.tsx:94` / `LoginPage.tsx:19/28`），**没有**回跳；
///    Flutter 侧按用户要求把原目标编码进 `?next=` 并在登录后回原地。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api/auth_api.dart';
import '../core/net/dio_client.dart';
import '../state/auth_bootstrap.dart';
import '../state/auth_prefs.dart';
import 'login_page.dart';

class LoginRoute extends ConsumerStatefulWidget {
  const LoginRoute({super.key, this.next});

  /// 守卫写入的回跳目标（`/login?next=...`，已 URL 编码）。
  final String? next;

  @override
  ConsumerState<LoginRoute> createState() => _LoginRouteState();
}

class _LoginRouteState extends ConsumerState<LoginRoute> {
  /// 手动提交在途（`_submit` 自己的标志）。
  bool _manualSubmitting = false;

  /// 冷启动自动登录在途（来自 `auth_bootstrap.dart` 的模块级状态）。
  bool _autoSubmitting = false;

  String? _error;

  /// 回填用：已保存的账号密码（未保存时为空串）。
  String _username = '';
  String _password = '';

  /// 两个开关的当前值。
  bool _remember = false;
  bool _auto = false;

  /// 「登录中…」= 任一路径在途（web 只有手动路径；自动登录是新增功能，反馈面沿用同一档）。
  bool get _busy => _manualSubmitting || _autoSubmitting;

  @override
  void initState() {
    super.initState();
    // 自动登录可能**先于本页挂载**就在跑（`main.dart` 在 runApp 前触发）
    // ⇒ 初值直接取模块级状态，再订阅变化（结束后按钮回到「登录」可点）。
    _autoSubmitting = aylaAutoLoginInFlight.value;
    aylaAutoLoginInFlight.addListener(_onAutoLoginChanged);
    unawaited(_loadSavedCredentials());
  }

  @override
  void dispose() {
    aylaAutoLoginInFlight.removeListener(_onAutoLoginChanged);
    super.dispose();
  }

  void _onAutoLoginChanged() {
    if (!mounted) return;
    setState(() => _autoSubmitting = aylaAutoLoginInFlight.value);
  }

  /// 读取已保存的凭据与开关（「记住密码」的回填面）。
  ///
  /// 失败语义由 [AylaAuthPrefsStore.load] 承担：存储不可用 ⇒ 返回空偏好（形态同「没勾过」），
  /// 不在这里吞掉异常也不弹错误（用户没做错什么，手动输入照常可用）。
  Future<void> _loadSavedCredentials() async {
    final AylaAuthPrefs prefs = await ref.read(authPrefsStoreProvider).load();
    if (!mounted) return;
    setState(() {
      _remember = prefs.rememberPassword;
      _auto = prefs.autoLogin;
      if (prefs.hasCredentials) {
        _username = prefs.username;
        _password = prefs.password;
      }
    });
  }

  /// 开关变化（UI 已保证「自动登录 ⇒ 记住密码」）。
  ///
  /// ## 落盘时机：**只在登录成功后写**（本方法只在"取消勾选"时动存储）
  /// 勾选的瞬间表单里可能是**还没输完**的内容 —— 若此刻就落盘，会存下一半的密码。
  /// 所以真正写入的唯一时机是 [_submit] 的登录成功分支（用提交时那份凭据），
  /// 本方法只负责**取消勾选 = 立刻清空**（用户点「取消记住密码」就是要它马上忘掉）。
  void _onRememberChanged(bool remember, bool auto) {
    setState(() {
      _remember = remember;
      _auto = auto;
    });
    if (!remember) {
      unawaited(ref.read(authPrefsStoreProvider).clear());
    }
  }

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
    // ⚠️ **根容器必须在任何 await 之前取**：`ProviderScope.containerOf(context)` 要读
    // `BuildContext`，await 之后再读会触发 `use_build_context_synchronously`；
    // 而且这个容器正是 `main.dart` 传给 `UncontrolledProviderScope` 的那一个 ——
    // 与冷启动自动登录链用的是同一个（副作用链共享同一份 provider 实例）。
    final ProviderContainer container =
        ProviderScope.containerOf(context, listen: false);
    setState(() {
      _manualSubmitting = true;
      _error = null;
    });
    try {
      final TokenPair pair = await AuthApi.login(username, password);
      await aylaApplyLoginSession(container, pair);
      // 只在**登录成功后**落盘（存了一个连不上的口令没有意义）。
      if (_remember || _auto) {
        unawaited(
          ref.read(authPrefsStoreProvider).save(
                rememberPassword: _remember,
                autoLogin: _auto,
                username: username,
                password: password,
              ),
        );
      }
      if (!mounted) return;
      context.go(_target);
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _error = err is ApiException ? err.message : '登录失败，请稍后重试';
      });
    } finally {
      if (mounted) setState(() => _manualSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return LoginPage(
      onSubmit: _submit,
      errorText: _error,
      submitting: _busy,
      onGoRegister: () => context.go('/register'),
      initialUsername: _username,
      initialPassword: _password,
      rememberPassword: _remember,
      autoLogin: _auto,
      onRememberChanged: _onRememberChanged,
    );
  }
}
