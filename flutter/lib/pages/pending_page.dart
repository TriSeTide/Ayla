/// 路由占位页 —— **只用于「路由已就位、页面本体属后续批次」的路由**（第 0 步 B 登记）。
///
/// 口径：第 0 步 B 按 `web/src/App.tsx` 建全 28 条 `Route`（含 2 条重定向 + 1 条 catch-all）；
/// 页面本体按批次交付（第 1 批 = 登录接线 + Register / Profile / UserProfile / Favorites / Search）。
/// 未实现的路径**显式指向本页**而不是静默重定向到 `/group`：
/// · 点进来能看到明确反馈（而不是白屏，也不是跳进另一个同样未实现的页面）；
/// · 「哪些路由已实现」这件事在 UI 上可见，与 13 号文档的清单互为对照。
///
/// ⚠️ 本页**不是视觉件、没有 web 对应物**：样式全部复用公共件 [AylaPageState]
/// （= web `.home-state` + placeholder 族，`home.css:620–629` + `shell.css:595–629`）。
library;

import 'package:flutter/material.dart';

import '../widgets/base/page_state.dart';

class PendingPage extends StatelessWidget {
  const PendingPage({super.key, required this.path, required this.webSource});

  /// 该路由的路径（原样显示，便于核对路由表）。
  final String path;

  /// web 事实源（`文件:行 → 组件`），逐条来自 `web/src/App.tsx`。
  final String webSource;

  @override
  Widget build(BuildContext context) {
    return AylaPageState(
      title: '该页面属后续批次',
      description: '路由已就位：$path\n$webSource',
    );
  }
}