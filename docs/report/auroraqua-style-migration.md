# Auroraqua 卡片、侧栏与交互样式迁移

## 需求与来源

2026-09-07，用户要求参考 Auroraqua-UI 的卡片、侧栏和切换效果，随后明确两项验收边界：保留 Ayla 既有配色；按钮悬停/按下、卡片悬停、选项卡样式及内容切换均应采用参考项目可复用的交互形式。截图不能代替源码研究。用户进一步指出宽屏输入框与悬浮侧栏割裂，因此本次将宽屏输入外壳一起迁移为独立玻璃面板。

初始讨论曾把截图中的粉桃紫背景当成迁移目标，这一理解已纠正：本次没有替换背景、流体光斑、品牌、字体、消息身份色或在线光环。新增阴影和选中胶囊只使用 Ayla 现有 RGB。

上游仓库：[micromimo/Auroraqua-UI](https://github.com/micromimo/Auroraqua-UI)，只读核验 revision 为 `087bffc51b3c83b6214c2b3cec5c9899aaed6b2e`。实际检查了下列代码：

| 源文件 | 确认的实际配方 | Ayla 适配 |
| --- | --- | --- |
| [src/index.css](https://github.com/micromimo/Auroraqua-UI/blob/087bffc51b3c83b6214c2b3cec5c9899aaed6b2e/src/index.css) | liquid-glass 的 blur 24px、8/32 外阴影、顶沿内高光；glass-hover 的 -2px 与 12/40 阴影 | 原玻璃底 .55/.78、白边 .65、saturate(1.4) 不变；阴影 RGB 映射为 70,91,146 |
| [GlassCard.jsx](https://github.com/micromimo/Auroraqua-UI/blob/087bffc51b3c83b6214c2b3cec5c9899aaed6b2e/src/components/ui/GlassCard.jsx) | 默认卡片 16px 圆角、300ms 过渡；默认不倾斜/不抬升 | 静态信息卡保持位置，可点击的群/帖子/直播/语音/桌游列表卡采用独立 hover 配方 |
| [GlassButton.jsx](https://github.com/micromimo/Auroraqua-UI/blob/087bffc51b3c83b6214c2b3cec5c9899aaed6b2e/src/components/ui/GlassButton.jsx) | 200ms、hover scale1.02、press .98、600ms 扫光 | 保留 primary/glow/destructive 的系统色；ghost 用原玻璃底；扫光改为 transform，非点击波纹 |
| [PillTabBar.jsx](https://github.com/micromimo/Auroraqua-UI/blob/087bffc51b3c83b6214c2b3cec5c9899aaed6b2e/src/components/ui/PillTabBar.jsx) | 单一活动胶囊 300ms 滑动 | 各导航实例独立 layoutId；胶囊使用既有 ice 色系，保持图标/文字/角标和键盘语义 |
| [SidebarNavItem.jsx](https://github.com/micromimo/Auroraqua-UI/blob/087bffc51b3c83b6214c2b3cec5c9899aaed6b2e/src/components/ui/SidebarNavItem.jsx) | 选中态内层 700ms 横向扫光；PillTabBar 选中项也有同一配方 | 统一选中导航扫光，伪元素不拦截点击，不改导航文字/徽标颜色 |
| [animations.jsx](https://github.com/micromimo/Auroraqua-UI/blob/087bffc51b3c83b6214c2b3cec5c9899aaed6b2e/src/components/ui/animations.jsx) | FadeInCard .95→1 / 500ms，StaggerItem 20px / 300ms / 50ms delay | 全页显现与列表入场分别统一；列表 stagger 封顶300ms，恢复滚动时不重播 |
| [Case3Sidebar.jsx](https://github.com/micromimo/Auroraqua-UI/blob/087bffc51b3c83b6214c2b3cec5c9899aaed6b2e/src/components/case3/Case3Sidebar.jsx) | 悬浮侧栏，16px 圆角，外沿留白，500ms 位移进入；内容300ms | 不改变既有侧栏宽度，12px外沿与全边框统一，保留sticky/独立滚动；宽屏首次进入左侧栏入场，切群第一列稳定、第二频道栏独立退出/进入，React motion持有编排而不叠加CSS入场 |
| [Case3.jsx](https://github.com/micromimo/Auroraqua-UI/blob/087bffc51b3c83b6214c2b3cec5c9899aaed6b2e/src/pages/Case3.jsx) / [routes.jsx](https://github.com/micromimo/Auroraqua-UI/blob/087bffc51b3c83b6214c2b3cec5c9899aaed6b2e/src/routes.jsx) | 页面 ±20px 位移、opacity、300ms easeInOut | 沿用 Ayla 方向/路由owner/播放器生命周期与手势提交阈值，仅替换过渡参数 |

上游声明 MPL-2.0；本次按配方重新组织现有 Ayla CSS 和 Framer Motion 原语，没有引入上游字体、图标资产、EXE 或运行时依赖。没有执行用户附带的安装程序。

## 覆盖范围与实现位置

- `tokens.css`：新增材料阴影、filter、导航渐变与动效参数；仅既有半径 token 调整为卡片16px、面板20px。旧颜色、透明度、font、bubble、halo 与 fluid token 保持原值。
- `app.css`：glass/solid 共同材料、登录注册卡、会话/语音/直播侧栏、语音面板、直播卡、主播面板、会话菜单、@选择器、表情面板。保留 `.solid-card` 类名，引用它的个人资料、个人内容、群信息管理/子群/成员卡自动获得同一材料。
- `home.css`、`boardgame.css`、`posts.css`、`voice.css`：群卡/列表、桌游、群内外帖子与详情、群内外语音卡及房间双卡。媒体封面继续由内层裁剪，不影响卡片外的置顶、收藏与菜单。
- `group.css`、`messages.css`、`live.css`：群/频道/服务器/消息/直播侧栏，场景标题、申请与好友行、直播选择、快捷消息和子群弹窗。
- `profile.css`、`search.css`、`private.css`、`shell.css`：个人内容与收藏条目、搜索结果与资料/申请面板、统一创建/确认弹层、导航和更多菜单。
- `auroraqua.css`：共用卡片hover/press、按钮scale/扫光、各级选项卡高亮、侧栏进入、宽屏输入及标题外壳、媒体控件的小幅反馈、减少动态效果与无backdrop-filter降级。通过 `main.tsx` 最后导入；材料主规则在所属 CSS 原地维护，无新增 `!important`。
- `base.css`：普通内容/列表改为20px、300ms显现；消息到达仍是8px/180ms，避免长消息流喧闹；背景和在线光环keyframes保持。
- React过渡集中在 `components/motion/auroraquaMotion.ts`，导航指示器集中在 `AuroraquaNavHighlight.tsx`；视觉迁移阶段不因动画创建额外播放器或重取数据。后续快速语音切换暴露独立的请求/连接竞态，本任务已扩展到语音会话与LiveKit客户端生命周期，不能将早期视觉范围表述为整次交付完全不改业务运行链；详见下方事故记录。

## 输入区与窄屏边界

宽屏群聊/私聊`.composer`、群内发帖`.group-posts-input`与帖子详情`.post-detail-composer`使用12px外沿、8px内边距、16px完整圆角、原玻璃底和高光边。相邻侧栏已经拥有右侧12px时，群聊/群帖/私聊输入与私聊标题不再叠加左margin。最终文本字段统一原`--glass-bg`的.55浅玻璃；语音/直播已在父房间卡内的composer只保留间距与分隔边，布局外框透明，避免又叠一张玻璃卡。直播弹幕侧列以及私聊/帖子/直播标题在宽屏一起形成悬浮面板。此处替换早期“字段统一强玻璃、嵌套输入仍加compact卡片”的阶段性配方。

用户随后指出输入区偏远、字段偏高、窄屏子群开合未覆盖、顶部五点冗余与滑动后偏离中心。根任务浏览器采样确认：1440px群侧栏右边356、输入左边380，相隔24px；字段继承 `.field` 上下12px padding，导致49.25px，而工具/发送为40px。已将共享间隔修为12px；字段改为22px行高、上下8px padding、1px边框，单行40px，宽屏空外壳58px。769px/1024px另发现长 placeholder 在正常流中换行撑高空编辑器，已将其改为绝对定位单行省略；真实正文仍可自然增高至140px。769–900px把四工具放到独立一行，避免窄桌面只剩约64px的文字输入宽度。修正后的10组宽屏尺寸结果见下方验收记录。

窄屏子群栏最终采用覆盖层：稳定的 `.group-chat-compose-area` 包裹输入区，switcher绝对定位在输入框上沿，不占消息列表高度。居中把手视觉为36×18px无边框上半圆，透明命中区48×32px；展开panel、tabs及选中胶囊无边框，周围透明空白不拦截消息，按钮和tab自身仍接收事件。Framer Motion继续管理300ms height/opacity、稳定按钮DOM及隐藏态无障碍语义。窄屏顶部五个装饰指示点已移除；底部主导航和群顶部导航恢复方角，其他卡片/输入圆角保留。

窄桌面的顶部导航也补齐收缩规则：模块文字nowrap且保留内容最小宽度，769–900px压缩模块/图标间距及搜索框到160–200px，避免新增外沿后把“主页”等文字挤成竖排；模块与图标均保留至少40px触达高度。

用户最后明确独立工具行要等宽平铺。窄屏与769–900px的换行工具组现使用自动列网格，按群聊4个/私聊3个工具等分整行、间隔8px，发送仍留在输入行；工具按钮统一40px高、12px圆角、原玻璃底/亮边/compact阴影与共享hover/press。录音停止等功能状态不被通用玻璃底覆盖。

滑动问题包含两个已区分的根因：路由过渡与drag offset原先竞争同一transform，现拆成同原点的外/内两层；随后逐帧发现正常Presence退出同步清零offset，会在opacity仍为1时从±180px硬跳回0。最终正常退出仅停止活动拖拽/回弹并保留当帧offset参与淡出，快速返场从保留位置连续归零。运行中开启reduced-motion或真正禁用才立即取消、停止并清零，并屏蔽旧回调，避免直播外层y冻结。先前“退出时都清零”的判断已由这一最终行为替换；仅检查最终x=0不足以证明过程连续。

窄/宽屏更多入口已按真实DOM核对，分别为NarrowTopBar中的 `.narrow-topbar-more > .icon-btn-40` 与TopNav中的 `.top-nav-more > .top-nav-icon-btn`。触发器统一12px玻璃按钮与600ms扫光；两个菜单共用300ms顶部淡入/轻移，菜单项补公共hover/press与reduced降级。没有改菜单功能、权限、外部点击或Escape关闭逻辑。

个人页/公开他人页使用稳定的profile-side/profile-main布局wrapper，宽屏两栏独立滚动且卡片保持自然高度；他人未公开内容时沿用原条件，不渲染右栏，窄屏wrapper不产生额外布局盒。群详情阴影截断来自无padding的独立滚动列：overflow-y:auto使横向边缘也裁剪，卡片恰好贴边。已在列内预留24px阴影空间、底部32px并调整轨道宽度，保持双栏滚动；769–1000px可用内容不足时退为单列整页滚动。

2026-09-08追加收紧个人页中央间隔：原两列内侧各24px形成48px空档，现两列各向中间扩16px、保留24px阴影padding，卡片净间隔16px且外沿仍24px。重叠的透明容器不接收pointer事件，直属卡片恢复命中与滚轮冒泡，避免后一列透明边缘压住前一列卡片。私密他人页的单列分支不扩展。

矮视口补验纠正了一条早期误判：1440px自页右栏最初报告wheel后scrollTop仍0，是采样没有等待paint/wheel完成；补充实际命中和等待后，769/1440×600px自页左右列分别可滚224/176px，他页右列可滚至240px（总extent277px）。真实缺陷是切页后旧OverlayScrollbar的fixed thumb留在body中，opacity0仍接收指针，在新16px列间隔下覆盖他人页右卡左2px。现DOM移除批次只清理已断开的owner及其thumb/timer/hover/active/drag，仍连接的owner不变；隐藏thumb禁用指针命中，全局卸载也逐owner清理计时器。未改变滚动换算、列宽或页面业务数据，此代码修复可逆且无需数据迁移。定向测试覆盖失效owner、其他活动owner、同批DOM移动、重新挂载、隐藏命中与拖拽/全局清理。

宽屏切群的整体滑入最初来自外层身份重建与侧栏CSS入场。AppShell使用稳定wide-group-shell，ServerRail owner/指示条id持续存在；用户随后明确新的分区动效要求：首次进入主页左侧栏从左、输入从下，切群第一列只移动粉色标记，第二频道栏旧内容收起/退出后新内容从左进入。此前“第二列完全不动”的阶段性目标已被这一最新要求替代；频道栏与群内容仍按groupId隔离编辑/弹窗/输入状态。CSS关闭这两列的自动整列入场，具体进入/切换由React motion按owner编排。

私信追加相同分区进入语义：进入消息中心的会话列从左进入，选聊天标题从上/输入从下，换好友时标题退出再进入且消息内容过渡。输入框左侧阴影的硬截断来自`.private-chat`的overflow:hidden，卡片为了保持12px侧栏间隔而取margin-left:0，正贴此裁剪边。宽屏该外壳改overflow:visible，消息滚动仍由.message-scroll负责，外层页面继续界定画面；没有增加z-index、输入padding或改变40px字段。

相应wrapper保持原布局边界：`.channel-sidebar-slot`在旧栏退出期间维持284px固定占位，`.conversation-transition`/`.chat-messages-motion`继续flex:1和min-size:0，输入wrapper不收缩且允许阴影溢出。宽屏React motion接管的群/私信侧栏、composer不叠加旧CSS自动入场；消息滚动和输入实例归原业务组件所有。

直播分区最终方向为宽屏直属LiveChannelRail从左20px，群内外切房时既有视频stage从下20px、弹幕side从右20px重播300ms easeOut。标题按channelId小范围Presence退出/进入；stage/side由WAAPI持有，`.has-media-panel-motion`关闭旧side CSS入场，均不为视觉重播添加key或额外媒体实例。跨频道时原runtime可以更换一次video/HLS，稳定的是播放器宿主，动画不能额外触发媒体切换；不能将首次进入settled前后video相同扩大为跨房video总同DOM。窄屏展开直播列表时`.live-rail.is-panel-motion`改由Framer从右20px/300ms进入，关闭旧CSS左入，宽屏常驻栏仍从左进入；reduced直接归位。此处直接替换了早期“切房不重播标题”“只重播标题、视频区无动画”的阶段性结论。

语音房方向为标题上入、语音成员卡下入，聊天卡宽屏右入、窄屏下入，均20px/300ms easeOut。首次进入与群内切房由单一动画owner在同一面板DOM重播；`.voice-room-body.is-panel-motion`下关闭CSS自动入场及旧`.reveal`的opacity/transform，内部composer不再叠加100%位移。视觉层未给房间或LiveKit宿主增加key，外观重播不能触发额外连接/订阅；reduced直接归位。随后追加的快速点击修复改变异步连接所有权与取消流程，其契约独立于该动画规则，见[语音会话切换](../architecture/voice-session-switching.md)。

群/私信/直播房/语音房及自他人页/收藏/桌游房/帖子详情的分区外壳以`panelOwned`等明确边界排除整页进入位移；群内容只编排子面板，主内容不再另挂整体tab-panel位移。该规则扩展到窄屏，但保留原PrimaryNav/scene/FullScreenSwipeBack手势轨道；页面退出仍淡出，reduced直接完成。它取代对所有直播/语音入口笼统应用整页浮入的描述，避免单播放器或LiveKit宿主被祖先再次平移；群外帖子旧500ms过渡迁到正文，详见下段。

后续宽屏静态分区扩展到群详情左右栏、自/他人页顶栏与左右列、桌游房标题、群内各现存列表标题以及收藏标题，统一使用共享20px/300ms方向关键帧，保持原宽度、独立滚动与断点。收藏标题补同款玻璃/亮边/16px圆角/compact阴影，宽度按1200px轨道减两侧24px内沿，和卡片外沿对齐。群内直播直接显示房间，没有额外列表标题；使用直播房头的同一owner。

帖子详情宽窄屏均头上入、评论输入下入，20px/300ms；输入inline不再叠加原100%→0和100ms延迟。为保持群外正文原有行为，原页面500ms y20/scale(.95→1)只迁到正文滚动区，article/comments已有300ms reveal与评论stagger保留；群内正文补独立300ms进入。shell底栏离场状态、安全区和输入业务状态仍独立管理；不能把整个帖子页面替换成一套新动效而丢掉群外原主体过渡。

窄屏按实际纵向结构扩展分区：普通顶栏自上，个人页的实际solid-card和群详情两段内容自下；收藏窄屏标题补玻璃并与列表16px内沿对齐。窄屏进群导航保留“底栏滑动到顶栏”的跨视口轨迹；此前将其改为顶部-20px入场是对需求的错误泛化，用户明确指出后已按该独立导航契约回正，不能把其他普通顶栏的方向套到进群导航。群消息右入、群/私输入下入保持，直播仅窄屏底部input由CSS下20px/300ms，宽屏仍只跟随右侧面板。既有100%输入滑动、旧reveal与整页进入不会同时叠加到这些新分区；safe-area、滚动owner和真实手势提交边界保持。

窄屏`/messages`的真实头是`.messages-tabs`，不是NarrowTopBar；排除整页位移后补该头首次从上20px/300ms进入，切tab不重播整头且不影响宽屏侧栏。所有尺寸的`.chat-motion-panels .composer`均关闭旧CSS入场，让群/私输入仅由各自motion分区移动。GroupPage旧整体500ms/80ms延迟层已移除，GroupScene自动切换原位淡入/淡出300ms，真实drag持有与释放连续性保持；子群列表只在所选正文就绪时重播，日常新增消息不重复进入。

浏览器复核又定位到群帖子列表底部遗漏：`.group-posts-input`原本只有expanded态250ms浮入，普通入口没有动画。现基础态宽窄共用下20px/300ms，expanded以原高特异性规则独占展开动画，不叠加位移；reduced两态均直接呈现。用户随后指出外观仍未覆盖，确认旧外框使用`.78`强玻璃与贴底单上边：现补`.55`浮框材料与宽屏12px外沿/8px内沿/16px圆角，左margin0保留侧栏单12px缝。窄屏与现有composer一致，内PostEditor padding清零，compact textarea/发布按钮40px，字段与媒体工具同款玻璃。展开仍absolute、同级遮罩与原内部滚动，宽屏最大高度扣除上下24px外沿；没有改上传/发布状态或shell安全区。

群内语音列表、帖子列表、帖子详情与桌游列表的轻微左侧裁影来自实际滚动器16px内沿：1440px时频道栏右356、滚动器左368、标题左384，32/40px模糊阴影在滚动器边缘截断；群帖子/详情又有外壳overflow:hidden。四个宽屏滚动器现左margin -32px、左padding48px，保留内容的原16px轨道与overflow-y:auto；两个外壳只取消多余裁剪。新增透明绘制带pointer-events:none，真实直接子内容auto，让侧栏点击穿透，内容wheel仍冒泡至原owner。该变更保留列表、标题、骨架位置和宽度；验收需包含侧栏/卡边命中与真实滚动，不能仅凭阴影截图推断交互正常。

子群内容切换补齐当前`.message-list`的右20px/300ms淡入；没有为动画复制消息运行实例或编辑器。默认子群初次建立只登记基线，由父面板负责首次进入，避免父子双入场。后续真实选择变化时，缓存可用立即进入，无缓存等待当前选择revision对应的请求完成标记，避免旧请求或共享loading提前消费新选择。用户随后补充输入上下过渡，现由原`.composer`执行向下退出300ms、再从下20px进入300ms，不key重挂编辑器，保留草稿与焦点；快速切换取消旧动画。外层`.group-chat-compose-area`继续只拥有面板初入，子群条及开合覆盖层不随消息内容移动。
窄屏保留原fixed/absolute、安全区、独立滚动、横向手势让位和单播放器约束。消息菜单、确认/子群弹窗和媒体查看器继续使用已有Portal/层级边界。所有伪元素禁用pointer事件；不会把功能徽标重定位到普通文档流。

## 加载、列表排版与透明度补充

用户后续把“所有加载界面动画”明确限定为转圈和骨架屏。`base.css`现提供唯一`ayla-loading-spin`及800ms token，消息历史/发送/下拉刷新的14px或18px环共用样式，RefreshFab保留原SVG而共享循环配方。消息发送环原轨道颜色保持。所有骨架共用1600ms `frost-pulse`，保留原玻璃材料与可见范围列表的樱粉底；span补inline-block以兑现宽高，媒体继续block撑满frame。修复媒体原独立动画绕过reduced-motion的问题：减少动态时，圈和骨架均静态显示，尺寸与状态语义保持。页面入场、路由、reveal、背景、光环、消息到达和LivePlayer单次刷新不属于这次加载补充。

收藏页最终复用帖子的 `useMasonryColumns` 和两条独立flex列：>768px双列、≤768px单列，卡片按各自高度连续错落，最大1200px轨道、左右24px内沿和12px列距，宽屏帖子摘要最多3行。先前普通grid方案会因同行较高卡片而在较矮卡下留下空白，用户明确指出与帖子瀑布不同，已替换该方案。收藏id分配保持稳定，记忆按用户/分类/列数隔离，API源数组不排序；键盘沿真实列从上至下、由左到右，与帖子相同，不设置正tabindex。列表在真实内容挂载后才绑定量高观察器，列不裁剪卡片或菜单。

共享hook同时修复迟挂载的observer生命周期：原effect在loading空列时运行，之后真实DOM出现而列数不变时不会登记观察。动态ref现负责observe/unobserve和即时量高，断点变化/清理带owner守卫；后续新卡按实测较矮列，同批未量高沿用原320px预估交错，已分配卡不因测量重排。帖子页展示逻辑与断点没有改动。

定向回归另发现分类切换首帧旧数据污染新分列key：filter已同步变化而load effect尚未置loading，旧favorites会在新分类key下短暂挂载。现在加载门同时检查`settledFilter !== filter`，当前分类响应确认前只展示骨架；测试保留新分类独立分配期望，并用deferred请求断言等待时没有旧列表。

搜索页769–1024px居中680px，1025px起1200px与24px内沿、结果类别两列；用户姓名/签名改上下排，群结果接入36px Avatar。核对发现既有群搜索响应漏回模型现有avatar，后端在原群发现GET响应补该兼容字段，前端沿既有资源路径加载；没有从聊天store补数据，也不改变搜索或入群权限。内部媒体签名授权补齐同一群发现边界：只开放被type=group完整引用的image头像给已登录用户，私聊头像仍要求成员、普通附件保持原权限，清除引用后不再签发；已签对象存储URL沿用原600秒有效期。细节与独立权限契约见媒体架构文档。

真实请求加载验收还发现两个原状态问题：PostsHub先setLoading(true)再setError(null)，后者会把loading清掉；宽屏Home在会话GET未完成时直接显示无群空态。已改为帖子先清错误再置pending，宽屏Home等待期间显示6张原骨架，失败保留错误/重试。

用户随后指出骨架缺少左右留白。根因在外层布局：帖子骨架缺width且尾部固定max680，voice/live复用未限宽的conv-loading，帖子详情骨架不跟正文max680。现帖子/我的帖子骨架与feed共用680→1200px、16→24px水平内沿及宽屏两列；语音/直播骨架共用真实列表2/3/4列、max1200与外沿；详情骨架有效宽680、两侧16px外沿；群帖子加载区跟feed同限宽。Home宽屏临时骨架补1200/24轨道，窄屏Home、桌游、收藏与搜索原有匹配轨道继续使用。没有把内部骨架padding当成页面留白。

直播卡片“不够通透”的直接样式根因是`.live-card`仍用`.78`的`--glass-bg-strong`，而其他主卡片为`.55`；封面占位还有完全不透明的蓝粉渐变，遮住大部分玻璃。已把大厅卡改为公共`.55`材料，`.live-card-cover`、`.live-rail-cover`和群侧栏`.channel-live-cover`改透明占位，保留亮边、图标与状态色。真实封面没有修改opacity/filter。实际组件是LiveHall的`.live-card`及两种频道栏，没有`.live-channel-card`这个类；群内进入LiveRoomBody，频道列表由ChannelSidebar持有。

## 有意保留的原有行为

- 原流体极光、主体气泡/光环和文字体系：用户明确要求保色。
- 消息内容、图片/视频/音频、真实播放器和浮窗宿主：不加卡片hover位移或3D Tilt；其周边玻璃面板/按钮可以使用相同材质和交互。
- 长列表恢复、旧消息加载、手势阈值、pointercancel、同一路由key归一和活动播放器：属于功能连续性，保持现有契约。
- 系统窗口/EXE、Auroraqua演示专用彩屑/粒子/数据统计数字动画：不属于Ayla现有卡片/导航的共同交互，不接入。

## 验证记录

2026-09-07 首轮38个页面/视口组合只作为粗查：虽然无JavaScript错误和横向溢出，但帖子正文和pointer状态存在harness采样问题，不能据此宣称每页内容或交互完整通过。修正后采用以下定向证据。

- **早期自动化定向测试**：截至搜索与Home/Posts加载状态修复阶段累计30文件、228个唯一用例通过，含动效参数、导航稳定性、消息输入、子群开合、侧栏身份、个人页、搜索头像与加载路径。该数字只代表当时快照，后续收藏瀑布、分页与新增分区动效的最终证据单列，不把重复子集累加。
- **早期类型与生产构建记录**：最初过渡拆层阶段的`tsc -b`与Vite构建通过，转换667个模块，存在既有静态/动态混合导入及大于500kB的chunk提示。该构建早于后续分区、窄屏与子群消息追加，不能代表最终全部修改；新增宽屏分区阶段的`tsc -b --noEmit`另已通过。最终冻结后的回归、类型检查与构建按下方最新验证条目记录。
- **群头像后端契约**：搜索API 9项、媒体头像ACL 17项通过；使用 `config.settings_test` 内存SQLite及 `--nomigrations`。直接跑旧迁移会在0011的MySQL专用 `ENGINE=InnoDB` 语句处导致SQLite setup失败；本次无schema变更、未修改旧迁移，测试结论限于现有模型与接口/权限契约。
- **实际加载状态与减少动态**：`ayla-loading-final-summary.json`汇总8场景（home/posts/userprofile/groupinfo/postdetail/groupvoice/media/history）×375/1440px×normal/reduced，共32/32通过。常态骨架统一frost-pulse 1.6s ease-in-out无限、历史环ayla-loading-spin .8s linear；reduced均animation:none/opacity:.8且多时点静止，media/history另4组在pending中切换reduced验证立即停止与恢复。完成后内容均可见，0运行时错误、0未知API、0抽样16个颜色token差异与0水平溢出。汇总使用修复后的Home/Posts各4项结果，原normal报告保留首次诊断失败，不能将该旧文件单独称为全通过。此验收先于骨架外沿追加，外沿对齐另行记录。
- **骨架与真实内容边缘**：`ayla-loading-padding/report.json`与`padding-summary.json`记录18/18组通过。375/1440px的posts/detail/voice/live/games/favorites/groupPosts及375px home，pending首个骨架卡与loaded首卡的左边缘、宽度差均为0px；375px posts/detail/favorites/groupPosts边缘16px、home12px；1440px posts/favorites首卡x=144/w=570，voice为144/279、live为144/276、detail为380/680、groupPosts为384/514。宽屏Home骨架max1200+24px内沿，首卡x=144，完成跳群，不作跨布局的虚假等宽对照。搜索文字加载内边缘16/144px与结果轨道一致。0运行时错误、0未知API和0溢出，完成内容均可见；同目录保留18组pending/done截图。
- **宽屏尺寸**：769、900、901、1024、1440px各群聊/私聊，共10组；输入、工具、发送均40px；901px起空输入外壳58px，769–900px两行外壳106px；侧栏到输入外沿12px。无横向溢出或运行时错误。截图存于本机 `ayla-auroraqua-sizing-final/`。
- **真实CDP触摸序列**：375×812、768×812，`hasTouch=true`、`isMobile=true`、coarse指针与 `maxTouchPoints=1`；群场景/一级模块分别普通左右切换和动画中快速反向，共16次。四组最终均回到原路由，路由层与拖拽层最终x=0、宽度等于视口、transform=none、centerError=0。两组子群展开高度0→40→0，2个tabs按状态显隐、`aria-expanded`正确，toggle、消息列表与composer DOM均不重挂，五个装饰点不存在。
- **松手过程逐帧复核**：`ayla-auroraqua-release-trace-baseline/report.json`确认旧版同一退出节点从±180px归零且前后opacity均为1的硬跳；`release-trace-after`同条件8次释放未再出现该跳变，群内/一级页最大相邻可见帧差分别7.44/6.31px。`release-fast-reentry`额外两步反向中的18.31px变化跨100ms，属于原生回弹先行，没有180px直归零。但CDP响应较慢，快速反向提交时原退出节点已经卸载，记录`originalNodeRevived:false`；不能据此宣称同一DOM节点复活的浏览器验收通过。
- **触摸验收边界**：0运行时错误、0缺失模拟API；8条WebSocket全部由fixture隔离，只允许本地前端GET，Google字体请求阻断。上述是浏览器触摸仿真与隔离数据验收，不宣称物理设备或真实媒体服务验收。报告与截图：`C:/Users/ricer/.codex/visualizations/2026/09/07/01a07c53-0232-7d91-83a9-15341768ca76/ayla-auroraqua-gestures/report.json`，同目录保存375/768的swipe-final、subgroup-open/closed截图。
- **减少动态效果**：375px/1440px各5页，共10组；0运行时错误、0内容失败、0横向溢出；语音卡片与玻璃按钮hover/press的scale/translate均为none，导航胶囊稳定后transform均为none。
- **最终子群覆盖层**：`ayla-auroraqua-subgroup-overlay-final/report.json`记录375/768px开合所有状态；message-list、message-scroll、composer、input与compose-area的top、bottom、height、clientHeight、scrollTop变化均精确为0，DOM不重挂。两tabs真实tap可切换，tab内真实横滑不传到场景/路由；半露把手与panel/tabs均无边框。
- **早期宽屏切群阶段**：`ayla-auroraqua-server-rail-final/report.json`与769/1440轨迹记录在三个群间切换，第一列ServerRail稳定、粉色活动线119.5→184.5→249.5→119.5各段有中间帧、目标中心误差0，群编辑器owner切换且无草稿串群；82条fixture API与6条WebSocket隔离，0运行时/缺失API/内容错误。该阶段第二列也未入场；此部分已被用户最新“第二列退出再进入”要求替代，旧报告不能作为新第二列动画的验收证据。
- **宽屏群/私分区最终轨迹**：`ayla-chat-partition-summary.json`汇总`ayla-partition-chat-1440`、`ayla-partition-chat-900`、`ayla-partition-chat-reduced`，1440/900px×常态/reduced共44阶段、152个新进入记录全部通过。首次群rail/频道栏从左，消息从右、输入从下；切群第一rail身份稳定且粉色标记移动，第二aside旧退后新进。私信侧栏从左、header上/输入下/消息右，换好友先退后进。快速连续切换与直接私聊路由回切保持最多1个编辑器，活动会话归属正确；所有群输入外沿距频道栏12px，新增composer-motion/chat/ConversationTransition到content/pane的祖先均允许阴影溢出，未增加贴边裁剪。常态均归位；reduced共2490个面板采样直接位移0/opacity1；0运行时错误、0未知API、0断言失败。该项不代替随后新增的窄屏分区与子群列表过渡验收。
- **资料/详情/更多菜单**：`details-final`在375/769/1024/1440px共16组为0运行时错误、0溢出、0色板差异和0缺失API；个人页双列与群详情阴影已目视检查。`more-final`、`more-reduced`在375/1440px确认常态菜单300ms opacity0→1/transform归零、按钮hover1.02/press.98，减少动态时动画/scale均none，Escape关闭正常。首次details菜单采样早于paint，不作为动效结论。
- **最新布局与材料**：`ayla-latest-layouts/report.json`覆盖375/769/1024/1440px各favorites/search/profile/user-profile/live/group-live，共24组，全为0运行时错误、0缺失API、0横向溢出和0抽样颜色token差异。收藏卡实高112.80/154.39/84px，各宽屏列内连续间隔12px，呈独立错落；搜索每视口2个API头像均真实解码（naturalWidth720）及1个首字回退；直播大厅背景rgba(255,250,251,.55)、blur24/saturate1.4，占位背景透明/无渐变，真实图opacity1/filter:none。769/1024/1440px自他人页卡片间隔均16px。该矩阵高度1000px时内容未溢出，独立滚动使用下一项矮视口证据。
- **个人页滚动与失效thumb回收**：`ayla-profile-owner-final/report.json`在769/1440×600px覆盖自/他人页，共4组全部通过；卡片间隔16px，两栏边缘命中各自owner，旧透明thumb不再覆盖新卡。真实wheel让自页左右列分别滚224/176px，他人页右列滚至240px（extent277px）。`overlay-scrollbar.test.tsx`的6例覆盖owner卸载及其他owner保留、同批DOM移动、重新挂载、隐藏指针、拖拽状态与全局清理；全部通过。此前未等待wheel完成造成的1440px不滚误判已在根因段改正。
- **宽屏媒体分区首次进入**：`ayla-media-partition-summary.json`汇总`ayla-media-panels-baseline`、`ayla-media-panels-900`、`ayla-media-panels-reduced`，1440/900px×常态/reduced共16阶段、24个分区进入记录全部通过。常态直播左栏/标题/弹幕为左/上/右、语音标题/成员/聊天为上/下/右，各±20px→0且配置300ms，祖先没有叠加位移；reduced全部采样位移0且opacity/effectiveOpacity1。settled前后播放器DOM及HLS attach次数、语音factory/connect次数不变，0运行时错误、0缺失API、0颜色差异、0横向溢出。rAF采样未稳定60fps，不以此宣称帧率；媒体连接使用隔离适配器，未验证真实媒体传输。该项证明首次进入，不代替后续切房头部/语音重播的专项验收。

静态审计：15份CSS通过PostCSS解析且无空规则；对比Git基线的69个原token，仅卡片/面板两个半径改变，其他67个（包括背景/字体/玻璃颜色/气泡/光环）逐值一致；`base.css` 除列表入场外的11个keyframes逐字一致。减少动态效果的hover/press覆盖采用与常态等同的选择器特异性，避免鼠标仍悬停时缩放残留；语音卡片的交互transition由共享配方拥有。

**群列表阴影与发帖浮框专项**：`ayla-group-surfaces-final`及`ayla-group-surfaces-settled`的8个宽屏页面，A/B切换旧margin0/padding16与新margin-32/padding48，卡片/标题x与width差全部0；侧栏右沿内2px、卡片左右内2px命中正确，真实wheel仍落原scroll owner。群帖四个宽度的收起/展开/再收起通过：宽屏侧栏gap12、字段/发布40px、24px blur/16px圆角/8px内沿；窄屏18px blur与8/12/12px内沿，展开textarea可滚且草稿保留。1440px初采wheel/展开两项早于settled，等待真实动画完成后补采通过，没有据此修改正确产品行为。

**后续真实分页范围**：用户进一步要求收藏/搜索/帖子新增卡单独进入，以及直播/语音/桌游一级与群内列表滚底分页。三个后端目录新增显式limit/cursor的兼容分页与group_id白名单过滤，真实SQL读取limit+1，保留旧数组消费者；完整total与语音total_member_count不按首屏推算。排序在SQL复现既有有人/曾进/从未与在播/曾播/从未规则，再以rank/time/id形成稳定游标，不能仅按旧后端默认id取20条再局部sort。前端保留原即时活动排序：WS真实sortIdentity改变时只重排该查询已加载项，复用旧DOM且不重播；正常metadata/count/activity不使cursor失效、不弹刷新提示，后续页沿原cursor按ID去重，重复迟到页不能盖掉请求后实时descriptor/人数。仅部分目录的真实成员集合/过滤归属变化失效，授权REST确认后的完整目录直接增删并更新总数，异群/未知删除不影响当前查询。普通metadata/count变化与分页append不重排。早期“WS只提示刷新、不即时排序”以及“每次真实活动排序都使cursor失效”均已被最终契约替换；动态keyset不宣称静态快照完整性。详细契约见[目录分页架构](../architecture/catalog-pagination.md)。本阶段早期实现曾误用后端默认id排序、误把User的CharField主键校验成整数，均在交付前审查/契约测试中更正；SQL引号断言也改为数据库自身quote_name，空时间Coalesce显式Cast以兼容MySQL。

**群内帖子分页**：去掉首屏最多10次未读补齐循环，改为group scope首屏20条、滚底每次再取20条，游标持有与去重append均在当前用户/群的请求owner内。重复scroll共享忙锁，下一页失败保留旧卡/cursor并等待明确重试；旧群迟到响应不能覆盖新群。store只同步本目录已加载卡的单调已读/浏览状态，不能把全局缓存并进来绕过页边界；新建/编辑WS只对账单条权限详情，删除只移除目标，不重拉首页。未加载未读仍用会话完整计数，详情返回保留已经加载的页和cursor。`useListEntryMotion`仅对新DOM卡片进入，刷新不再key重挂整个流；请求在详情中完成不能撤掉返回恢复抑制。`group-posts.test.tsx`共12例通过，包含pending append→详情→回包→返回320px且旧卡不重播→下一页仅新卡进入。

**一级帖子信息流分页**：`PostsHubPage`去掉刷新用的整流key，追加失败在底部显示错误与明确重试，保留已加载卡和原cursor，禁止滚动自动重复失败请求。刷新持有新revision，旧追加成功、失败与finally均不能覆盖新首页、cursor或后续请求loading；刷新失败保留原页并能继续原cursor。卸载使未完成请求失效，WS删除不会被迟到页复活，刷新期间新帖与单调浏览/已读状态保留，收藏仍由原store持有。无可滚动高度时可用“加载更多”按钮；重复id和不推进cursor有显式处理。`posts-hub-page.test.tsx`最终局部12例通过，新增8例覆盖并发/错误/卸载/WS与320px恢复后只新DOM入场，旧卡刷新不重挂；根任务冻结回归另行记录。

**搜索用户结果语义**：结果行改为普通容器，头像按钮与姓名/签名按钮并列；头像沿原用户主页跳转，文字沿原资料弹窗，消除button嵌套button而不扩大点击目标副作用。`search-page.test.tsx`局部13例通过，含两条用户结果的头像/正文独立动作、无嵌套按钮及资料弹窗约束。

**分页底部高度修复**：真实浏览器503重试发现目录footer按钮换三点时缩短约34px，群帖移除失败notice时缩短62px；底部scrollTop先被较小滚动范围夹回，成功追加后又跳回，旧卡DOM与内容坐标没有变化，根因不是旧卡重播。新增`StablePaginationFooter`保留本挂载期间footer实测最高高度，ResizeObserver仅测当前footer并在卸载断开；错误、加载、重试共用同一root，完整错误可换行，footer不作为浏览器滚动锚点，不补写列表scrollTop。目录、GroupPosts与PostsHub接入；1440/375×直播/语音/游戏/群帖共8/8真实浏览器复验通过，503→重试pending→成功及第三页旧卡/scrollTop不跳，仅新卡入场。主内容终页继续保留空间；用户随后指出侧栏空白，语音/直播侧栏明确传`retainCompletedSpace=false`，无加载/错误/后续页/失效时移除footer，不再保留80px尾空白。前述8例证据`ayla-pagination-stable-footer-final/pagination-report.json`属于此追加前阶段；最终侧栏行为需用后续专项验收，早期`ayla-pagination-1440-settled`仅保留失败诊断。

随后侧栏专项暴露共享footer的`flex-basis:100%`在column与Framer自动高度下形成增长反馈：20条内容不变时scrollHeight从4832→5488→7456，重试按钮30s无法稳定点击。已删除共享百分比basis，保持flex:none/width100%，跨列只留帖子布局自身规则；原最高高度记录属于当次DOM，复验使用新挂载。`ayla-pagination-sidebar-diagnostic`记录修正后footer95.25px、parent757.25px、scrollHeight1162，18.7s共45帧恒定；实际503重试复验另行记录，不能以强制点击绕过问题。旧失败证据保存在`ayla-pagination-group-sidebar/pagination-report.json`。

语音侧栏排序的原分段UL会让房间跨“前三项/展开项”时更换父节点，无法保留连续位置过渡。现全部已加载房间处于同一稳定UL，折叠高度92px只露前三项，尾行同时aria-hidden并禁用按钮/tab；展开为auto。行复用原DOM并用300ms easeOut位置FLIP，滚动根登记layoutScroll并禁用原生锚定；语音房选中背景关闭自己的共享layout投影，跟随父行移动。业务排序立即提交，连接编排不等待动画，也不手写scrollTop补偿。该排序修复保持原折叠边界；后续用户明确恢复sticky透字修复，新增裁剪范围见文末记录。最终滚动与背景跟随证据见下方竞态记录。

**输入与单层卡材料**：用户追加指出输入偏白和双层玻璃卡。只读TSX与CSS定位到普通`.field`的surface实底、弹幕/开播/宽聊天/群帖字段的.78强底、搜索surface底，以及宽语音卡内panel、宽语音聊天卡内head/composer、直播aside内input/area、个人“我的内容”卡内row的重复材料。字段最终使用.55、白边.65、12px圆角、blur24/saturate1.4及同一inset/focus；搜索/全屏输入只在外框铺底、原生input透明。窄语音聊天卡、独立直播input、帖子详情composer父底也降为原.55，保持尺寸、输入类型、状态和safe-area。四组嵌套卡保留外卡并将内部布局层透明，分隔边/hover/状态色仍在；窄语音panel及独立聊天浮层、收藏/群信息分卡/帖子article确认并非重复玻璃，保留。原颜色token没有修改。新静态审计再次15 CSS/69原token/11原动画通过。375/1440实际输入矩阵共24个有效页面：`ayla-input-single-glass-verified`中20个页面，加`ayla-input-auth-verified`中真正登录/注册4个页面；前一报告中认证路由重定向到群页的4项不重复计入。另`ayla-profile-expanded-materials`两视口各8条展开个人内容row确认透明、无blur/阴影；这些检查均无运行时错误、未知API、横向溢出或抽样原色板差异。

**开播控制台补齐**：用户进一步指出开播界面遗漏。已按真实`LiveStudioPage → LiveRoomBody(showOwnerPanel) → LiveOwnerPanel / LiveStreamAddresses`核对：`.live-studio-owner-panel`与main本来是透明布局，`.live-owner-panel`的.78强底改为.55，内部`.live-owner-visibility`去掉.35重复底、保留分隔边；`.live-studio-stream`补齐glass-shadow/blur24与白边，内部`.live-copy-value`沿用只读code并使用.55/白边/12px/inset。窄`.live-room-body.is-studio.is-narrow > .live-room-side`及直属弹幕wrap明确透明、无blur/卡片阴影，240px高度、正常流和整页滚动不变；其内部input/area作为布局保持透明，真实文本字段保留统一材料。封面按钮加入共享hover/press/reduced反馈，开播/保存/复制/权限与播放器业务未改；验收只用合成推流信息，不输出真实stream_key。

900px补验发现两项可用宽度缺陷：开播左/右侧栏之间的资料栏仍强制单行，200px标题会覆盖开播/保存；群语音固定320–380px聊天列把成员卡压至104px。首次将表单换行、双卡最小宽度改为240px后，真实375/769/900/1024/1440矩阵虽然无body溢出/运行时错误，实图仍显示900px语音昵称/状态竖排，以及769px开播中央仅109px导致封面、权限/复制按钮不可读；“没有body溢出即布局通过”的结论无效。最终769–1100px开播保留左频道栏，右侧主区/弹幕改为上下布局，资料栏继续按实际560px边界换行；语音双列至少各320px、聊天最多380px/45%，内容不足656px沿原DOM顺序上下排列。原先280px聊天列在1024px仍把placeholder折成两行裁切，故最终提高到320px，没有修改正文多行语义。均只调整CSS，媒体、输入与分区动画owner保持。根任务最终实图确认769/900/1024语音昵称、状态、输入完整可读，1440保留双栏，开播字段无重叠且收起侧栏自动满宽无空列；浏览器无运行时错误、body横溢出与抽样原色板差异。`ayla-studio-scroll-verified/report.json`进一步用真实wheel验证769px侧栏展开时main从0滚至39（extent39）、收起后从47滚至138（extent138），最终地址行可见。此阶段未包含sticky标题后透字修复；用户随后明确要求处理该问题，并统一上下五个场景标题的材料，新增范围见文末记录。

**主验收与追加定向**：主批42文件、335项前端测试一次全部通过，耗时186.85s，日志`auroraqua-final-regression.log`；该阶段`tsc -b --noEmit`另通过。之后用户更正窄屏进群应底栏升到顶栏，导航以独立translate从`calc(100dvh - 64px - safe-area-inset-bottom)`到0、300ms且opacity1回正；连同footer稳高六文件49项定向通过，日志`auroraqua-nav-footer-final.log`。默认子群初入还定位到render内消费初始化ref在StrictMode第二次render被误判为真实切换，现改为layout-effect提交基线，两处消息/输入hook同commit抑制默认双入场。最终侧栏六文件73项全通过，28.60s，日志`auroraqua-sidebar-final.log`：directory-store15、directory-api5、footer5、subgroup-switcher23、group-page16、group-voice9，覆盖即时排序、前三项边界移动同DOM、折叠交互禁用和迟到页竞态。上述批次存在重叠，不累加为新总数，也不以旧5项宣称默认子群修复验证完成。

**最终开播/语音布局证据**：375/769/900/1024/1440两页共10个有效页面。`ayla-studio-voice-responsive-verified/report.json`提供四个桌面宽度的8页，其中1024语音以`ayla-voice-1024-final/report.json`替换；375两页仅使用`ayla-studio-voice-responsive-final/report.json`的375结果，该旧报告其他宽度不能当作最终通过。`ayla-studio-collapse-verified/report.json`提供769收栏验证，前述`ayla-studio-scroll-verified/report.json`两页提供展开/收栏真实wheel和最后地址行visible=true。

**最新宽屏媒体重播**：`ayla-media-latest-root/root-motion-audit.json`与`ayla-media-latest-root-reduced/root-reduced-audit.json`在1440px常态/减少动态各11阶段均0运行时/未知API/断言失败。常态global live的同一stage/side分别下20px/右20px重播300ms，rail不重挂；每次普通切房1次attach/1次destroy，快速切换最多对应3次真实点击，无额外媒体实例。群语音头/成员/chat同DOM上/下/右重播。reduced共1097个面板记录x/y0且opacity/effectiveOpacity1。常态记录约7fps受录制开销影响，不能宣称60fps或每帧平滑；媒体运行使用隔离适配器，仍不等同真实服务传输验收。

## 快速语音切换竞态

2026-09-08，用户继续报告快速点击语音房后当前内容、连接与选中项不一致。本轮已超出此前视觉迁移：需要修复业务异步请求与媒体生命周期，不能继续笼统声称“语音/LiveKit运行链完全未改”。目录即时排序、稳定行DOM及位置动画继续保持；sticky透字在后续明确授权下独立补齐，详见文末裁剪记录。

诊断在1440px真实浏览器用合成房间A=710、B=711、C=712连续点击，并分别扣住旧请求的不同阶段，等路由到C后放行旧阶段。HTTP、WS和媒体传输均为隔离fixture。证据根目录为`C:/Users/ricer/.codex/visualizations/2026/09/07/01a07c53-0232-7d91-83a9-15341768ca76`：

| 旧工作被延迟的阶段 | 原始诊断证据 | 放行后的真实状态 |
| --- | --- | --- |
| REST join响应 | `ayla-voice-race-baseline/voice-race-report.json`的join项 | 路由与标题为C，currentChannelId、唯一活动媒体、心跳和侧栏选中项却回到A |
| members响应 | 同报告members项 | 与上行相同，旧成员铺底完成后恢复了A活动会话 |
| SDK connect完成 | 同报告connect项 | 与上行相同，旧媒体完成后把C页面绑定到A |
| 旧REST leave响应 | `ayla-voice-race-leave-baseline/voice-race-report.json`的leave项 | 放行前已经在C；之后C媒体被断开，A重新成为当前媒体、心跳和会话记录，路由仍为C |

这四项是独立阶段复现，不应称为同一次动作出现四个错误。详情descriptor延迟的对照项原本通过，不能记为修复前失败；最早leave脚本未正确命中目标的记录已剔除，只采用上表重新执行的有效leave诊断。表中均为修复前证据，不能用于宣称修复已通过。

源代码复核确认两个边界缺口。上层`joiningRef`会直接忽略进行中出现的后续join，而局部generation没有随最后选择可靠推进；离开、连接、开麦和成员对账的多个`await`之后也缺少共同的有效选择校验。底层`VoiceLiveKitClient`跨`await`读写共享`this.room`，断开不能撤销待返回工厂/连接，旧room事件也没有owner校验。这解释了为何画面已经导航到C而运行链仍完成A；仅保持选中动画或调整排序不会修复数据归属。

已完成的客户端修复为独立room owner与generation、立即`AbortError`取消、旧产物/晚连接定向清理、七类事件过滤，以及麦克风/播放/音量的局部room捕获。`createLiveKitRoom()`内部不变。根任务独立验证封装15项与真实适配器17项，共32项通过，耗时6.37s，日志`auroraqua-livekit-owner-final.log`；此批次只证明客户端边界，不替代上层共享选择队列与四阶段浏览器联测。稳定契约见[语音会话切换](../architecture/voice-session-switching.md)。

上层修复集中在既有`voiceSessionRuntime`、`useVoiceChannel`及相关页面：路由layout-effect在详情未齐时即登记最后目标；共享selection revision与串行队列合并同一选择、跳过过时queued目标，每个阶段校验账号/挂载/选择。未commit的临时媒体换目标立即定向取消，已建立媒体保留到新REST确认；旧join回执和补偿leave请求结算后才执行后续目标，不能把已经发送的REST假装撤销。旧频道leave/expiry、members对账和静音失败只作用于原owner，目标失败重试使用路由id。显式leave与登出REST leave共用队列，登出本地立即断开；补偿使用原账号闭包凭据，401不刷新或用新账号重试。用户随后明确选中反馈应即时变化，侧栏已按路由voiceChannelId高亮，独立于真正连接的currentChannelId；没有取消原活动排序。

滚动后的FLIP跳跃还有独立的浏览器锚定原因。`ayla-sidebar-realtime-anchor-disabled/sidebar-realtime-report.json`对应的A/B诊断中，原生`overflow-anchor:auto`令scrollTop从378变为0；fixture仅关闭锚定后保持378，初次projection恢复到原可见y=522。产品在非bottom的`.channel-sidebar-list`滚动根使用`overflowAnchor:none`并保留`layoutScroll`和稳定UL/row位置FLIP；未写手工scrollTop补偿。该A/B是定位证据，产品最终连续点击/滚动复测结果另列，不能直接将fixture改样式视为最终通过。

随后逐帧确认父行已经移动时，子选中背景仍被共享layout反向平移，出现父行约+321.43px、背景约-321.43px相互抵消。最终仅对语音房行传`sharedLayout=false`，保留父行位置FLIP与其他导航的共享胶囊。`ayla-sidebar-realtime-pill-final/sidebar-realtime-report.json`在1440px常态下三阶段全部通过，且`fixtureAnchorOverride=false`，实际使用产品锚定设置：底部实时排序及503重试后追加的scrollTop全程378，选中背景与按钮y差最大0、背景自身translateY为0，随父行从非零位移回正。首个列表提交即采用真实活动顺序，旧行DOM保留，追加后39个唯一id且没有刷新提示；0运行时错误、0未知API、0断言失败。该专项验证滚动与背景跟随，不把较稀疏采样扩称为逐帧60fps流畅保证。

补充测试单独验证了两个较小契约：`voice-api.test.ts`13项通过，其中新用例确认已换账号时原凭据leave只发一次，401不refresh/重试也不清改新认证；`voice-runtime.test.ts`8项通过，覆盖同选择合并、跨owner A挂起时B跳过且C待A收尾、取消queued选择、旧403对同房重启/换房新心跳均无效，并确认当前403仍正常处理。均只使用合成凭据，记录的是布尔匹配与路径，不输出请求头。此处是各文件局部结果，后续集成批次有重叠时不累加。

**最终语音浏览器联测**：`ayla-voice-race-final-summary.json`汇总1440px的join、members、connect、leave、detail、stale-left、retry503七项，以及900px的join、connect、retry503三项，10/10通过，0运行时错误、0未知API。详情报告分别为`ayla-voice-race-final-1440/voice-race-report.json`与`ayla-voice-race-final-900/voice-race-report.json`。延迟旧工作尚未释放时，路由和唯一选中背景已经指向最后选择C；结算后currentChannelId、活动会话、唯一媒体、心跳与成员均属于C。900px的503重试前保留A已建立媒体与心跳，路由/选中仍为C，重试明确加入C后完成一致收敛。所有门控REST都被显式释放，不能据此声称无限悬挂REST也可向前推进；未使用正式账号、真实麦克风、LiveKit服务器或外部WS，真实媒体传输仍不在该验收范围。

**最终语音与导航自动化**：上层三文件初跑中`use-voice-channel`7项与`group-voice`10项通过；switching文件因`importActual`触发循环mock曾有3项失败及1个未处理拒绝，改为同步mock并等待真实心跳调用后，13项全部通过，耗时9.87s，日志`auroraqua-voice-switching-verified.log`，包含跨hook实例切房与迟到阶段隔离。随后相关16文件151项一次全部通过，耗时120.38s，日志`auroraqua-voice-related-final.log`，覆盖语音UI、store、WS、共享runtime、API、认证与客户端边界。最终语音行背景修正后，subgroup24、group-page16与auroraqua-navigation3，共3文件43项全部通过，耗时26.35s，日志`auroraqua-route-highlight-final.log`。这些结果来自不同且重叠的批次，不能累加为一次全量运行的数量。

**语音阶段冻结类型与构建**：上述背景修正之后，根任务运行`tsc -b --noEmit`通过，Vite生产构建通过，转换676个模块、耗时8.27s；日志为`auroraqua-final-typecheck.log`和`auroraqua-final-build.log`。只有既有静态/动态混合导入与chunk大于500kB提示，没有构建错误。此条取代更早的构建，作为语音阶段代码快照的证据；后续侧栏裁剪另行验收。

修复仅改工程代码、测试与文档，没有数据迁移或正式频道数据操作。实验保持合成账号/频道和隔离传输，未停止、重启用户运行的Elysium。回退需一并撤销该请求编排与客户端取消契约的精确差异，避免上下层只回退一半；不得用共享仓库宽范围恢复覆盖其他工作。

**真实MySQL后端回归**：使用`settings_test_mysql`和独立任务测试库执行真实迁移，9文件回归160项通过、2个不适用参数组合跳过、1项失败。失败是旧直播URL单测硬编码localhost却继承本机SRS配置；只在该单测注入两项settings fixture后，连同新增完整语音人数与撤权空页共3项定向补测全部通过。去重后162项通过、2项跳过；这是一次回归加定向补测，不能描述成9文件一次全绿。日志为`auroraqua-api-mysql-final.log`和`auroraqua-api-mysql-tail.log`。根任务最终只读核验本次三个隔离测试库`test_ayla_auroraqua_20260908_0134`、`0139`、`0143`均由pytest清理，剩余数为0；未写正式库、未修改产品schema或运行配置。

后续样式回归应继续覆盖：宽屏 `.composer`、`.post-detail-composer`、`.voice-room-composer`、`.danmaku-input-area`、`.wide-messages-sidebar .messages-tab`；窄屏 `.group-card-foot`、`.group-chat-subgroup-switcher`、独立工具网格与房间safe-area；交互 `.auroraqua-nav-highlight`、按钮伪元素、两层route/drag原点及reduced-motion后的translate/scale。

## 侧栏吸附标题内容裁剪

2026-09-08，用户明确恢复此前暂缓的标题后透字修复，并追加要求：滚动区聊天/语音/直播三张卡的材料以固定帖子/桌游两张为准。旧“暂缓/未修”仅描述前面阶段，已由本次要求取代。根因是三个透明sticky行与长下拉处于同一滚动容器，内容仍在标题后绘制；加在上三行的额外`backdrop-filter`既不能消除字形，又形成不同于下两张卡的重复采样。处理改为去掉额外行滤镜，五张卡继续共用原`.channel-scene`未选、选中及hover配方，不新增白底或遮挡玻璃层。

`useSidebarContentClip`在原`ChannelSidebar`内批量读取滚动可视区、实际三标题矩形及row-gap，再把clip-path写到三个已有下拉容器。可见区始于本标题底边加gap，止于下一标题顶边减gap；最后一组止于滚动可视区底。顶部/底部吸附使用同一实际几何，反向或零高可见区直接全裁，避免顶部叠卡之间4px缝隙残留字形。clip只影响绘制与命中，不改列表高度、scrollTop、scrollHeight、排序、分页、原row FLIP或语音生命周期。

同步由scroll、ResizeObserver及React布局提交触发；仅观察滚动根的直接childList，处理AnimatePresence内部最终删除零高退出节点而只改变flex gap的情况，不观察自身style。增删子节点同步RO登记，卸载移除listener、断开两类observer，并仅清理本hook最后写入的clip。键盘焦点不会仅因clip自动退出Tab序列，因此另用真实Tab验证；本hook没有focus滚动逻辑、没有新增scroll-padding，也没有任何scrollTop写入。

根任务现有相关回归`subgroup`24、`group-page`16与`directory-load-more`5，共3文件45项通过，23.69s，日志`auroraqua-sticky-related.log`；既有act警告保留，没有新增失败。独立`use-sidebar-content-clip`测试首跑发现卸载后的迟到observer回调仍读取旧容器，现用active守卫在cleanup首步撤销该实例；根任务最终10/10通过，5.47s，日志`auroraqua-sticky-clip-final-tests.log`，覆盖实际顶/底标题、4px缝、零高/反向窗口、纯绘制滚动边界、resize、React与内部退出节点增删、卸载和迟到回调。两批无重复，共55项通过。最终冻结代码的`npm run build`也通过，其中`tsc -b`成功，Vite转换677个模块、8.52s，仅有既有混合导入与chunk体积警告，日志`auroraqua-sticky-final-build.log`；这是本次裁剪代码的构建证据。

**最终浏览器验证**：证据为上述可视化根目录的`ayla-sticky-final/sticky-final-summary.json`、`sticky-occlusion-report.json`与`sticky-pixel-report.json`。1440px、900px各6个滚动/选中状态、每状态3个标题，共36个标题区域；对标题内部、边缘及上下4px gap，将当前正常绘制与临时隐藏后方下拉的反事实截图比较，按任一RGB通道差值大于2计为差异像素，结果均为0。180个命中采样没有命中已裁内容。未选、hover、选中三态逐一比较五张卡的background、filter、border、shadow、radius、color，六字段在同态全部一致，上三行额外filter均为none，原共享选中胶囊保留。

两视口各完成真实Tab、wheel、聊天/语音/直播三组折叠恢复、实际选择语音717，共12项交互通过。Tab从语音展开键进入原先在裁剪区外的710后，浏览器自然滚到651，目标y501–531在本标题底495与下一标题顶834之间，焦点环与命中均可见。wheel将scrollTop从1000推进到1180，scrollHeight保持3493；三组开合与目标717的路由/唯一合成连接均正常。0运行时错误、0未知API、0断言失败。报告有12张状态截图及34条interaction记录，其中22条是材料采集记录，不能把34写成34项业务测试。

**更正诊断中的键盘误判**：初次`ayla-sticky-after-gap`诊断在滚动触发的clip更新绘制前读取样式，曾将目标几何已滚入但clip尚未更新的瞬间判成焦点不可见；原实际截图与最终双rAF稳定后、截图后的命中检查都确认焦点可见，故该早读结论无效。产品没有为此增加未经证实需要的focus滚动或scroll-padding。原`ayla-sticky-before`为修改前基线；`before-stable`与`after-gap`仅是诊断，不冒称重建基线或最终结果。最终批次未注入基线样式或scroll-padding覆盖，截图仅冻结动画以比较稳定绘制；HTTP、WS及媒体仍是隔离合成fixture，不宣称正式媒体或实体设备已验收。

功能验收清单保留原F01–F61编号。后续用户将范围扩大为所有可增长列表与当前可达控件状态，现新增F62–F74；所有用户亲自验收状态仍为待验。F28群帖刷新风险已在后续授权中修复并通过定向测试，不能继续表述为未修复。最新实现和逐项证据以[分页核对](growing-list-pagination-audit.md)及[控件补验](auroraqua-control-state-browser-acceptance.md)为准。

本次涉及前端样式、过渡、加载状态、收藏瀑布布局、列表新增卡进入、目录与群帖真实分页、群搜索头像字段和对应媒体授权边界，以及快速语音切换的请求/连接所有权和侧栏吸附标题裁剪修复；无数据库迁移，无正式Elysium服务启动或重启；实现验收结束时尚未提交或推送，这是该阶段的历史状态。分页后端与前端需作为兼容版本一起部署，旧无分页参数消费者继续工作。回退可按本任务差异逐hunk撤销；不要对共享工作区执行宽范围restore。

后续提交：本阶段12个模块及父指针已逐对提交，Ayla截止`26e6e85`。用户随后扩展为所有可增长列表与当前可达控件状态；新增实现、最终验证与下一轮模块边界见[本轮交付记录](auroraqua-all-lists-delivery.md)。每次模块提交仍立即同步父仓库指针，最终ID以Git历史为准，未推送。
