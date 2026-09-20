# 10 - Ayla Flutter 复刻：Batch 4 交付与当前状态

> 交接文档。写于 2026-09-20，对应当前 `HEAD`：
> 子仓库 Ayla `60b18b0` / 父仓库 `54bea434`。
>
> 本文档面向「接手继续开发的下一个 agent」。先读本文，再读
> `06-开发步骤.md`（主操作手册）与 `05-实施提示.md`（配方速查）。

## 1. 当前进度总览

已完成 5 个批次，组件库已具备复刻全部 27 个 tsx 页面的基础件。

| 批次 | 内容 | 提交 |
|---|---|---|
| — | 组件库从零重建：设计 token / 玻璃基元 / 47 图标 / 预览画布 | `58c6eea` |
| — | 玻璃卡通透性修复 + 按钮族 + 登录页 | `7179b29` |
| B2 | 展示型基元：LayoutSwitch / SegmentedTabs / CapsuleTag / Scrolling* | `e05ea65` |
| — | 组件库全量审查：修复 9 处与 web 不符 | `470d584` |
| B3 | 卡片族：GroupCard / GroupCarousel / GroupListItem / 状态角标 / 更多菜单 | `fc5662f` |
| **B4** | **通用基元 + 目录筛选族 + 组件库复用重构** | **`60b18b0`** |

### B4 交付清单（14 个组件）

| 组件 | 文件 | 对应 web |
|---|---|---|
| `MediaSigner` | `lib/core/media/media_signer.dart` | `api/media.ts` |
| `ResourceImage` | `lib/widgets/resource_image.dart` | `ResourceImage.tsx` |
| `ConfirmDialog` / `AylaAsyncState` | `lib/widgets/dialogs.dart` | `ConfirmDialog.tsx` / `AsyncState.tsx` |
| `SignedVideo` | `lib/widgets/media_interaction.dart` | `SignedVideo.tsx` |
| `AylaPullToRefresh` / `PullTracker` / `dampPull` | 同上 | `PullToRefresh.tsx` |
| `StablePaginationFooter` | `lib/widgets/directory_controls.dart` | `StablePaginationFooter.tsx` |
| `AylaDirectoryLoadMore` | 同上 | `DirectoryLoadMore.tsx` |
| `AylaHistoryControls` | 同上 | `HistoryControls.tsx` |
| `AylaFavoriteButton` | 同上 | `FavoriteButton.tsx` |
| `AylaVisibilitySelector` | 同上 | `VisibilitySelector.tsx` |
| `AylaUserProfileCard` | `lib/widgets/profile_and_filters.dart` | `UserProfileCard.tsx` |
| `AylaDirectoryFilters` | 同上 | `DirectoryFilters.tsx` |
| `PrivacySheet` | `lib/widgets/privacy_sheet.dart` | `PrivacySheet.tsx` |
| `AylaModalCard` / `AylaModalOverlay` | `lib/widgets/dialogs.dart` | `.create-sheet-card` / `.privacy-sheet-card` 共用容器 |

### 剩余批次

- **B5** 帖子族 / **B6** 语音族 / **B7** 直播族 / **B8** 聊天族
- 之后是 27 个 tsx 页面（窄屏 + 宽屏两种形态）

## 2. 组件库能力现状（复用优先原则）

用户明确定下的规矩：

> **遇到可复用的内容不要手动自己写，要先看整个组件库；
> 只有在整个组件库里都没有实现的内容，才新增组件。**

B4 期间为遵守该规矩，扩展了组件库（而非在页面里重复造）：

| 组件 | 新增能力 | 为什么必须加 |
|---|---|---|
| `AylaModalCard` | 新建 | `.create-sheet-card` 与 `.privacy-sheet-card` 规格同源，重复实现会让材质在两处漂移 |
| `AylaModalOverlay` | 新建 | 同上（遮罩 + 窄屏贴底 + 点遮罩关闭） |
| `GlassButton` | `destructive` 变体 | web 有 `.btn-destructive`，组件库原缺 |
| `GlassInput` | `keyboardType` / `inputFormatters` / `maxLength` / `onChanged` | 验证码输入需要数字键盘 + 过滤非数字 |
| `GlassSurface` | `radiusOverride` / `borderOverride` | 支持「无圆角顶栏」「只下边框」（原只能表达均匀圆角 + 四边有无） |
| `AylaGlassShadow.ring` | 由私有 `_OuterShadowPainter` 提升为公共 API | 多个组件需要「只画形状之外」的阴影 |
| `AylaNavHighlight` | `showBorder` | 宿主播钮已画同色边时避免双层白线 |
| `AylaIcon` | `filled` 运行时覆盖 | web 按用途传 `fill="currentColor"` |

**全库公开组件清单**（下次改动前先查这里）：
`app_icons`(AylaIcon) · `app_theme`(AylaTextStyles) · `aurora_background` ·
`buttons`(AylaPressScale/AylaIconButton/AylaCornerFab/AylaCreateFab/AylaMessageFab/
AylaToolButton/AylaMsgActionButton) · `glass`(GlassSurface/GlassCard/GlassButton/
GlassInput/AylaGlassShadow/AylaGlassInset/GlassConfig) · `avatar_halo` ·
`avatar_status_badges` · `conversation_more_menu` · `dialogs`(ConfirmDialog/
AylaAsyncState/AylaModalCard/AylaModalOverlay) · `directory_controls`(9 个) ·
`group_card`(8 个) · `loading`(LoadingSpinner/AylaSkeleton/FullScreenLoader) ·
`media_interaction`(3 个) · `primitives`(AylaLayoutSwitch/AylaSegmentedTabs/
AylaNavHighlight/AylaSegmentedTab/AylaCapsuleTag/AylaScrollingText/AylaScrollingTags) ·
`privacy_sheet` · `profile_and_filters`(2 个) · `resource_image` · `tab_badge`

## 3. 本轮踩过的坑（**必读，避免重犯**）

### 3.1 工作方式类（最重要）

**① 改之前必须完整读 web 源码 —— 不能用推理代替事实。**

B4 收尾阶段（筛选条）我连续返工 10+ 轮，**根因全部是"用推理代替读代码"**。
用户明确批评过一次："你改之前又没看 web 端代码"。

正确顺序：
1. `grep` 出组件的**全部** CSS 命中（含 `auroraqua.css` 覆写）
2. 读 tsx 看 JSX 结构与事件绑定
3. 读 motion 配置（`auroraquaMotion.ts`）
4. **才开始写代码**

**② 测试时的 `tester.pump()` 不带时长参数不推进动画时间。**

我用 `await tester.pump()` 读 `AnimationController.value`，一直读到静止值，
误判成"扫光卡住"，据此做了两轮错误修复。正确写法：
```dart
await tester.pump(const Duration(milliseconds: 100));  // 必须给时长
```

**③ 事件驱动 ≠ 状态谓词。**

CSS 的 `:hover` 是**每帧求值的谓词**，不是事件。Flutter 的
`MouseRegion.onEnter/onExit` 只在**指针移动**时触发 →
漏掉「指针静止、高亮滑到指针下」这一半。
凡是 web 用 `:hover`/`:focus-visible` 表达的状态，Flutter 侧都应在
**build 时求值**（记录索引/标志，而非订阅事件）。

### 3.2 Flutter 与 CSS 的语义差（本项目高频事故源）

| # | CSS 语义 | Flutter 行为 | 修法 |
|---|---|---|---|
| 1 | `box-shadow` **不在 border-box 内部绘制** | `BoxShadow` **铺满形状含内部** → 半透明面上发灰、hover 时冰蓝染进按钮内部 | `AylaGlassShadow.ring`（`Path.combine(difference,…)` 挖空内部） |
| 2 | `background` 与 `border` **分离绘制**，两者都可见 | `BoxDecoration` 同时给 `gradient` + `border` 时，**渐变盖住 1px 边框** | 拆层：底色 → 内高光 → **边框（独立层）** |
| 3 | `background-color` 过渡用 **premultiplied alpha**（色相恒定） | `Color.lerp` **逐通道直插**（`painting.dart` 424–457）→ 从 `Colors.transparent`（**透明黑**）插值中途是**中性灰** | 零透明用**同色相** `color.withValues(alpha: 0)` |
| 4 | `overflow` 裁剪边界是 **padding box**（含 padding） | `SingleChildScrollView` 裁剪在**自己的 content box** → 外阴影被裁断 | padding 放进滚动视图**内部** |
| 5 | `transition` 在元素**挂载时若 `:hover` 已匹配** → 首帧直接是终点值，**不产生过渡** | `AnimationController.forward()` 会从头播 → 行程被提前消耗 | 直接置 `controller.value = 1.0`（见 `setSweep(jump: true)`） |
| 6 | `transform: translateX(120%)` 百分比相对**自身宽度** | `FractionalTranslation` 同样相对自身 ✓（一致） | 无需处理 |
| 7 | `linear-gradient` 长度 `\|W·sinθ\|+\|H·cosθ\|` | `Alignment` 端点在**归一化空间**插值 → 只有正方形等价 | `cssLinearGradient(aspectRatio: 宽/高)`，在 `LayoutBuilder` 内生成 |
| 8 | `backdrop-filter: blur(24px) saturate(1.4)` | 需 `ImageFilter.compose(outer: ColorFilter.matrix, inner: blur)` | `GlassConfig.backdropFilter`；**saturate 是分档的**（24/18→1.4；8→无；app.css 3585 是 1.2） |
| 9 | 7 个 `--glass-*` 阴影 token 全含 `--glass-inset` | `BoxShadow` 无 inset 变体 | `AylaInset.topHighlight(height)` / `AylaGlassInset.over` |
| 10 | `Stack` 默认不裁剪越界装饰？ | Flutter `Stack` 默认 `Clip.hardEdge` → 越界装饰**完全不可见**（但 `getRect` 报位置正确） | `clipBehavior: Clip.none` |

### 3.3 其他环境坑

- **`previewTheme` 必须提供 `MaterialLocalizations` + `Overlay`**：
  否则所有含 `TextField` 的组件在预览与测试里**直接崩溃**。
  且 locale **必须是 `en`** —— `DefaultMaterialLocalizations.delegate`
  只认英文，传 `zh_CN` 会**静默返回 null**（已踩）。
- **不能在 `initState` 读 `MediaQuery`**：抛
  `dependOnInheritedWidgetOfExactType<MediaQuery>() was called before
  initState() completed` → 放到 `didChangeDependencies`。
- 条件表达式 `? 1 : 0` 返回 **int**，Dart **不会**提升为 `double`，
  传给 `Opacity.opacity` 会崩（analyzer 也不报）→ 写 `1.0` / `0.0`。

## 4. 验收与测试现状

- `dart analyze lib` **零告警**
- `flutter test --concurrency 1` → **74/74 通过**
  （并发跑会因内存压力导致 `icons_golden_test` "did not complete"）
- Windows release 构建通过：
  `Ayla/flutter/build/windows/x64/runner/Release/ayla_flutter.exe`

## 5. 预览环境

```bash
cd Ayla/flutter
bash tool/preview-up.sh        # 幂等；健康则复用，绝不杀进程
```
- 当前预览端口曾为 **57003**（会变，以脚本输出为准）
- CDP 工具：`tool/cdp-look.mjs`（`info` / `reload` / `shot` / `eval` / `viewport`）
- **组件画布** `lib/preview/component_gallery.dart` 是**模型的可截图验收面**
  （预览器首屏外的分组模型看不到：无 DOM 文本节点、无可滚动容器、
  WheelEvent 注入无效）
- 每个组件都必须有 `@Preview`，并同时加入画布 —— **无预览 = 未交付**

## 6. 下一步建议

1. **B5 帖子族**（`PostCard` / `PostEditor` / `CommentList` / `CommentComposer` /
   `PostVideoCover` / `EmojiPackPanel` 等）
2. 继续遵守「复用优先」：**先查 §2 的组件清单**，缺能力就扩组件库
3. 每批完成即：`dart analyze` → 全量测试 → 加预览与画布 → 提交（子 + 父指针）
