# Ayla Web 前端设计方案 ——「千禧冰樱 / Y2K Frost」

> 文档状态：设计规范 v2（阶段五全部界面 + 聚合主页与多端布局增量，见 §12）
> 适用范围：`Ayla/web/`（React 18 + Vite + TS + Zustand），聊天 / 语音 / 直播 / 桌游 / 爱莉集成 / 主页 / 消息 / 搜索 / 个人界面
> 参考来源：Y2K 美学参考图（冰蓝→樱花粉渐变 + 磨砂卡片 + hot pink 辉光）、Miro 设计系统结构、ui-ux-pro-max 规则库（Y2K Aesthetic / Vibrant & Block-based / Fredoka·Nunito 字配）
> 结构约定：与 `miro_design.md` 同构，方便对照查阅与 agent 直接消费

---

## 1. Visual Theme & Atmosphere

Ayla 是爱莉在 Web 端的「具身家园」。视觉主题定为 **「千禧冰樱（Y2K Frost）」**：冰蓝到樱花粉的极光渐变打底，磨砂半透明玻璃卡片漂浮其上，关键交互与爱莉身份用 hot pink 辉光点亮——千禧年的科技乐观主义，但执行是安静、轻盈、有呼吸感的，不是喧闹的蒸汽波。

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

## 12. 聚合主页与多端布局组件配方（增量）

> 适用范围：本次「聚合主页与多端布局」增量（窄屏五 tab + 宽屏 TopNav + Discord 式左侧栏）。所有配方从 §2/§3/§5 token 推导，遵守 §8 Do/Don't 与 §10 可访问性。

### 12.1 底部五 tab 栏 BottomTabs（窄屏专属）

- 容器：高 64px + `env(safe-area-inset-bottom)`，整面玻璃 `--glass-bg` + blur 18px，顶部 1px `--glass-border` 描边
- tab 项：五等分；线性 SVG 图标 24px（2px 描边圆角端点）+ 11px Fredoka 文字（`--text-secondary`）；选中态图标+文字转 `--text-primary`
- **主页 tab 居中凸起**：圆形背板 48px 上浮 8px，底 `--surface`，选中时附 `--glow-shadow`（全屏允许的主 CTA 级辉光之一）
- 未读徽标：`--pink-500` 实底白字小圆点（11px Fredoka），右上角偏移
- 进场/退场：`translateY` 200–250ms，ease-out 进 / ease-in 出

### 12.2 顶部导航栏 TopNav（宽屏常驻）

- 容器：高 64px，整面玻璃 `--glass-bg` + blur 18px，常驻不滚走，底部 1px `--glass-border`
- 布局：左起 头像（40px 圆形带 `--ring-online` 光环，→个人界面）→ 一级模块文字链（主页/语音/直播/帖子/桌游，Nunito 700 15px `--text-primary`）→ 消息（带未读徽标）→ 搜索框（240px 胶囊，见 12.9）→ 更多（三，40px 图标按钮）
- 当前模块：文字 `--text-primary` + 底部 2px `--glow-500` 指示条
- hover：模块文字底 `rgba(157,191,230,0.18)` 胶囊（200ms 过渡）

### 12.3 服务器栏 ServerRail（宽屏，主页/群场景最左）

- 容器：宽 72px，整面玻璃 `--glass-bg` + blur 24px，纵向排列，间距 12px，顶部留 16px
- 群头像：48px 圆形，带 `--ring-online` 光环；当前群左侧 3px `--glow-500` 指示条 + 头像微放大（48→52px，200ms）
- 状态角标：头像右下角 16px 圆形底（`--pink-500` 未读 / `--glow-500` 直播 / `--ice-500` 语音 / `--sakura-300` 桌游），内嵌 10px 白色线性图标
- 底部用户卡：40px 头像带光环 + 在线状态点；点击进个人界面

### 12.4 频道侧栏 ChannelSidebar（宽屏，主页/群场景）

- 容器：宽 240–280px，整面玻璃 `--glass-bg` + blur 24px
- 群名头：Fredoka 500 20px `--text-primary`，padding 16px，点击进群信息；右侧 chevron 图标
- 场景项（聊天/语音/直播/帖子/桌游）：行高 40px，圆角 12px 胶囊，左 20px 线性图标 + Nunito 600 15px 文字（`--text-secondary`）；选中态底 `rgba(157,191,230,0.35)` + 文字转 `--text-primary`；hover 底 `rgba(157,191,230,0.18)`
- 状态标识：行右侧——语音在麦人数（Space Grotesk 12px `--text-secondary`）、直播 LIVE 徽标（`--pink-500` 底白字 11px Fredoka 胶囊）、帖子未读数（`--pink-500` 圆点）

### 12.5 浮动按钮 FAB（两形态）

- CreateFAB（右下，两形态都有）：56px 圆形，主 CTA 样式——`--indigo-700` 实底 + 白色加号线性图标（24px），常驻 `0 2px 12px rgba(70,91,146,0.18)` 浅投影；hover/按下附 `--glow-shadow`（200ms）。窄屏 `right:16px; bottom:底栏高+12px`；宽屏 `right:32px; bottom:32px`
- MessageFAB（窄屏左下）：56px 圆形玻璃底 `--glass-bg` + blur 18px + 1px `--glass-border`，消息线性图标 `--text-primary`；未读聚合徽标 `--pink-500` 右上角
- FAB 动作面板：窄屏底部上滑面板 / 宽屏 FAB 上方浮层——`--glass-bg-strong` + blur 18px + 圆角 24px（上沿）/16px（浮层），背景压暗 `rgba(70,91,146,0.25)`；面板项 = 图标 + 文字行（行高 48px）

### 12.6 群卡片 GroupCard 与轮播（窄屏主页）

- 卡片：实心卡片底 `--surface` + 圆角 16px + 极浅投影 `0 2px 12px rgba(70,91,146,0.08)`（design.md §4 实心卡片）
- 封面区：4:3，内嵌 8px，轮播图圆角 12px；无动态时回退群头像（居中 64px 带光环）
- 轮播：300ms 滑入切换，3s 间隔；**进视口才启动、离开暂停**（IntersectionObserver）；`prefers-reduced-motion` 降级为首帧静态。轮播指示点：底部居中 3 个 4px 圆点（当前 `--glow-500`，其余 `--ice-300`）
- 状态角标列：封面右上角纵向叠放（未读 > 直播 > 语音 > 桌游），同 12.3 角标规格
- 卡片底部行：群头像 24px 带光环 + 群名 Nunito 700 15px `--text-primary` 一行省略
- 列表布局（GroupListItem）：行高 64px，玻璃底；左群头像 44px 带光环（右下角状态角标），中群名 Nunito 700 15px + 新消息预览 13px `--text-secondary` 一行省略，右未读徽标 `--pink-500`

### 12.7 直播间（两形态）

- 窄屏沉浸式：视频全屏；覆盖层顶部主播信息行（玻璃底 `--glass-bg`）、底部弹幕输入框（`--glass-bg-strong` 半透明，InputBar 变体）；左上角返回键 40px 圆形玻璃容器 + 箭头图标
- 宽屏：视频主区 + 弹幕侧列 360px（整面玻璃，弹幕列表 + 底部弹幕输入框）；视频两侧「上一个/下一个」40px 圆形玻璃按钮 + 键盘 ↑↓
- LIVE 徽标：`--pink-500` 实底白字 11px Fredoka 胶囊，左上角
- 直播间卡片（聚合网格）：封面 16:9 圆角 12px + LIVE 徽标 + 标题 Nunito 700 15px + 主播 13px `--text-secondary` + 来源标识（公开/好友/群名，Micro Tag 11px Fredoka `--sakura-300` 底 `--grape-700` 字）

### 12.8 帖子卡 PostCard 与信息流

- 卡片：实心卡片 `--surface` + 圆角 16px + 极浅投影；padding 16px
- 头部：作者头像 36px 带光环 + 昵称 Nunito 700 15px + 时间 Space Grotesk 12px `--text-secondary`
- 正文：Nunito 400 15px `--text-primary`，超 3 行折叠 +「展开」（`--ice-500` 文字钮）
- 图片：1 图大图圆角 12px；多图 3 列九宫格 gap 4px 圆角 8px
- 底排：评论数 / 收藏（线性图标 18px + Space Grotesk 12px 数字，`--text-secondary`）；收藏激活态图标填 `--pink-500`
- 评论输入框：InputBar 变体（底 `--surface` + 1px `--ice-300`，focus 转 `--glow-500` + 辉光）

### 12.9 搜索框与结果

- 顶栏搜索框（两形态）：胶囊，底 `--surface`、1px `--ice-300` 描边、圆角 999px，左搜索图标 `--text-secondary`；focus 边框转 `--glow-500` + `--glow-shadow`（200ms）
- 宽屏内联下拉结果面板：`--glass-bg-strong` + blur 18px + 圆角 16px，宽 360px；分组（用户/群聊/直播间/帖子/桌游室）组头 Micro Tag 11px Fredoka `--text-secondary` 大写，每组 ≤3 条 + 「查看更多」
- 窄屏独立搜索页：TopBar 变搜索输入态（自动聚焦）；历史搜索胶囊 chips（`--ice-100` 底 `--text-primary` 字，可清空）

### 12.10 语音房卡片与语音房

- 语音房卡片：实心卡片；房间名 Nunito 700 15px + 房主 13px `--text-secondary` + 在麦人数（麦克风图标 + Space Grotesk 12px）+ 成员头像堆叠（≤5 个 28px 圆形重叠 -8px，带光环）+ 来源标识 Micro Tag
- 语音房（进入后）：成员网格（头像 64px 带光环 + 麦克风状态角标——开麦 `--glow-500` / 闭麦 `--ice-300`）；底部控制排（静音/扬声器/上麦/离开，48px 圆形玻璃钮，离开为 `--destructive`）+ 输入框（房内打字）
- 上麦按钮：主 CTA 胶囊（`--indigo-700` 实底白字）

### 12.11 桌游室卡片

- 实心卡片 2 列网格；封面占位图（`--ice-100` 底 + 游戏线性图标 `--ice-500` 48px）圆角 12px + 房间名 Nunito 700 15px + 状态 tag（等待中 `--ice-300` 底 / 对局中 `--sakura-300` 底 `--grape-700` 字，Micro Tag 胶囊）+ 人数 Space Grotesk 12px

### 12.12 手势与场景动画（窄屏）

- 五 tab / 群内五子场景横向滑动：跟手 `translateX` + 松手吸附 200ms ease-out；方向锁（垂直位移占优让位滚动）
- 进群动画：BottomTabs `translateY(0→100%)` 200ms ease-in → 群场景变体滑入；中央槽位「主页」文本交叉淡化为群头像（槽位宽 48→64px 弹性过渡，总时长 ≤300ms）；输入框 `translateY(100%→0)` 250ms ease-out 延迟 100ms
- 下拉回主页：跟手位移 + 阈值 80px，回弹 200ms ease-out
- 直播间上下滑切换：跟手 `translateY` + 上下一张 20% 预览露出，松手过半切换 250ms ease-out

### 12.13 增量场景 Agent Prompt 速查

- 「做底部五 tab：玻璃底 blur 18px 高 64px，语音/直播/帖子/桌游为 24px 线性图标 + 11px Fredoka，主页居中圆形背板 48px 上浮 8px 带 --glow-shadow，未读 --pink-500 徽标」
- 「做宽屏 TopNav：玻璃底高 64px，左头像 40px 带 --ring-online，一级模块 Nunito 700 15px，当前模块底部 2px #F796FF 指示条，右 240px 胶囊搜索框 focus 转 #F796FF」
- 「做服务器栏：72px 玻璃列，48px 群头像带光环，当前群左 3px #F796FF 指示条，角标 16px 圆底（未读 #F17EB3 / 直播 #F796FF / 语音 #9DBFE6 / 桌游 #F9B0FF）」
- 「做频道侧栏场景项：行高 40px 圆角 12px，左 20px 线性图标 + Nunito 600 15px，选中底 rgba(157,191,230,0.35)，右侧在麦人数 Space Grotesk 12px 或 LIVE #F17EB3 徽标」
- 「做直播间卡片：16:9 封面圆角 12px，左上 LIVE #F17EB3 白字胶囊，标题 Nunito 700 15px #465B92，来源 Micro Tag #F9B0FF 底 #722E88 字」
- 「做帖子卡：实心 --surface 圆角 16px，头像 36px 带光环 + Nunito 700 昵称 + Space Grotesk 12px 时间，正文 15px 超 3 行折叠，底排评论/收藏 18px 线性图标」

---

> 本文件是 `Ayla/web/` 视觉唯一事实源。新增组件先看 §4 / §12 有没有配方；没有就按 §2/§3/§5 的 token 与刻度推导，推导不出来再改本文件——不要在组件里散落裸 hex。
