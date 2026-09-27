# 流体极光背景：Flutter ↔ web 逐像素对账与三处根因修正

- 日期：2026-09-27
- 域：`Ayla/flutter/lib/theme/{aurora_background,aurora_baked_layer,aurora_turbulence}.dart`
- 事实源：`Ayla/web/src/styles/tokens.css`、`base.css`、`auroraqua.css`（三文件为唯一依据）
- 报障现象（用户）：**web 端**是「四角四色在缓慢旋转、能明显看到樱粉 `--pink-500 #F17EB3`」；
  **Flutter 端**是「中间一大片白、看不到四色在转、也看不到樱粉」

---

## 1. 事实源归属（先 grep 再动手）

| 内容 | 落点 |
|---|---|
| `--bg-aurora` 九层 radial、`--bg-aurora-grid` 两层 repeating-linear、`--bg-aurora-turbulence` SVG、`--fluid-*` 变量 | `tokens.css` 28–63 |
| `html` 静态兜底（25）· `html::before` 流层（57–80）· `html::after` 湍流层（82–95）· `body::before/::after` 双光斑（99–128）· 全部 `@keyframes`（131–208）· 窄屏档（211–246、249–303）· reduced-motion（305–314） | `base.css` |
| `#root { z-index: 1 }`（内容浮在背景上） | `base.css` 44–48 |
| 背景层 | **`auroraqua.css` 零命中** —— 它只有交互材质、断点布局覆写、reduced-motion 关交互动效 |

结论：背景的层、关键帧、降级分支全部在 `base.css`，token 定义在 `tokens.css`；
`auroraqua.css` 不参与背景，但它最后加载 ⇒ 排查任何类名时仍要连带确认覆写。

## 2. 对账方法（可复现）

1. 把三个事实源文件内联进一个静态页（`<style>` 里按 `tokens → base → auroraqua` 顺序），
   起临时静态服务（本次用 `python3 -m http.server`，只读、用完即关）。
2. 相位对齐：页面里 `document.getAnimations().forEach(a => { a.pause(); a.currentTime = t })`。
   `currentTime` 已包含负延迟（`activeTime = currentTime − delay`）⇒ `t = 0` 就是页面加载瞬间的
   `-8s` / `-5s` 相位，与 Flutter 侧 `AnimationController(value: 8/20)` 同相。
3. 同尺度出图：浏览器 `setViewportSize` 按**设备像素**计（本机 DPR 1.25）⇒ 传 `1908×910`
   得到 CSS 视口 **1526×728**，截图 1908×910 设备像素；Flutter 侧逻辑 1526×728 + DPR 1.25 ⇒
   同样输出 1908×910。两侧的 `150vmax` / `40vw` / `blur(40px)` 因此在同一像素空间可比。
4. 逐像素比对（`OffscreenCanvas` + `getImageData`，直接比原始字节，**不经 PNG 中转**）。
5. 逐层隔离：web 侧 `addStyleTag` 注入 `html::after{display:none!important}` 等；
   Flutter 侧用 `kAyla*LayerEnabled` 开关。**「关掉哪一层后 Δ 塌下来」就是那一层的问题。**

## 3. 三处根因

### 3.1 流层尺寸写成 165vmax（web 是 150vmax）

- web：`base.css:62-63` —— `width: 150vmax; height: 150vmax;`；
- 本地：`AylaFluidAurora.gradientVmax = 165`，注释却自称「150vmax」，测试里还写着
  「本实现有意放大（露边）」——**查无依据**：web 自己在 `base.css:73-77` 就论证过 150vmax 不露边
  （「内切圆 52.5vmax ≥ 视口边缘 50vmax…旋转任意角度均不露边」）。
- 后果：四角四色被推离视口 ⇒ 视口内只剩第 9 层中心暖白与 5–8 层边中点白 = **「中间一大片白」**；
  同时 `@keyframes` 的 `translate3d(±4%)` 以**元素自身尺寸**为百分比基准 ⇒ 漂移幅度一并偏大 10%
  （实测同一相位矩阵平移 `96.76` vs web `88.01`）。

### 3.2 `--bg-aurora-grid` 两处语义写错（tokens.css:39-40）

原文：`repeating-linear-gradient(0deg, rgba(157,191,230,.015) 0 1px, rgba(157,191,230,.008) 3px, transparent 4px 96px)`。

- 漏掉 `0–1px` 的**常量段**（旧实现 0→1px 直接 A→B 插值）；
- `0deg` 的相位起点写成**顶边**（CSS `0deg` 表示**向上** ⇒ 渐变线起点在**底边**）；
- 连带：`transparent` = `rgba(0,0,0,0)`（黑色透明），不能写成同色 0 alpha。

影响有限（alpha .015 + `blur(40px)` ⇒ 肉眼不可见），但属实现偏差，已按规范逐段重写。

### 3.3 湍流层落盘成非预乘（本次「整体发白」的真正机制）

- `ui.decodeImageFromPixels(..., PixelFormat.rgba8888)` 的引擎语义是 **`kPremul_SkAlphaType`**
  —— 它把传入字节**当作已预乘**。旧实现落盘的是**非预乘** sRGB（还多走了一条
  `×na8 → q8 → ÷na8` 的伪预乘链，`q8()` 内部再乘 255 ⇒ 颜色几乎恒被钳成 255）。
- 后果：Skia 不再乘 alpha，湍流层以「未预乘亮度」参与 src-over 合成 ⇒ **全屏均匀抬亮
  Δ≈13/255**（alpha 越低抬得越多），且 t>0 相位最明显。
- 隔离验证：只关掉湍流层，全层平均 Δ 从 **13.51 → 0.47**。

## 4. 修正

| 文件 | 改动 |
|---|---|
| `lib/theme/aurora_background.dart` | `gradientVmax` 165 → **150**；网格按 CSS 逐段重写（常量段 + 底边/左边相位 + 黑色 transparent）；头部补「尺寸口径」与本节结论 |
| `lib/theme/aurora_turbulence.dart` | LUT 索引用**非预乘**线性值；落盘改为**预乘 8bit sRGB**（`srgb × na8`），删掉伪预乘链；更正头部与 `pixels()` 的语义说明 |
| `test/aurora_background_test.dart` | `gradientVmax == 150`；湍流**预乘锁**（逐像素 `R/G/B ≤ A`）；几何断言改用常量表达 |
| `test/aurora_pixels_test.dart` | 新增两个**组件级对账**用例（全层 t=5000 十三点 / reduced-motion 九点，基准值取 web 实渲染） |
| `lib/preview/component_gallery.dart` | 背景分区 source 补对账口径与「层分解小舞台只判有无、观感看 1440×810」提示 |

## 5. 验证结果

平均绝对差（255 制，两侧同按设备像素出图）：

| 档位 | 修正前 | 修正后 |
|---|---|---|
| 宽屏 t=0 / 5000 / 10000 / 15000 | 0.63 / **13.51** / 11.87 / 11.99 | 0.63 / **0.47** / 0.54 / 0.46 |
| 窄屏 376×240 t=0 / t=5000 | — | 1.06 / 0.68 |
| reduced-motion（只剩静态九层） | — | 0.67 |

纹理级：Dart 生成的 480×480 feTurbulence 与浏览器实渲染**97.98% 四通道完全一致**，
均值绝对差 R=0.060 / G=0.142 / B=0.009 / A=0.0000（余下差异为 8bit 预乘往返量化）。

`dart analyze lib`：0 告警。

## 6. 本次更正的历史结论（原句已直接改写，不留两种说法）

- 「湍流纹理逐字节 RGBA 98.92% 相同」——**假象**：旧对比经 `toByteData(png)` 中转，
  该接口按预乘解释输入，会把非预乘数据整片钳成 255，恰好掩盖缺陷。真实一致率 97.98%。
- 「不同时刻的截图本来就不该直接比」——**错**：相位可以精确对齐（见 §2.2）。
- 「『app 背景白很多』的最可能机制 = 烘焙未就绪/失败」——那两处修法（降级直绘 + `try/catch`）
  保留（解决的是独立的健壮性缺陷），但它不是本次「白」的原因。

## 7. 待决 / 后续

1. 本次只对账了**背景本身**；`LoginPage` 等页面上的玻璃卡（`backdrop-filter blur(24) saturate(1.4)`）
   会把背景再糊一层，那是页面级观感，需在真机上另看。
2. 烘焙降采样（`bakeMaxSide`）在 4K 视口下会更明显 —— 属性能取舍，未改。
3. 「露边」在 web 侧本来就是既有行为（最坏相位 `scale 0.78` + 漂移），本次按 web 原样复刻，
   未做「放大层」的自由发挥。
