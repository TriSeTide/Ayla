# Elysia Web 前端设计方案 ——「千禧冰樱 / Y2K Frost」

> 文档状态：设计规范 v1（供 M5-2 起所有前端界面统一执行）
> 适用范围：`Ayla/web/`（React 18 + Vite + TS + Zustand），阶段五全部界面（聊天 / 语音 / 直播 / 桌游 / 爱莉集成）
> 参考来源：Y2K 美学参考图（冰蓝→樱花粉渐变 + 磨砂卡片 + hot pink 辉光）、Miro 设计系统结构、ui-ux-pro-max 规则库（Y2K Aesthetic / Vibrant & Block-based / Fredoka·Nunito 字配）
> 结构约定：与 `miro_design.md` 同构，方便对照查阅与 agent 直接消费

---

## 1. Visual Theme & Atmosphere

Elysia 是爱莉在 Web 端的「具身家园」。视觉主题定为 **「千禧冰樱（Y2K Frost）」**：冰蓝到樱花粉的极光渐变打底，磨砂半透明玻璃卡片漂浮其上，关键交互与爱莉身份用 hot pink 辉光点亮——千禧年的科技乐观主义，但执行是安静、轻盈、有呼吸感的，不是喧闹的蒸汽波。

**一句话气质**：像 2003 年想象里的未来聊天软件，被 2026 年的工艺重新做了一遍。

**Key Characteristics:**
- 全局极光渐变背景（冰蓝 `#BDD4E9` → 樱粉 `#FCD8FF`），固定不动，内容在其上滚动
- 磨砂玻璃卡片：`backdrop-filter: blur()` + 半透暖白底 + 1px 高光描边
- Hot pink 辉光（`#F796FF`）只给三类东西：爱莉身份、主 CTA、在线状态
- 圆润几何：大圆角（12–28px）、气泡形、胶囊形，无尖锐直角
- 深靛蓝（`#465B92`）承担全部正文与主要交互，保证可读性不被粉色系拖垮
- 动效轻快短促（150–300ms），辉光呼吸是唯一允许的环境动画

**与通用 Y2K 的差异**：不用铬金属质感、不用 CRT 扫描线、不用 glitch——那些是复古噱头。本方案只取 Y2K 的「冰蓝×泡泡粉×辉光×乐观」，其余让给现代可用性。

## 2. Color Palette & Roles

全部颜色围绕给定色系摇摆，定义为 CSS 变量（落盘位置：`web/src/styles/tokens.css`）。

### Core（给定色板原色）

| Token | Hex | 角色 |
|---|---|---|
| `--ice-100` | `#ECF0F2` | 冷灰白，次级表面、分割线底色 |
| `--ice-300` | `#BDD4E9` | 冰蓝，渐变起点、选中态底 |
| `--ice-500` | `#9DBFE6` | 冰蓝加深，hover 底、弱强调 |
| `--slate-500` | `#7E95BD` | 灰蓝，仅用于 ≥14px 次要文字 / 图标（对比度 ~2.9:1，禁止小号正文） |
| `--indigo-700` | `#465B92` | **主文字 + 主交互色**（对 `#FFFAFB` 对比度 ~6.4:1 ✓） |
| `--sakura-100` | `#FCD8FF` | 淡樱粉，渐变终点、爱莉侧气泡底 |
| `--sakura-300` | `#F9B0FF` | 亮樱粉，辉光内层、tag/芯片 |
| `--glow-500` | `#F796FF` | **hot pink 辉光**，阴影/外发光专用，不作文字色 |
| `--pink-500` | `#F17EB3` | 樱花粉，强调图形、徽标底（文字必须配深底） |
| `--grape-700` | `#722E88` | 深紫，粉底的文字色（对 `#FCD8FF` 对比度 ~6.6:1 ✓）、爱莉专属强调 |
| `--surface` | `#FFFAFB` | 暖白，实心卡片底、输入框底 |

### Functional（派生）

| Token | 值 | 用途 |
|---|---|---|
| `--bg-aurora` | `linear-gradient(160deg, #BDD4E9 0%, #ECF0F2 38%, #FCD8FF 100%)` | 全局背景，fixed |
| `--glass-bg` | `rgba(255, 250, 251, 0.55)` | 磨砂卡片底 |
| `--glass-bg-strong` | `rgba(255, 250, 251, 0.78)` | 弹层/模态磨砂底（需更高遮挡） |
| `--glass-border` | `rgba(255, 255, 255, 0.65)` | 玻璃 1px 高光描边 |
| `--text-primary` | `#465B92` | 正文、标题 |
| `--text-secondary` | `#7E95BD` | 次要信息（≥14px） |
| `--text-on-pink` | `#722E88` | 粉底上的文字 |
| `--bubble-self` | `linear-gradient(135deg, #9DBFE6, #BDD4E9)` | 自己发的消息气泡 |
| `--bubble-elysia` | `linear-gradient(135deg, #FCD8FF, #F9B0FF)` | 爱莉的消息气泡（专属） |
| `--bubble-other` | `rgba(255, 250, 251, 0.72)` | 其他用户气泡（玻璃） |
| `--glow-shadow` | `0 0 16px rgba(247, 150, 255, 0.45)` | 辉光外阴影 |
| `--ring-online` | `conic-gradient(from 210deg, #9DBFE6, #F9B0FF, #F796FF, #9DBFE6)` | 在线光环（见 §6 签名元素） |

### Semantic

- **Success**：`#3FA97C`（青绿，避开粉蓝系歧义）
- **Warning**：`#E8A33D`
- **Destructive**：`#D64D6E`（玫红，与樱粉同族但足够深，白字对比 ✓）
- **Focus ring**：`2px solid #F796FF` + `2px` offset

**配比纪律（继承 Miro 「单区不超过 2 个 pastel 强调」）**：任一屏内，粉系（sakura/glow/pink）与蓝系（ice/indigo）必同时出现，但辉光 `#F796FF` 全屏不超过 3 处。

## 3. Typography Rules

### Font Families

- **Display（标题 / 品牌 / 大数字）**：`Fredoka`（600/500）——圆头几何体，Y2K 泡泡感的人格载体
- **Body（正文 / 界面）**：`Nunito`（400/600/700）——与 Fredoka 同族的圆润人文无衬线
- **Utility（时间戳 / 数据 / ID）**：`Space Grotesk`（400/500）——一点 retro-tech 味道
- **CJK 回退**：`"PingFang SC", "Hiragino Sans GB", "Noto Sans SC", "Microsoft YaHei", sans-serif`（中文场景下 Fredoka/Nunito 只覆盖拉丁与数字，中文由系统圆体承接，气质兼容）

```css
font-family: "Fredoka", "PingFang SC", "Noto Sans SC", sans-serif;   /* display */
font-family: "Nunito", "PingFang SC", "Noto Sans SC", sans-serif;    /* body */
font-family: "Space Grotesk", "PingFang SC", monospace;              /* utility */
```

### Hierarchy

| Role | Font | Size | Weight | Line Height | Letter Spacing |
|---|---|---|---|---|---|
| Display Hero | Fredoka | 40px | 600 | 1.15 | -0.5px |
| Page Title | Fredoka | 28px | 600 | 1.2 | -0.3px |
| Card / Section Title | Fredoka | 20px | 500 | 1.25 | 0 |
| Bubble / Body | Nunito | 15px | 400 | 1.55 | 0 |
| Body Strong | Nunito | 15px | 700 | 1.55 | 0 |
| Label / Button | Nunito | 14px | 700 | 1.3 | 0.2px |
| Caption | Nunito | 13px | 400 | 1.45 | 0 |
| Timestamp / Data | Space Grotesk | 12px | 400 | 1.4 | 0.3px |
| Micro Tag | Fredoka | 11px | 500 | 1.2 | 0.8px |

**纪律**：正文最小 13px；`--slate-500` 只允许 14px 以上；时间戳统一 Space Grotesk（retro-tech 细节就在这种地方）。

## 4. Component Stylings

### Buttons
- **Primary**：`--indigo-700` 实底 + 白字，14px/700，圆角 999px（胶囊），hover 时附加 `--glow-shadow`，transition 200ms
- **Glow CTA**（每屏至多 1 个，如「和爱莉聊天」）：`linear-gradient(135deg, #F9B0FF, #F796FF)` 底 + `--grape-700` 字 + 常驻 `--glow-shadow`
- **Ghost**：透明底 + `1px solid rgba(70, 91, 146, 0.35)` + indigo 字，hover 底 `rgba(157, 191, 230, 0.18)`
- 最小高度 40px（触屏目标 ≥44px 的区域用 padding 补足）

### Cards / Panels
- 标准卡片：`--glass-bg` + `backdrop-filter: blur(18px) saturate(1.4)` + `1px solid var(--glass-border)` + 圆角 20px + 内阴影 `inset 0 1px 0 rgba(255,255,255,0.5)`
- 实心卡片（内容密集区，如消息列表）：`--surface` + 圆角 16px + 极浅投影 `0 2px 12px rgba(70, 91, 146, 0.08)`
- **禁止重投影**——深度靠「玻璃 vs 实心」的质地对比，不靠阴影堆叠（继承 Miro）

### Inputs
- 底 `#FFFAFB`（不透明，保证可读）、`1px solid #BDD4E9`、圆角 12px、padding 12px 16px
- focus：边框转 `#F796FF` + `--glow-shadow`，200ms 过渡
- 错误：边框 `--destructive`，错误文案紧贴字段下方（不放顶部汇总）

### Chat Bubbles
- 自己：`--bubble-self` 渐变底 + `--indigo-700` 字，圆角 18px（右下 6px 小角）
- 爱莉：`--bubble-elysia` 渐变底 + `--grape-700` 字 + 1px `rgba(247,150,255,0.5)` 描边，圆角 18px（左下 6px）——**爱莉的气泡全应用唯一，不可复用于其他用户**
- 其他人：`--bubble-other` 玻璃底 + indigo 字
- 引用回复：左侧 3px `#9DBFE6` 竖条 + 弱化一层透明度

### Nav / Sidebar
- 会话列表侧栏：整面大玻璃（`--glass-bg` + blur 24px），选中项 `rgba(157,191,230,0.35)` 胶囊底
- 图标：SVG（Lucide 风格线性图标），**禁止 emoji 当图标**；emoji 只出现在消息内容与表情包

### Tags / Badges
- 胶囊形，`--sakura-300` 底 + `--grape-700` 字（如参考图里的 hot pink 标签），11px Fredoka
- 未读徽标：`--pink-500` 实底白字小圆点

## 5. Layout Principles

- 间距刻度：4 / 8 / 12 / 16 / 24 / 32 / 48（聊天密度场景以 8/12/16 为主）
- 圆角刻度：8（小件）/ 12（输入）/ 16–20（卡片）/ 24–28（面板）/ 999（胶囊、头像）
- 主布局：左侧栏（玻璃，280–320px）+ 主内容区（透明，透出极光背景）+ 按需右栏
- 内容最大宽度 1200px；聊天页不设限宽，气泡列最大 720px 居中偏左
- 网格：12 列，24px gutter；卡片间距 ≥16px

## 6. Depth & Elevation —— 签名元素

**签名：「在线光环」（Presence Halo）**。爱莉与在线用户的头像外圈是一圈 2.5px 的 `--ring-online` 锥形渐变环，爱莉的光环额外带 8px `--glow-shadow` 呼吸（opacity 0.5↔0.9，3.2s ease-in-out）。离线则光环褪为 `--ice-100` 灰环。这是「数字生命在线」的唯一视觉语言，全应用一致，也是这个设计被记住的那一笔。

其余层级：

| 层级 | 表达 |
|---|---|
| 背景 | 固定极光渐变（z 最低，不动） |
| 内容 | 实心卡片浮于背景 |
| 浮层 | 玻璃面板 + blur |
| 模态 | `--glass-bg-strong` + 背景压暗 `rgba(70,91,146,0.25)` |
| 辉光 | 只服务光环、主 CTA、focus |

## 7. Motion

- 时长：hover/焦点 150–200ms；面板进出 200–300ms；`ease-out` 进、`ease-in` 出（退出快于进入）
- 消息到达：气泡从下方 8px 浮入 + 淡入，180ms；不弹跳
- 光环呼吸是唯一常驻动画；其余装饰性循环动画禁止
- 骨架屏：所有 >300ms 的异步加载用 `animate-pulse` 风格骨架（玻璃质感骨架块），禁止白屏/冻结
- `prefers-reduced-motion`：关闭呼吸、浮入，保留透明度渐变

## 8. Do's and Don'ts

### Do
- 每屏蓝粉双系并置，玻璃与实心卡片分层使用
- 辉光只给：爱莉、主 CTA、focus——三处以内
- 圆角走刻度，胶囊留给按钮/标签/头像
- 图标用线性 SVG，2px 描边，圆角端点
- 中文用系统圆体回退，拉丁用 Fredoka/Nunito 出挑

### Don't
- 不用铬金属、扫描线、glitch、像素字——不做复古噱头
- 不把 `#F796FF`/`#F17EB3` 当正文文字色（对比度不达标）
- 不用重阴影、不在玻璃卡片上再叠玻璃卡片
- 不一屏超过 3 处辉光、2 种 pastel 强调
- 不用 emoji 充当功能图标
- 不把爱莉专属气泡/光环样式复用到普通用户

## 9. Responsive Behavior

- 断点：480 / 768 / 1024 / 1440
- ≤768px：侧栏收成抽屉，聊天全屏；辉光阴影强度降 30%（移动端省电省性能）
- `backdrop-filter` 降级：不支持的浏览器回退 `--glass-bg` → `rgba(255,250,251,0.92)`（加不透明度，保可读）
- 验证视口：375 / 768 / 1024 / 1440

## 10. Accessibility Guardrails（ui-ux-pro-max 强制项）

- 正文对比度 ≥ 4.5:1；`--text-primary`、`--text-on-pink` 已达标，`--slate-500` 限大字
- 可点目标 ≥ 40×40px（推荐 44），间距 ≥ 8px
- focus 可见：`#F796FF` 光环式 focus ring，禁止 `outline: none` 无替代
- 色彩不作唯一信息载体：在线状态 = 光环 + 文字标签双通道
- 键盘可达：会话列表、气泡操作、表情面板均可键盘遍历

## 11. Agent Prompt Guide

### Quick Color Reference
- 背景：`--bg-aurora`（fixed 极光渐变）
- 正文/交互：`#465B92`；粉底文字：`#722E88`
- 玻璃卡片：`rgba(255,250,251,0.55)` + `blur(18px)` + `1px rgba(255,255,255,0.65)`
- 辉光：`0 0 16px rgba(247,150,255,0.45)`（限 3 处/屏）
- 爱莉专属：`#FCD8FF→#F9B0FF` 气泡 + 锥形渐变光环 + 呼吸辉光

### Example Component Prompts
- 「做会话列表项：玻璃底（--glass-bg, blur 18px），左头像带 --ring-online 光环，昵称 Nunito 700 15px #465B92，预览 13px #7E95BD，未读徽标 #F17EB3 白字，选中态 rgba(157,191,230,0.35) 胶囊底」
- 「做爱莉聊天气泡：linear-gradient(135deg,#FCD8FF,#F9B0FF)，#722E88 字，1px rgba(247,150,255,0.5) 描边，圆角 18px 左下 6px，到达时 180ms 上浮淡入」
- 「做主 CTA：胶囊，linear-gradient(135deg,#F9B0FF,#F796FF)，#722E88 14px/700，常驻 --glow-shadow，hover 亮度 +6%，200ms」

---

> 本文件是 `Ayla/web/` 视觉唯一事实源。新增组件先看 §4 有没有配方；没有就按 §2/§3/§5 的 token 与刻度推导，推导不出来再改本文件——不要在组件里散落裸 hex。
