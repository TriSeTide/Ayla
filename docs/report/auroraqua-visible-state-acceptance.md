# Auroraqua 当前可达界面状态验收清单

2026-09-08。建表基线为 Ayla 本地提交 `26e6e85`，依据 `web/src/App.tsx`、`layout/shellConfig.ts` 及下列实际组件读取。清单覆盖当前路由和能被真实入口打开的界面分支；每行是一组可执行的状态要求，不把行数当成截图数或独立测试数。本轮分页与错误恢复已经落地；有限补验批次已经收口，下表逐行记录动作证据和历史复用边界，不将代码存在等同于通过。

本轮目的：补齐此前“页面、材料及选定交互通过”与“当前可达卡片、按钮、输入状态均已有证据”之间的缺项。**本表区分当前有效证据、仅可复用的历史材料，以及尚未取得结果的分支，不笼统宣称全站状态通过。** 浏览器 fixture 必须截断真实写请求、媒体连接及外部通知，只用合成数据；截图不得包含真实凭据、推流密钥或私人聊天。

## 执行与判定

- 视口：每个不同布局至少窄屏 375 和宽屏 1440；双栏/工具栏/弹层边界另用 768、769、900。状态只影响文案而结构相同时可以复用布局对照，但需记录实际触发的分支。
- 每个可操作按钮至少检查默认、真实指针 hover、按下、键盘 Tab focus-visible；仅在源码有 `disabled` 分支时验证 disabled。选中、展开、pending、失败由每行明确列出。不能用 CSS 强加伪类冒充真实交互结果。
- 每个可编辑字段检查空、输入、focus、长文本换行/溢出；源码可达时再检查校验、只读/禁用、提交中和错误。浏览器原生 required/email 错误与应用内错误分别记录。
- 弹层检查入口、打开终态、初始焦点、Tab 可达、遮罩/关闭/Escape 的实际支持、关闭后布局与焦点；无源码支持的路径只登记现状，不预设为已实现。
- 滚动/折叠/追加列表检查内容裁剪、真实 wheel、滚动位置、末页/footer、新增卡片入场与旧卡片稳定；动画同时检查正常与 reduced-motion。不能把静态截图代替时间序列或交互验收。
- 每次结果记录：ID、代码 revision、route、viewport、角色/fixture 分支、实际动作、截图/JSON、控制台错误及未知 API、结论。待验改为通过必须有可追溯证据；产品变化后原证据标为历史。

状态含义：**已验**后只列有动作/截图/JSON的分支；**已有专项/复用**限定历史证据范围。`E*`为历史专项，`R*`为当前补验索引。同一行保留具体适用边界，不能把整行机械折算为一个通过数字。

## 路由覆盖

| 路由族 | 可达入口与页面 | 对应状态组 |
| --- | --- | --- |
| `/login`、`/register` | 公开认证页 | V01–V02 |
| `/group` | HomePage；`/`、`/home`、未知路由重定向到此，不另计页面 | V03–V08、V13 |
| `/voice`、`/voice/:channelId` | 语音目录、语音房 | V15、V40–V44 |
| `/live`、`/live/:channelId`、`/live/start/:channelId` | 直播目录、观众页、主播页 | V16、V45–V51 |
| `/posts`、`/posts/mine`、`/posts/:postId` | 公开帖子、我的帖子、详情 | V17、V35–V39 |
| `/games`、`/games/:roomId` | 桌游目录、占位房间；没有独立对局引擎页面 | V18、V52–V53 |
| `/messages`、`/chat/:conversationId` | 消息中心、私聊；宽屏可在消息中心嵌入私聊 | V24–V34 |
| `/search`、`/profile`、`/user/:userId`、`/favorites` | 搜索、自己资料、他人资料、收藏 | V54–V62 |
| `/group/:id`、`/group/:id/:scene` | 群聊天、info/posts/voice/live/games；无效 scene 按当前 GroupPage 处理 | V19–V23、V24–V44、V45–V53 |
| `/group/:id/posts/:postId`、`/group/:id/voice/:voiceChannelId`、`/group/:id/live/:liveChannelId` | 群内帖子/语音/直播详情 | 同对应详情组，另验群壳层与侧栏 |

## 公共壳层、卡片与创建入口

| ID | 当前真实入口/源码 | 必须触发的状态 | 当前证据与精确缺项 |
| --- | --- | --- | --- |
| V01 | LoginPage | required 空提交、两个字段 focus/输入、提交 pending 禁钮、401/网络错误、注册链接与成功路由 | 已验：两宽原生 required、字段键盘/指针、pending、401/服务失败、纠正与成功路由、注册链接；R01。仅合成账号服务。 |
| V02 | RegisterPage | required/email 原生校验、短密码、两次密码不同、可选昵称空/长、pending、服务错误、成功/返回登录 | 已验：两宽 required/email、短密码/不一致及纠正、可选昵称、pending/服务失败、成功与返回登录；R01。 |
| V03 | TopNav / BottomTabs / NarrowTopBar | 五主 tab 选中与切换；无所属模块页不高亮；消息/头像/搜索入口；窄屏搜索展开/清空/退出 | 已验：五主模块实际切换/高亮、非模块不误高亮、导航控件四态、窄搜索展开/提交/清除/返回；R02。 |
| V04 | ServerRail / HomePage LayoutSwitch | 群头像有图/失败回退、未读、当前群、布局切换；空群/多群/溢出滚动；创建入口 | 已验：群目录30→60→65、末页、尾错保留/重试、未读/当前群/活动角标、窄屏卡片与列表切换、创建入口；R06/E2。两宽空群创建入口、头像签名503回退仍能点击进入群见R26。 |
| V05 | ScrollTopFab / RefreshFab | 滚动未过阈值不可 Tab；过阈值出现/回顶/换路由隐藏；刷新旋转/结束；窄宽堆叠避让 | 已验：宽屏真实滚动/回顶/刷新pending与完成、窄屏CDP触摸下拉刷新/回顶、带滚动换路由后隐藏且tabindex=-1；R02。RefreshFab仅宽屏存在，没有disabled分支。 |
| V06 | SessionActivityIndicator | 无活动不显示；仅语音、仅直播、两者；当前房间隐藏对应入口；折叠/展开、拖动限界、Tab/Enter | 已验：无/单/双活动、折叠/展开、真实拖动限界、Tab/Enter、折叠后不可聚焦、房内隐藏自身入口；R02。活动身份为合成store快照。 |
| V07 | RealtimeStatusBanner | 全在线/预期 offline 隐藏；connecting、failed、一项/多项、长错误换行；状态变化 | 已验：两宽online/offline隐藏、connecting/failed、多项长错误、恢复及玻璃穿透修复后12状态；R03。 |
| V08 | MessageFab / QuickMessageFab / QuickMessagesSheet | 一级页常驻入口、其他可达页未读触发、0/多未读；打开/关闭、私聊进入、列表空/错 | 已验：主页零未读入口、其他页零未读隐藏/123显示99+、徽标归零保持已开面板、打开私聊/返回/关闭及空错；R02/R08。 |
| V09 | CreateFab / CreateSheet | 五种实际创建入口；随路由关闭；群内 posts/live 使用自身入口；窄屏底部/宽屏居中；焦点及关闭 | 已验：两宽五种实际创建入口打开与history-back路由变化后关闭；宽屏建群沿ServerRail，窄屏沿CreateFab；R24。不是五选项展开菜单。 |
| V10 | ConfirmDialog 各真实调用处 | 自动聚焦取消、长标题/正文、取消/确认/关闭/Escape/遮罩；busy 调用时禁止关闭；宽窄 portal 不裁切 | 已验：会话删除、群管理/转让/子群、语音删除和桌游删除的实际入口；两宽普通/reduced默认取消焦点、Tab圈定、Esc只关闭顶层/回焦；R07/R09/R16/R17。busy只按各调用是否传入验证，不能统一推定。 |
| V11 | Avatar / ResourceImage / SignedVideo / FavoriteButton / Tags | 真图片解码、缺图与失败回退、长名称、在线/活动标志；收藏未选/已选/pending/error/disabled（按源码） | 已验：独立收藏按钮unknown/加载失败/pending/失败/成功/WS迟到保护；R11。图片失败重试/查看器见R13，视频签名/原生播放错误及重试见R22；Avatar/Tags正常材料沿用E4，不能由收藏按钮推定所有媒体态。 |
| V12 | AsyncState / StablePaginationFooter / DirectoryLoadMore | 首次骨架、成功空态、首错重试、追加 loading、追加失败重试、末页、查询切换；每个数据 owner 分开验 | 已验：社交、收藏、搜索、资料、语音/直播历史、自有直播、群直播、成员、表情和三个帖子目录的各自分页owner；R06–R08/R10–R12/R14–R21。没有用一次通用footer测试替代各owner。 |
| V13 | GroupCreateDialog | 空名称禁提交、成员查询 loading/空/有结果、选择/移除 chip、打开私聊 busy/error、创建 pending/error/success | 已验：空名、搜索首/尾错重试、30→65、跨查询已选保留/移除、私聊失败、建群pending/失败/成功；R06。两宽直接私聊pending禁钮及成功导航/关弹窗见R25。 |
| V14 | VisibilitySelector（V15/V17/V18 等表单内） | public/friends 互斥、group 组合、当前群锁定 disabled、多群勾选、搜索无匹配、加载骨架/无群 | 已验：public/friends互斥且可与group组合、锁定群disabled、页外群搜索/多选chips保留、无匹配/错误/重试、合成创建参数；R04/R05/R06。 |
| V15 | VoiceChannelCreate | 名称空点击/Enter 校验、合法名、pending 禁钮、服务错误保留表单、创建成功；公开及锁定群两入口 | 已验：公开/锁定群两入口、两宽空Enter不请求、64字符上限、组合可见性、pending防重复Enter、503保稿、trim参数成功关闭；R05。 |
| V16 | LiveStartSheet | 正在加载、错误、没有自有房、有多个自有房、LIVE 标识；选已有房/+新建 pending/error/成功 | 已验：本人房间20→40→45、首/尾错、选第45房进入控制台和侧栏续读；R15。新建pending/503见R04；两宽自有房空、新建pending/成功关闭弹窗进入studio见R26。 |
| V17 | PostEditor（公开 sheet、群内底部） | 收起/展开；空标题/正文禁发布；附件预览/移除、上传中、校验失败、部分上传失败重试、上限、发布 pending/error | 已验：公开发帖空禁发布、长字段、可见性组合、附件部分失败/重试/移除/9项上限、pending与合成成功；R04。群内同一PostEditor的收起/展开和锁群材料复用E3，锁群选择器契约见R06；没有把公开提交截图冒充群内独立重跑。群帖子目录见R21。 |
| V18 | GameRoomCreate | 空名禁钮、Enter 空校验、可见性、pending、服务错误、创建成功；公开/群内入口 | 已验：公开/锁群两入口、两宽空Enter/64字符上限/pending防重复/503保稿/trim参数成功；R05。 |

## 群壳层、管理与聊天

| ID | 当前真实入口/源码 | 必须触发的状态 | 当前证据与精确缺项 |
| --- | --- | --- | --- |
| V19 | ChannelSidebar / GroupTopTabs | 群子场景选中；聊天/语音/直播展开/收起、空/长列表、创建权限；切换路由时高亮立即更新 | 已验：即时路由高亮、折叠/长列表/末页与实时排序，E6；新子群30→60→65和默认项解析见R07。创建权限已按owner/admin/member对照，R07。 |
| V20 | ChannelSidebar 吸顶区 | 三标题阅读区、边缘/间隙、滚动/折叠/追加/排序中隐藏内容不命中；键盘自然滚动可达 | 复用E7三标题阅读边界/命中/滚动/折叠专项；当前diff只改子群数据页与追加footer，没有修改吸顶行结构、定位代码或group.css。已目视对照R24当前900/1440群聊天侧栏布局；180命中点仍是E7历史执行数量，不冒充本轮重跑。 |
| V21 | GroupInfo 基本/管理表单 | owner/admin/member 三角色；编辑与取消、名称/描述/头像、保存 busy/error；加入方式 listbox、开关、申请审批、禁用 | 已验：owner编辑取消/长字段，admin/member权限差异及审批30→60→65、错误/重试、同意/拒绝结果；R07。两宽资料校验/提交/失败/成功、头像类型/预览/上传失败保留/成功、加入方式/表情开关及成员设管理员/移除失败重试见R25。 |
| V22 | GroupInfo TransferOwnerDialog | 名称搜索、有/无候选、选择、未选禁确认、busy/error、第二层转让确认、取消返回 | 已验：首屏30不自动耗尽、搜索/无匹配、未选禁钮、跨查询保留选择、二次确认/取消、失败保留；R07。两宽转让pending冻结、成功后关闭弹窗且角色降为成员见R25。 |
| V23 | SubGroupDialog + 群管理确认 | 新建/编辑、空名禁保存、muted 开关、默认组不能删除、busy/error；删子群/退群/解散/转让确认 | 已验：添加/编辑真实入口、空名禁保存、默认子群禁删除、muted切换/保存失败、解散确认取消、普通成员退出确认/Esc；R07。两宽非默认子群保存、删除取消/pending冻结/错误可见/重试成功，解散与退出失败/成功见R25。成员移除是直接动作。 |
| V24 | GroupChat / PrivateChatPane | 初始 loading、找不到/权限拒绝、空历史、长历史、自己/他人/系统消息、顶端历史追加/失败、新消息提示 | 已验：两宽历史读取失败/重试成功、非好友拒绝、空输入与长历史操作，R22；聊天分区/切换/历史材料E5/E8。消息目录空错不代替聊天历史空错。 |
| V25 | MessageInput | 空/文字/长多行、发送 disabled、回复引用与取消、禁言只读提示、窄宽工具栏、发送失败；粘贴/选择附件 | 已验：两宽空输入禁钮、长多行、发送pending保留新稿、失败/重试成功、引用/取消后quote-bar消失、选图/文件替换/空文件错误、上传失败保留本地媒体/重试；R22。追加两宽粘贴预览、群禁言、上传可取消及撤回失败后重试成功清notice；@分页与工具栏见R09/E1/E2。 |
| V26 | MessageBubble / MediaContent | 消息 hover 动作、回复、未发送/发送中/失败重试；图片/视频/文件/语音各类型、加载/损坏回退 | 已验：帖子/评论共用ResourceImage错误与查看器，R13；两宽聊天descriptor/文件签名错误重试、音频加载失败/play拒绝/重试播放/暂停拖动、视频签名及查看器原生error重试，R22。使用可解码合成媒体，不连接正式媒体服务。 |
| V27 | ConversationMoreMenu / ConversationList | 菜单打开/选中/hover/press/键盘/Escape；置顶/删除确认、动作pending/error；未读长文本 | 已验：两宽普通会话与375快捷面板首末行命中、指针/键盘、Esc仅关菜单/回焦、外点、pin pending/失败/成功、删除取消/失败保留/成功；R09。新portal的reduced专项亦通过；当前菜单没有免打扰项。 |
| V28 | MentionPicker | 输入 @ 打开、有匹配/无匹配、方向键/Enter/点击选择、长名单滚动、关闭与焦点 | 已验：两宽首屏30、追加失败保留/重试60、服务端搜索第65人、无匹配、键盘token/Esc；portal材质已目视复验。reduced方向键进入/移动/选择/回焦/空态通过；R09。 |
| V29 | EmojiPackPanel | 无表情/多表情、角色可上传/删除、上传中/部分失败、发送/失败、关闭、长列表滚动 | 已验：两宽群表情30→60→65、首/尾错、部分上传保留、已解码图片发送失败、删除失败/重试、三权限/空态/关闭；R20。系统包搜索只有API没有当前可见入口，不虚构页面。 |
| V30 | 语音录制工具（MessageInput） | 能力支持/不支持入口；开始、录音时长、取消、停止发送、上传中、权限失败/上传失败重试 | 已验：两宽权限等待/拒绝、录音中/取消、停止失败、上传失败/重试发送、不支持入口，R22。使用合成媒体能力，不实际采集。 |
| V31 | ImageViewer | 单张/多张、首尾翻页禁钮、上一张/下一张、视频、保存 pending/error、未发送本地媒体禁保存、Esc/关闭 | 已有图片/多图/视频查看及键盘/滑动E8；两宽视频签名失败、原生error与重试至ready、保存pending/error/重试请求、本地媒体禁保存已验R22。保存重试请求成功不等同于真实文件系统下载落盘。 |
| V32 | MessagesPage / WideMessagesSidebar | chat/friends/requests tabs、宽屏左右独立滚动、私聊未选占位、会话空/加载/失败/重试、好友空态 | 已验：宽屏消息中心、窄屏中心/快捷面板；各目录30→60→65、追加错误保留/重试、DOM稳定、初错/空/重试、私聊未选/打开；R08。 |
| V33 | 消息中心好友与认证 | 好友移除 busy/error；好友申请、群邀请、入群申请同意/拒绝；退群与本地通知“知道了”；全空 | 已验：好友移除失败/成功，好友申请/群邀请/入群申请的失败与拒绝成功，退群通知已读、各类空态；R08。两宽好友/群邀请同意成功移除对应项见R26，管理员审批同意见R07。 |
| V34 | ElysiaEntry / QuickMessagesSheet | 入口加载/错误/正常、私聊进入失败；快捷面板空/多会话/未读、打开目标后关闭与窄宽差异 | 已验：Elysia入口正常/不可用/私聊进入失败，快捷多会话/未读、通知分页空错、实际私聊打开/返回/关闭、未读归零仍保留；R02/R08。 |

## 帖子、语音、直播、桌游

| ID | 当前真实入口/源码 | 必须触发的状态 | 当前证据与精确缺项 |
| --- | --- | --- | --- |
| V35 | PostsHub / GroupPosts / MyPosts | 首骨架/空/首错、正常卡片与长文展开、追加 loading/error/末页、查询/筛选刷新、缓存返回 | 已验：两宽三个目录长卡片、20→40→47、尾错保留/重试、末页、缓存返回、首错/空态；R21。MyPosts已补尾错重试入口；R13评论分页不用于替代本行。 |
| V36 | PostCard | 图/视频封面、作者入口、长标题/正文、展开/收起、收藏状态与失败（按各页实际 props） | 已验：帖子/评论图片失败后重试和查看器，R13；收藏动作与错误R11；两宽长文展开/收起和作者资料入口R21。当前PostCard只有评论数/浏览数/收藏，没有点赞按钮。 |
| V37 | PostDetailPage | 骨架、找不到/失败返回、本人/他人操作差异、编辑全屏、保存禁用/pending/error、媒体新增删除/错误 | 已验：作者/非作者差异、编辑pending/错误/成功、fresh首错/返回/404及媒体增删保存，R13。另修复1600ms终态确认的详情/评论透底：编辑期间原三区域hidden/inert/aria-hidden，保留原DOM/草稿/320px滚动位置；两宽稳定图只透出页面背景，保存后状态和焦点恢复。旧动作PASS不代表旧编辑视觉通过，视觉结论由修后证据替代。 |
| V38 | 帖子删除 / 评论动作 | 帖子两次点击确认文案、取消/错误；评论自己/别人可见操作、回复定位、删除成功/失败、无评论 | 已验：帖子内联二次删除确认/pending/失败、本人/他人操作边界、评论回复归因及删除pending/失败/成功；R13。帖子确认是内联二次点击，非ConfirmDialog。 |
| V39 | CommentComposer | 文本/纯图/图文、空禁发送、上传进度/失败重试、图片上限/移除、回复目标/取消、发送中/错误 | 已验：空禁发送、评论部分图片失败/重试/移除、回复、发送pending/错误/成功及请求期间新稿保留；R13。追加两宽4图上限、纯图发送、图文发送成功。 |
| V40 | VoiceHub / GroupVoice 目录 | 骨架、空、首错、追加失败/重试、末页、当前/可加入/无权限、删除入口角色差异 | 已验：语音房403/重试、非owner隐藏、成员目录20→40→45、首尾错与125人轻量运行对账；R16。语音频道目录分页正常/末页沿用E5/E6，避免混同成员分页。 |
| V41 | 语音频道删除确认 | 本人创建可删、非本人隐藏；确认/取消、失败反馈、当前频道被删除状态 | 已验：两宽本人创建删除确认/取消、失败保留当前runtime、成功清runtime；非owner隐藏由权限场景覆盖；R16。 |
| V42 | VoiceControls / VoiceChannelPanel | idle/connecting/connected/reconnecting/failed；WS online/connecting/offline；错误、重新加入、离开 | 已验：两宽idle/connecting/connected/reconnecting/failed及WS三态，失败重加与离开在当前成员批次真实触发；R16/E10。状态注入不代表真实网络重连。 |
| V43 | VoiceMemberRow | 自己/他人/爱莉技术状态；静音/恢复、slider 最小/最大/focus、说话音量环、长名/头像回退 | 已验：自己麦克风、他人静音/恢复、slider Home/End；补齐长名/技术标签/说话量和实际Tab焦点；R16。媒体与音量输入为合成快照。 |
| V44 | 语音路由切换与窄宽房布局 | 延迟 join/members/connect/旧 leave、快速 A/B/C、重试503、旧事件；900/1440面板与375/769边界 | 已有专项：E10十个语音竞态、即时路由高亮与失败保留/重试；当前成员改造后的重加入/离开R16，宽窄房间和断点R24/E11。没有真实LiveKit或永不结算REST证明。 |
| V45 | LiveHall / GroupLive / ChannelRail | 空/首错/列表、直播/离线卡片、当前选中、长列表滚动、追加 loading/失败/末页；群内开播入口 | 已验：群直播20→40→45、首/尾错、空态、选择页外房间；自有房/主播侧栏R15，群直播R18。公开目录既有排序/末页E5/E6，不能将群内场景当所有公开状态。 |
| V46 | LiveRoomBody / LivePlayer | 未开播、连接中、播放失败、直播画面；controls 显隐、跳最新、PiP 支持差异、fullscreen 进入/退出 | 已验：等待/未播/失败/直播分支、controls三秒隐藏/唤醒、真实fullscreen进出、宽PiP API拒绝保留、窄PiP不显示；R19及旧媒体控件有效场景。无真实视频解码证明。 |
| V47 | 全屏弹幕 / DanmakuInput | 空禁发送、输入、发送中、失败、全屏输入随controls显隐；图片上传与发送重试、等待期草稿、键盘焦点（当前无弹幕开关控件） | 已验：空禁发送、输入focus、fullscreen与controls显隐；R14/R19。R27补齐两宽普通/全屏新稿保留、重复Enter锁、图片上传失败重试、发送失败复用原media ID和文字、切房迟到上传零POST、全屏错误可见且不挤压32px输入行、成功重试。当前没有独立弹幕开关。 |
| V48 | DanmakuList / DanmakuOverlay | 空/多/长弹幕、历史分页/继续读取/回最新、旧窗与实时隔离 | 已验：语音/直播历史首错、50→100→120、追加错保留/末页、旧阅读窗口与实时帧隔离、回最新失败重试、合成WS重连；R14。当前没有自己/系统专属样式，入口是继续读取/回最新，不虚构暂停开关。 |
| V49 | LiveStudio / LiveOwnerPanel | 本人/非本人/加载/无权限/错误；编辑标题简介封面可见性、dirty/pending/error；开播/停播/删除控制 | 已验：两宽本人/非本人/首错/重试、资料校验/长字段/可见性/保存，封面类型/预览/上传错重试，开播/停播pending/失败/成功及删除；R18。主播删除是直接动作，没有ConfirmDialog。 |
| V50 | LiveStreamAddresses | 3类地址、复制成功/失败、超长地址水平/换行、提示文本；只用假地址，勿截真实密钥 | 已验：两宽三类合成地址复制失败/成功及布局；R18/E11。没有真实推流密钥进入证据。 |
| V51 | LiveMiniPlayer | 拖动限界、双指缩放、点击/Enter 返回、关闭；与活动按钮/FAB/底栏并存时自身可操作、可拖动移开（当前无独立展开/收起控件） | 已验：1440 PiP支持/拒绝、375无PiP入口；小窗返回/真实拖动限界/Enter/关闭；375CDP双触点缩放120×68至320×180、松手不误返回；R19。375最大尺寸可覆盖部分底栏，证据证明小窗自身操作和可移开，不证明所有位置下导航同时可命中。没有独立展开/收起按钮。 |
| V52 | GamesHub / GroupGames / GameRoomCard | 初载/空/首错、长卡片、房主/成员/访客、加载更多/追加失败/末页、详情返回 | 已验：房主/成员/访客在房间操作与回目录，R17；目录初载/空错/追加/末页复用E5，当前断点布局见R24。本轮GamesHubPage与GroupGames没有源码差异，资料页新增mine/owner参数不改变这些目录请求，不将成员分页证据冒充目录重跑。 |
| V53 | GameRoomPlaceholder | 访客加入/成员离开 pending/error；房主成员列表、移出/转让 busy/结果、删除确认/失败 | 已验：访客加入与成员离开pending/失败/成功；房主成员20→40→45真实wheel、尾错、页外移出/转让pending/失败/成功、删除取消/失败/成功；R17。只验现有占位控制，无对局引擎主张。 |

## 搜索、资料、收藏与交叉状态

| ID | 当前真实入口/源码 | 必须触发的状态 | 当前证据与精确缺项 |
| --- | --- | --- | --- |
| V54 | SearchPage | 初始无查询、搜索中/空/失败、五种结果组、更多、长查询/清空、各结果卡片 hover/focus | 已验：五结果组分别分页、空/首错/尾错/重试、返回位置、长查询/清空、卡片四态；R10。壳层初始无查询与搜索返回见R02/R24。 |
| V55 | 搜索 UserProfileCard | 长昵称/签名/头像、打开关闭、加好友申请中/失败、发消息进入中/失败/成功 | 已验：长昵称/签名、用户卡打开/关闭、好友申请pending/失败/成功、私聊pending/失败/导航；R10。成功没有另造源码不存在的独立提示。 |
| V56 | 搜索申请入群弹层 | 未加入群入口、输入申请说明、pending 禁钮/取消、失败、成功反馈、遮罩/关闭 | 已验：未加入身份来自服务端is_member，申请说明长文、pending/禁钮、失败/成功、公开群直接加入；R10。关闭路径按实际控件/遮罩支持验证。 |
| V57 | ProfilePage 表单 | dirty 前禁保存、编辑/保存中/成功/失败；在线状态 radio、可见性 switch、长签名；退出登录 | 已验：clean/dirty、四状态radio、展示switch、pending/503保稿、长签名/退出；trim同步及等待期新文字/新头像保留，R04/R12。 |
| V58 | ProfilePage 头像/内容列 | 头像预览/上传中/错误、本人帖子/直播/桌游各骨架/空/错/分页、独立滚动与卡片操作 | 已验：头像类型/预览/上传失败/重试/保存、本人帖子/直播/桌游独立20→40→45、首尾错保留/重试、折叠/滚动；R04/R12/E4。 |
| V59 | UserProfilePage | 加载、找不到/失败、自己ID跳本人页、好友/待验证/陌生人、加好友/发消息busy/error、内容空/错/隐藏 | 已验：本人/好友/陌生人内容分区、隐藏内容不请求、资料失败重试、好友动作失败保留卡片；R12。两宽自己ID跳/profile、pending_sent禁申请、pending_received进入消息中心见R26。 |
| V60 | FavoritesPage | 全部/各类别 tab、加载、空、首错重试、消息/帖子/语音/直播/群/桌游不同卡片、取消收藏失败 | 已验：两宽六分类20→40→47、空/首错/尾错/重试、旧DOM/返回位置、失效目标、取消失败保留/成功删除、WS更新、18控件四态；R11。 |
| V61 | 覆盖层组合 | CreateSheet/Confirm/Viewer/菜单在当前页滚动/其他活动UI并存时不被裁切；一个真实组合至少宽窄各验 | 已验：快捷面板上菜单/Confirm的真实两层组合及reduced关闭归属，R09；群转让/子群二次确认R07；播放器/活动球组合R19/R02。按这些真实组合收口，不推定任意多层笛卡尔积。 |
| V62 | 响应式与减少动效 | 每种实际布局 375/768/769/900/1440；文本缩放与长名称；正常/reduced 下 loading、弹层、按压、追加/折叠终态 | 已验：既有响应式15路由5断点+125%视觉zoom共90有效状态（原13+修正2场景），另两宽15路由字号/行高×1.25共30状态无横向文档溢出；R24。文字压力并非真实浏览器字体缩放；新菜单/Confirm/@ reduced25状态R09，其他动效按各历史专项边界。 |

## 既有证据索引与适用边界

证据根目录：`C:/Users/ricer/.codex/visualizations/2026/09/07/01a07c53-0232-7d91-83a9-15341768ca76/`。以下是此前已核对过的专项索引，详细数值与修复边界以 `auroraqua-style-migration.md` 为准。本表不将多批数量相加成一次测试，也不把单元测试当作视觉状态截图。

| 索引 | 证据目录/文件 | 可以复用的范围 |
| --- | --- | --- |
| E1 | `ayla-input-single-glass-verified/`、`ayla-input-auth-verified/`、`ayla-profile-expanded-materials/` | 24个有效页面/45字段材料与资料行背景；不包含全部 validation/focus/pending |
| E2 | `ayla-auroraqua-toolbars-final/`、`ayla-auroraqua-server-rail-final/`、`ayla-narrow-latest-settled/` | 工具栏尺寸、壳层/导航与窄屏正常布局 |
| E3 | `ayla-group-surfaces-final/`、`ayla-post-panels-normal/`、`ayla-post-panels-reduced/`、`ayla-auroraqua-subgroup-overlay-final/` | 群/帖子面板、编辑器与指定弹层材料/动画 |
| E4 | `ayla-latest-layouts/`、`ayla-profile-owner-final/`、`ayla-profile-scroll-final/` | 资料/收藏/搜索/直播正常布局、头像、独立滚动 |
| E5 | `ayla-loading-padding/`、`ayla-loading-media-history-final/`、`ayla-pagination-stable-footer-final/` | 骨架对齐、历史/媒体加载、指定目录追加503重试与footer稳定 |
| E6 | `ayla-sidebar-realtime-pill-final/`、`ayla-sidebar-six-terminal/` | 实时目录排序/选中背景、末页侧栏与折叠 |
| E7 | `ayla-sticky-final/sticky-final-summary.json` | 1440/900三标题阅读区36像素区域、180命中点、12真实交互；不等同所有控件态 |
| E8 | `ayla-partition-chat-1440/`、`ayla-partition-chat-900/`、`ayla-partition-chat-reduced/` | 聊天分区/切换与选定媒体/历史流程 |
| E9 | `ayla-auroraqua-more-final/`、`ayla-auroraqua-more-reduced/` | 更多菜单宽窄、普通/reduced、hover/press/Escape |
| E10 | `ayla-voice-race-final-summary.json`、`ayla-voice-race-final-1440/`、`ayla-voice-race-final-900/` | 10个fixture语音竞态场景；没有真实麦克风/LiveKit服务/永不结算REST证明 |
| E11 | `ayla-studio-voice-responsive-final/`、`ayla-voice-1024-final/`、`ayla-studio-scroll-verified/`、`ayla-studio-collapse-verified/`、`ayla-live-studio-materials/` | 房间/主播页容器响应式、折叠、滚动与玻璃材料 |
| E12 | `ayla-control-states-first/`认证场景、`ayla-auth-states-complete/control-states-report.json` | V01/V02宽窄正常、校验、pending、错误、真实指针/键盘与隔离成功；详见`auroraqua-control-state-browser-acceptance.md` |

## 已排除的伪入口与补验顺序

`LiveCreate` 组件当前没有页面直接挂载（其地址解析 helper 被复用），实际创建入口是 `LiveStartSheet`；`ElysiaVoicePanel` 当前没有页面调用。它们不冒充当前可达产品页。无效路由跳转与兼容别名另验导航，不重复计完整页面。`UserProfileCard` 真实挂载入口是搜索结果，组件注释提到的好友/群成员场景不能代替实际引用证据。

## 当前补验索引与替代关系

以下目录若未加前缀，位于上述可视化证据根目录；`T/`表示本机临时证据根 `C:/Users/ricer/AppData/Local/Temp/auroraqua-reference-audit-20260907/`。各目录默认读取 `control-states-report.json`。详细流程见 [控件浏览器验收](auroraqua-control-state-browser-acceptance.md)。只采用指定case/width，未选中或被替代的中断不能混入通过数量。

| 索引 | 最终证据与限定 |
| --- | --- |
| R01 | `ayla-auth-states-complete`42状态/22控件四态，`ayla-auth-route-links`4状态；认证字段SHA见报告。 |
| R02 | `ayla-shell-state-branches`、`ayla-pull-refresh-narrow-verified`；活动正常场景来自`ayla-media-control-states-first`，其1440中断由`ayla-activity-wide-verified`替代；交叉补充`ayla-shell-cross-states-final`15状态。V05以`ayla-scroll-route-verified`两宽2场景11状态验证回顶/刷新/换路由隐藏，替代固定1100ms等待的过早采集。 |
| R03 | `ayla-status-banner-glass-verified`两宽12状态，替代无滤镜时的旧横幅外观。 |
| R04 | `ayla-control-states-first`中通过的创建/资料场景；`ayla-form-branches-final`采用两宽资料+375发帖，1440发帖由`ayla-post-form-submit-verified`11状态替代。 |
| R05 | `ayla-create-branches-final`语音/桌游公开/锁群两宽8场景56状态，包含实际Enter防重入及成功。 |
| R06 | `ayla-social-directory-final`4场景29状态，群目录/轻量订阅、建群搜索与可见性。 |
| R07 | `ayla-group-management-verified`24状态/12控件矩阵；`ayla-group-role-approvals-verified`4场景24状态。旧`ayla-group-role-approvals-final`采集越过目标/入场首帧失败不计入；解散确认早期窄屏采样由`ayla-group-confirm-narrow-verified`替代。 |
| R08 | `ayla-social-notifications-final`79状态；空/首错采用`ayla-message-empty-error-verified`的375普通15+快捷13，以及`ayla-message-empty-error-wide-verified`1440的15状态，明确排除前一目录1440中断。 |
| R09 | `ayla-menu-actions-verified`30状态；`ayla-mention-portal-verified`12状态；新`ayla-popovers-reduced-verified`5场景25状态，实际reduce、终态、方向键/Home/End、Tab圈定与Esc回焦。旧菜单E9和修复前@交互不代替当前portal视觉证据。 |
| R10 | `ayla-search-pages-verified`30状态/14控件矩阵，`ayla-search-actions-final`16状态。 |
| R11 | `ayla-favorite-pages-verified`32状态/18控件矩阵；`ayla-favorite-status-controls-final`16状态/2按钮矩阵。 |
| R12 | `ayla-profile-content-pages-final`12场景94状态/6控件矩阵；verificationRuns记录首次StrictMode消耗错误fixture和纠正后30状态的替代关系。 |
| R13 | `ayla-post-comment-states-final`58状态/18控件矩阵；`ayla-comment-final-branches`两宽6状态补齐4图上限、纯图及图文发送；`ayla-detail-final-branches`两宽12状态补齐fresh详情首错/返回/404和编辑媒体增删保存。后续`ayla-post-edit-settled`诊断确认旧编辑视觉透底，最终`ayla-post-edit-settled-fixed`两宽2场景12状态及editSettle/editRestore替代旧编辑视觉结论，验证原DOM/草稿/滚动/焦点。重复动作不相加成独立通过数；脚本case名中的V35不直接作为PostsHub/MyPosts目录证据。 |
| R14 | `ayla-media-history-pages-verified`32状态；直播重连最终采用`ayla-live-history-reconnect-verified`22状态；旧历史读取不进入实时overlay。 |
| R15 | `T/ayla-owned-live-pages-visible`的owned-live-pagination两宽16状态；包含第45项及控制台侧栏分页。 |
| R16 | `T/ayla-member-controls-scroll-verified`只采用voice-visible45/voice-runtime125两宽18状态；`T/ayla-members-final`只采用voice-delete两宽6状态；`T/ayla-media-final-role-actions`的voice-permission-retry；旧媒体控件脚本中的音量Home/End与静音/恢复共同组成V43证据。 |
| R17 | `T/ayla-members-final`只采用game-member-actions两宽14状态；`T/ayla-game-wheel-final`两宽24状态；`T/ayla-media-final-role-actions`的game-delete-success。 |
| R18 | `T/ayla-group-live-pages-final`14状态；`T/ayla-live-control-branches-second`只采用studio-owner-actions两宽36状态；`T/ayla-live-role-errors-final`6状态；`T/ayla-studio-cover-final`8状态。 |
| R19 | 采用`T/ayla-player-pip-final`的1440五状态与`T/ayla-mini-touch-final`375十一状态。后者以真实CDP双触点补齐缩放，替代旧375播放器九状态；不是两批全部相加。 |
| R20 | `T/ayla-emoji-signed-media-final`两宽30状态；已补签名承接与实际图片解码，替代早期漏签名fixture的报告。Ref选中case/width及逐文件SHA见`T/media-final-whitelist.json`。 |
| R21 | `ayla-post-directory-states-final`两宽12场景42状态、14控件矩阵，PostsHub/GroupPosts/MyPosts三种目录均覆盖长卡片、20→40→47、尾错保留/重试、缓存返回、首错/空态；`ayla-post-card-final-branches`两宽6状态验证长文展开/收起、作者资料入口，实际无点赞按钮。运行异常及未知API为零。 |
| R22 | `ayla-chat-input-states-final`两宽8场景70状态，历史/非好友、输入/回复/上传、录音、文件/语音/视频/查看器错误恢复；`ayla-chat-recall-cancel-states-final`两宽8状态验证撤回失败后成功无旧notice和上传取消；`ayla-chat-final-branches`两宽12状态验证保存pending/error/重试请求、本地媒体禁保存、粘贴预览与群禁言。各批运行异常及未知API为零。代码及定向测试见[聊天媒体恢复](chat-media-failure-recovery.md)。 |
| R24 | `ayla-cross-final`只采用两宽V62文字压力30状态+375 V09十状态；wide V09由`ayla-create-route-wide-final`十状态替代。文字压力为计算字号/行高×1.25。`ayla-responsive-finish`只计13通过case，排除group-chat/MyPosts两次失败，由`ayla-responsive-finish-corrected`对应两case替代；合计15路由×6状态=90，含375/768/769/900/1440五断点及125% CDP pageScaleFactor视觉zoom，不是浏览器文本zoom。 |
| R25 | `ayla-social-actions-complete`选中两宽4场景64状态，私聊pending/成功与群主资料、头像、策略、成员、子群删除、解散、转让、退出结果均通过。`verificationRuns`记录`ayla-social-final-branches-verified`的两宽私聊+375群主，以及`ayla-social-final-branches-wide-final`的1440群主整case；早期850ms响应使pending采集过期，改成截图后释放的合成gate后重跑，仅采用指定结果，不混入旧失败。 |
| R26 | `ayla-last-exact-branches`只采用V04-failed-group-avatar与V33-approve-success两宽4场景8状态；`ayla-last-exact-branches-verified`采用V04空群、V16空自有房/新建、V59本人跳转/待验证关系两宽6场景18状态。总计选中10场景26状态；旧错误class、窄屏旧文案及离场双匹配的失败尝试被整case替代，不计入通过。 |
| R27 | `T/ayla-danmaku-input-first`只选danmaku-upload-owner两宽4状态；`T/ayla-danmaku-input-final`选四场景22状态，覆盖普通图片重试与全屏草稿/错误。选中合计6场景26状态，旧图片错误文案定位失败场景及被替代全屏场景不累计。最新`T/media-final-whitelist.json`选中14报告36场景222状态，含本追加批次。 |

## 收口与验证边界

- glass_styles：R25两宽64状态与R09 reduced25状态已完成；其他owner最后的指定报告已按实际动作回填，表格冻结。
- Motion：R13详情/评论、R21帖子目录/卡片、R22聊天/录音/查看器/媒体错误及最后分支均已归档，按真实组件映射；脚本case编号不作为inventory映射的唯一依据。
- root：R24当前断点/文字压力/创建路由关闭、R26精确分支均已提供指定结果；负责整体源码只读对照与最终汇总。
- Reference：媒体及V47最终证据已冻结，按T/media-final-whitelist.json的选中case复用，共222状态；新增问题才重跑。

V37的最后修正不是采集等待问题：旧页面在动画结束后仍将透明编辑层与可见详情/评论共同保留。最小修复隐藏并隔离底层区域，保持原DOM及状态，未新增白底或改配色；按钮的现有visibility过渡结束后才恢复焦点，再次编辑/卸载取消旧恢复。修后两宽12状态和23项定向契约通过，详细根因、证据及稳定行为见[帖子评论验收](post-comment-control-state-audit.md)及[帖子评论分页架构](../architecture/post-comment-pagination.md)。本表明确撤回旧编辑截图的视觉通过含义，保留其已完成的动作证据。

全部新增补验均使用隔离合成API/WS与明确指定的媒体能力，不构成正式后端写入、真实麦克风、真实LiveKit/SRS重连或真实下载落盘证明。当前无挂载组件、无实际控件，以及V51小窗覆盖范围均按源码和证据如实限定；历史复用不冒充本轮重跑。后续正式服务联机验收仍由实际部署环境承担，不为本次界面验证启动、停止或重启Elysium。
