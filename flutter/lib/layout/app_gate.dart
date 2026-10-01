/// 全屏预加载门 × 路由页面的**互斥装配** —— web `App.tsx:48–51`。
///
/// ## 事实源
/// web 在 `appInit.status === "loading"` 时**直接 `return <FullScreenLoader />;`**
/// ⇒ **Routes 根本不渲染**，门之下只有全局那一层 `.aurora`；ready 后才渲染 Routes。
///
/// Flutter 侧不能卸载路由子树（退出画布 / 回跳要保活），故用 `Offstage` 表达「不绘制」：
/// - `gate`（loading）⇒ 页面 offstage + 全屏门显示（同屏只有门，页面内容不参与合成）；
/// - `ready` ⇒ 反过来。
///
/// ## ⚠️ 尺寸陷阱（2026-10-01 实机「全屏加载界面那个转圈圈怎么没了」）
/// 本件**必须**返回 `Stack(fit: StackFit.expand)`。若用默认的 `StackFit.loose`：
/// Stack 的尺寸由**非定位子级**决定，而门打开时唯一的非定位子级恰好是
/// **offstage 的 `Offstage`** —— `RenderOffstage` 在 offstage 时
/// `size = constraints.smallest`（`rendering/proxy_box.dart` 的 offstage 分支）
/// ⇒ **Stack 塌成 0×0** ⇒ `Positioned.fill` 的门被填成 0×0 ⇒ **整个门不可见**。
///
/// 该塌陷**只在门打开时**发生（正是需要它的时刻），ready 后页面一切正常
/// ⇒ 症状表现为「页面没事，只是加载界面没了」，极易漏过 ⇒ 故有
/// `test/app_gate_test.dart` 把「门打开时门的实绘尺寸 == 视口」钉死。
library;

import 'package:flutter/material.dart';

import '../core/app_init.dart';
import '../widgets/base/loading.dart';

/// 见库文档：全屏门与路由页面的互斥装配。
class AylaAppGate extends StatelessWidget {
  const AylaAppGate({
    super.key,
    required this.page,
    this.gallery,
    this.showGallery = false,
  });

  /// 路由子树（`main.dart` 传给 `MaterialApp.router` 的 `child`）。
  final Widget page;

  /// 组件画布（仅 debug 浮标切换用；null ⇒ 不挂）。
  ///
  /// 以参数注入而不是 import `preview/`：本件属 layout 层，不应反向依赖预览层。
  final Widget? gallery;

  /// 是否正在看画布（画布态不显示门，与改动前一致）。
  final bool showGallery;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppInit.instance,
      builder: (BuildContext context, Widget? page) {
        final bool gate =
            !showGallery && AppInit.instance.status == AppInitStatus.loading;
        return Stack(
          // ⚠️ 必须 expand（见库文档的尺寸陷阱）：否则门打开时本 Stack 会塌成 0×0。
          fit: StackFit.expand,
          children: <Widget>[
            Offstage(
              offstage: showGallery || gate,
              child: page ?? const SizedBox.shrink(),
            ),
            if (gate) const Positioned.fill(child: AylaFullScreenLoader()),
            if (showGallery && gallery != null)
              Positioned.fill(child: gallery!),
          ],
        );
      },
      child: page,
    );
  }
}
