// G3 认证链路冒烟：用工程内真实代码（DioClient + AuthApi）打真实后端。
//
// 必须以 flutter 工具链运行（dart CLI 缺 dart:ui，无法编译 flutter 依赖）：
//   cmd.exe /c "cd /d E:\Elysium-AyerElysia\Elysium\Ayla\flutter && E:\flutter\bin\flutter.bat test tool\auth_smoke.dart"
//
// 说明：本文件不初始化 TestWidgetsFlutterBinding（普通 test() 而非 testWidgets），
// 网络不受 flutter_test mock 影响，可直连 daphne（只绑 Windows 127.0.0.1:8100）。
//
// 链路：login（取双令牌）→ refresh（轮换：access 变化、refresh 仍可用）→ me（Bearer 生效）。
// 全部断言通过 = 冒烟 PASS（flutter test 退出码 0）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ayla_flutter/core/api/auth_api.dart';
import 'package:ayla_flutter/core/net/dio_client.dart';
import 'package:ayla_flutter/state/auth_state.dart';

/// 内存 TokenStore（冒烟用；App 内由 AuthNotifier 承担）。
class _MemoryTokenStore implements AuthTokenStore {
  String? _access;
  String? _refresh;

  @override
  String? get accessToken => _access;

  @override
  String? get refreshToken => _refresh;

  @override
  void setTokens(String access, String? refresh) {
    _access = access;
    _refresh = refresh;
  }

  @override
  void clear() {
    _access = null;
    _refresh = null;
  }
}

void main() {
  test('认证链路冒烟：login → refresh（轮换）→ me（真实后端）', () async {
    // wiring：DioClient 单例 + 内存 token store（与 App 启动同构）
    final _MemoryTokenStore store = _MemoryTokenStore();
    DioClient.instance.init(tokenStore: store, onSessionExpired: () {
      stdout.writeln('SMOKE_INFO sessionExpired 回调触发（401 刷新失败路径）');
    });

    // 1) login
    final TokenPair pair = await AuthApi.login('123', '12345678');
    expect(pair.access, isNotEmpty, reason: 'login access 非空');
    expect(pair.refresh, isNotNull, reason: 'login refresh 非空');
    expect(pair.refresh, isNotEmpty, reason: 'login refresh 非空');
    // 真实 App 流程：登录成功后令牌写入状态（AuthApi 纯请求，不写 store——
    // 职责分离同 web：auth store 调 API 后 setTokens）
    store.setTokens(pair.access, pair.refresh);
    stdout.writeln('SMOKE_PASS login access=${pair.access.substring(0, 16)}…');

    // 2) refresh（互斥锁 + 轮换）
    final String oldAccess = pair.access;
    final String oldRefresh = pair.refresh!;
    final bool refreshOk = await AuthApi.refresh();
    expect(refreshOk, isTrue, reason: 'refresh 成功');
    final String newAccess = store.accessToken ?? '';
    final String? newRefresh = store.refreshToken;
    expect(newAccess, isNotEmpty, reason: 'refresh 后 access 已写回 store');
    expect(newAccess, isNot(oldAccess),
        reason: 'access 已轮换（新旧不同）');
    expect(newRefresh, isNotNull, reason: 'refresh 轮换后仍有 refresh');
    stdout.writeln(
        'SMOKE_PASS refresh 轮换 accessChanged=${newAccess != oldAccess} '
        'refreshRotated=${newRefresh != null && newRefresh != oldRefresh}');

    // 3) me（Bearer 注入生效）
    final AuthUser user = await AuthApi.me();
    expect(user.id, isNotEmpty, reason: 'me 返回用户 id');
    expect(user.username, isNotEmpty, reason: 'me 返回 username');
    stdout.writeln(
        'SMOKE_PASS me id=${user.id} username=${user.username} '
        'nickname=${user.nickname} email=${user.email}');

    // 4) 401 静默刷新 + 重放一次（web api/client.ts 语义实测）：
    // 用无效 access 覆写 store → me 请求 401 → 拦截器用有效 refresh 刷新 → 重放 → 200
    final String? validRefresh = store.refreshToken;
    store.setTokens('invalid.access.token', validRefresh);
    final AuthUser userAfterReplay = await AuthApi.me();
    expect(userAfterReplay.id, isNotEmpty,
        reason: '401 后静默刷新并重放成功（返回真实用户而非 401）');
    expect(store.accessToken, isNot('invalid.access.token'),
        reason: '重放后 store 持有新 access（刷新已写回）');
    stdout.writeln('SMOKE_PASS 401 静默刷新重放 access=${store.accessToken!.substring(0, 16)}…');

    stdout.writeln('SMOKE_ALL_PASS');
  });
}
