# Flutter 语义树崩溃：traversalParentIdentifier 重复断言 —— 根因与修复

- 日期：2026-10-02
- 工作区：E:\Elysium-AyerElysia\Elysium，Flutter 工程 Ayla/flutter/
- 环境：Flutter 3.47.4 stable（framework 9584c6713b，engine 06a2e2a110）、Windows、Impeller、debug
- 事故主体：用户 debug 实例满屏刷两类 ERROR + 语义断言

## 一、结论（先读这段）

| 现象 | 是不是故障 | 根因 | 处置 |
|---|---|---|---|
| traversalParentIdentifier must be unique（semantics.dart:5016） | **是**，Flutter framework 缺陷 | Tooltip → OverlayPortal 无条件插入遍历锚点；该锚点被 absorb 上提后，带 GlobalKey 的行在**未加 key 的列表 item 之间下移索引**时，两个 IndexedSemantics 节点同帧各自持有同一标识 | **已修**：AylaTooltip 按上游 issue #193677 的 workaround 在 Tooltip 外套 Semantics(container: true) |
| Nodes left pending by the update: 617（accessibility_bridge.cc:114） | **是**，但**与「节点过多」无关** | 引擎 ax_tree.cc:1778-1786 逐 id 拼接的**单个未决节点 id** —— 语义更新里「某个节点被挂空」 | 同一根因链的下游产物，随上游不自洽更新消除；**引擎侧无恢复路径**，只能不产生坏更新 |
| Contents::SetInheritedOpacity ... CanAcceptOpacity（Impeller） | **是，但独立** | 本任务无关（另案：lib/widgets/base/reveal.dart 已登记的「Opacity 祖先 + BackdropFilter」问题） | 不在本次范围 |

### 1.1 被推翻的两个前提（重要）

1. **617 不是节点个数。** 引擎 ax_tree.cc:1778-1786：

   ```cpp
   if (!update_state.pending_nodes.empty()) {
     error_ = "Nodes left pending by the update:";
     for (const AXNode::AXID pending_id : update_state.pending_nodes)
       error_ += base::StringPrintf(" %d", pending_id);   // ← 逐个 id 拼接
   ```

   即 617 是**一个**未决语义节点的 id。数字的个数才是节点数。
   ⇒ 「节点太多导致 bridge 更新失败」**不成立**。

2. **lib/ 里确实有 traversalParentIdentifier 的来源。** 不是本库传参，而是 Tooltip 内部的 OverlayPortal：
   框架 widgets/overlay.dart:2096/2116 **无条件**写 Semantics(traversalParentIdentifier: this, child: widget.child)
   （this = OverlayPortal 的 State）。本库 29 处 Tooltip（全部经 AylaTooltip）**每一个都会留下一个遍历锚点**。
   本地实测：语义树中 traversalParentIdentifier != null 的节点，其标识持有者就是这些 Tooltip 节点。

> 补充：Lead 原先怀疑的 _AylaSceneFade（group_page.dart:1043-1064）**不是**根因。
> 该处旧场景被 ExcludeSemantics 包住，实测群页五场景来回切换（宽/窄屏、逐帧）**零异常**。

## 二、复现（已实测）

### 2.1 最小复现（框架级，与 App 无关）

形态：**带 GlobalKey 的行（含 Tooltip）挂在未加 key 的列表 item 内，随后下移索引**。

实测输出（[W-raw] = 裸 Tooltip）：

```
[W-raw] initial=ok
[W-raw] move2to1='package:flutter/src/semantics/semantics.dart': Failed assertion: line 5016 pos 13:
  '!_traversalParentNodes.containsKey(node._traversalParentIdentifier) ||
   _traversalParentNodes[node.traversalParentIdentifier!] == node':
  The traversalParentIdentifier must be unique. No two semantics nodes can share the same traversalParentIdentifier.
[W-raw] move0=<同上>
[W-fix] initial=ok / move2to1=ok / move0=ok      ← 套 Semantics(container: true) 后消失
```

> 断言文案与用户实机报错**逐字一致**（含 line 5016 pos 13）。

### 2.2 语义等价实测（证明修复不削弱无障碍）

AylaTooltip(message: '一键禁音', child: Text('禁音')) 的语义树导出：

```
#4{label="禁音" tooltip="一键禁音" tp=Y children=0}   ← 提示语义与锚点都在，且无额外节点
```

⇒ Semantics(container: true) **不产生独立语义节点**，label / tooltip 原样保留。

## 三、改动

### 3.1 代码（唯一生产改动）

- Ayla/flutter/lib/widgets/base/tooltip.dart
  - AylaTooltip.build：在 Tooltip **之外**套 Semantics(container: true)；
  - 文件头新增「语义崩溃规避」小节，登记根因链、上游 issue 号、文件:行 依据与「视觉零影响」论证。

⚠️ 包裹必须在 Tooltip **之外**（放在 child: 里无效，实测两者锚点节点不同）。
⚠️ **零视觉改动**：不涉及任何尺寸 / 颜色 / 动画时长 / 布局结构。

### 3.2 测试（新增回归锁）

- Ayla/flutter/test/semantics_traversal_lock_test.dart（新增，5 条）：
  1. 生产 AylaTooltip：连续重排不抛语义断言；
  2. **正对照**：裸 Tooltip 仍会抛（证明锁对缺陷敏感；缺陷消失时只打日志提醒复核，不判失败）；
  3. 语义等价：label / tooltip 保留 + 每个标识只有唯一持有者；
  4. 端到端：**群页五场景来回切换**（宽屏，真实路由 + 真实主题 + 真实表面）；
  5. 端到端：**宽屏 rail 重排**（1440→900→1440→700→1600）。

### 3.3 文档

- Ayla/flutter/lib/preview/component_gallery.dart：订正原「1600+ 节点导致 bridge 失败」的结论
  （该结论与引擎源码矛盾，会误导后续取舍）。

## 四、验证与操作记录

| 项目 | 命令 | 结果 |
|---|---|---|
| 静态分析 | flutter analyze lib（workdir Ayla/flutter） | **No issues found** |
| 新增锁 | flutter test test/semantics_traversal_lock_test.dart --concurrency 1 | **5 passed** |
| 定向回归 | group_info_lists_test / group_scene_pieces_test / smoke_gallery_test / voice_member_row_test / message_list_test / channel_sidebar_test（逐文件、--concurrency 1） | **全绿** |
| 最小复现 | 见 §2.1 | 裸 Tooltip 抛、修复后不抛 |

### 4.1 一次误操作及恢复（如实记录）

排查收尾时执行 Remove-Item test\tmp_*.dart 清理探针，**误删了 18 个仓库既有的跟踪文件**
（test/tmp_*_probe_test.dart，属其他并行任务的产物）。已立即用精确路径
git checkout -- <逐个列出的 18 个路径> 全部恢复，git status 复核后工作树只剩本任务两个文件。
⇒ **教训**：清理探针必须逐个列出自己的文件名，**禁止通配删除**。

## 五、可逆性与回滚

三项改动均为**纯增量、可单独回退**：
1. 代码：git checkout -- Ayla/flutter/lib/widgets/base/tooltip.dart（回到裸 Tooltip）；
2. 测试：删除 test/semantics_traversal_lock_test.dart（注意：其正对照会随之消失，缺陷将无锁）；
3. 文档：git checkout -- Ayla/flutter/lib/preview/component_gallery.dart。

> 回滚代码即恢复原崩溃形态（已在 §2.1 实测）。

## 六、ensureSemantics() 的处置结论

**保留。** 依据：
1. 根治后断言在 §2.1 的复现形态下**不再出现**，group_page 五场景与宽屏重排路径零异常；
2. ensureSemantics() 是 debug-only 调试辅助（main.dart:96-100），本次它是**暴露问题的探针**，
   不是问题本身 —— 真实辅助技术接入时同样会走这条语义管线；关掉只会掩盖；
3. 上游缺陷**至今未修**（master 与 3.47.4 stable 均有该断言），升级版本不能替代本次规避。

## 七、仍然待决（归属人：用户）

1. **617 那个未决节点究竟是谁**：本次未能在测试环境复现（测试无真实数据，语义节点仅 9–29 个；
   真实数据下才有 600+ 节点）。若刷屏仍在，请提供一条完整日志上下文（前后各 20 行 + 当时的操作），
   可据此定位是哪个语义节点被挂空。
2. **/voice 路由的既有 FlutterError**：实测宽/窄屏均抛
   setState() or markNeedsBuild() called during build（HomePage，DEFUNCT element）。
   与语义树无关，**本次未修**（不在本任务范围），建议单独立项。
3. **上游 issue #193677** 修复后，AylaTooltip 的包裹可评估撤除；§3.2 的正对照用例会在那时打日志提醒。

## 八、证据来源

- 框架：E:\flutter-3.47.4\packages\flutter\lib\src\{semantics\semantics.dart, widgets\overlay.dart, widgets\basic.dart, rendering\object.dart, rendering\custom_paint.dart}
- 引擎：E:\flutter-3.47.4\engine\src\flutter\{third_party\accessibility\ax\ax_tree.cc, shell\platform\common\accessibility_bridge.cc}
- 上游：flutter/flutter issue **#193677**（open，即本形态）、#191173（同断言旧报，被 stale bot 关）；
  引入 commit fccfa978a976 = "Reland Refactor OverlayPortal semantics (#173005)"（随 3.41.0 发布）；master 该断言仍在。
- 本库：lib/widgets/base/tooltip.dart（29 处调用点的唯一汇聚点）、lib/main.dart:96-100。
