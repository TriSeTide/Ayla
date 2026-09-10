# Ayla Web 前端设计方案 ——「千禧冰樱 / Y2K Frost」

> 文档状态：设计规范 v3（保留千禧冰樱配色，卡片、侧栏、按钮与切换采用 Auroraqua 材质/交互配方）
> 适用范围：`Ayla/web/`（React 18 + Vite + TS + Zustand），聊天 / 语音 / 直播 / 桌游 / 爱莉集成 / 主页 / 消息 / 搜索 / 个人界面
> 参考来源：现有 Y2K Frost 色板、字体与主体身份设计；Auroraqua-UI 实际源码提供材料和交互结构。适配范围和固定源码版本见下文。
> 结构约定：与 `miro_design.md` 同构，方便对照查阅与 agent 直接消费

---

## 0. Auroraqua 源码适配边界

用户要求保留本系统配色，学习 Auroraqua 的卡片、侧栏、按钮、选项卡和动效。**所有既有颜色 token、背景渐变、流体背景、字体、消息气泡和在线光环保持原值**。材料阴影使用 Ayla 的 indigo `70,91,146`；选中胶囊使用既有 ice `157,191,230`；按钮分别保留 indigo、sakura、grape 和 destructive 语义。截图只是参考，不能从截图推断上游实现。

固定参考版本：[Auroraqua-UI `087bffc51b3c83b6214c2b3cec5c9899aaed6b2e`](https://github.com/micromimo/Auroraqua-UI/tree/087bffc51b3c83b6214c2b3cec5c9899aaed6b2e)。已读取 `src/index.css`、`GlassCard.jsx`、`GlassButton.jsx`、`TiltCard.jsx`、`PillTabBar.jsx`、`animations.jsx`、`routes.jsx`、`Case3.jsx`、`Case3Sidebar.jsx` 和 `SidebarNavItem.jsx`。

- 普通 `GlassCard` = `liquid-glass` + 16px 圆角 + 300ms 过渡，默认不抬升、不做 3D。可交互列表卡选择上游独立的 `.glass-hover`：上浮 2px、阴影 12/40；不把 TiltCard 的跟随旋转施加到文本、输入、视频或拖拽容器。
- `.liquid-glass` = blur 24px、宽软阴影 8/32、1px 高光边与顶沿内高光。Ayla 保留原有白底 .55/.78、边框 .65、saturate(1.4)，不引入上游白底 .15、靛紫和粉桃色。
- `GlassButton` = 200ms hover 1.02 / press .98、600ms 横向白光扫过；`PillTabBar` = 单一选中胶囊 300ms 滑动；`SidebarNavItem` 与 `PillTabBar` 的选中项均有 700ms 扫光。实现扫光使用 transform，不复制上游 left 逐帧更新。
- CSS 材料变量在 `tokens.css`；页面材料在各自 CSS；共用 hover/press/扫光、导航高亮和侧栏进入在 `auroraqua.css`；React 切换参数在 `components/motion/auroraquaMotion.ts`。继续使用现有 React/CSS/Framer Motion 栈。

## 1. Visual Theme & Atmosphere

Ayla 是爱莉在 Web 端的「具身家园」。视觉主题定为 **「千禧冰樱（Y2K Frost）」**：冰蓝到樱花粉的极光渐变打底，磨砂半透明玻璃卡片漂浮其上，关键交互与爱莉身份用 hot pink 辉光点亮——千禧年的科技乐观主义，但执行是安静、轻盈、有呼吸感的，不是喧闹的蒸汽波。

**一句话气质**：像 2003 年想象里的未来聊天软件，被 2026 年的工艺重新做了一遍。

**Key Characteristics:**
- 全局流体极光渐变背景（冰蓝 `#BDD4E9` ↔ 樱粉 `#FCD8FF`），缓慢流动，内容在其上滚动（见 §7.2）
- Auroraqua 磨砂玻璃卡片：原有半透暖白底 + 24px blur + 1px 高光描边 + 宽软外阴影与顶沿内高光
- Hot pink 辉光（`#F796FF`）只给三类东西：爱莉身份、主 CTA、在线状态
- 圆润几何：大圆角（12–28px）、气泡形、胶囊形，无尖锐直角
- 深靛蓝（`#465B92`）承担全部正文与主要交互，保证可读性不被粉色系拖垮
- 动效分层：按钮200ms、交互卡片/切换/页面分区300ms、普通页面缩放显现与未分区侧栏进入500ms；常驻环境动画仍为辉光呼吸 + 流体极光背景（§7.2）

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
| `--surface` | `#FFFAFB` | 暖白，不支持玻璃的降级表面；正常文本输入使用`--glass-bg` |

### Functional（派生）

| Token | 值 | 用途 |
|---|---|---|
| `--bg-aurora` | `linear-gradient(var(--fluid-gradient-angle), #BDD4E9 0%, #ECF0F2 50%, #FCD8FF 100%)` | 全局背景（流体渐变，见 §7.2），fixed |
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

- **Primary**：保留 `--indigo-700` 实底和原白字，14px/700，12px 圆角；静态紧凑玻璃阴影，hover 保留品牌辉光。
- **Glow CTA**：保留 sakura→glow 渐变、grape 文字和既有身份/CTA 辉光。
- **Ghost**：已有 `--glass-bg` + `--glass-border` + blur(8px) + `--glass-shadow-button`（2/8 阴影）；hover 沿用 ice 底并升到 `--glass-shadow-button-hover`（4/16 阴影）。
- 三类按钮、图标按钮、输入工具、收藏、播放器控制按钮共用 `200ms ease`，精细指针 hover `scale(1.02)`、按下 `scale(.98)`；使用独立 scale 属性，避免覆盖原有定位 transform。危险操作、disabled/aria-disabled、媒体 overlay 底色保持原语义。
- 自包含按钮使用 600ms 横向高光扫过，选中导航使用 700ms；伪元素 `pointer-events:none`，不能覆盖文字、截断徽标或阻断点击。
- 最小高度 40px（触屏推荐 44px）；`prefers-reduced-motion` 禁用缩放和扫光，保留焦点/状态反馈。

### Cards / Panels

- 通用 `.glass-card` 与兼容类 `.solid-card` 统一使用 `--glass-bg` + `--glass-filter` + 完整 `1px --glass-border` + 16px `--radius-card` + `--glass-shadow`。旧 `.solid-card` 类名保留以兼容现有页面，不再代表不透明卡面。
- `--glass-shadow` = `0 8px 32px rgba(70,91,146,.2), var(--glass-inset)`；可交互卡片 hover 为 `0 12px 40px rgba(70,91,146,.2)` 与同一内高光，上浮 2px、300ms ease；按下缩放 .99。
- 密集小行卡使用 `--glass-shadow-compact`（4/16 阴影）；菜单用常规玻璃阴影；弹窗使用 `--glass-bg-strong`、20px `--radius-panel`、`--glass-shadow-modal`（20/60 阴影）；认证页卡片改用普通玻璃 `--glass-bg` 并沿用 20px 面板圆角与 modal 阴影（见 §5 登录与注册）。所有 RGB 来自原系统。
- 原“禁止重投影、仅靠实心/玻璃区分深度”规范已被本次需求替换：宽软阴影与顶沿高光是新的共同材料。同一视觉卡片只保留一个材料owner，内部布局块不得再叠玻璃底、blur与整块阴影；多张独立卡片的集合wrapper应透明。交互字段和独立浮层仍各自保留材料与状态，不能用`.glass .glass`泛选择器清除所有后代。
- 已核对的单层组合：宽屏语音成员卡保留外卡、内`.voice-panel`透明；宽屏语音聊天卡的header/composer为透明布局并保留分隔边；直播aside内`.live-room-input > .danmaku-input-area`透明，窄屏普通观看独立input自己持有材料；自/他人`.profile-mine.solid-card`保留外卡，内部`.profile-section-row`无玻璃/blur/阴影，hover保留ice反馈。窄屏语音成员panel与展开聊天浮层保持各自独立材料；收藏、群信息各分卡、帖子正文卡已是单层，不改其背景。
- 开播控制台`/live/start/:channelId`必须按`showOwnerPanel`的真实分支单独验收：`.live-owner-panel`与`.live-studio-stream`各是一张.55/16px/完整玻璃阴影与blur24卡，内部`.live-owner-visibility`保持透明布局和分隔边，推流值保持只读`code`语义。窄屏`.live-room-body.is-studio.is-narrow > .live-room-side`及其弹幕wrap明确无背景/blur/卡片阴影；240px高度、整页滚动、内部输入与原开播/保存/复制权限逻辑保持。
- 769–1100px开播控制台保留频道栏，右侧主区与弹幕上下排列，分别保留原滚动；资料栏再按`.live-studio-owner-panel`的实际宽度响应，容器≤560px时字段上下排列，开播/保存按钮另起横排。不能让固定三栏把表单压成竖排或让200px标题覆盖按钮；≤768px仍使用原窄屏资料栏布局。
- 仅可交互列表卡抬升；资料卡、静态信息板和正在阅读的帖子详情保留稳定位置。滚动恢复时不重播入场，减少动态效果时不抬升/按压缩放。

### Inputs
- 文本字段使用`--glass-bg`（rgba(255,250,251,.55)）、`1px solid --glass-border`（白色.65）、12px圆角、`--glass-inset`顶沿与`--glass-filter`（blur24px/saturate1.4）；普通field保留12px/16px内边距，其他单/多行控件保持原尺寸。不能混用不透明surface、.78强玻璃或白色常量造成输入框明暗不一。
- focus：边框转 `#F796FF` + `--glow-shadow`，200ms 过渡
- 错误：边框 `--destructive`，错误文案紧贴字段下方（不放顶部汇总）
- **宽屏聊天输入外壳**：群聊/私聊`.composer`与帖子`.post-detail-composer`在>768px使用12px外沿、8px内边距、完整16px圆角和亮边、`--glass-bg` + `--glass-filter` + `--glass-shadow`。语音`.voice-room-composer`与直播aside内`.danmaku-input-area`保留相同布局间距，但由父房间卡片持有唯一材料，内部外框透明、不再叠完整卡片阴影，保留分隔边。相邻侧栏已贡献右侧12px时，群聊/私聊输入及私聊标题不再叠加左外边距；侧栏到输入外沿共享间隔为12px。
- 宽屏私信外壳不在卡片边缘裁剪：`.wide-messages-pane .private-chat`使用`overflow:visible`，实际消息滚动/裁剪由`.message-scroll`持有；标题、输入及其动画wrapper保留阴影溢出空间。不能用抬高z-index绕过祖先overflow裁剪，也不能补第二份左padding把12px间隔扩成24px。
- **输入行高度**：`.composer-input` 与 contentEditable 使用 22px 行高、上下 8px 内边距、1px 边框，单行 40px；发送与工具按钮同为 40px，宽屏普通空输入外壳为 58px。编辑器只设 `min-height:40px` / `max-height:140px`，真实多行内容自然增高；空 placeholder 单行省略且绝对定位，不得参与高度计算。769–900px 的窄桌面把工具组放在输入行下方，给字段保留可输入宽度，不能靠压扁按钮或把空占位文字折成竖列腾空间。
- **独立工具行**：窄屏与769–900px换行后的工具组使用等宽网格，占满整行；按当前功能数量自动分为群聊4格、私聊3格，格间8px、按钮高40px。发送按钮留在输入行。所有断点的工具按钮共用12px圆角、原玻璃底/高光边、compact阴影与hover/press，录音停止等功能状态继续保持原有状态色。
- 所有宽窄屏文本输入由同一材料规则覆盖`.field`（含contenteditable）、`.voice-create-input`、`.live-create-input`、`.danmaku-input`以及复合外框`.top-nav-search`、`.narrow-topbar-search`、`.live-player-fs-input`。搜索和全屏弹幕的原生input保持透明，材料与focus由外框持有一次；全屏弹幕文字改用原`--text-primary`配合浅玻璃底，placeholder共用`--slate-500`。窄屏语音聊天卡、独立直播input与帖子详情composer父底也为.55，避免额外强白底。工具按钮仍12px玻璃钮，focus/disabled/密码类型、禁言/上传/取消提示和媒体预览语义保持，底部定位与safe-area不变。

### Chat Bubbles
- 自己：`--bubble-self` 渐变底 + `--indigo-700` 字，圆角 18px（右下 6px 小角）
- 爱莉：`--bubble-elysia` 渐变底 + `--grape-700` 字 + 1px `rgba(247,150,255,0.5)` 描边，圆角 18px（左下 6px）——**爱莉的气泡全应用唯一，不可复用于其他用户**
- 其他人：`--bubble-other` 玻璃底 + indigo 字
- 引用回复：左侧 3px `#9DBFE6` 竖条 + 弱化一层透明度

### Nav / Sidebar
- 会话、群、语音、直播侧栏：原 `--glass-bg` + `--glass-filter` + 四向高光边框 + 16px 圆角 + `--glass-shadow`，外沿留 12px，形成独立悬浮面板；保持各自宽度、滚动 owner、sticky 和 Portal 边界。选中项使用原 ice 色系渐变胶囊 `--nav-active-bg`、顶沿高光与同色柔光，300ms 共享指示器移动；选中项 hover 有 700ms 扫光。
- 图标：SVG（Lucide 风格线性图标），**禁止 emoji 当图标**；emoji 只出现在消息内容与表情包
- 窄屏底部主导航 `.bottom-tabs` 与群场景顶部导航 `.group-top-tabs` 保持方角，顶部五个装饰指示点已移除；其他玻璃卡片、输入和按钮继续使用各自圆角。
- 窄屏子群栏以稳定 `.group-chat-compose-area` 为锚点，绝对定位在输入框上方，不消耗消息列表高度。开合把手贴输入框上沿左侧、略超出输入框左边缘（`left:-8px`）：收起态为透明48×32px命中区、视觉仅36×18px无边框上半圆；同一个按钮DOM保住焦点。展开时把手向上移动（位移复用子群面板 disclosure 动画节奏，300ms、reduced-motion为0ms）变为32×32px圆形玻璃按钮，与子群胶囊行垂直居中；展开的panel与把手同行、位于把手右侧（`left:40px`），右侧延伸到屏幕最右（`right:-12px`，超出 compose-area 右边缘），选项卡容器与选中胶囊均无边框，直接覆盖在消息区上方；透明空白不拦截消息操作。展开层负责300ms height/opacity（reduced-motion为0ms），收起时同时 `aria-hidden`、禁用按钮并移出tab顺序；选项卡横向滚动独占手势，不触发场景切换。
- 宽窄屏切换子群时，当前实际`.message-list`执行右20px→0与淡入的300ms内容过渡；仅变更导航胶囊不足以表达消息内容切换。默认子群首次建立只登记选择基线，初入由父面板统一持有，不能父子重复进入；后续真实选择变化时，缓存命中立即进入，无缓存等待当前选择对应的请求完成标记。选择revision区分重复进入同一子群，旧请求不能提前触发新选择。输入使用原`.composer`先向下退出300ms、再从下20px进入300ms；不添加key或重挂编辑器，保留焦点，快速切换取消旧动画。草稿按「会话+子群」隔离（`convId:subgroupId`），每个子群保留独立草稿，切换互不覆盖，发送只清当前子群草稿；私聊保持会话级草稿。外层`.group-chat-compose-area`仍只拥有原面板初入，子群条不随消息移动，减少动态直接展示。
- 窄/宽屏右上角更多入口分别是 `.narrow-topbar-more > .icon-btn-40` 和 `.top-nav-more > .top-nav-icon-btn`，共用12px圆角玻璃按钮、200ms hover/press与600ms扫光；菜单均为300ms顶部淡入/轻移，reduced-motion时关闭位移、缩放和扫光。菜单项与既有返回/收藏/登出行为保持。

### Tags / Badges
- 胶囊形，`--sakura-300` 底 + `--grape-700` 字（如参考图里的 hot pink 标签），11px Fredoka
- 未读徽标：`--pink-500` 实底白字小圆点

### Switch / Toggle 胶囊开关
- 结构优先使用原生 checkbox 或 `button[role="switch"]`；外层保留 ≥44px 触达高度，视觉轨道为 44×24px 胶囊，滑块为 18px 圆形。
- 未选中轨道使用 `--ice-300`，选中轨道使用 `--pink-500`，滑块使用 `--surface`；轨道可叠加 `--glass-border` 与 `--glass-inset`，状态切换使用 `--dur-fast` + `--ease-out`。
- 必须同步暴露 `aria-checked`/原生 checked 状态；键盘 focus 使用 `--focus-ring`，不能只靠颜色表达开关状态。

### CornerFabStack 右下浮层按钮组
- 仅桌面宽屏（`>768px`）启用，位于 CreateFAB 上方；自下而上为 CreateFAB（56px）→ RefreshFAB（44px）→ ScrollTopFab（44px），次级按钮间距 `--sp-3`，三个按钮水平中心对齐。
- RefreshFAB 与 ScrollTopFab 使用 44px 玻璃圆钮：`--glass-bg` + blur(18px) + `--glass-border` + `--card-shadow`，次级按钮不追加辉光；回顶按钮仅在主滚动容器超过一屏后出现，刷新按钮复用当前页面刷新回调。
- 按场景白名单渲染：列表页可同时显示刷新与回顶，消息中心刷新按钮可放左下；群聊正文、群内直播与非列表详情不渲染。出现/消失遵循 §7 的 200ms 浮入淡出，`prefers-reduced-motion` 关闭位移。

### 群内场景标题栏 `.group-scene-head`
- 语音、帖子、桌游三个可滚动群内子场景共用；标题栏是滚动容器的直接子元素，`position: sticky; top: 0; z-index: 10`，最小高 72px，padding `--sp-4`，标题与尾部动作 gap `--sp-3`。
- 标题栏是独立玻璃卡片而非拉伸横条：`--glass-bg` + `--glass-filter` + `--glass-border` + 16px 圆角 + `--glass-shadow-compact`；滚动容器提供四向 gutter 与 `--sp-4` 内容间距，禁止负 margin 破坏圆角和焦点可见性。
- 标题使用 `--font-display` 18px/500、说明使用 14px/`--text-secondary` 单行省略；尾部控件保持 ≥40px 触达，滚动容器设置对应 `scroll-padding-top`。

### 聊天「回到底部」按钮
- `.message-jump-bottom` 挂在聊天滚动容器内，不与全局 FAB 竞争层级；44px 玻璃圆钮、纯线性 SVG 图标，右下保留 `--sp-6` 间距。
- 仅当用户离开实时底部跟随位置时显示；点击回到底部并恢复实时跟随。按钮必须有 `aria-label`/`title`，隐藏态不可聚焦且不拦截底层点击。
- 出现/消失使用 opacity + translateY 的 200ms ease-out；`prefers-reduced-motion` 只保留透明度过渡。

## 5. Layout Principles

### 登录与注册

- `/login`、`/register`共用`auth.css`，认证专属样式不再散落在`app.css`。页面背景沿用全局极光；认证卡是唯一材料 owner，标题与表单透明、内部不再叠卡片材料。
- 卡片材质用普通玻璃 `--glass-bg`（0.55）+ `--glass-filter` + 20px `--radius-panel` + `--glass-shadow-modal`，透出极光与光斑；不使用 `--glass-bg-strong`（0.78 在浅色极光上视觉近乎不透明）。认证卡内 `.field` 的 `--glass-border` 白边在浅玻璃上不可见，统一覆写为 `rgba(70,91,146,0.3)` 描边，focus 仍为辉光边。
- **宽屏（>768px）左右分栏**：`.auth-page` 横排、两栏间距 `clamp(48px,6vw,96px)`；左栏 `.auth-intro` 品牌区（H1「Ayla」56px Fredoka 渐变字 + 22px 副题「爱莉的家」+ 15px 一句简介 `--text-secondary`；≥1024px 追加三枚特性胶囊，`--sakura-300` 底 / `--grape-700` 字），右栏 440px 玻璃表单卡，卡内标题降为 26px 分区标题层级，品牌主视觉让给左栏。左栏 `position: sticky; top: 50dvh; translate: 0 -50%` 钉在视口垂直中点，表单区滚动时品牌区保持原位；品牌字 `line-height ≥1.25`（Fredoka 圆体字形绘制区超出 1.1 行盒，`background-clip: text` 会裁掉超出盒外的字形——如 y 的底部变透明——行高不足时字号越大越明显）。
- **窄屏（≤768px）**：`.auth-intro` 隐藏，退回 440px 居中单卡，卡内品牌 40px。
- 卡片默认32px内沿与24px区块间距；≤480px或高度≤700px时卡片内沿24px、页面外沿16px并计入安全区。卡片可自然长高，页面统一滚动；短屏不能因居中裁掉表单头部或底部入口。
- 字段与主操作至少44px高，输入使用统一`.field`，主提交保持原`btn-glow`，登录/注册互跳使用ghost按钮。错误保留可读正文和alert语义，注册字段校验使用`aria-invalid`与错误说明关联；请求期间显示真实pending状态，认证接口和校验规则保持原契约。

### 页面与内容轨道

- 间距刻度：4 / 8 / 12 / 16 / 24 / 32 / 48（聊天密度场景以 8/12/16 为主）
- 圆角刻度：8（小件）/ 12（按钮、输入、导航项）/ 16（卡片、侧栏）/ 20（弹窗面板）/ 24（贴底抽屉上沿）/ 999（胶囊、头像）
- 主布局：左侧栏（玻璃，280–320px）+ 主内容区（透明，透出极光背景）+ 按需右栏
- 普通内容流最大宽度 1200px；带页面筛选侧栏的搜索/收藏及个人两栏页填满可用内容区，不叠加居中限宽制造大块空白。聊天页不设限宽，气泡列最大 960px 居中（宽屏加宽，减少两侧留白；窄屏由滚动区内边距自然收缩）
- 网格：12 列，24px gutter；卡片间距 ≥16px
- 个人页与公开的他人页在>768px使用同一两栏布局：顶栏横跨，左侧资料/设置，右侧本人或公开内容；页面是唯一纵向滚动容器，`.profile-side`/`.profile-main` 保持自然高度和正常命中。鼠标位于任一列时均滚动整页，不使用透明负边距重叠区或嵌套滚动。无公开内容、加载或错误分支回到居中单列，不渲染空右栏；窄屏wrapper为 `display:contents` 保持原顺序与间距。
- 个人页左栏280–340px、两栏卡片净间隔16px、页面外沿24px，主体两栏不设1200px上限。宽屏资料卡内沿与卡内间距收为16px，表单字段间距12px；长表单通过整页滚动全部可达，不为了固定左栏裁掉内容。
- 全局OverlayScrollbar的fixed thumb必须与实际滚动owner一同结束：DOM移除批次只回收已断开owner及其thumb、timer、hover/active与drag状态，同批移动后仍连接的owner保留。隐藏thumb为`pointer-events:none`，可见或拖动期间继续可命中；全局卸载先断开观察器，再逐owner清理，不能让旧页透明滚动条覆盖新页卡片。
- 群详情由`.group-info`统一滚动，页面左右/顶部24px、底部32px留白容纳阴影；两列内不再各加24px留白，卡片净间距16px。左轨道为 `clamp(280px,32%,340px)`，两列自然高度，鼠标落在资料、管理、子群或成员区时都推进同一页面。769–1000px因额外两条导航栏挤占内容宽度，详情退为连续单列；≤768px维持窄屏原顺序。长管理区和表单不得截断。
- 群详情成员区按右列实际可用宽度响应：≤420px时成员操作换到下一行并保持可见，昵称与状态保留独立空间；不按整个浏览器宽度猜测右列空间，也不改变成员操作权限。

## 6. Depth & Elevation —— 签名元素

**签名：「在线光环」（Presence Halo）**。爱莉与在线用户的头像外圈是一圈 2.5px 的 `--ring-online` 锥形渐变环，爱莉的光环额外带 8px `--glow-shadow` 呼吸（opacity 0.5↔0.9，3.2s ease-in-out）。离线则光环褪为 `--ice-100` 灰环。这是「数字生命在线」的唯一视觉语言，全应用一致，也是这个设计被记住的那一笔。

其余层级：

| 层级 | 表达 |
|---|---|
| 背景 | 固定极光渐变（z 最低，不动） |
| 内容 | 16px 玻璃卡片 + 8/32 宽软阴影 + 顶沿内高光 |
| 浮层 | 强玻璃面板 + 24px blur + 20/60 阴影 |
| 模态 | `--glass-bg-strong` + 背景压暗 `rgba(70,91,146,0.25)`（`--overlay-dim`） |
| 沉浸查看器 | 图片查看器等 lightbox：压暗加深至 0.45（`--overlay-dim-strong`）+ blur(8px)，z 在弹窗层之上 |
| 辉光 | 原有光环、主 CTA、focus；导航选中态增加同色柔光，保持状态颜色语义 |

## 7. Motion

- 时长：按钮200ms ease；卡片hover 300ms ease；方向路由300ms easeInOut；普通页面显现与未分区侧栏500ms easeOut；宽窄屏分区、导航胶囊与折叠300ms easeOut。参数来自§0源码，独立放在Auroraqua命名变量中，不改既有手势/消息/背景动画token。
- **framer-motion 使用纪律**：只接管 CSS 难以可靠完成的三类能力——① 跟手（motion value 逐帧驱动拖拽/下拉/侧滑）；② 进出协同（`AnimatePresence` 管理旧内容退出与新内容进入）；③ 编排（多层导航、场景内容、输入框的时间线）。既有 CSS keyframes（如 `frost-rise`、`halo-breathe`、`reveal-item-in`）全部保留，不为同一语义建立第二套动画；其余简单状态过渡优先使用 tokens.css 的 CSS transition/keyframes。
- **路由与拖拽分层**：`.page-transition.primary-nav-page`持有一级路由自身过渡；`.group-scene-inner`自动进入直接归位、退出仅淡出，由子面板执行各自进入方向。内部`.primary-nav-drag` / `.group-scene-drag`只负责真实拖拽offset。两层使用同一`absolute; inset:0; min-width:0; min-height:0`原点，保留业务key、提交门槛与播放器生命周期。正常Presence退出只停止活动拖拽/回弹，保留释放当帧offset参与路由淡出；不能同步清零，否则会在opacity仍为1时硬跳。相同DOM快速返场从保留位置连续归零；真正禁用或运行中开启reduced-motion才立即取消并清零，避免冻结在半途。
- **宽屏分区进入与切换**：进入主页时左侧栏从左进入、聊天输入从下进入；切群时第一列ServerRail持续存在，只有粉色活动标记移动，第二列频道栏按旧内容退出/收起后新内容从左进入。进入私信时会话列从左进入；选会话时标题从上、输入从下进入，换好友时标题执行退出/进入、消息区执行内容过渡。过渡必须保留单个活动消息订阅/编辑器和会话隔离，不为退出动画复制旧聊天运行实例。减少动态时直接显示最终状态。
- **分区容器布局**：`.channel-sidebar-slot`固定保留频道栏260px加两侧12px的占位，旧栏退出期间不能挤动主聊天区；`.conversation-transition`、`.chat-messages-motion`、`.chat-composer-motion`保留flex/min-size与阴影溢出空间，消息列表自己持有滚动。已由React motion持有的宽屏群/私信侧栏和输入关闭自动CSS入场，禁止两个owner同时移动同一分区。
- **直播分区**：宽屏直属`.live-rail`仍由CSS从左20px进入；群内外切换直播间时，既有`.live-room-stage`从下20px、弹幕分区从右20px进入，由同一WAAPI owner按channelId重播300ms easeOut。弹幕目标在宽屏/控制台为`.live-room-side`，窄屏普通观看为当前场景owner下的`.danmaku-wrap`；`.has-media-panel-motion`关闭宽屏侧面板旧CSS入场。标题从上20px进入，并以channelId作为小范围Presence身份，旧标题退出后新标题进入，`.live-room-head.is-panel-motion`关闭CSS入场。body/main/播放器宿主不因视觉动画增加key或重挂；跨频道时video/HLS仍可由原媒体runtime更换，视觉重播不得额外触发媒体切换，不能把宿主稳定误写成跨房video始终同一DOM。窄屏展开直播列表时，覆盖层`.live-rail.is-panel-motion`由Framer从右20px进入，旧CSS左入同时关闭；常驻宽屏左栏方向不变。reduced-motion直接归位。
- **语音房分区**：标题从上20px、语音成员卡从下20px进入，聊天卡宽屏从右20px、窄屏从下20px进入，均300ms easeOut；首次进入与群内切房均由单一动画owner在相同面板DOM上编排/重播，`.voice-room-body.is-panel-motion`下三面板关闭自动CSS入场及旧`.reveal`的opacity/transform。聊天卡内部输入始终在最终位置，不再叠加100%位移；窄屏聊天列表的浮层开合仍是独立交互。禁止为重播给VoiceRoomBody、音频或LiveKit宿主增加key；连接和订阅继续由真实房间切换管理，reduced-motion直接归位。
- **其他宽屏分区**：群详情`.group-info-side`从左、`.group-info-main`从右；自/他人页顶栏从上、资料列从左、内容列从右；桌游房标题、群内帖子/语音/桌游列表的`.group-scene-head`以及收藏页标题从上进入，统一20px/300ms。分区位移不改变§5规定的整页滚动与断点；减少动态时直接归位。收藏标题使用同款玻璃、亮边、16px圆角和compact阴影，横跨筛选栏与结果区，与页面12px外沿对齐。
- **帖子详情**：宽窄屏头部从上20px、评论输入从下20px进入，均300ms；输入不再叠加原100%位移与100ms延迟。群外正文滚动区单独继承原页面500ms的20px/scale(.95→1)显现，article/comments原300ms reveal与评论stagger保持，不能为新头部动画删掉正文过渡。群内正文补独立300ms进入。帖子外壳不同时持有整页位移，shell底栏离场状态与safe-area继续独立管理。
- **窄屏分区方向**：NarrowTopBar、个人页/收藏/群列表/桌游房/帖子/直播/语音的普通顶栏从上进入；窄屏进入群聊的导航单独保持“底栏滑动到顶栏”，不能用顶部-20px入场替代这条跨视口轨迹。个人页wrapper为display:contents，实际资料/内容卡片各自从下进入；群详情单列的两段内容也从下进入。群/私聊天输入由各自motion分区从下进入；直播只有窄屏底部`.live-room-input`从下20px/300ms进入，宽屏输入随右侧面板进入，不能再叠第二层。收藏窄屏标题同样使用玻璃面板，与列表16px内沿对齐。顶部/内容/输入不共用整页浮入，PrimaryNav/scene/FullScreenSwipeBack等手势层继续持有原手势，不因分区动画重挂或清空滚动；reduced-motion直接归位。
- **窄屏消息列表标题**：`.messages-page .messages-tabs`仅在挂载时从上20px/300ms进入；群聊/私信tab切换继续由原胶囊高亮与内容过渡持有，不重播整个tab头。此规则不匹配宽屏侧栏，reduced-motion直接呈现。
- **群帖子底部编辑器**：宽窄屏基础`.group-posts-input`从下20px/300ms进入；`.is-expanded`以更高特异性继续独占原250ms展开关键帧，保留展开定位、限高与内部滚动，两个animation不同时叠加。减少动态时基础态与展开态均直接归位。
- **群内左侧阴影空间**：宽屏群语音/桌游/帖子列表及帖子详情的实际竖向滚动器保留原16px内容轨道，以左margin -32px和左padding 48px增加绘制空间；标题、卡片、骨架的原位置及宽度保持，滚动DOM和`overflow-y:auto`不变。群帖子/详情外壳不另裁剪；扩出的透明带不接收指针，真实子内容恢复pointer事件，wheel从内容冒泡至原滚动owner，侧栏右沿仍可点击。
- **PageTransition 时长表**：

  | 路由形态 | 进入 | 退出 | 说明 |
  |---|---|---|---|
  | 群/私信/直播房/语音房/自他人页/收藏/桌游房分区外壳 | 外层直接`opacity:1`、位移0、scale1；各指定面板按上述宽窄屏结构进入 | 外层仅300ms淡出 | `panelOwned`排除普通整页浮入；群内容也只编排子面板，不再次移动整个内容区；真实手势轨道与机械退出仍独立，减少动态时直接完成 |
  | 帖子详情 | 外壳直接归位；头上/输入下300ms；正文按上述群内/外规则 | 外层仅300ms淡出 | 群外旧500ms浮入只迁到正文滚动区，原正文reveal与评论stagger保持 |
  | 普通路由 | `opacity: 0→1` + `translateY(20px→0)` + `scale(.95→1)` | `opacity: 1→0` | 进入 500ms Auroraqua easeOut；退出 300ms easeInOut |
  | 搜索页内容 | `opacity: 0→1` + `translateY(-20px→0)` + `scale(.95→1)` | `opacity: 1→0` | 顶栏固定，沿原方向展开；500ms / 300ms |
  | 窄屏群内场景 | 场景外壳直接归位；子面板分别进入 | 300ms淡出 | 真实group-scene-drag继续跟手，不叠加场景自动位移或整页缩放 |
  | 窄屏直播间同类切换 | inner pager保留原手势方向的20px位移 + 淡入，300ms easeInOut | 反向20px + 淡出 | 直播间路由详情key归一，保持单播放器运行实例；视频/弹幕分区各自重播见上文 |

- **消息到达**：仅新到达的乐观消息或 WS 实时消息挂 `.msg-arrive`，复用 `frost-rise` 从下方 8px 浮入 + 淡入，180ms；初始历史加载、滚动恢复和重新挂载的历史消息不播放到达动画，不弹跳。
- **滚动恢复与 stagger 互斥**：命中`useScrollRestore`的历史位置（包括显式保存的`scrollTop=0`）时，先恢复内容高度与位置，恢复节点禁止`.reveal-item`/stagger。增量列表后续分页、实时新增或刷新产生的新DOM才播放进入；刷新保留的DOM不重挂，但刷新完成后经`useListEntryMotion`的`replayKey`整批重播一次浮入（第一页也有动画，见 §7.1）；未改为增量hook的既有静态内容继续使用自身reveal。
- 常驻环境动画仅两个：光环呼吸 + 流体极光背景（§7.2）；其余装饰性循环动画禁止
- 骨架屏：所有 >300ms 的异步加载用 `animate-pulse` 风格骨架（玻璃质感骨架块），禁止白屏/冻结
- `prefers-reduced-motion`：关闭呼吸、浮入与跟手位移；新分区与增量列表直接显示最终opacity/transform，不等待渐变。拖拽/切换必须退化为可用的直接控件路径。

### 7.1 内容入场与增量卡片

帖子详情及未指定分区方向、未接入增量hook的异步内容共用`.reveal`；宽窄屏直播和语音房的指定面板由§7分区规则接管，同一面板不再叠加本原语：

- **CSS**：`base.css` 的 `.reveal` 初始 `opacity:0 + translateY(20px)`，`.reveal.is-in` 300ms Auroraqua easeOut 回到正常位置；`prefers-reduced-motion` 下直接呈现。
- **静态样式元素**：既有`.reveal-item`保留给尚未改为增量DOM入场的内容与评论（20px/300ms），`staggerDelay`每项50ms、累计封顶300ms。
- **增量列表**：收藏、搜索、帖子与目录卡片使用`useListEntryMotion`记录已经出现的实际DOM；首屏、加载下一页和实时新增都只让新节点从下20px/300ms进入，批内50ms错峰封顶300ms。已存在卡片不重播，刷新不以key重挂整个列表；减少动态或滚动恢复阶段直接呈现新建DOM，恢复结束后真正追加的新卡仍可入场。**刷新反馈**：各列表页（帖子/直播/语音/桌游及群内对应子界面、收藏、搜索、帖子详情评论）在刷新完成后递增`replayKey`，`useListEntryMotion`对已入场卡片整批重播一次浮入（同样20px/300ms、50ms错峰封顶300ms），让第一页也有动画；重播不重挂DOM、不动seen，保留滚动位置与焦点，新增卡片仍由主effect单独入场不重复播放，`prefers-reduced-motion`与滚动恢复抑制期不重播。
- **目录活动排序**：语音/直播WS真实sortIdentity变化沿用原业务排序，即时重排当前查询已加载卡，复用旧DOM、不重播入场；正常metadata/count/activity更新不使分页失效，后续页沿原cursor并按ID去重。仅部分目录的真实成员集合/过滤归属变化提供明确刷新入口，完整目录直接同步增删与总数；普通metadata/count变化与分页append不重排，不能把“新页不搬动旧卡”扩大为取消原活动排序。语音侧栏同一稳定UL保存已加载行，折叠仅显示前三项/92px、尾项不可交互，展开恢复auto高度；位置FLIP为300ms easeOut，排序立即生效且不改写scrollTop。完整分页契约见[目录分页架构](architecture/catalog-pagination.md)。
- **语音选择与连接**：侧栏选中胶囊按路由voiceChannelId立即更新，独立于实际媒体currentChannelId；真实成员活动排序仍即时生效。`.channel-sidebar-list`滚动根登记`layoutScroll`并禁用原生`overflow-anchor`，保留同DOM位置FLIP，避免排序时浏览器锚定把scrollTop跳回。语音房行的胶囊设`sharedLayout=false`，背景随父行一起移动，不再以第二套共享layout投影反向抵消父行位移；其他导航继续使用原共享胶囊过渡。快速切换的共享选择/REST补偿/媒体取消见[语音会话切换](architecture/voice-session-switching.md)，不能用等待连接来延迟导航反馈。
- **侧栏吸附标题阅读边界**：聊天、语音、直播与固定帖子、桌游共用`.channel-scene`未选/选中/hover材料；上三行没有独立底色或额外backdrop-filter。`useSidebarContentClip`读取同一滚动区内实际标题矩形、可视边界和row-gap，把三个原下拉容器的绘制裁剪在自身标题下方与下一标题上方；标题吸顶、吸底及相邻4px间隙均不绘制后方条目。裁剪不改变列表DOM、尺寸、排序、scrollTop或分页，行FLIP继续由原节点持有；scroll、ResizeObserver与仅直接childList的MutationObserver同步，卸载回收监听、观察器及自身clip。不能把裁剪后的几何存在或单次命中检查当作完整键盘可达性证明。
- **分页提示区稳定**：目录/群帖/一级帖子的`StablePaginationFooter`保留本次挂载测得的最高高度，错误、重试与加载共用同一DOM，完整错误可换行；主内容终页保留空间，语音/直播侧栏传`retainCompletedSpace=false`，无加载/错误/后续页/失效时移除footer，避免空白尾段。footer不参与浏览器滚动锚定。共享footer用`flex:none`与`width:100%`，禁止在侧栏column内设`flex-basis:100%`，以免自动高度与最高高度保留互相放大；帖子瀑布流的跨列规则只在本布局生效。
- **Hook**：`useRevealOnEnter(active)` 返回 `{step, revealed}`，双 rAF 首帧隐藏→过渡显示。**内容由异步加载产生时，必须把 `active` 接到「内容就绪」信号（如 `!loading`），否则动画会在加载完成前就跑完、看不到浮入**。
- **滚动恢复互斥**：`useScrollRestore`命中历史位置时，恢复节点不挂CSS stagger或重播WAAPI入场。分页请求在详情中完成不能撤掉该抑制；返回先恢复原位置，此后新增页只动画新增节点。
- 语义边界：`.reveal`只管未指定方向的内容块；宽窄屏聊天输入、帖子输入与直播输入分别归上述单一分区owner，底栏显隐状态继续独立管理。不同独立区域可以协调进入，同一节点与其整页祖先不能重复持有同一次位移。

### 7.2 流体极光背景（Fluid Aurora）

全局背景为**四色漩涡渐变 + SVG 湍流置换纹理 + 双色丝滑螺旋光斑 + 极淡网格**（纯 CSS 驱动：静态 SVG 纹理 + CSS transform 动画，无 JS/Canvas/Web Animations/SVG 动画）：

- **渐变**：**四角四色螺旋**——四角各一个柔和 radial 弥散色光（左上冰蓝 `#BDD4E9` / 右上冰蓝深 `#9DBFE6` / 右下亮樱粉 `#F9B0FF` / 左下淡樱粉 `#FCD8FF`，全部 design.md Core 浅色同族，无深色/紫/深蓝），边缘中点白色光斑隔离蓝粉（避免混合出紫），中心 35% 暖白光晕（非线性过渡：0-18% 快降被卡片盖住/白对白不可见，18-35% 缓降边缘等值线疏——避免"年轮"同心圆纹理）；150vmax 正方形 fixed 层（`left: 50%; top: 50%` + 负 margin 半尺寸，层中心恒等于视口中心——层超视口时 `inset+margin:auto` 会失效导致中心偏右露边）**变速旋转 400° 超圈**（先快后慢）+ 不规则漂移 + **明显缩放呼吸（0.8↔1.2，四角色光随层变大变小）**（GPU transform 合成，禁止 `background-position` 动画重绘；150vmax 在 scale 0.8 + 漂移 5% 极端组合下内切圆 52.5vmax ≥ 视口边缘 50vmax，旋转任意角度不露边），四角色光绕中心丝滑螺旋流动（无 conic 扇形放射感）
- **网格**：极淡 ice-500 网格纹理（`--bg-aurora-grid`，柔和 3px 渐隐线 + 96px 周期 + 0.015 透明度——仅保留微妙层次感，肉眼几乎不可见，避免摩尔纹/可见网格线）叠加在渐变层，增加层次不抢主视觉
- **湍流置换**：SVG `feTurbulence`（fractalNoise，baseFrequency 0.018，冰蓝调 alpha 0.2）静态纹理（`--bg-aurora-turbulence`）叠加在渐变层之上，**不规则路径漂移（±6%）+ 大角度旋转（±14°）**模拟湍流随机有机流动；层透明度 `--fluid-turbulence-opacity`（0.2，有效 ≈0.04）+ `filter: blur(24px)`（噪声更柔和，仅保留有机流动感，肉眼不可见纹理）
- **光斑**：2 个 radial-gradient 圆（冰蓝深 `--ice-500 #9DBFE6` / 亮樱粉 `--sakura-300 #F9B0FF`），`filter: blur(40px)` 柔化轮廓 + 单段 radial 70% 截止（无多 stop 等值线）+ opacity 0.65（窄屏 0.7 提亮）；**定位**：宽屏左右半区（A `left: 25%` / B `right: 25%`，垂直贴顶/底 -10%），窄屏上下半区（A `top: 25%` / B `bottom: 25%`，水平 `left/right: 50%` + 负 margin 半尺寸居中，尺寸加大 80vw/70vw 与宽屏视觉占比相当）；**动画**（10s，`infinite alternate`）：漂移蓄势（0-30%）→ 30-50%（2s）匀速置换去对向（宽屏左右互换 / 窄屏上下互换，`translate` 帧值固定）→ 对向驻留（50-100%）；**活动范围缩小**（宽屏 ±80%/-90%、窄屏 50%/-60%）不贴边 + **呼吸 0.65↔1.35**（A/B 错相）——是"漂移 + 匀速置换 + 驻留"的有机交叉流动；**全站统一**：直播大厅/直播间/私聊浮层/帖子编辑等 5 处容器不再覆盖 `--bg-aurora`，全局流体背景全站生效
- **层级**：html 静态兜底 < `html::before` 渐变+网格层（`filter: blur(40px)` 模糊 radial 等值线消除"年轮"纹理，整体水彩晕染）< `html::after` 湍流层（`blur(60px)`）< `body::before/::after` 光斑（`blur(40px)`）< `#root` 内容（z-index:1）；光斑在玻璃卡片之下，被 `backdrop-filter: blur(18px)` 模糊后透出，保持通透
- **随机感**：四层动画周期互质（渐变 22s / 湍流 17s / 光斑 10s）+ 负延迟错开初始相位（-8s/-5s）+ 光斑双侧同周期同相（A/B 同步置换交叉），各层永不同步，产生有机湍流流动感
- **可调参数**（tokens.css，禁止硬编码）：`--fluid-gradient-angle` / `--fluid-gradient-speed`（11s，渐变层单圈 = ×2 = 22s）/ `--fluid-turbulence-speed`（17s）/ `--fluid-turbulence-opacity`；光斑尺寸/周期/位移当前直接写在 base.css（宽屏 40vw·40vw @ 10s、窄屏 80vw·70vw @ 10s，`--fluid-blob-*` 为遗留备存变量）
- **降级**：`prefers-reduced-motion` 停止全部流动动画，回退 html 静态 `--bg-aurora`；不支持 `backdrop-filter` 时光斑回退为降低透明度的实色圆；≤768px 双光斑保留并改为上下半区（A 上 80vw / B 下 70vw，alpha 0.7 提亮）且渐变/湍流放慢（省电）
- **纪律**：光斑不是辉光（`--glow-shadow` 仍限 3 处）；背景保持明亮浅色通透，禁止深色/紫色/深蓝混入

### 7.3 加载指示器与骨架屏

- 转圈使用 `base.css` 的 `.loading-spinner` 与唯一 `ayla-loading-spin`：`--loading-spin-duration:800ms`、linear、循环一整圈。默认/md为18px，sm为14px；2px环使用原ice轨道和indigo顶部，消息发送保留既有 `rgba(70,91,146,.25)` 轨道。消息历史、消息发送与下拉刷新复用同一类；RefreshFab的原SVG仅共享旋转配方，外形与请求状态保持。
- 骨架统一 `.skeleton`：原玻璃底、白色亮边与 `frost-pulse` 的 `.55→.9→.55`，`--loading-pulse-duration:1600ms`、ease-in-out。span默认inline-block以兑现显式宽高，div保持块级布局；媒体/查看器骨架继续block撑满预留frame，避免资源就绪时跳动。可见范围群列表保留既有樱粉背景。
- 骨架外层必须跟随真实内容的水平轨道，不能只改骨架内部padding：帖子/我的帖子用同一680→1200px限宽和16→24px内沿，宽屏双列；语音/直播加载区跟随真实列表的2/3/4列与max1200px，桌游和收藏直接复用各自轨道。帖子详情的满宽骨架有效区为680px，两侧16px外沿与加载后的正文卡边缘对齐；搜索当前为文字加载状态，仍使用结果轨道。宽屏主页在跳转群页前不铺骨架（登录后宽屏主页即三列群聊界面，骨架与群页布局无法对应），用轻量加载指示（`.home-loading`：居中 `loading-spinner--md` + 「正在加载群聊…」文字）；窄屏共用原群卡网格骨架。
- `prefers-reduced-motion` 下循环转圈与骨架脉冲均停止，保留静态加载标识、状态文字、aria语义和预留尺寸。不要在场景CSS重新声明同一种循环动画而绕过共同降级。
- 此配方仅表示真实未完成的异步工作；加载、完成、失败与取消由原请求生命周期控制。页面进入、列表reveal、路由、消息到达、背景和光环属于各自原语，不能随加载样式统一而重放；LivePlayer的600ms单次刷新反馈保持其现有行为。

### 7.4 全屏加载界面（FullScreenLoader）

- 场景：进入网页 / 浏览器刷新 / 登录（注册）成功后，核心数据预加载完成前覆盖全屏——「所有页面完成预加载后才进入页面」，避免白屏、闪跳登录页与进入页面后又各自加载。
- 预加载范围（`src/appInit.ts` 的 `appInit.run()`）：群列表、语音/直播/游戏目录、帖子信息流、私聊列表，与页面 store 全局预热共用，进各 hub 秒开。预加载失败不阻断（catch 后进入页面，页面内自行重试）；20s 硬上限兜底，个别请求异常挂起时不得永远卡在全屏加载界面。
- 视觉：`.fullscreen-loader` 固定全屏（z-index 100 最高层），Ayla 品牌（40px Fredoka 渐变字，`line-height ≥1.25` 防 `background-clip: text` 裁字，同 auth-brand 断言）+ `loading-spinner--md` 垂直居中直接浮于极光背景之上，无卡片容器、不放文案行。
- 生命周期：main.tsx 先渲染 loader 再 `await bootstrap()`（会话恢复 + 预加载）后渲染 App；App 订阅 appInit 状态，loading 期间渲染 loader；登录/注册成功经 useAuth 触发 `appInit.run()`，登出 `appInit.reset()` 使下一位用户重新预加载。

## 8. Do's and Don'ts

### Do
- 保留每屏既有蓝粉配色，卡片/侧栏共用玻璃材料，以阴影尺寸与原底色透明度区分层次
- 爱莉/主 CTA/focus 延续原辉光；选中导航用同色柔光和可读的胶囊轮廓
- 圆角走刻度，胶囊留给按钮/标签/头像
- 图标用线性 SVG，2px 描边，圆角端点
- 中文用系统圆体回退，拉丁用 Fredoka/Nunito 出挑

### Don't
- 不用铬金属、扫描线、glitch、像素字——不做复古噱头
- 不把 `#F796FF`/`#F17EB3` 当正文文字色（对比度不达标）
- 不使用上游粉桃紫色板；阴影采用 Auroraqua 的宽软几何和 Ayla 原有颜色，不堆叠多层深色阴影
- 品牌辉光继续限量；导航状态只在各导航组当前项显示柔光，不用持续闪烁强调
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
- 玻璃卡片：原 `rgba(255,250,251,0.55)` + `--glass-filter` + 原亮边 + `--glass-shadow`，详见 §4
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

- 容器：高 64px，原 `--glass-bg` + `--glass-filter`，顶部及左右外沿 12px 留白、16px 圆角、四向 `--glass-border` 与 `--glass-shadow`，常驻不滚走
- 布局：左起 头像（40px 圆形带 `--ring-online` 光环，→个人界面）→ 一级模块文字链（主页/语音/直播/帖子/桌游，Nunito 700 15px `--text-primary`）→ 消息（带未读徽标）→ 搜索框（240px 胶囊，见 12.9）→ 更多（三，40px 图标按钮）
- 品牌 logo（`.top-nav-logo`）：导航条水平居中（绝对定位于两端集群之间的空白区，`left:50% + translate(-50%)`，不参与内容宽度竞争），`Ayla` 22px Fredoka 600 渐变字标（indigo→grape，`line-height ≥1.25` 防 `background-clip: text` 裁字），hover 微提亮，点击回主页 /group；**≤1000px 隐藏**（中间空白不足约 58px 时与两端集群贴边，屏幕变窄不足以显示即隐藏），>1000px 显示
- 当前模块：原文字颜色 + 12px 圆角的 `--nav-active-bg` 胶囊、高光与柔光；`AuroraquaNavHighlight` 300ms 移动，不再显示独立底部线
- hover：模块文字底 `rgba(157,191,230,0.18)` 胶囊（200ms 过渡）
- 模块文字必须单行、不收缩成竖排；769–900px 将模块间距收为4px、两端内边距8px，导航外壳内边距/间隙12px，搜索框收为160–200px，消息/更多图标按钮仍为40px。更宽视口保持原24px外壳内边距、240px搜索框。

### 12.3 服务器栏 ServerRail（宽屏，主页/群场景最左）

- 容器：宽 72px，`--glass-bg` + `--glass-filter` + 四向亮边、16px 圆角、`--glass-shadow`；上下左留 12px，与频道侧栏相隔 12px；头像间距与滚动行为不变
- 群头像：48px 圆形，带 `--ring-online` 光环；当前群左侧 3px `--glow-500` 指示条 + 头像微放大（48→52px，200ms）
- 宽屏切换群时AppShell使用稳定的 `wide-group-shell`，ServerRail owner与共享指示条id不重挂，粉色指示条在同一导航owner内移动。第二列ChannelSidebar按当前groupId编排旧内容收起/退出、新内容从左进入；频道栏和群内容保持群私有编辑/弹窗/消息输入的归属，不能为外观连续把状态串到另一群。首次进入主页的左移入场与同一主页内切群须由不同生命周期边界控制，避免第一列反复滑入。
- 状态角标：头像右下角 16px 圆形底（`--pink-500` 未读 / `--glow-500` 直播 / `--ice-500` 语音 / `--sakura-300` 桌游），内嵌 10px 白色线性图标
- 底部用户卡：40px 头像带光环 + 在线状态点；点击进个人界面

### 12.4 频道侧栏 ChannelSidebar（宽屏，主页/群场景）

- 容器：宽 260px，原 `--glass-bg` + `--glass-filter`、四向亮边、16px 圆角、`--glass-shadow`，四向外边距 12px；保持内容独立滚动和场景 sticky
- 群名头：Fredoka 500 20px `--text-primary`，padding 16px，点击进群信息；右侧 chevron 图标
- 场景项（聊天/语音/直播/帖子/桌游）：行高 40px，圆角 12px 胶囊，左 20px 线性图标 + Nunito 600 15px 文字（`--text-secondary`）；选中态底 `rgba(157,191,230,0.35)` + 文字转 `--text-primary`；hover 底 `rgba(157,191,230,0.18)`
- 状态标识：行右侧——语音在麦人数（Space Grotesk 12px `--text-secondary`）、直播 LIVE 徽标（`--pink-500` 底白字 11px Fredoka 胶囊）、帖子未读数（`--pink-500` 圆点）
- 「聊天」下子群：默认组固定第一，其他子群按最近消息顺序倒排；新消息到达立即重排，自己发送或正在查看的子群同样适用。无消息/活动相同保持原序，先排序再取默认展示的前三项；展开更多延续同一顺序，重排保留当前选中子群。窄屏子群选项卡继续保持原顺序。
- 子群红点按实际看到的消息消除：进入/切换子群只加载历史，未读标签只定位；消息进入可视区后逐条确认，未看到的消息与其他子群未读继续保留。此行为在宽屏侧栏和窄屏子群选项卡一致。

### 12.4.1 群内场景统一标题栏 GroupSceneHead

- 适用语音、帖子、桌游三个**可滚动**的群内子场景；标题栏必须是各自滚动容器的直接子元素，以 `position: sticky; top: 0; z-index: 10` 吸顶；顶部留白由滚动容器 gutter 提供，不能再用 sticky 偏移重复叠加，亦不能被下拉刷新或场景切换动画的位移层包住。
- 规格：最小高 72px、padding 16px、标题区与尾部动作间 gap 12px；滚动容器统一四向 16px gutter，并由父容器 `gap: 16px` 保证头部与下方内容分隔，与卡片内容轨道对齐；`--glass-bg` + `--glass-filter` + 完整 `1px --glass-border` + 16px 圆角和 `--glass-shadow-compact`，不用负 margin 拉伸成整面横条；不支持 backdrop-filter 时切换 `--glass-bg-strong`。
- 文案：标题 Fredoka 500 / 18px `--text-primary`；可选说明 Nunito 14px / 1.45 `--text-secondary`，为保持三场景同高，说明一行省略而标题仍可自然收缩；尾部按钮保持自身 ≥40px 触达目标。滚动容器设置与标题高度匹配的 `scroll-padding-top`，确保键盘焦点/程序定位不被吸顶栏遮住；窄屏不能由玻璃头部制造横向滚动。

### 12.5 浮动按钮 FAB（两形态）

- CreateFAB（右下，两形态都有）：56px 圆形，主 CTA 样式——`--indigo-700` 实底 + 白色加号线性图标（24px），常驻 `0 2px 12px rgba(70,91,146,0.18)` 浅投影；hover/按下附 `--glow-shadow`（200ms）。窄屏 `right:16px; bottom:底栏高+12px`；宽屏 `right:32px; bottom:32px`
- MessageFAB（窄屏左下）：56px 圆形玻璃底 `--glass-bg` + blur 18px + 1px `--glass-border`，消息线性图标 `--text-primary`；未读聚合徽标 `--pink-500` 右上角
- FAB 动作面板：窄屏底部上滑面板 / 宽屏 FAB 上方浮层——`--glass-bg-strong` + blur 18px + 圆角 24px（上沿）/16px（浮层），背景压暗 `rgba(70,91,146,0.25)`；面板项 = 图标 + 文字行（行高 48px）

### 12.6 群卡片 GroupCard 与轮播（窄屏主页）

- 卡片：`--glass-bg` + `--glass-filter` + 16px 圆角 + `--glass-border` + `--glass-shadow`，可交互卡片 hover/press 复用 §4
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

- 窄屏沉浸式：视频观看区优先；顶部主播信息行（玻璃底 `--glass-bg`）、底部弹幕输入框（`--glass-bg-strong` 半透明，InputBar 变体）；左上角返回键保持 ≥40px 圆形玻璃触达区 + 箭头图标。
- **竖屏弹幕浮层化配方（U5 方案留档）**：弹幕不再以独立实心/玻璃卡片铺满视频下方，最近 3–5 条以无独立背景的轻量浮层覆盖视频下沿，自下而上以 180ms `.reveal-item`/透明度浮入；浮层点击展开完整弹幕底部抽屉，抽屉约占视口 70% 高度，使用 `--glass-bg-strong` + blur(18px) + 上沿 `--radius-panel`，并提供遮罩、关闭按钮与 ESC 退出。弹幕文本、头像和「有新弹幕」操作仍须保持可读对比与 ≥40px 触达。
- **当前实现边界**：上述浮层/抽屉是本轮走查提出并记录的方案变体；2026-08-26 用户最终拍板撤销该变体，当前窄屏实现恢复为视频上方、透明背景的弹幕滚动区（不覆盖视频、不展开抽屉），输入框仍独立使用 `--glass-bg-strong`。后续若重新启用浮层，必须同步实现与验收，不得仅按历史配方改文档或局部样式。
- 宽屏：视频主区 + 弹幕侧列 360px（整面玻璃，弹幕列表 + 底部弹幕输入框）；视频两侧「上一个/下一个」40px 圆形玻璃按钮 + 键盘 ↑↓。
- 普通弹幕输入的发送按钮共用`.btn-primary`，图片入口共用ghost玻璃按钮；两者至少40px高、12px圆角，图片按钮为原生button并以ref唤起文件选择，键盘可达。输入保持可收缩，发送按钮不被挤成竖排；pending、图片失败重试、已上传媒体复用及新草稿保留继续由原请求生命周期控制。
- LIVE 徽标：`--pink-500` 实底白字 11px Fredoka 胶囊，左上角。
- 直播间卡片（聚合网格）：封面 16:9 圆角 12px + LIVE 徽标 + 标题 Nunito 700 15px + 主播 13px `--text-secondary` + 来源标识（公开/好友/群名，Micro Tag 11px Fredoka `--sakura-300` 底 `--grape-700` 字）。
- 直播列表材料与群/语音/帖子卡相同，使用 `.live-card` 的 `--glass-bg`（.55）、`--glass-filter` 和 `--glass-shadow`，不另用更实的 `.78` 底。大厅、直播侧栏及群频道侧栏的空封面均透明，保留亮边/视频图标，避免不透明渐变遮住玻璃；真实封面维持原像素与opacity，不通过降低整张卡片透明度制造通透感。

### 12.7.1 直播画面飘弹幕层 DanmakuOverlay（任务 04 增量）

> 在视频画面上叠加从右向左飘过的弹幕（B 站式），与弹幕侧列/列表是同一数据的**另一种展示形态**，不替代列表、不改数据链路；直播间与开播控制台（`LiveRoomBody`）统一生效。

- **挂载与层级**：`DanmakuOverlay` 作为 `LivePlayer` 的 children 渲染在 `.live-player` 容器内——`position: absolute; inset: 0; overflow: hidden`；`z-index: 4`（视频之上、悬浮控件 z5 之下，不遮控制条）；`pointer-events: none`（不挡播放器交互、控制条可点）；容器随宽窄屏 / 全屏 / 切台自适应（ResizeObserver 维护宽度）。
- **数据接入**：订阅 live store 的 `current.danmaku`，**只飘新弹幕**（WS 实时 append）；进房历史与重连对账（merge）以挂载基线快照排除，不重放；`channelId` 变化重建基线并清空画面（切台无残留）。渲染条件 `!loading && srsStatus === "live"`——进房完成（历史已 merge）才挂载，避免把历史误当新弹幕。
- **轨道管理**：轨道数按容器高度动态算（行高刻度 36px，2~10 条）；分配选最空闲轨道；同轨道同速 → 开始时间差 ≥ 最小间距（60px / 速度），从数学上避免重叠与堆积（纯函数 `danmakuTracks.ts`）。
- **动画**：CSS transform 动画（GPU 合成），`--fly-from`（容器宽）→ `-100% - 24px`（完全出屏，不依赖逐条测宽）；时长 = (容器宽 + 文本估算) / 速度（150px/s），宽窄屏视觉速度一致；`animationend` 移除 DOM，画面同时飘 ≤80 条防长直播堆积。
- **样式**：16px Nunito 700 白字 + 深色多重描边/投影（视频上可读性，媒体叠加场景不适用界面正文对比度规则）；弹幕左侧飘发送者头像（20px 圆 + 1px 白描边）；媒体弹幕只飘**缩略图**（固定 72×36 小图框，不飘原图），纯图占位文案「图片」不飘文字。
- **图片与头像加载**：一律走 `ResourceImage` 签名加载（`<img>` 裸引用媒体路径会 401 破图）；图片弹幕点击打开 `ImageViewer` 放大（与聊天界面一致，仅图片按钮 `pointer-events: auto`，其余区域仍穿透不挡控制条）。
- **可达性**：`aria-hidden`（纯装饰层）；`prefers-reduced-motion` 下整层不渲染（飘弹幕本质是动效，无静态降级需求）。
- **不做**：不改弹幕数据链路、不删除/不替代弹幕列表、不做弹幕开关与密度设置（需求未强制，保持最小实现）。

### 12.7.2 相邻直播间预览卡 LivePeerPreview（方案留档）

- 这是直播上下滑三槽 pager 的轻量预览配方：封面铺满并 `object-fit: cover`；没有封面时使用 `--bg-aurora` 占位并配线性视频图标。
- 左上使用 `--pink-500` 实底 + `--surface` 白字的 LIVE 胶囊；底部使用玻璃 meta 区（`--glass-bg` + blur(18px) + `--glass-border`），展示标题与主播，文字遵循正文/次要文字层级。
- 预览卡**纯展示、无播放组件、无 `useLiveRoom`、无 WS/轮询副作用**，不能为了切换动画常挂多个真实直播播放器。
- **当前实现边界**：该配方曾作为 G3 的三槽预览卡落地，后续用户返工将现行切换改为“视频 + 弹幕区”整体滑动，删除 `LivePeerPreview`；本条保留为可复用的轻量预览配方，不能据此声称当前直播间正在渲染预览卡。

### 12.7.3 直播播放器控件（低延迟 + 跳到最新）

- **无原生控制条**：`<video>` 不带 `controls`——去掉进度条、手动倍速与原生全屏，纯直播观看（对齐 B 站直播体验）；画中画小窗能力保留。
- **低延迟起播**：hls.js 分支开 `lowLatencyMode` + `liveSyncDurationCount=2`，`startLoad(-1)` 从直播边缘起播（连上推流即显示最新画面，不从头回放历史）；**不做追帧倍速**（保持 `liveSyncPlaybackRate` 默认 1.0，画面不自动加速）；延迟延后由用户手动刷新跳边。Safari 原生 HLS 分支维持原生贴边行为。
- **悬浮小按钮（非常态显示 + 无操作自动隐藏）**：三个 32px 圆形悬浮钮，indigo 半透明底（`rgba(70,91,146,0.32)`，与 tokens `--overlay-dim` 同源）+ 白线性图标 + `blur(8px)`；**默认隐藏**，桌面悬停/移动播放器显示、移出隐藏，触屏点击视频显示；**显示后 3 秒无操作（鼠标静止/无点击）自动隐藏**，鼠标移动或点按钮重置计时、不常驻；淡入淡出 `opacity` 180ms。
  - 左下「跳到最新」刷新键（`IconRefresh`）：**健康播放**（视频已有当前帧 `readyState ≥ HAVE_CURRENT_DATA`）→ `refreshToLiveEdge()` 跳边秒跳（hls.js 用 `liveSyncPosition`、兜底 seek 到 `seekable` 末尾、再兜底 reload+play）；**黑屏/实例缺失/未就绪** → 重建播放器（销毁 + 重新 attach，`startLoad(-1)` 从边缘起播 = 跳到最新）；图标旋转 0.6s 反馈（`prefers-reduced-motion` 下禁用旋转）。
  - 右下「画中画」（`IconPip`）：仅浏览器支持时渲染（`document.pictureInPictureEnabled` 或 Safari `webkitSetPresentationMode`）。
  - 右下「全屏」（`IconFullscreen`）：对整个 `.live-player` 容器 `requestFullscreen`（全屏黑底铺满、圆角/边框去除），悬浮按钮仍在全屏画面内；**窄屏（手机）全屏后锁横屏**（`screen.orientation.lock("landscape")`），**iOS Safari 走 `webkitEnterFullscreen()` 原生视频全屏（自动横屏）**；退出全屏（含 ESC/系统返回）经 `fullscreenchange` 解锁方向。
  - **全屏弹幕输入框**（标准容器全屏时，屏幕下方中间）：与其他输入区共用浅玻璃材料，外框至少50px高，宽度为`min(320px, calc(100% - 120px))`，给两侧媒体控制按钮让位；内部input透明，发送按钮为40px、12px圆角的`.btn-primary`。保持bottom 8px及原控制条显隐（3s无操作隐藏、移动唤醒、聚焦暂停隐藏）。Enter或发送按钮发弹幕，成功只清除本次提交对应草稿，新输入保留；错误在全屏内可见。iOS原生视频全屏无自定义UI时不显示。
- **黑屏自动恢复**（切台/切界面后画面不加载的根治，学 B 站「减少黑屏 + 真黑屏立马刷新」）：
  - `videoRef` 用**粘性 ref 代理 + videoVersion 重建信号**：沉浸式上下滑切台（`AnimatePresence mode="sync"`）与宽窄屏切换时，旧 video 卸载（React 把共享 ref 置 null，忽略）、新 video 挂载即 `setVideoVersion` 触发播放器 effect **重新 attach 到新 video**——根治「video 重建但 effect 依赖 srsStatus/hlsUrl 不变 → 不重 attach → 永久黑屏」，video 挂载即接上、不靠轮询；
  - **全屏冻结 isNarrow**：手机点全屏锁横屏会改变 viewport 宽度 → `isNarrow` 翻转 → 窄↔宽布局切换 → 播放器(video)重建 → 黑屏；`LiveRoomBody` 在 `fullscreenchange`（方向变化前触发）冻结进入全屏前的 `isNarrow`，全屏期间布局不切换、播放器不重建，从根源减少「点全屏就黑屏」；
  - **fatal 错误自动重建**：hls.js 不可恢复 fatal 后（冷却期外）自动重建播放器；
  - **事件驱动黑屏/卡死检测（替代轮询）**：监听 video 的 `waiting/stalled/error`（卡顿/黑屏信号），卡顿持续 2s 未恢复（仍无帧/暂停）且冷却期（4s）已过 → 自动重建，`playing/canplay` 恢复即取消——正常播放零开销，黑屏发生的瞬间（事件）就启动重载，不用轮询去猜；
  - 刷新键主功能 = 跳边跟上直播进度，黑屏时顺便重建兜底（平时由事件驱动接管）。
- **触达口径例外**：媒体悬浮钮为 32px（用户明确拍板「改小一点」——视频上辅助操作、非常态显示）；非媒体/常驻交互仍遵守 §10 ≥40px。focus ring 可见、`prefers-reduced-motion` 下无位移/旋转。

### 12.7.4 手机端浮动小窗（任务 05）

> 手机端（iOS/Android）浏览器原生画中画不可用或受限，改为 **App 内浮动小窗**：离开直播间页面后迷你播放器浮在页面角落继续播放。桌面端保持原生 PiP 按钮与行为（不回归）。

- **触发条件**（全部满足）：窄屏（≤768px）+ 普通观看（非主播开播控制台）+ 直播中（`srsStatus=live` 且无播放错误）+ 离开直播间页面（返回列表/切到其他页）。主播控制台离开后仍走活动态悬浮球入口。
- **播放连续性（核心）**：video 元素由 `liveSessionRuntime` 全局单例唯一持有，HLS 实例**不重建**；大窗↔小窗/宽屏↔窄屏切换时 video 在容器间**原子移动**（`useLayoutEffect` cleanup 在 DOM 移除前把 video 移入暂存容器，再从暂存原子移入目标容器——全程不脱离文档、浏览器不暂停、时间连续）。`attachPlayer` 幂等（相同流不重建），小窗期间播放器不销毁，`attachPlayer`/轮询只在直播结束时兜底释放。
- **交互**：点击小窗主体 → 回到直播间大窗（`sourceRoute`：一级直播 `/live/:id`，群内直播 `/group/:id/live`）；右上关闭按钮 → 完整销毁会话（hls → WS → 轮询 → store → 活动态）；单指拖动（pointer 位移超阈值，clamp 视口内）；双指缩放（120–320px 宽，保持 16:9，右下角锚定）。
- **样式**：fixed 右下角 16px，默认 168×94（16:9），`z-index: 60`（活动态悬浮球 55 之上、弹层遮罩 70 之下）；外层无 `overflow:hidden`（关闭按钮突出在小窗**右上角外侧**，不遮挡画面），内层 `.live-mini-player-video-wrap` 负责圆角/边框/投影/裁剪（`--glass-bg-strong` + `--glass-filter` + `--glass-shadow-compact` + `--glass-border` + `--radius-input`）。
- **唯一 owner**：同一时间至多一个小窗（store `miniPlayer` 唯一）；小窗激活时隐藏 SessionActivityIndicator 的直播悬浮球（避免重复入口）；退出登录/切直播间完整清理。

### 12.8 帖子卡 PostCard 与信息流

- 卡片：`--glass-bg` + `--glass-filter` + 16px 圆角、完整亮边、`--glass-shadow`；padding 16px，详情卡保持稳定位置
- 头部：作者头像 36px 带光环 + 昵称 Nunito 700 15px + 时间 Space Grotesk 12px `--text-secondary`
- 正文：Nunito 400 15px `--text-primary`，超 3 行折叠 +「展开」（`--ice-500` 文字钮）
- 图片：1 图大图圆角 12px；多图 3 列九宫格 gap 4px 圆角 8px
- 底排：评论数 / 收藏（线性图标 18px + Space Grotesk 12px 数字，`--text-secondary`）；收藏激活态图标填 `--pink-500`
- 评论输入框：InputBar 变体（底 `--surface` + 1px `--ice-300`，focus 转 `--glow-500` + 辉光）
- **列表布局与返回连续性**：窄屏单列；>1024px 为两列等宽错排瀑布流（列 gap 与卡片纵向 gap 均为 12px，最大内容宽 1200px），群外信息流、群内帖子、我的帖子共用。入场由卡片外层持有，PostsHub/GroupPosts使用增量WAAPI，卡片本体hover可上浮2px；reduced-motion下不位移。进入详情前保存滚动位置；返回时连同已加载分页恢复，且按§7.1跳过恢复节点的stagger。
- **视频媒体封面（秒开策略）**：上传时前端抽首帧经 `POST /media/{id}:poster` 回传（JPEG ≤2MB 存为 thumbnail 派生，QQ 同款）；卡片/详情页封面一律渲染 thumbnail 签名缩略图（320px JPEG `<img>` 直连，秒出、零视频拉流，不挂 `<video>` 元素）+ ▶ 角标；查看器播放时 original 签名就绪前显示同一海报帧 `<img>`，`<video poster>` 同帧衔接 + `preload="auto"`——点开即见画面无跳变；无海报帧（存量/抽帧失败）降级 SignedVideo 首帧预览。服务端在 poster 回传后异步做 mp4 faststart 重排（moov 前置，`manage.py ensure_video_faststart` 补存量），起播 Range 往返从 2~3 次降到一次顺序读——详见《媒体预签名直传与播放架构》

### 12.8.1 发帖编辑器 PostEditor 与创建浮层 CreateSheet

- **创建浮层（CreateSheet 与 GroupCreateDialog 同规格，语音/直播/发帖/桌游/建群共用）**：对齐 §12.5 弹层规格——
  - 宽屏：居中浮层，宽 `min(480px, 100%)`、max-height 80vh 内滚，`--glass-bg-strong` + `--glass-filter` + 1px `--glass-border` + 20px 圆角 + `--glass-shadow-modal`；遮罩保持原 `rgba(70,91,146,0.25)`；不支持 backdrop-filter 时使用 `--surface` 实底
  - 窄屏：底部上滑面板——全宽贴底、上沿圆角 24px、左右/下无边框、底部 `safe-area-inset-bottom` 补距，`250ms var(--ease-out)` 上滑入场，`prefers-reduced-motion` 关闭
- **群内发帖输入面板（PostEditor collapsible 变体）**：
  - 外框：宽屏使用原`.55`玻璃、24px blur、亮边/16px完整圆角、8px内沿和12px外沿；左侧12px由频道栏提供，输入不再叠左margin。窄屏沿用聊天composer的全宽布局、18px blur与8/12/12px内沿，安全区仍归shell持有。只有外壳提供padding，内PostEditor清零，避免双重内沿。
  - 字段与工具：原强玻璃字段、亮边与内高光，聚焦保留辉光；compact正文与发布按钮均40px，正文22px行高/上下8px。媒体工具使用同款玻璃、圆角和阴影，扩展内容不改可见性、上传与提交语义。
  - 收起态：单行输入框 + 发布按钮，**点输入框直接展开**（无独立展开按钮）；展开后右上角 32px 圆形玻璃收起钮
  - 展开态：面板容器**脱离文档流贴底**（absolute 覆盖标题栏与列表，二者已被遮罩压暗），可用高度 = 整个群内内容区，窄屏`max-height:100%`、宽屏扣除上下24px外沿；编辑器仍以`min(90vh,1000px)`兜底。可见性/群列表选项区内部滚动，媒体预览横排（128px 方块、超宽横滚）与图片/视频按钮保持原顺序；发布成功自动收起。
  - 上方遮罩：展开时压暗帖子列表与标题栏（`rgba(70,91,146,0.25)`），点击收起。**层级实现约束：遮罩必须与输入面板容器平级（z-index 夹在列表与面板之间，如 45/50），不能作为面板后代用 fixed + 正 z-index——面板容器的堆叠上下文会把遮罩限制在面板内部，反而盖住输入框**
  - 手势隔离：编辑器根元素 touch 事件一律 stopPropagation——图片预览横滑、正文横移光标不触发群内五子界面左右切屏手势；组件级处理，未来一级页面切屏手势同样被隔离（弹层形态天然在路由容器之外，双保险）
  - 展开弹出动画：收起态单行 → 展开态贴底面板的切换用 `group-posts-editor-rise`（`opacity 0→1` + `translateY(20px→0)`，250ms `--ease-out`）入场；上方遮罩同步 200ms 淡入（`group-posts-scrim-in`）；`prefers-reduced-motion` 关闭位移（`animation: none`）
  - 群内发帖可见性锁定（VisibilitySelector `lockGroup`，仅群内发帖路径）：「指定群可见」大类强制勾选且不可取消——复选框 disabled + 保持选中态视觉（`label.is-locked`，不灰化，避免把「已锁定生效」误读成「不可用」）；群搜索/多选列表保留，其中**本群那条**恒勾选、不可取消（`visibility-group-option.is-locked`），其他群仍可多选。公开/好友可与「指定群可见」共存：允许「公开+群可见」或「好友+群可见」，但公开与好友二者之间仍互斥（单选）。提交时后端单值 visibility 映射 public 优先 → friends → group，本群恒在 `allowed_group_ids`（后端 `allowed_groups` 是独立准入维度，与 visibility 组合判定，见 §12.8 与 common/visibility.py）
  - 可见性多选语义（全站 live/voice/post/boardgame 统一）：`public` 与 `friends` **互斥**（单选），`group`（指定群可见）是**独立维度**、可与公开或好友叠加——「公开+群」「好友+群」均合法。归属群 `group` FK 仅作来源标记、**不承载可见性**，群可见性完全由白名单 `allowed_groups` 决定（后端 `visible_queryset`/`can_view`/`scope=group:` 只认 allowed_groups；创建时 services 把归属群兜底落白名单）。
  - 群内锁定规则（`lockGroup`）：帖子/语音/桌游群内创建**强制锁定本群**（大类 disabled + 本群条目 disabled，不可取消）；**直播群内不锁定**——本群自动勾选、但可取消（群内开播跳转到独立开播控制台，是否在本群显示由用户在开播控制台自行决定）。标签显示据此支持「公开/好友」与群名共存（getVisibilityLabels）。
  - **帖子详情编辑面板（PostDetailPage 编辑已有帖子）**：点「编辑」在**帖子页面内**（`.post-detail` 内 `position:absolute; inset:0`，保留顶部导航与底栏，不超出帖子界面）覆盖弹出；顶栏 = 取消（返回箭头）+「编辑帖子」标题 +「重新发布」保存钮，内容列居中（max-width 680px）内部滚动；字段顺序：标题 → 正文 → **图片/视频预览区**（紧贴正文，网格可换行、128px 方块 + 移除钮，`prefers-reduced-motion` 关闭入场）→ 可见性选择器 → 错误提示。媒体**全量替换**：前端维护「已有 + 新增」媒体列表，图片有增删才携带 `images` 字段提交，后端 PATCH 按新顺序重建 `PostImage`（media 校验与发帖同语义：存在/READY/image|video/访问权），被移除的媒体在提交成功后由前端回收（`deleteMedia`）；取消编辑回收未提交的新上传媒体。

### 12.9 搜索框与结果

- 顶栏搜索框（两形态）：胶囊，底 `--surface`、1px `--ice-300` 描边、圆角 999px，左搜索图标 `--text-secondary`；focus 边框转 `--glow-500` + `--glow-shadow`（200ms）
- 宽屏内联下拉结果面板：`--glass-bg-strong` + `--glass-filter` + `--glass-shadow` + 16px 圆角，宽 360px；分组（用户/群聊/直播间/帖子/桌游室）组头 Micro Tag 11px Fredoka `--text-secondary` 大写，每组 ≤3 条 + 「查看更多」
- 窄屏独立搜索页：TopBar 变搜索输入态（自动聚焦）；历史搜索胶囊 chips（`--ice-100` 底 `--text-primary` 字，可清空）
- 搜索提供“全部、用户、群聊、帖子、直播间、语音房、桌游室”七个筛选。全部保留六类分组（用户/群聊/帖子/直播间/语音房/桌游室）和各组独立续页，类型筛选仅显示对应类别。查询、分类、账号共同隔离缓存与滚动位置；切换新分类从顶部开始，返回已浏览分类恢复原位置，旧请求不得落到新分类。
- 当前搜索页通过宽/窄顶栏提交或清空关键词时保留有效分类；从其他页面新发起搜索默认全部。顶栏在搜索页随URL关键词更新，只有分类变化时不覆盖尚未提交的输入。
- 搜索与收藏共用`DirectoryFilters`：>768px为224px左栏，页面12px外沿、筛选与结果之间12px间隔，结果轨道填满余宽；≤768px为结果区上方固定筛选，单行横向滚动（可左右滑动），选中项自动滚入可视区。筛选处于结果滚动容器之外，滚动结果不能带走筛选或上方导航。筛选支持方向键、Home/End、选中态与tabpanel关联，减少动态时直接归位。
- 搜索窄屏顶栏贴顶铺满：`.narrow-topbar` 在 ≤768px 取消外边距、圆角与阴影，仅保留底部分隔线，与筛选条同属方角顶栏；收藏页独立顶栏已移除，窄屏改用 AppShell 收藏态顶栏（返回键 +「我的收藏」标题 + 更多菜单），宽屏由侧栏左上角返回键承担。宽屏侧栏（`.directory-filters`）与窄屏顶栏/筛选条挂载时分别按 `auroraqua-sidebar-in`（左入）与 `auroraqua-panel-from-top`（上入）滑入，`prefers-reduced-motion` 直接归位。
- 搜索所有选项卡在>768px统一两列瀑布：全部按分组瀑布（`columns:2` + `column-gap:24px` + `break-inside:avoid`，组块不跨列、列间高度自然平衡，不留空行），单个类型按卡片瀑布（组内 `columns:2`，卡片不跨列）；≤768px 单列。历史、加载、错误、空状态共用结果轨道。用户结果姓名/签名上下排并可省略；群结果使用36px `Avatar` 展示既有搜索接口返回的群头像，资源为空或失败时使用组件原有回退，不从聊天store补造结果。内部图片仍走鉴权签名路径，群头像公开边界仅限被可发现群完整引用的图片；私聊头像与普通附件保留原权限，详见媒体架构文档。
- 搜索/收藏宽屏侧栏顶部各有一个仅装饰的线性图标（搜索=放大镜，收藏=爱心）：64px、`--pink-500` 低透明度（opacity 0.42）、`-8deg` 倾角、`pointer-events:none`，不作为按钮；选项卡整体随之下移。窄屏隐藏装饰图标，保持单行方角筛选条。
- `/search` 与收藏同样属于面板自编排路由：整页转场外层立即归位，窄屏顶栏/筛选条及宽屏侧栏分别复用 `auroraqua-panel-from-top` / `auroraqua-sidebar-in` 滑入，避免整页位移覆盖内部滑入动画。

### 12.9.1 分类选项卡 DirectoryFilters（6 页面共用）

> 搜索、收藏、语音（/voice）、直播（/live）、帖子（/posts）、桌游（/games）六个一级页面共用同一 `DirectoryFilters` 组件与 `directory-filters.css` 布局（2026-09-09 起覆盖 6 页面）。组件零改动复用，页面只传参。

- **布局**：页面根元素加 `directory-page` 类（`height:100% + overflow:hidden + flex column`），内包 `directory-body`（`flex:1 1 0` 横排，gap 12px）。宽屏左侧 224px 玻璃侧栏（`auroraqua-sidebar-in` 从左滑入）；窄屏（≤768px）转为顶部水平选项卡（`auroraqua-panel-from-top` 从顶滑入，`flex:none` 固定不随内容滚动，`touch-action: pan-x` 横向滑动，选项卡多时可横滑）。
- **滚动容器迁移（窄屏顶栏固定的前提）**：滚动必须由 `.directory-content`（`overflow-y:auto`）持有；页面根元素不得残留 `overflow-y:auto`（否则双层滚动或顶栏跟随滚动）。各页面的 onScroll（分页加载/滚动恢复）、`useScrollRestore`、`useListEntryMotion`、下拉刷新 `isAtTop` 全部挂到 `.directory-content`。窄屏内容区 `padding-bottom: calc(68px + env(safe-area-inset-bottom))` 避让 FAB。
- **内容区**：`.directory-content` 占满侧栏右侧（`flex:1 1 0`），内部网格/瀑布流列数断点与卡片样式保持各页面原样，只去掉原 max-width 居中容器（语音/直播/桌游 1200px、帖子 680px）；列表左右 padding 归零由内容区统一提供，宽屏首卡顶边与侧栏顶边对齐。
- **装饰与标题（宽屏侧栏，窄屏隐藏）**：decor 图标 64px、`--pink-500`、opacity 0.42、rotate -8deg、`pointer-events:none`——搜索 IconSearch / 收藏 IconHeart / 语音 IconMic / 直播 IconVideo / 帖子 IconPost / 桌游 IconGame；下方 header = kicker（10px Fredoka 粉色大写）+ 标题（17px Fredoka 700）+ 统计行（12px Space Grotesk `--text-secondary`）。统计：语音「X 房间在线 · Y 人在聊」（directory.total / totalMemberCount）、直播「X 直播间 · Y 在播」（total + 已加载在播数）、帖子「X 条帖子」（已加载数）、桌游「X 个房间」（total）；拿不到统计只放 kicker + 标题。
- **选项卡与过滤（全部前端实现，分页加载后过滤够用）**：
  - 语音：全部 / 公开 / 好友 / 有人（member_count>0）/ 我的（owner_id=当前用户）
  - 直播：全部 / 在播（status=live）/ 公开 / 好友 / 停播（status≠live）/ 我的（is_owner）
  - 帖子：全部 / 热门（view_count 降序，唯一排序例外）/ 公开 / 好友 / 我的（is_author）
  - 桌游：全部 / 公开 / 好友 / 我的（is_owner）/ 等待中（status=waiting）/ 对局中（status=playing）
  - **好友 tab = 作者是好友**（friendIds 集合，`useSocialPage("friends")` 加载），不是 visibility=friends 才显示——好友发布的 public/friends 内容都归入该类
  - 排序除帖子热门外全部保持原页面排序（语音有人区优先+last_occupied_at、直播在播优先+started_at、桌游 created_at 倒序、帖子 feed 原顺序）
- **每 tab 独立加载（2026-09-09 用户反馈修正）**：filter 进 directory key（语音/直播/桌游），每个 tab 独立游标/分页，切 tab 自动拉取该 tab 第一页（有加载态），滚到底加载该 tab 的下一页；**过滤参数由后端执行**（`apply_catalog_filters`，common/visibility.py）：`?visibility=public|friends|group`（公开）、`?friends=1`（作者是我的好友，含 public/friends）、`?status=live|idle|ended|offline`（直播在播/停播，offline=status≠live）、`?status=waiting|playing|ended`（桌游等待中/对局中）、`?occupied=1`（语音有人，member_count>0）、`?owner=<id>`（我的）——每个 tab 拉到的就是该 tab 过滤后的数据，**不依赖「全部」分页进度**（全部页没加载到该分类的分页时，切 tab 也能主动加载出来）；帖子页每 tab 独立缓存（模块级 Map，账号切换清空），「我的」拉 scope=mine，公开/好友由后端过滤，热门/全部拉 feed 后前端排序/过滤（热门只排序不筛内容，无"加载不到"问题）。切回已加载 tab 缓存命中（60s 内不重拉）。
- **状态保持**：选项卡切换用 URL search 参数（?type=xxx，与收藏/搜索一致），支持返回/刷新保持；各 tab 独立滚动位置（`useScrollRestore`，scope 含 filter）；切换时内容区重挂载（key=scope）走 `directory-content-in` 淡入上移动画（300ms，reduced-motion 关闭）。
- **无返回键**：六个页面均不传 `leading`（窄屏由 AppShell 顶栏承担返回语义）。
- **过滤空态**：非「全部」tab 过滤后为空时显示分类空态（「这个分类还没有…」+ 换分类引导）；「全部」tab 空态保持各页面原文案。

### 12.10 语音房卡片与语音房

- 语音房卡片：§4 统一玻璃卡片，群内外共用；房间名 Nunito 700 15px + 房主 13px `--text-secondary` + 在麦人数（麦克风图标 + Space Grotesk 12px）+ 成员头像堆叠（≤5 个 28px 圆形重叠 -8px，带光环）+ 来源标识 Micro Tag
- 语音房（进入后）：成员网格（头像 64px 带光环 + 麦克风状态角标——开麦 `--glow-500` / 闭麦 `--ice-300`）；底部控制排（静音/扬声器/上麦/离开，48px 圆形玻璃钮，离开为 `--destructive`）+ 输入框（房内打字）
- 桌面语音成员/聊天双卡按房间实际余宽布局：两列至少各320px，聊天列最多380px/45%；内容宽度<656px时沿原DOM顺序改为上下等分，分别保留内部滚动。最小宽度需包含成员音量控件、昵称/状态和聊天输入的真实可读空间；窄屏成员卡与底部聊天浮层仍按原结构。
- 上麦按钮：主 CTA 胶囊（`--indigo-700` 实底白字）
- 语音成员行的「行尾操作区」（`.voice-member-actions`，**所有成员行同一水平线、上下等距**）：开关按钮 + 音量条（自己麦克风与远端成员**同一样式** VoiceVolumeMeter，90px 行内对齐）。开关按钮 `.voice-meter-toggle`（28px 圆形无底，hover 浅冰底；`is-off` 禁音/静音态灰 + 斜线图标）——自己行 = 麦克风按钮（lucide mic/mic-off，一键禁音/一键恢复，媒体层 toggleMic）；远端行 = 喇叭按钮（lucide volume-2/volume-x，一键静音/一键恢复，本地播放 `locallyMuted`，不改变 volume 设定值）。
- 音量条（VoiceVolumeMeter）：**三层结构**（下→上）——
  1. 底层轨道 `.voice-meter-track`：**双色填充**（滑块左边 `--indigo-700` = 设定音量、右边 `rgba(ice-300,0.55)` 浅色；`--fill` 内联变量随设定值）→ "滑块左边始终有颜色"；
  2. 中层跳动条 `.voice-meter-fill`：`--glow-500 → --ice-500` 渐变、高 4px、圆角，宽度随实时说话音量左右伸缩跳动（静音 0、说话伸长，说话态加微辉光），**覆盖在轨道上方**；
  3. 上层 slider：轨道透明（不遮跳动条）+ `--indigo-700` 白边圆把手。
  - 自己条目：设定 = 本地麦克风音量 0~100（100 = 原始，改变自己说话别人听到的响度），跳动随 `localAudioLevel`（本地 Web Audio 分析）；本地偏好不落库、刷新重置。
  - 远端条目：设定 = 本地播放音量 0~100（本地偏好，不落库），跳动随**本地 Web Audio 分析远端轨道**（与本地同机制，rAF 帧驱动 + 100ms 节流；不依赖 server speaker update，响应快）——说话即见跳动，可辨识"谁在说话"；无本地开麦且无远端音频轨道时帧循环完全停止（零开销，任务 08）。

### 12.11 桌游室卡片

- §4 统一玻璃卡片 2 列网格；封面占位图（`--ice-100` 底 + 游戏线性图标 `--ice-500` 48px）圆角 12px + 房间名 Nunito 700 15px + 状态 tag（等待中 `--ice-300` 底 / 对局中 `--sakura-300` 底 `--grape-700` 字，Micro Tag 胶囊）+ 人数 Space Grotesk 12px

### 12.12 手势与场景动画（窄屏）

> 实现状态表（M1–M6c 收尾）：以下已落地项均保留可见按钮/键盘等等效路径；手势不是唯一操作方式。三个可切页 pager 的松手判定统一使用 `useSwipeCommit`，而私信边缘返回与下拉刷新保留各自更符合语义的边界状态机。

| 交互 | 实现与范围 | 状态 | 松手 / 让位语义 |
|---|---|---|---|
| 一级五页横滑 | `PrimaryNavPage`；窄屏 `/voice → /live → /group → /posts → /games` | ✓ 已落地 | `resolveSwipeCommit`：净位移 ≥ 容器 1/3，或同向甩动速度 ≥300px/s 且净位移 ≥40px；交叉轴 ≥ 主轴时让位 |
| 群内五场景横滑 | `GroupPage`；窄屏群内 chat/voice/live/posts/games | ✓ 已落地 | 同上；`dragElastic=0.8` 跟手与边缘阻尼；横轴守卫抢在浏览器接管前保护横拖，垂直滚动让位 |
| 直播间上下滑切换 | `LiveRoomBody`；群内外窄屏普通观看 | ✓ 已落地 | 同上，主轴改为 y；视频 + 弹幕区整体滑动，顶栏与输入框固定；端头只回弹不切换，保持单真实播放器 |
| 图片查看器横滑 | `ImageViewer`；多媒体条目 | ✓ 已落地 | 同样使用 `useSwipeCommit`：净位移 ≥容器 1/3，或同向甩动 ≥300px/s 且 ≥40px；交叉轴让位、`pointercancel` 只回弹；左右按钮与键盘为等效路径，单条目不切图并保留关闭语义 |
| 私信左边缘右滑返回 | `/chat/:id` 窄屏，起手边界 24px | ✓ 已落地 | `resolveEdgeSwipe`：净位移 ≥120px 或速度 ≥0.3px/ms；否则 200ms 回弹；非边缘与垂直手势让位 |
| 下拉返回主页 | 群场景窄屏 | ✓ 已落地 | `useSwipe` 方向锁 + 80px 阈值；顶部导航与内容协同跟手，未达阈值回弹 |
| 下拉刷新 | 列表顶部（主页/消息/帖子/直播/语音/桌游及群内已接入页） | ✓ 已落地 | `PullToRefresh` 独立状态机；原始下拉 ≥64px 触发，视觉位移阻尼，刷新停留 52px |

- **统一 pager 松手契约**：`resolveSwipeCommit({ net, cross, velocity, size })` 使用 framer-motion `PanInfo.velocity` 的 **px/s** 单位；主判定为净位移 ≥ `size / 3`，补充判定为同向甩动（速度 ≥300px/s、净位移 ≥40px、速度与位移同向），交叉轴净位移 ≥ 主轴时方向锁让位；划回原位不切换。调用处过滤 `pointercancel`（系统取消不等于用户松手），横向 pager 另用 `useTouchAxisGuard` 避免浏览器提前接管。
- 进群动画：窄屏导航以独立`translate`从`0 calc(100dvh - 64px - env(safe-area-inset-bottom, 0px))`滑到`0 0`，300ms easeOut、opacity始终1；原跟手transform继续独立。群消息从右进入，输入从下20px/300ms进入，不为输入叠加100%滑动或100ms延迟。中央槽位的主页/群头像切换保持原导航语义；场景内容由自身分区进入，真实横滑与回退手势仍由原轨道持有。
- 进直播间/语音房/帖子详情：shell继续管理底部导航下滑离场状态；顶部栏从上20px、底部输入或语音底部聊天卡从下20px进入，统一300ms。各分区拥有自己的进入动画，旧房内输入100%位移/250ms/延迟100ms不再与新分区叠加；宽屏语音聊天从右，具体响应式方向见§7。
- 下拉回主页：跟手位移 + 阈值 80px，回弹 200ms ease-out；群页内容与顶栏共同移动，退出时内容滑出后再回主页
- 直播间上下滑现行配方：视频与弹幕区作为唯一滑动单元，`translateY` 跟手 + 300ms / 20px Auroraqua 方向转场；顶栏与输入框固定，切换后再更新标题/主播；不常挂多个真实播放器

### 12.13 增量场景 Agent Prompt 速查

- 「做底部五 tab：玻璃底 blur 18px 高 64px，语音/直播/帖子/桌游为 24px 线性图标 + 11px Fredoka，主页居中圆形背板 48px 上浮 8px 带 --glow-shadow，未读 --pink-500 徽标」
- 「做宽屏 TopNav：原玻璃底高 64px，四向亮边和16px圆角，12px外沿；一级模块沿用字体，当前模块用 Auroraqua 300ms 移动胶囊，配色只取既有 ice；搜索 focus 保留原色」
- 「做服务器栏：72px 玻璃列，48px 群头像带光环，当前群左 3px #F796FF 指示条，角标 16px 圆底（未读 #F17EB3 / 直播 #F796FF / 语音 #9DBFE6 / 桌游 #F9B0FF）」
- 「做频道侧栏场景项：行高 40px 圆角 12px，左 20px 线性图标 + Nunito 600 15px，选中底 rgba(157,191,230,0.35)，右侧在麦人数 Space Grotesk 12px 或 LIVE #F17EB3 徽标」
- 「做直播间卡片：16:9 封面圆角 12px，左上 LIVE #F17EB3 白字胶囊，标题 Nunito 700 15px #465B92，来源 Micro Tag #F9B0FF 底 #722E88 字」
- 「做帖子卡：--glass-bg + --glass-filter + --glass-shadow 圆角 16px，头像 36px 带光环 + Nunito 700 昵称 + Space Grotesk 12px 时间，正文 15px 超 3 行折叠，底排评论/收藏 18px 线性图标」

### 12.14 会话列表项与会话管理菜单（M5 消息中心）

> 用于 /messages 与 /chat/:id 的会话列表（ConversationList）。在线状态双通道原则（§10）保持：光环 + 名字行文字标签。

- **名字行**：昵称 Nunito 700 15px `--text-primary`（一行省略）+ 紧随其后在线状态胶囊——`is-online` 时 `--success` 字 + 6px 圆点，离线 `--text-secondary`；底 `rgba(157,191,230,0.16)`，圆角 999px，11px/700，padding 1px 8px
- **预览行**：最新一条消息摘要 Nunito 400 13px `--text-secondary` 一行省略（替代原「在线/离线」文字）；群聊预览带 `发送者名: 内容`，媒体消息占位 `[图片]/[语音]/[表情]`，**文件消息显示文件名**（`content` 即文件名，非 `[文件]` 占位），已撤回 `[已撤回]`，无消息 `暂无消息`
- **⋯ 更多按钮**：行右侧绝对定位（`right:6px` 垂直居中），40×40px 圆形触达区（§10 ≥40px），三点线性 SVG 18px `#a9b8d4`；hover/展开态底 `rgba(157,191,230,0.25)`、图标转 `--text-primary`；行内 padding-right 52px 给按钮让位
- **弹出菜单**（`.conv-menu`）：绝对定位**向上展开**（`bottom: calc(100% - 2px)`，避免被列表滚动容器 `overflow-y:auto` 裁剪），右对齐；层级 `z-index: 60`——高于底栏/顶栏/侧栏（20–50），低于弹层遮罩（70+），保证不被固定栏遮挡；`--glass-bg-strong` + `--glass-filter` + 16px 圆角 + `--glass-border` + `--glass-shadow`；菜单项行高 40px 圆角 10px Nunito 600 14px，hover 底 `rgba(157,191,230,0.22)`，危险项（删除）`--destructive` 字 + hover 底 `rgba(224,100,100,0.12)`
- **置顶会话视觉标识**（`.conv-item.is-pinned`）：左侧 3px `--glow-500` 圆角指示条（同 ServerRail 指示条语言，装饰不承载信息）+ 非选中态淡 sakura 粉底 `rgba(249,176,255,0.1)`（hover 0.16）+ 标题转 `--grape-700`（对比度 ≈6:1 达标）；选中态（active）背景保持 ice 蓝胶囊、标题仍 grape
- 置顶会话排列表最前（置顶组/非置顶组内保持原顺序）；删除为软删除（仅隐藏本人列表，消息保留），confirm 确认后执行

**消息中心红点实时刷新**（M5）：红点以 `GET /me/badges/` 聚合为权威，由 ChatWS 事件驱动 `fetch` 实时刷新（任务 08 后**无周期轮询**：AppShell 原 30s 降级轮询已删除，WS 重连成功后补拉一次对账）。三处红点统一：

- 消息入口聚合红点（宽屏 TopNav 消息项 / 窄屏左下 MessageFAB）= 私信未读 + 好友申请 + 群邀请 + 待审批入群申请，`--pink-500` 徽标，>99 显示 99+；
- 认证消息 tab 红点（窄屏 MessagesPage / 宽屏 WideMessagesSidebar）= 好友申请 + 群邀请 + 待审批入群申请（不含私信未读；私信未读属会话列表行内 `conv-unread` 徽标）；
- 会话行内未读徽标（ConversationList `conv-unread`）= 该会话 `unread_count`，实时由 `message.new` → bumpUnread 增量，打开会话标已读后清零。
- WS 事件 → 红点刷新：私信 `message.new` / `elysia.reply` → `private_unread`；`friend.request.new` / `friend.request.resolved` → `friend_requests`；`group.invite.new` → `group_invites`；`group.request.new` / `group.request.resolved` → `join_requests_pending`；群消息 `@我`（message.new 带 mention 段）→ `mention_unread`。好友申请事件（`friend.request.*`）由 accounts 视图经用户级组 `chat_user_<id>` 广播，ChatConsumer 转发；普通群未读不进消息中心红点（属群卡片/ServerRail 角标）。

### 12.15 红点快捷消息栏（R-QM，窄屏非导航页）

> 窄屏左下角「私信按钮」显示策略（需求 R-QM）：**打断式跳转 → 就地弹层**，减少对当前上下文（直播间/语音房/帖子详情/群聊等）的打断。

- **三态显示规则**（`AppShell` 读 `isPrimaryNavRoute`）：
  - 五个一级导航页（`/group` `/voice` `/live` `/posts` `/games`，含 `/home` 兼容）：常态显示 `MessageFAB`，点击跳 `/messages`；
  - `/messages` 页：左下角为「返回主页」`MessageFAB`（`backHome` 变体，历史需求保留）；
  - `/chat/:id` 私聊窗口：不渲染左下角按钮（底部有聊天输入框，壳层不出 chrome）；
  - **其余页面**（群聊场景 `/group/:id`、直播间、语音房、帖子详情、搜索、个人、收藏、用户页等）：**仅当红点 > 0** 时显示 `QuickMessageFAB`（无红点不显示）。
- **QuickMessageFAB**（复用 `.message-fab` 外观 + `.quick-message-fab` 修饰）：与 MessageFAB 同位置（`left:16px; bottom:底栏高+12px`，位置天然避让沉浸页底部输入框）；出现后 **4s 无点击 → 侧边半贴**（`translateX(-44px)`，仅露 28px 右半，200ms `--ease-out`），半贴态点击「点出来」展开，展开态点击**就地弹出快捷消息栏**（不跳路由）；`prefers-reduced-motion` 关闭位移过渡。
- **快捷消息栏**（`.quick-messages-overlay`，`z-index:70`）：底部滑入 **70% 高度**面板（`translateY(100%→0)` 250ms `--ease-out`）+ 上方 **30% 遮罩**（`rgba(70,91,146,0.25)`，点击关闭）；面板 `--glass-bg-strong` + `--glass-filter` + `--glass-shadow-modal` + 上沿圆角24px；ESC 关闭。**开关存 shell store（`quickMessagesOpen`），由 AppShell 独立渲染，只随手动关闭（遮罩/ESC/关闭钮）卸载——打开会话标已读导致红点归零时，QuickMessageFAB 会卸载，但快捷栏保持打开（R-QM 修复）**。
- **两个选项卡**（复用 `.messages-tab`）：私信 / 认证消息。栏内**所有操作不跳转新页面、头像一律不可点**（`disableAvatarNav`）：
  - 私信 tab：爱莉入口 + 会话列表（`ConversationList`），点会话**内联**打开 `PrivateChatPane`（不跳 `/chat/:id`），返回按钮回到列表；
  - 认证消息 tab：与 `/messages` 认证消息 tab 同构（退群通知 / 好友申请 / 群邀请 / 入群申请 + 同意/拒绝），实时刷新同 §12.14。

### 12.16 图文混排消息与乐观发送（M7）

> 聊天消息发送重构：发送不阻塞输入（乐观气泡 + 左上角状态）；图片/视频多选进输入区缩略图条，点发送统一上传；支持粘贴；混排气泡文本与媒体段流式排列；查看器支持同消息多图/视频切换。会话列表/引用/群活跃度的混排摘要由后端 `preview` 统一生成（「文本文本[视频]文本[图片]」形态）。

- **输入区缩略图条**（`.composer-picked`，`role=group aria-label=待发送媒体`）：输入框上方横向 flex wrap，`gap 8px`；缩略 44×44px（视频 58px 宽）`--radius-sm` 圆角 + 1px `--glass-border` + `--glass-bg` 底，`object-fit: cover` 预览本地 objectURL（**未上传**）；视频叠加 18px 玻璃播放徽标；右上 `-5px` 处 18px 圆形移除钮（hover 转 `--destructive` 白字）。**小尺寸不挤压输入框**；移除即 revoke objectURL。
- **混排气泡**（`.mixed-flow`）：flex wrap + `gap 8px`；文本段 `.mixed-text` 流式排列（`max-width:100%`，`white-space:pre-wrap`）；媒体段 `.mixed-img` 180×180px 方块（`--radius-input` 圆角、`cover` 裁剪、`cursor:zoom-in`）多图自动换行成网格；视频段复用 `.media-frame-video` 海报帧封面+播放徽标（有 thumbnail 渲染签名缩略图 `<img>`，无海报降级首帧预览；与 §12.8 秒开策略同一事实）（240px 宽 4:3）。乐观消息（未上传）媒体段用本地 objectURL 渲染，无 descriptor 不报错。
- **乐观发送状态**（`.msg-send-state`，仅自己的气泡）：与气泡同一行、位于气泡左侧垂直居中（`position:absolute; right:calc(100%+8px); top:50%` 反向偏移）——上传中显示 `.msg-send-progress`「上传中 n%」（`--text-secondary` 12px）+ 玻璃小按钮「取消」；纯文本发送中为 14px indigo 旋转 spinner（`prefers-reduced-motion` 停止旋转）；失败态 `--destructive`「发送失败」+ 玻璃小按钮「重试/删除」（复用 `.msg-action-btn`，11px 图标+文字，hover `--glow-shadow`）。重试复用同一幂等键重新上传发送。
- **查看器多图切换**（`ImageViewer`）：同消息的 image/video 段合成条目列表，`←/→` 键或左右玻璃圆形 nav 钮（44px，`--glass-bg-strong` blur 12px，`top:50%` 垂直居中，disabled 时 opacity 0.35）切换；底部玻璃胶囊加计数 `1/2`（`--font-utility` 12px `--text-secondary`）；对话框 `aria-label="图片查看：n/总数"`（单图为 `图片查看：<alt>`）。本地乐观预览（未上传）只展示、保存钮显示「发送后可保存」。
- **会话列表/引用/活跃度摘要**：混排消息按段生成占位（text 拼原文、image→`[图片]`、video→`[视频]`），与单媒体 `[图片]` 占位及撤回 `[已撤回]` 共用同一预览语义；后端 `last_message.preview` 为权威，WS `message.new` 后前端按 segments 兜底生成。

### 12.17 大文件流式上传与取消（M7.1）

> 上传链路对齐 QQ/微信语义「临时存储 + 进度条 + 可取消」：文件先传服务端临时存储（三步上传会话），传完才真正发消息；全程有进度、可中止；大文件不整块驻留内存。

- **流式写入（防 OOM 卡死）**：后端 `PUT /media/uploads/{id}` 改为 `request.stream` 按 1 MiB 分块读入临时文件（边读边校验累计大小，超限立即 413 中断），再经 `ObjectStorage.put_stream`（S3 `upload_fileobj` 分块上传）落对象存储——1GB+ 文件不再整体读入内存（旧实现 `request.body` 整块 bytes 曾导致进程 OOM、页面报错）。
- **进度与取消**：前端二进制段改 XHR（`upload.onprogress` 实时字节进度；fetch 无上传进度）；`AbortSignal` 中断 → `xhr.abort()` 并 fire-and-forget 调幂等 `DELETE /media/uploads/{id}` 清理临时对象与会话（非本人 403，重复调用 204）。多文件并发上传时按真实字节数聚合为单一百分比（封顶 99%，保留 100 给发送阶段）写入 store，气泡左侧显示进度与取消钮。
- **本地预览生命周期**：乐观气泡的 objectURL 由渲染组件在卸载时统一 revoke（`useEffect` 空 deps cleanup）；发送/重试成功路径**不提前 revoke**（避免替换渲染前的竞态空白图）；重试因旧气泡卸载 revoke 而重新 `createObjectURL`。
- **取消语义**：取消 = 放弃该次发送（abort 上传 + 删除乐观气泡 + 服务端清理），与失败态（保留气泡可重试/删除）区分。
- 气泡图片用 320px 缩略图（GIF 例外走原图保动图），点击进查看器才加载原图；查看器以 createPortal 挂 body（防祖先毛玻璃困住 fixed 弹窗）。上传直传/播放直连/权限等非视觉实现见 `docs/媒体预签名直传与播放架构-2026-08-24.md`。

### 12.18 帖子流双列瀑布流（>1024px）

- 群外帖子流、群内帖子、我的帖子共用同一布局契约：`>1024px`（即最小 1025px）启用两列等宽瀑布流，内容轨道最大宽度 1200px，列间距与卡片纵向间距使用 `--sp-3`；≤1024px 回到单列，窄屏内容不产生横向滚动。
- 新卡片优先插入当前较矮列；列高由 `ResizeObserver` 观测，无法立即测量时使用有限的预估增量保证同批卡片交错。一次分配完成后锁定 item→列关系，且记忆键必须包含列表身份与列数，避免断点切换/HMR 把所有卡片留在同一列。
- `.reveal-item` 只挂在卡片外层，卡片本体保留 hover/focus 的轻微上浮；滚动恢复命中时按 §7.1 禁止 stagger。列表加载提示跨两列排列。

### 12.18.1 收藏列表

- 收藏筛选按§12.9使用宽屏左栏/窄屏固定顶部，保留全部、消息、帖子、直播间、语音房、桌游室六类（群聊已不再支持收藏，分类与入口一并移除）。结果区是独立滚动容器，分类切换与详情返回保存该容器的位置。>768px所有分类统一使用与帖子相同的`useMasonryColumns`和两条flex列，列间距12px；≤768px单列。结果填满可用余宽，不再限制1200px并居中留白。
- 新卡按当前较矮列优先分配，收藏id到列的关系保持稳定；分配记忆按用户、分类与列数隔离。尚未量高的同批卡片沿用帖子hook的320px预估增量交错分配，量高后仅影响后续新卡，不因高度变化重排既有卡。API数组不排序，列内保留源顺序；宽屏原生键盘顺序沿每列从上至下、再到右列，与帖子一致，不添加正tabindex。窄屏恢复完整API顺序。列容器不裁剪卡片阴影或菜单；列表组件在数据就绪后挂载，共享hook通过动态ref观察/解除观察真实列，覆盖loading后迟挂载、断点变化与重挂载，并在卸载断开observer。
- 分类切换后，当前分类响应确认前只展示骨架（`loading || settledFilter !== filter`），不能在effect置pending之前把上一分类结果挂到新分类的分列记忆中。
- 每张收藏卡保留类别、目标标题与取消按钮，宽屏帖子摘要最多显示3行；只改变展示布局，不改变收藏过滤、顺序、目标跳转、取消或实时更新的契约。
- **收藏消息卡片**（`.typed-message-card`）：头部为发送者昵称（`--text-secondary` 13px + `IconMessage` 18px），下方为消息内容。媒体消息（图片/语音/文件/表情/图文混排）复用聊天 `MediaContent` 真实渲染（§4 Chat Bubbles 同款媒体样式：图片缩略图+查看器、语音波形+播放、文件下载、mixed 图文段），媒体本体独占一行（`.typed-message-media`，`flex-basis:100%`）。**整卡可点**（`.is-openable` cursor:pointer）：点击头部/文本/空白区域跳转到原消息位置（`/chat/:id?msg=&seq=&subgroup=`，群聊经路由重定向保留参数，定位后复用 `mention-jump-highlight` 粉框辉光）；媒体区（`.typed-message-media` cursor:default）与取消收藏按钮自带交互并 stopPropagation，点击不触发跳转。撤回消息显示「该消息已撤回」弱化占位（`.typed-message-recalled`，ice 底 + `--text-secondary`），不渲染媒体；戳一戳消息显示「戳一戳消息」占位。

### 12.19 下拉刷新 PullToRefresh

- 适用于列表顶部且滚动容器已在顶端的窄屏场景；状态机为 `idle → pulling → refreshing → done → idle`，不足阈值回弹，刷新完成短暂停留后收起。
- 指示器是玻璃圆点：`--glass-bg-strong` + blur(18px) + `--glass-border` + `--glass-inset`，跟随内容顶部以 `--ease-out` 位移；`pulling` 显示下拉箭头，`refreshing` 显示 spinner，`done` 显示勾号，三态均须有可观察的非颜色语义。
- 手指原始下拉达到 64px 才触发刷新；视觉位移使用递增阻尼 `96 × (1 − e^(-dy / 90))`，刷新停留位移 52px，指示器/内容位移不能改变列表的文档流高度。`prefers-reduced-motion` 下跳过位移，只保留状态反馈。
- 刷新与桌面 RefreshFAB 共用页面回调；主动刷新后通过列表容器重挂载重播 `.reveal-item`，不依赖数据是否变化。下拉刷新不覆盖浏览器原生边缘返回/系统手势。

### 12.20 滚动恢复 `useScrollRestore`

- 接入范围：全站帖子流、群内帖子、直播列表、我的帖子；每个列表以稳定 key 隔离滚动位置、用户身份与必要的分页/列分配投影，不能跨列表或跨账号复用。
- 详情入口在列表 DOM 仍存在时先保存真实 `scrollTop`；返回时在内容已就绪后由 `useLayoutEffect` 恢复，并在下一帧补写一次，以覆盖瀑布流/异步图片造成的高度晚落定。退出 cleanup 只卸载监听，不重新读取可能已被转场归零的 DOM。
- `restoring` 是可观察的恢复状态（包括显式保存的 0 位）；命中恢复时先稳定内容高度与位置，按 §7.1 禁止 `.reveal-item`/stagger。用户主动刷新清除本次恢复抑制并重新播放列表入场反馈。
- 返回必须保留已加载分页与列分配连续性；加载失败不得伪装成空列表或把滚动记忆跳到当前尾部。

### 12.21 文件消息（聊天传文件）

> 群聊/私信新增 `type=file` 单文件消息：任意格式、单个文件，气泡显示文件名+大小+下载，列表预览显示文件名。上传入口是与图片/语音并列的「文件」按钮。

- **上传入口**（`.composer-tool-btn`，`aria-label=发送文件`）：composer 工具区、图片按钮右侧；40×40px 圆钮（§12.16 同款），`IconFile` 18px；内嵌 `<input type="file">` **不设 `accept`（任意格式）、不设 `multiple`（单文件）**。
- **单文件互斥**：文件与图片/视频不能混排（`file` 是单媒体消息契约，不走 mixed 段）。选择文件会清空已选图片/视频，反之亦然；一次只能一个文件。
- **待发送队列文件项**（`.picked-thumb[data-kind=file]` → `.picked-file`）：宽条形态（`min-width:120px; max-width:180px`），`IconFile` 16px + 文件名 12px/600 一行省略；无缩略图、不建 objectURL。右上移除钮与其他媒体项一致。
- **文件气泡**（`.file-card`，§4 已有）：`IconFile` 40px 圆角底（`--ice-100` / `--indigo-700`）+ 文件名 14px/600 一行省略（`title` 全文）+ 大小 12px `--text-secondary` + 右侧 36px 下载圆钮（`<a download>` 签名 URL 原生下载，`aria-label=下载 <文件名>`）。
- **乐观文件消息**（descriptor 未就绪、上传中/失败）：复用 `.file-card` 显示本地文件名+大小（无下载钮）；上传进度/取消/失败重试/删除由 `MessageBubble` 外层 `.msg-send-state` 承接（§12.16）。服务端确认后原地替换为带 descriptor 的文件气泡。
- **列表预览**：`file` 消息 preview = 文件名（后端 `message_preview` 对 `TYPE_FILE` 取 `content`，非 `[文件]` 占位）；群聊带 `发送者名: 文件名`。WS `message.new` 与 REST 会话列表同契约。

### 12.22 个人页右侧内容卡片（重构版）

> 个人主页（/profile）与他人主页（/user/:id）右侧内容区共用 `ProfileContentSections`。重构后**不再折叠**，按固定顺序展示完整卡片；外层 `.profile-mine` 是透明 wrapper（design.md §4 单材料 owner），每类内容一张独立玻璃卡 `.profile-content-card`，不叠卡片。

- **顺序与数量**：① 正在直播的直播间（最多 1 个）→ ② 正在语音的语音房（最多 1 个）→ ③ 帖子（最多 3 条 +「更多帖子」按钮）→ ④ 正在玩的桌游（占位，玩法未实现）。
- **直播/语音并排**：两者同时存在时包在 `.profile-media-row`（flex row，子卡 `flex:1 1 0` 平均分配宽度）；只有一个时占满整行；≤768px 退回单列。
- **数据来源**：直播/语音用 `owner.is_live + live_room_id` / `owner.is_in_voice + voice_room_id` 拉频道详情（`getLiveChannel`/`getVoiceChannel`，走 can_view 过滤，403 静默不展示）；帖子 mine 走 `scope=mine`、他人走 `?owner=<id>`（后端要求对方开启 show_content）。mine 时 owner 为 auth store 的 currentUser（is_live/is_in_voice 由 WS 实时更新）。
- **卡片结构**：`.profile-content-card` = 玻璃卡（§4 材料）+ `.profile-content-head`（图标 + 标题 + 尾部徽标）；直播卡 LIVE 徽标 `--pink-500` 白字胶囊 + 封面缩略图（88×50 圆角 12px，无封面用 `--ice-100` 底视频图标占位）；语音卡在麦人数 Space Grotesk 12px；帖子卡 3 行（标题 + 摘要/时间）+ ghost「更多帖子」按钮。
- **更多帖子跳转**：mine → `/posts/mine`；他人 → `/user/:id/posts`（路由守卫见下）。
- **收藏入口**：个人主页的「我的收藏」移到左侧资料卡（`.profile-avatar-actions` 内、更换头像按钮右侧），ghost 按钮 + `IconHeart` 爱心图标（`--pink-500`），不再放右侧内容区头部。
- **他人帖子界面路由守卫**：`/user/:id/posts` 由 `UserPostsRoute` 守卫——`getUserDetail` 确认对方 `show_content` 开启才渲染 `MyPostsPage`（owner 模式，标题「xx的帖子」）；未开启显示提示页（「对方未开启内容展示」+ 返回），不渲染帖子内容。后端 posts/live/boardgame 的 `?owner=` 过滤同步要求 `owner__show_content=True`（权限边界，防止绕过前端直调 API）。

---

> 本文件是 `Ayla/web/` 视觉唯一事实源。新增组件先看 §4 / §12 有没有配方；没有就按 §2/§3/§5 的 token 与刻度推导，推导不出来再改本文件——不要在组件里散落裸 hex。
