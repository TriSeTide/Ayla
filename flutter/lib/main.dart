/// 应用入口（UI 层重建中：根临时指向组件库审核画布）。
///
/// 重建说明（2026-09-18 用户下令删除旧组件库后从零翻译）：
/// - `theme/` `widgets/` `preview/` 为从 web 源码重新推导的批 0/1；
/// - 逻辑层 wiring（自 PoC/M0 保留层沿用，勿改语义）：
///   ① `DioClient.instance.init`：注入 AuthNotifier 令牌存取 + 会话过期回调；
///   ② `initWsManager`：四通道 WS 管理器（chat/presence 先通，live/voice 占位）；
/// - 会话过期回登录的路由（`appRouterProvider` + `router.go('/login')`）待
///   AppShell/路由重建后恢复（当前 UI 阶段无路由，只做 reset + 断连）；
/// - **正式 App 结构**（批 0 验收后恢复）：ProviderScope → 极光背景 →
///   MaterialApp.router → AppShell（双形态）→ 页面；预加载门在 AppShell 内。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/app_init.dart';
import 'pages/login_page.dart';
import 'theme/app_theme.dart';
import 'theme/aurora_background.dart';
import 'core/net/dio_client.dart';
import 'core/ws/ws_manager.dart';
import 'poc/echo_page.dart';
import 'poc/hls_page.dart';
import 'preview/component_gallery.dart';
import 'state/auth_state.dart';

void main() {
  // 仅 debug：常开语义树（供预览工具读元素；release 下被摇树移除）。
  // 注：widget-preview 宿主目前不支持语义树（2026-09-18 实测），保留以备将来。
  if (kDebugMode) {
    SemanticsBinding.instance.ensureSemantics();
  }

  // 逻辑层 wiring：DioClient 单例 ← AuthNotifier（实现 AuthTokenStore 契约）
  final ProviderContainer container = ProviderContainer();
  final AuthNotifier auth = container.read(authNotifierProvider.notifier);
  DioClient.instance.init(
    tokenStore: auth,
    onSessionExpired: () {
      AppInit.instance.reset();
      wsManager?.disconnectAll();
      // TODO(UI 重建)：会话过期 → 回登录页（appRouterProvider 重建后恢复）
    },
  );
  initWsManager(tokens: auth);

  runApp(
    UncontrolledProviderScope(
      container: container,
      // UI 重建期：根 = 登录页（批 0 验收通过后恢复 AppShell 接入）
      child: const _UiStage(),
    ),
  );
}

/// 临时 UI 舞台：登录页 + 组件库画布的切换壳（预览用，M0 路由接入后移除）。
class _UiStage extends StatefulWidget {
  const _UiStage();

  @override
  State<_UiStage> createState() => _UiStageState();
}

class _UiStageState extends State<_UiStage> {
  bool _showGallery = false;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAylaTheme(),
      // 必须包 Scaffold：MaterialApp 在没有 Scaffold 时会给所有 Text 套上
      // 「未落在 Material 上」的默认文本装饰（**黄色双下划线**）——这是
      // Flutter 的视觉提示而非设计线，debug/release 都会出现。
      // 极光背景交给 Scaffold 的 body 铺满。
      home: Scaffold(
        backgroundColor: Colors.transparent,
        body: AuroraBackground(
          child: Stack(
            children: <Widget>[
              Positioned.fill(
                child:
                    _showGallery ? const ComponentGallery() : const LoginPage(),
              ),
              // 舞台切换开关（仅重建期临时存在）
              Positioned(
                right: 12,
                bottom: 12,
                child: FloatingActionButton.small(
                  onPressed: () => setState(() => _showGallery = !_showGallery),
                  child: Text(_showGallery ? '登录' : '组件'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// PoC 最小壳（自 PoC 基线 93cc2e9 原样保留，勿改）。
///
/// 用途：基线 `test/widget_test.dart`（PoC shell smoke test）导入本函数做
/// 双 PoC 入口回归；UI 重建期 main() 指向组件库画布，PoC 壳不参与启动。
class PocApp extends StatelessWidget {
  const PocApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ayla Flutter PoC',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFF9DBFE6),
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ayla Flutter PoC')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            FilledButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const EchoPage()),
              ),
              child: const Text('PoC-A 音频 Echo（语音中继）'),
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const HlsPage()),
              ),
              child: const Text('PoC-B HLS 播放（直播）'),
            ),
          ],
        ),
      ),
    );
  }
}
