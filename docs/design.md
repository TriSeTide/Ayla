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
| 模态 | `--glass-bg-strong` + 背景压暗 `rgba(70,91,146,0.25)`（`--overlay-dim`） |
| 沉浸查看器 | 图片查看器等 lightbox：压暗加深至 0.45（`--overlay-dim-strong`）+ blur(8px)，z 在弹窗层之上 |
| 辉光 | 只服务光环、主 CTA、focus |

## 7. Motion

- 时长：hover/焦点 150–200ms；面板进出 200–300ms；`ease-out` 进、`ease-in` 出（退出快于进入）
- 消息到达：气泡从下方 8px 浮入 + 淡入，180ms；不弹跳
- 光环呼吸是唯一常驻动画；其余装饰性循环动画禁止
- 骨架屏：所有 >300ms 的异步加载用 `animate-pulse` 风格骨架（玻璃质感骨架块），禁止白屏/冻结
- `prefers-reduced-motion`：关闭呼吸、浮入，保留透明度渐变

### 7.1 统一内容入场原语 `.reveal`

直播间/语音房/帖子详情/列表等所有异步界面的**主体内容浮入**统一用一套原语（复用，勿到处发明一次性动画）：

- **CSS**：`base.css` 新增 `.reveal`（初始 `opacity:0 + translateY(8px)`）与 `.reveal.is-in`（`opacity:1 + translateY(0)`，180ms `--ease-out` 过渡）；`prefers-reduced-motion` 下只保留透明度渐变。
- **样式元素**：`.reveal-item` 用于**列表/评论逐条浮现**（`animation: reveal-item-in 180ms forwards`，`--reveal-delay` 变量控制 stagger，封顶 300ms）。
- **Hook**：`useRevealOnEnter(active)` 返回 `{step, revealed}`，双 rAF 首帧隐藏→过渡显示。**内容由异步加载产生时，必须把 `active` 接到「内容就绪」信号（如 `!loading`），否则动画会在加载完成前就跑完、看不到浮入**。
- 语义边界：`.reveal` 只管**内容块自身**的浮入淡入；**底栏/输入框的位移**由 `useEnterRoomAnimation` / `useEnterGroupAnimation` 负责，两者不混淆、可叠加。

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
- 封面区：4:3，内嵌 8px，轮播图圆角 12px；无任何状态时回退群头像（居中 64px 带光环）
- 轮播：300ms 滑入切换，3s 间隔；**进视口才启动、离开暂停**（IntersectionObserver）；`prefers-reduced-motion` 降级为首帧静态。轮播指示点：底部居中 4px 圆点（当前 `--glow-500`，其余 `--ice-300`）
- 状态轮播卡（`useGroupCarouselSlides` 组装，实时 store）：
  - 消息+语音合卡（第一张）：渐变底居中多行——「N条新消息」（未读数，>0 显示）/ 每个「有人」语音房一行「N人在{房间名}连麦」（人数降序，最多 3 个房间）；两者至少其一才生成整张
  - 直播卡（每个在播直播间一张）：封面 + 左下角字幕「主播 在直播 标题」（重点「有人正在直播」）
  - 帖子卡（窗口内最新一帖一张）：帖图 + 左上角「有新帖」粉胶囊 + 左下角帖子标题 + 正文（覆盖在图上，白字 + 描边 text-stroke 保证可读；重点「有新」）；无图时图片区渐变占位、标题/正文仅左下角
  - 桌游卡：`SHOW_GAME_STATUS` 开关强制关闭（「是否有人在玩」判断未实现，保留实现勿删）
- 轮播背景禁用纯白：消息+语音卡与空态用冰蓝→樱花粉渐变，媒体卡无图 fallback 用渐变（design.md §8 气质）
- 轮播卡不再可点击跳动态；点卡片（轮播区或底部行）进入群聊主页（聊天页）
- 未读徽标：封面右上角 16px 圆底 `--pink-500` 数字（未读 > 0 显示）
- 卡片底部行：群头像 24px 带光环 + 群名 Nunito 700 15px `--text-primary` 一行省略
- 列表布局（GroupListItem）：行高 64px，玻璃底；左群头像 44px 带光环（右上/右/右下三位置状态角标），中群名 Nunito 700 15px + 新内容事件描述 13px 一行省略，右未读徽标 `--pink-500`
- 头像状态角标（`AvatarStatusBadges`，列表布局 + 宽屏 ServerRail 群头像）：直播/语音/桌游小标签在头像竖向一列，从下往上填——1 个右下角、2 个右下+右、3 个右上+右+右下；直播=「有人正在直播」、语音=「有人在语音房」（member_count>0）；桌游由开关关闭
- 宽屏 ServerRail：未读徽标在头像**左下角**（直播/语音角标占右下+右），置顶 pin 在左上角

### 12.6.1 群排序与"新内容"标识（M5 群活跃度）

> 主页群卡片 / 群列表 / 宽屏 ServerRail 共用 `components/home/groupActivity.ts`。三状态 store（live/voice/boardgame）由 ChatWS 实时推送维护 + 登录预加载，排序/角标/标识全部实时刷新，无需轮询。
> **排序按"新内容"（事件性），角标按"有内容"（存在性）——两者分开**（用户纠正：不是有直播 LIVE 就排前）。

- 排序（`useGroupActivityMap` + `sortGroupsByActivity`）：**置顶 > 有新内容排前（组内按最近事件时间新→旧）> 无新内容保持稳定**
- "新内容"判定（`NEW_CONTENT_WINDOW_MS` = 24h 窗口内事件）：新消息（最后一条消息 `last_message.created_at` 在窗口内，含自己的、不依赖已读）、新开播（直播 `started_at` 在窗口内）、新语音房被创建（`created_at` 在窗口内）、新桌游房被创建（`created_at` 在窗口内）、新帖子（`created_at` 在窗口内）；超出窗口的"在播/在房"不算新、不排前
- 「新消息」是**两套语义**（用户定稿）：排序用「有新消息」（窗口内最后一条消息，读了不清零、含自己的）；轮播「N条新消息」用未读数 `unread_count`（读了清零、不含自己）。两者分开，勿混用
- 头像状态角标（`useGroupPresenceMap`，存在性，与排序无关）：直播=群内当前有 status=live 直播；语音=群内有「有人」语音房（member_count>0）；桌游=有桌游房
- 列表布局"新内容"事件描述（`.group-list-sub.is-new` 粉色）：显示具体事件文本——「xx：消息内容 / xx 开播了 标题 / xx 创建了语音房 房名 / xx 创建了桌游房 房名 / xx 发了新帖 标题」，替代成员数预览；无新内容显示「N 人」
- 轮播实时刷新（后端 WS 事件 + 前端 store 订阅，无轮询）：新消息（`message.new` → unread）；有人进/出语音房与连麦人数变动（`voice.channel.member_count_changed` → patch voice store）；帖子编辑（`post.updated` → 拉详情 upsert）；直播间编辑封面/标题（`live.channel.updated` → 对账）；桌游房有人加入/离开/被踢/转让/编辑（`boardgame.room.updated` → 拉详情 upsert）

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
- 语音成员行的「行尾操作区」（`.voice-member-actions`，**所有成员行同一水平线、上下等距**）：开关按钮 + 音量条（自己麦克风与远端成员**同一样式** VoiceVolumeMeter，90px 行内对齐）。开关按钮 `.voice-meter-toggle`（28px 圆形无底，hover 浅冰底；`is-off` 禁音/静音态灰 + 斜线图标）——自己行 = 麦克风按钮（lucide mic/mic-off，一键禁音/一键恢复，媒体层 toggleMic）；远端行 = 喇叭按钮（lucide volume-2/volume-x，一键静音/一键恢复，本地播放 `locallyMuted`，不改变 volume 设定值）。
- 音量条（VoiceVolumeMeter）：**三层结构**（下→上）——
  1. 底层轨道 `.voice-meter-track`：**双色填充**（滑块左边 `--indigo-700` = 设定音量、右边 `rgba(ice-300,0.55)` 浅色；`--fill` 内联变量随设定值）→ "滑块左边始终有颜色"；
  2. 中层跳动条 `.voice-meter-fill`：`--glow-500 → --ice-500` 渐变、高 4px、圆角，宽度随实时说话音量左右伸缩跳动（静音 0、说话伸长，说话态加微辉光），**覆盖在轨道上方**；
  3. 上层 slider：轨道透明（不遮跳动条）+ `--indigo-700` 白边圆把手。
  - 自己条目：设定 = 本地麦克风音量 0~100（100 = 原始，改变自己说话别人听到的响度），跳动随 `localAudioLevel`（本地 Web Audio 分析）；本地偏好不落库、刷新重置。
  - 远端条目：设定 = 本地播放音量 0~100（本地偏好，不落库），跳动随**本地 Web Audio 分析远端轨道**（与本地同机制，100ms 轮询；不依赖 server speaker update，响应快）——说话即见跳动，可辨识"谁在说话"。

### 12.11 桌游室卡片

- 实心卡片 2 列网格；封面占位图（`--ice-100` 底 + 游戏线性图标 `--ice-500` 48px）圆角 12px + 房间名 Nunito 700 15px + 状态 tag（等待中 `--ice-300` 底 / 对局中 `--sakura-300` 底 `--grape-700` 字，Micro Tag 胶囊）+ 人数 Space Grotesk 12px

### 12.12 手势与场景动画（窄屏）

- 五 tab / 群内五子场景横向滑动：跟手 `translateX` + 松手吸附 200ms ease-out；方向锁（垂直位移占优让位滚动）
- 进群动画：底部导航条上移到视口顶部（`translateY(calc(100vh-64px)→0)` 250ms ease-out）→ 群场景变体滑入；中央槽位「主页」文本交叉淡化为群头像（槽位宽 48→64px 弹性过渡，总时长 ≤300ms）；输入框 `translateY(100%→0)` 250ms ease-out 延迟 100ms
- 进直播间/语音房/帖子详情动画（与进群方向相反，R-L2/R-V2/R-P3）：底部导航条下滑走（`translateY(0→100%)` 200ms ease-in）→ 房内输入框 `translateY(100%→0)` 250ms ease-out 延迟 100ms（先底栏下滑、再输入框升起）
- 下拉回主页：跟手位移 + 阈值 80px，回弹 200ms ease-out
- 直播间上下滑切换：跟手 `translateY` + 上下一张 20% 预览露出，松手过半切换 250ms ease-out

### 12.13 增量场景 Agent Prompt 速查

- 「做底部五 tab：玻璃底 blur 18px 高 64px，语音/直播/帖子/桌游为 24px 线性图标 + 11px Fredoka，主页居中圆形背板 48px 上浮 8px 带 --glow-shadow，未读 --pink-500 徽标」
- 「做宽屏 TopNav：玻璃底高 64px，左头像 40px 带 --ring-online，一级模块 Nunito 700 15px，当前模块底部 2px #F796FF 指示条，右 240px 胶囊搜索框 focus 转 #F796FF」
- 「做服务器栏：72px 玻璃列，48px 群头像带光环，当前群左 3px #F796FF 指示条，角标 16px 圆底（未读 #F17EB3 / 直播 #F796FF / 语音 #9DBFE6 / 桌游 #F9B0FF）」
- 「做频道侧栏场景项：行高 40px 圆角 12px，左 20px 线性图标 + Nunito 600 15px，选中底 rgba(157,191,230,0.35)，右侧在麦人数 Space Grotesk 12px 或 LIVE #F17EB3 徽标」
- 「做直播间卡片：16:9 封面圆角 12px，左上 LIVE #F17EB3 白字胶囊，标题 Nunito 700 15px #465B92，来源 Micro Tag #F9B0FF 底 #722E88 字」
- 「做帖子卡：实心 --surface 圆角 16px，头像 36px 带光环 + Nunito 700 昵称 + Space Grotesk 12px 时间，正文 15px 超 3 行折叠，底排评论/收藏 18px 线性图标」

### 12.14 会话列表项与会话管理菜单（M5 消息中心）

> 用于 /messages 与 /chat/:id 的会话列表（ConversationList）。在线状态双通道原则（§10）保持：光环 + 名字行文字标签。

- **名字行**：昵称 Nunito 700 15px `--text-primary`（一行省略）+ 紧随其后在线状态胶囊——`is-online` 时 `--success` 字 + 6px 圆点，离线 `--text-secondary`；底 `rgba(157,191,230,0.16)`，圆角 999px，11px/700，padding 1px 8px
- **预览行**：最新一条消息摘要 Nunito 400 13px `--text-secondary` 一行省略（替代原「在线/离线」文字）；群聊预览带 `发送者名: 内容`，媒体消息占位 `[图片]/[语音]/[文件]/[表情]`，已撤回 `[已撤回]`，无消息 `暂无消息`
- **⋯ 更多按钮**：行右侧绝对定位（`right:6px` 垂直居中），40×40px 圆形触达区（§10 ≥40px），三点线性 SVG 18px `#a9b8d4`；hover/展开态底 `rgba(157,191,230,0.25)`、图标转 `--text-primary`；行内 padding-right 52px 给按钮让位
- **弹出菜单**（`.conv-menu`）：绝对定位**向上展开**（`bottom: calc(100% - 2px)`，避免被列表滚动容器 `overflow-y:auto` 裁剪），右对齐；层级 `z-index: 60`——高于底栏/顶栏/侧栏（20–50），低于弹层遮罩（70+），保证不被固定栏遮挡；`--glass-bg-strong` + blur 18px + 圆角 14px + 1px `--glass-border` + `0 8px 24px rgba(70,91,146,0.16)`；菜单项行高 40px 圆角 10px Nunito 600 14px，hover 底 `rgba(157,191,230,0.22)`，危险项（删除）`--destructive` 字 + hover 底 `rgba(224,100,100,0.12)`
- **置顶会话视觉标识**（`.conv-item.is-pinned`）：左侧 3px `--glow-500` 圆角指示条（同 ServerRail 指示条语言，装饰不承载信息）+ 非选中态淡 sakura 粉底 `rgba(249,176,255,0.1)`（hover 0.16）+ 标题转 `--grape-700`（对比度 ≈6:1 达标）；选中态（active）背景保持 ice 蓝胶囊、标题仍 grape
- 置顶会话排列表最前（置顶组/非置顶组内保持原顺序）；删除为软删除（仅隐藏本人列表，消息保留），confirm 确认后执行

**消息中心红点实时刷新**（M5）：红点以 `GET /me/badges/` 聚合为权威，由 ChatWS 事件驱动 `fetch` 实时刷新（无轮询；AppShell 的 30s 轮询仅作断线降级）。三处红点统一：

- 消息入口聚合红点（宽屏 TopNav 消息项 / 窄屏左下 MessageFAB）= 私信未读 + 好友申请 + 群邀请 + 待审批入群申请，`--pink-500` 徽标，>99 显示 99+；
- 认证消息 tab 红点（窄屏 MessagesPage / 宽屏 WideMessagesSidebar）= 好友申请 + 群邀请 + 待审批入群申请（不含私信未读；私信未读属会话列表行内 `conv-unread` 徽标）；
- 会话行内未读徽标（ConversationList `conv-unread`）= 该会话 `unread_count`，实时由 `message.new` → bumpUnread 增量，打开会话标已读后清零。
- WS 事件 → 红点刷新：私信 `message.new` / `elysia.reply` → `private_unread`；`friend.request.new` / `friend.request.resolved` → `friend_requests`；`group.invite.new` → `group_invites`；`group.request.new` / `group.request.resolved` → `join_requests_pending`。好友申请事件（`friend.request.*`）由 accounts 视图经用户级组 `chat_user_<id>` 广播，ChatConsumer 转发；群未读不进消息中心红点（属群卡片/ServerRail 角标）。

### 12.15 红点快捷消息栏（R-QM，窄屏非导航页）

> 窄屏左下角「私信按钮」显示策略（需求 R-QM）：**打断式跳转 → 就地弹层**，减少对当前上下文（直播间/语音房/帖子详情/群聊等）的打断。

- **三态显示规则**（`AppShell` 读 `isPrimaryNavRoute`）：
  - 五个一级导航页（`/group` `/voice` `/live` `/posts` `/games`，含 `/home` 兼容）：常态显示 `MessageFAB`，点击跳 `/messages`；
  - `/messages` 页：左下角为「返回主页」`MessageFAB`（`backHome` 变体，历史需求保留）；
  - `/chat/:id` 私聊窗口：不渲染左下角按钮（底部有聊天输入框，壳层不出 chrome）；
  - **其余页面**（群聊场景 `/group/:id`、直播间、语音房、帖子详情、搜索、个人、收藏、用户页等）：**仅当红点 > 0** 时显示 `QuickMessageFAB`（无红点不显示）。
- **QuickMessageFAB**（复用 `.message-fab` 外观 + `.quick-message-fab` 修饰）：与 MessageFAB 同位置（`left:16px; bottom:底栏高+12px`，位置天然避让沉浸页底部输入框）；出现后 **4s 无点击 → 侧边半贴**（`translateX(-44px)`，仅露 28px 右半，200ms `--ease-out`），半贴态点击「点出来」展开，展开态点击**就地弹出快捷消息栏**（不跳路由）；`prefers-reduced-motion` 关闭位移过渡。
- **快捷消息栏**（`.quick-messages-overlay`，`z-index:70`）：底部滑入 **70% 高度**面板（`translateY(100%→0)` 250ms `--ease-out`）+ 上方 **30% 遮罩**（`rgba(70,91,146,0.25)`，点击关闭）；面板 `--glass-bg-strong` + blur 18px + 上沿圆角 24px；ESC 关闭。**开关存 shell store（`quickMessagesOpen`），由 AppShell 独立渲染，只随手动关闭（遮罩/ESC/关闭钮）卸载——打开会话标已读导致红点归零时，QuickMessageFAB 会卸载，但快捷栏保持打开（R-QM 修复）**。
- **两个选项卡**（复用 `.messages-tab`）：私信 / 认证消息。栏内**所有操作不跳转新页面、头像一律不可点**（`disableAvatarNav`）：
  - 私信 tab：爱莉入口 + 会话列表（`ConversationList`），点会话**内联**打开 `PrivateChatPane`（不跳 `/chat/:id`），返回按钮回到列表；
  - 认证消息 tab：与 `/messages` 认证消息 tab 同构（退群通知 / 好友申请 / 群邀请 / 入群申请 + 同意/拒绝），实时刷新同 §12.14。

### 12.16 图文混排消息与乐观发送（M7）

> 聊天消息发送重构：发送不阻塞输入（乐观气泡 + 左上角状态）；图片/视频多选进输入区缩略图条，点发送统一上传；支持粘贴；混排气泡文本与媒体段流式排列；查看器支持同消息多图/视频切换。会话列表/引用/群活跃度的混排摘要由后端 `preview` 统一生成（「文本文本[视频]文本[图片]」形态）。

- **输入区缩略图条**（`.composer-picked`，`role=group aria-label=待发送媒体`）：输入框上方横向 flex wrap，`gap 8px`；缩略 44×44px（视频 58px 宽）`--radius-sm` 圆角 + 1px `--glass-border` + `--glass-bg` 底，`object-fit: cover` 预览本地 objectURL（**未上传**）；视频叠加 18px 玻璃播放徽标；右上 `-5px` 处 18px 圆形移除钮（hover 转 `--destructive` 白字）。**小尺寸不挤压输入框**；移除即 revoke objectURL。
- **混排气泡**（`.mixed-flow`）：flex wrap + `gap 8px`；文本段 `.mixed-text` 流式排列（`max-width:100%`，`white-space:pre-wrap`）；媒体段 `.mixed-img` 180×180px 方块（`--radius-input` 圆角、`cover` 裁剪、`cursor:zoom-in`）多图自动换行成网格；视频段复用 `.media-frame-video` 首帧+播放徽标（240px 宽 4:3）。乐观消息（未上传）媒体段用本地 objectURL 渲染，无 descriptor 不报错。
- **乐观发送状态**（`.msg-send-state`，仅自己的气泡）：与气泡同一行、位于气泡左侧垂直居中（`position:absolute; right:calc(100%+8px); top:50%` 反向偏移）——上传中显示 `.msg-send-progress`「上传中 n%」（`--text-secondary` 12px）+ 玻璃小按钮「取消」；纯文本发送中为 14px indigo 旋转 spinner（`prefers-reduced-motion` 停止旋转）；失败态 `--destructive`「发送失败」+ 玻璃小按钮「重试/删除」（复用 `.msg-action-btn`，11px 图标+文字，hover `--glow-shadow`）。重试复用同一幂等键重新上传发送。
- **查看器多图切换**（`ImageViewer`）：同消息的 image/video 段合成条目列表，`←/→` 键或左右玻璃圆形 nav 钮（44px，`--glass-bg-strong` blur 12px，`top:50%` 垂直居中，disabled 时 opacity 0.35）切换；底部玻璃胶囊加计数 `1/2`（`--font-utility` 12px `--text-secondary`）；对话框 `aria-label="图片查看：n/总数"`（单图为 `图片查看：<alt>`）。本地乐观预览（未上传）只展示、保存钮显示「发送后可保存」。
- **会话列表/引用/活跃度摘要**：混排消息按段生成占位（text 拼原文、image→`[图片]`、video→`[视频]`），与单媒体 `[图片]` 占位及撤回 `[已撤回]` 共用同一预览语义；后端 `last_message.preview` 为权威，WS `message.new` 后前端按 segments 兜底生成。

### 12.17 大文件流式上传与取消（M7.1）

> 上传链路对齐 QQ/微信语义「临时存储 + 进度条 + 可取消」：文件先传服务端临时存储（三步上传会话），传完才真正发消息；全程有进度、可中止；大文件不整块驻留内存。

- **流式写入（防 OOM 卡死）**：后端 `PUT /media/uploads/{id}` 改为 `request.stream` 按 1 MiB 分块读入临时文件（边读边校验累计大小，超限立即 413 中断），再经 `ObjectStorage.put_stream`（S3 `upload_fileobj` 分块上传）落对象存储——1GB+ 文件不再整体读入内存（旧实现 `request.body` 整块 bytes 曾导致进程 OOM、页面报错）。
- **进度与取消**：前端二进制段改 XHR（`upload.onprogress` 实时字节进度；fetch 无上传进度）；`AbortSignal` 中断 → `xhr.abort()` 并 fire-and-forget 调幂等 `DELETE /media/uploads/{id}` 清理临时对象与会话（非本人 403，重复调用 204）。多文件并发上传时按真实字节数聚合为单一百分比（封顶 99%，保留 100 给发送阶段）写入 store，气泡左侧显示进度与取消钮。
- **本地预览生命周期**：乐观气泡的 objectURL 由渲染组件在卸载时统一 revoke（`useEffect` 空 deps cleanup）；发送/重试成功路径**不提前 revoke**（避免替换渲染前的竞态空白图）；重试因旧气泡卸载 revoke 而重新 `createObjectURL`。
- **取消语义**：取消 = 放弃该次发送（abort 上传 + 删除乐观气泡 + 服务端清理），与失败态（保留气泡可重试/删除）区分。

### 12.18 预签名直传与播放直连（M7.2，数据面旁路应用服务器）

> 大文件上传/播放的字节流**完全不再经过 Django 数据面**。背景：runserver 被 daphne 接管后走 ASGI，`ASGIHandler.read_body()` 会把整个请求体先读进内存才开始执行视图——3GB 视频经 Django 上传时进程内存暴涨 3GB+，Windows 动态建 C 盘临时页文件承接（表现为 C 盘两段式掉空间又恢复）；且 Channels 同步视图 thread_sensitive 串行执行，complete 占线程期间所有请求（含首帧加载）排队。根治 = QQ/微信同款架构：应用服务器只做信令与鉴权决策，字节流浏览器与对象存储点对点。

- **预签名直传上传**：`POST /media/uploads`（建会话）响应新增 `presigned_url`——`generate_presigned_url("put_object")` 签发的临时对象 PUT 地址（TTL ≥ 600s）。前端 XHR 直打该 URL（进度/取消语义不变），`:complete` 改轻校验：`stat` 对齐 expected_size → Range 读头部 64B 魔数嗅探（保留安全校验）→ ETag(MD5) 作 content_hash → `copy_object` 服务端复制落正式 key → 删 tmp。旧 `PUT /media/uploads/{id}` 端点保留兼容（流式写 MEDIA_TMP_DIR 临时文件再 put_stream），前端默认不走。
  - 坑：`generate_presigned_url` 的 Params 混入 ACL 等 extra args 会把对应头纳入签名，直传请求必须原样携带否则 S3 报 "headers not signed"；直连请求也绝不可附加 Authorization 头（同理 400）。content_hash 契约由 sha256 更新为 ETag MD5 内容指纹（用途=内容寻址去重；完整性强校验由客户端负责）。
- **播放直连**：`POST /media/{id}:sign` 返回对象存储 `presign_get` URL（TTL 600s，签发前完成 can_access_media 鉴权）。`<img>/<video>` 直连拉流，Range 请求（preload=metadata 的 `bytes=0-`、拖动 seek、moov 尾部探测的 `-suffix`）由对象存储原生处理——播放流量不占用 Django/Channels 的同步视图串行队列。
  - content 端点保留双通道鉴权（Bearer 登录 or 签名票据）与流式 Range 转发（`open_range_stream` 支持 start-end/start-/-suffix 三形态分块转发，任意大文件任意区间不整体进内存），作为兼容通道。
  - dev 环境 presigned URL 经 Vite `/minio` 同源代理（rewrite 剥前缀 + changeOrigin），规避跨源与 Private Network Access 策略差异；生产经反代同理（host 可用 MINIO_PUBLIC_ENDPOINT 覆盖，待实现）。
- **查看器 Portal**：ImageViewer 以 `createPortal(document.body)` 挂载——消息气泡的 backdrop-filter（毛玻璃）会创建 containing block，把 position:fixed 的查看器困在气泡内。
- **临时文件位置**：兼容通道的服务端中转临时文件走 `MEDIA_TMP_DIR`（默认 `backend/runtime/media_tmp`，数据盘），禁止回落系统 Temp。
- **已知限制**：mp4 moov 尾置时首帧需几次 Range 往返（每次 ~0.15s）；极致优化可后续加 ffmpeg faststart 转封装或服务端海报帧派生（未做）。

---

> 本文件是 `Ayla/web/` 视觉唯一事实源。新增组件先看 §4 / §12 有没有配方；没有就按 §2/§3/§5 的 token 与刻度推导，推导不出来再改本文件——不要在组件里散落裸 hex。
