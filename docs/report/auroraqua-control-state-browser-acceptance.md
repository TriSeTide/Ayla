# 控件状态浏览器补验记录

2026-09-08。对应 [当前可达状态清单](auroraqua-visible-state-acceptance.md) 的 V 编号。本批在本地 `26e6e85` 之后的共享工作树上执行；搜索和其他分页改造同时进行，因此受后续改动影响的结果必须重新验收，不能当作最终版本全站通过。

## 隔离方法与证据

使用真实 Chromium、375×812 与 1440×1000 视口、正常动效。每个 HTTP API 请求由浏览器 fixture 返回合成数据，所有 WebSocket 截断在 fixture 内；外部资源和实际媒体采集均阻断。提交错误用合成 503 触发，未写真实账号、聊天、群、直播或语音服务。媒体控件先经过真实页面与加入流程，连接状态再通过现有公开 store setter 提供合成快照；不把这部分当作真实网络重连、麦克风或视频流验收。

证据根目录：`C:/Users/ricer/.codex/visualizations/2026/09/07/01a07c53-0232-7d91-83a9-15341768ca76/`。每个子目录有 `control-states-report.json`，记录 route、viewport、真实操作、可见控件、focus/hover/pressed/disabled、材料、矩形、中心命中点、截图路径、运行错误与未知 API。字段值均为合成内容；密码字段只记掩码。

| 批次 | 结果与适用范围 |
| --- | --- |
| `ayla-control-states-first/` | 两视口，143 个状态截图；16/20 场景完成。0 运行错误、0 未匹配 API。桌游表单 selector 误匹配复选框、群资料误点侧栏编辑导致的4个中断属于脚本错误，已纠正，以下一批替代。 |
| `ayla-control-states-targeted/` | 两视口桌游创建、群管理定向补跑，36 状态截图；3/4 场景完成，0 运行错误/未知 API。375 解散确认的 JSON 过早采在入场动画起点，随后截图已清楚显示弹层，取消也实际成功；增加350ms等待后由`ayla-group-confirm-narrow-verified/`的8状态全部通过替代该中断。早期无可见目标不是产品缺陷。 |
| `ayla-media-control-states-first/` | 73 状态截图；两视口语音/直播控件、375活动球及快捷消息6场景完成。0 未匹配 API。1440活动球在并行搜索代码 HMR 期间遇到3次 `search is not defined`，该中间态中断已由`ayla-activity-wide-verified/`7状态全部通过替代，重验0运行错误/未知API。 |
| `ayla-auth-states-complete/` | V01/V02两视口4/4场景通过，42状态截图；22个实际控件分别检查normal、真实hover/按下及Tab/Shift+Tab回到目标后的focus-visible与中心命中。原生required/email、401保留输入、短密码/不一致/纠正后清错、长可选昵称及两种成功后进入主页均通过；0运行错误、0未知API。报告含认证相关源文件SHA-256，成功仅为隔离fixture响应。 |
| `ayla-auth-route-links/` | 两视口真实点击登录页注册链接、注册页登录链接，共2场景4状态通过，0运行错误/未知API。 |
| `ayla-form-branches-final/`、`ayla-post-form-submit-verified/` | 两视口资料头像类型校验/预览、上传失败保留预览、重试保存/退出和窄屏发帖表单分支通过；宽屏发帖发布busy早期采样在成功跳转之后，改为明确暂停合成响应后11状态完整通过。包含发帖长字段、public/friends互斥且与群组合、群查询空/恢复、附件部分失败/重试/删除/9项上限与成功发布；40个控件状态记录无伪类强制。0运行错误/未知API。资料尾空格问题另列下文，未用去空格输入掩盖该缺陷。 |
| `ayla-shell-state-branches/`、`ayla-pull-refresh-narrow-verified/` | 两视口五主模块真实点击/高亮、导航控件四态、窄屏搜索提交/清除/返回、宽屏非主模块无误高亮；实时状态offline/online隐藏、connecting/failed、多通道长错误与恢复；宽屏真实滚动/回顶/刷新通过。窄屏沿当前实际入口使用CDP触摸完成下拉/等待/完成，加回顶共5状态通过；旧脚本误找窄屏不存在的RefreshFab已纠正，不是产品缺陷。所有完成场景0运行错误/未知API，异常退出后的自建Chromium已确认没有残留。 |
| `ayla-status-banner-glass-verified/` | V07 两视口12状态通过。修复后横幅使用统一玻璃滤镜 `blur(24px) saturate(1.4)` 与阴影；多通道长错误和恢复态均通过，窄屏截图已目视确认背景文字不再清晰穿过横幅。0运行错误/未知API。 |
| `ayla-search-pages-verified/` | P15/V54–V56 两视口2场景、30状态、14控件四态记录通过。五类结果分别从3条续到11条；用户类追加503不清旧页，重试保留旧DOM；另四类独立续读。详情返回后55条及滚动位置保留；服务端is_member覆盖未加载群、空结果/首错、用户卡片两个动作失败、申请入群长文/pending/失败/合成成功通过。0运行错误/未知API。首次脚本误用不存在的`.search-groups`，纠正为`.search-results`后整批重跑。 |
| `ayla-favorite-pages-verified/` | P14/V60 两视口32状态、18控件四态记录通过。20→40→47分页，追加错误保留20条，重试后旧DOM不卸载；详情返回保留47条及滚动位置，六分类正确。失效目标禁止进入但仍可取消；取消失败保留、成功删除、WS删除及新增提示不清尾页、空态与首错重试均通过。0运行错误/未知API。早期控件脚本松开鼠标落在另一业务按钮、一次性错误被StrictMode重复请求消耗均已纠正，不是产品失败。 |
| `ayla-media-history-pages-verified/` | P23/P25 两视口4场景、32状态通过：首错重试、50→100→120历史、续读错误保留、末页、实时新消息不侵入旧阅读窗口、返回最新失败保留120条/重试成功取50条含新帧。四次可见锚点位移0.25–0.3125px；0运行错误/未知API。代表性375语音历史、375直播错误与1440收藏尾错截图已目视核对。早期live fixture漏`channels`路径与StrictMode首错采样已修正并全量重跑。 |
| `ayla-live-history-reconnect-verified/` | P25最终重连改造后两视口22状态通过。真实关闭合成WS（1012）后重连，出现继续读取提示且旧50条保留；刷新失败仍保留、重试成功。并重跑50→100→120和旧窗/实时消息分支；0运行错误/未知API。历史GET不再回灌实时overlay，由runtime定向测试交叉验证。 |
| `ayla-favorite-status-controls-final/` | P32/V11两视口16状态、2个独立按钮四态通过。unknown/首次失败没有`aria-pressed=false`伪装；重试恢复、收藏/取消的pending/错误/成功，WS新增胜过迟到null查询通过。每视口实际批量查询3个目标，0全量收藏GET；100个目标上限和并发2由单元/接口测试验证。0运行错误/未知API。 |
| `ayla-search-actions-final/` | V55/V56两视口16状态通过，补齐长昵称/签名、好友申请pending/成功、私聊pending/成功导航、公开群直接加入pending/成功导航。0运行错误/未知API，不代表真实用户收到申请或消息。 |
| `ayla-social-directory-final/` | P01/P04/P31两视口4场景29状态通过。可见群目录30→60→65，尾错保留与重试、旧DOM稳定；初始只见30群时65群已通过独立紧凑目录订阅，没有resume0。窄屏卡片/列表切换、宽屏完整状态角标、建群成员65项分页/错误、查询变更保留2个已选成员、成功payload含这2个ID；可见性搜索页外第65群/错误/空态及已选chips保留和移除。0运行错误/未知API。 |
| `ayla-group-management-verified/` | P02/P03/V21–V23两视口24状态、12控件四态记录通过。成员30→60→66、子群30→60→65，追加失败保留并重试；成员服务端搜索、无结果，转让首屏30不自动拉完、跨查询选中保留、二次确认/取消/失败保留选择；长群资料取消、默认子群禁止删除、空名禁保存、muted切换与保存失败保留通过。0运行错误/未知API。最初fixture的transfer-owner路径和确认动画采样已纠正。 |
| `ayla-group-member-pages-final/` 的 mentions 两场景 | P02/V28两视口12状态通过：首屏30、追加失败保留/重试60、服务器搜索第65人、键盘选择形成@token、无匹配/Escape关闭。本批目视发现浮层背景文字穿透，其交互记录保留为历史；修复后的最终材料与交互证据使用下列`ayla-mention-portal-verified/`。 |
| `ayla-social-notifications-final/` | P01/P05/P06/P08–P10/V32–V34宽屏消息中心、窄屏消息中心、窄屏快捷面板共3场景79状态通过。各可增长列表30→60→65、尾错保留/重试、旧DOM稳定；好友移除失败/成功，好友申请/群邀请/入群申请同意失败/拒绝成功，退群通知已读、实际打开私聊及快捷返回/关闭通过。0运行错误/未知API。本批明确排除另行修复的会话菜单操作。 |
| `ayla-profile-content-pages-final/` | P19–P21/V57–V59共12场景94状态、6控件状态矩阵通过。本人/好友/陌生人各分区20→40→45且total固定45，首错/尾错/恢复，隐藏内容不请求、资料失败重试、好友动作错误保留卡片；trim清dirty和pending期间新文字/新头像保留通过。0运行错误/未知API/水平溢出。`verificationRuns`保留StrictMode一次性错误fixture初次尝试与纠正后30状态复验的替代关系。 |
| `ayla-create-branches-final/` | V15/V18语音和桌游、公开和锁定群、两视口共8场景56状态通过；控件逐一真实hover/press/Tab。空Enter不发POST、64字符上限、public/friends与锁群组合、pending重复Enter只发1次、503保留原草稿、重试发送trim后参数且成功关闭通过。0运行错误/未知API。 |
| `ayla-conversation-menu-verified/`、`ayla-menu-actions-verified/` | V27原遮挡最小脚本两视口通过；完整版含宽窄消息中心及375快捷消息共3场景30状态通过。首末行真实命中、键盘打开/方向键、Esc只关闭最上层并回焦、外点、pin等待/失败/成功、删除确认取消/失败保留/成功移除。0运行错误/未知API。早期外点误点可导航会话、未等待scrollIntoView滚动结算均修正；独立保留产品Esc同时关闭背景层的修复记录。 |
| `ayla-mention-portal-verified/` | P02/V28修复后两视口12状态通过，成员30→60分页/失败保留与重试、服务端搜索/空结果、键盘生成@token/Escape均正常。375尾错图已目视确认正文不再清晰穿透成员和重试区域；0运行错误/未知API。 |
| `ayla-shell-cross-states-final/` | V06/V08/V34共3场景15状态通过。两视口活动球真实Tab/Enter折叠、收起后隐藏球不可聚焦、回到对应语音/直播控制台后隐藏自身入口；375零未读隐藏快捷入口、123显示99+、已打开面板在徽标归零后保留、主页零未读入口与消息页返回主页。0运行错误/未知API。活动身份使用明确合成store状态，不冒称真实媒体会话。 |
| `ayla-post-comment-states-final/` | V35–V39两视口58状态、18控件真实hover/press/Tab矩阵通过。评论20→40→47、旧DOM不重建、返回47条且680px不变，刷新期间WS增删优先于迟到页；首尾失败/重试、回复归因、评论/帖子删除权限、部分图片失败/重试、新草稿保留与编辑保存期间冻结。0运行错误/未知API。共享图片失败材料后续重拍另记。 |
| `ayla-message-empty-error-verified/`、`ayla-message-empty-error-wide-verified/` | V32–V34窄消息15状态、窄快捷13状态、宽消息15状态通过：会话/好友/四类通知首错、显式重试及空态；爱莉入口读取不可用、恢复后打开私聊503反馈。0运行错误/未知API。宽屏最后的错误选择器原误找`.messages-action-error`，实际为`.chat-notice`；更正后以独立宽屏15状态替代旧批失败。 |
| `ayla-group-role-approvals-verified/` | V21/P07两宽4场景24状态通过；admin/member角色边界和审批按钮、pending/失败/成功。完整角色和人数不由当前成员页推算；0运行错误/未知API。 |
| `ayla-popovers-reduced-verified/` | V10/V27/V28/V61/V62共5场景25状态通过，实际`prefers-reduced-motion: reduce`。普通会话宽窄与375快捷菜单、双层确认、Home/End/方向键/Tab圈定/Esc只关顶层并回焦，以及两宽@键盘选择/空结果；0运行错误/未知API。 |
| `ayla-responsive-finish/`、`ayla-responsive-finish-corrected/` | V62计入15路由族、375/768/769/900/1440五断点及900宽125%浏览器视觉缩放，共90个有效状态记录。首批13场景通过；群聊旧离场editor与新editor双匹配、我的帖子选择器错误，更正后2场景12状态通过替代。0运行错误/未知API。该批检查布局和可命中区域，不冒称全部媒体状态或文本专用缩放。 |
| `ayla-cross-final/`、`ayla-create-route-wide-final/` | V09计入窄宽各10状态，五种实际创建入口打开后使用浏览器返回触发路由变化，弹层全部关闭。宽屏主页会自动进入最近群，最初脚本错误等待`/group`，最终沿ServerRail建群入口10状态通过替代。V62另计两宽15路由的30状态：显式将computed字体与数字line-height乘1.25，保持布局尺寸，未发生文档横向溢出。此为文本压力模拟，和上一批浏览器视觉缩放分别记录；0运行错误/未知API。 |
| `ayla-scroll-route-verified/` | V05两宽11状态通过：隐藏回顶不可Tab、真实wheel显示/回顶、宽刷新和窄真实触摸下拉刷新pending/完成，以及再次滚动后切路由隐藏回顶并恢复tabindex=-1。首次宽屏固定1100ms过早判断平滑滚动未完成；改为等待真实aria-hidden终态后整批通过，未修改产品。0运行错误/未知API。 |
| `ayla-post-directory-states-final/` | V35/P12三类帖子目录、两宽共12场景42状态14控件矩阵通过。20→40→47、尾错保留和重试、同DOM、详情返回不另发请求/不重复入场并恢复位置，首错与空态分别覆盖。0运行错误/未知API。我的帖子此前无可见续页错误入口，本轮已补齐；该证据独立于评论分页。 |
| `ayla-chat-input-states-final/` | V24–V26/V30–V31两宽8场景70状态、6控件矩阵通过。消息历史/权限、发送与上传失败重试、空文件、录音能力/权限/取消/停止异常/语音重试；媒体描述符、音频拒播/暂停/seek、视频签名/原生错误与恢复。0运行错误/未知API。媒体轨道与响应完全合成；后续撤回及建上传会话期间取消的新增分支单列，不用本批代替。 |
| `ayla-social-actions-complete/` | V13/V21–V23两宽4场景64状态通过。建群弹窗直接私聊pending/成功；群资料、头像、加入方式、表情权限、成员操作；非默认子群保存/删除pending/失败/成功、解散、转让后降角色、退出失败/成功。0运行错误/未知API。`verificationRuns`保留旧pending采样过早及1440整case重跑替代关系；最终pending由截图后显式释放合成响应验证。 |
| `ayla-chat-recall-cancel-states-final/` | V25两宽8状态通过：撤回失败后重试成功不残留旧错误；建上传会话期间即可取消，取消后不发后续消息。0运行错误/未知API；上传请求及清理均为合成fixture。 |
| `ayla-myposts-footer-wheel/` | V35窄屏真实wheel补验7状态通过。原尾错截图在错误区域增高后仍停旧末尾，并非按钮不可达；实际滚到底剩余0，重试按钮bottom=735.64，小于容器bottom=748，完整可见。无需样式改动。 |
| `ayla-last-exact-branches/`指定两类、`ayla-last-exact-branches-verified/` | V04/V16/V33/V59最终10场景26状态通过。首份仅取两宽坏头像回退仍可点击进群、好友/群邀请同意成功，4场景8状态；第二份6场景18状态覆盖空群创建入口、自有直播空/新建pending与成功、自己ID跳本人页、pending_sent禁钮、pending_received去消息中心。前批错误均为旧选择器、窄屏文案和离场profile双匹配，整case纠正后重跑；0运行错误/未知API。 |
| `ayla-chat-final-branches/` | V25/V31两宽4场景12状态通过。查看器保存pending/签名失败/重试触发合成下载，本地未发媒体禁保存；真实File/DataTransfer粘贴产生图片预览且不插入HTML，群禁言禁编辑/发送。0运行错误/未知API，下载事件不证明磁盘落盘。 |
| `ayla-comment-final-branches/`、`ayla-post-card-final-branches/` | V36/V39两宽各2场景6状态通过。评论实际4图上限、纯图/图文发送；帖子长文展开/收起、作者进入资料页。当前PostCard只有评论数/浏览数/收藏，没有点赞控件。0运行错误/未知API。 |
| `ayla-detail-final-branches/` | V37两宽2场景12状态的动作通过，覆盖详情首错/找不到/返回及编辑媒体新增/移除/保存。后续目视发现编辑页稳定透出底层评论，因此本批编辑截图不能作为最终视觉通过证据；由下列settled-fixed替代。独立详情入口纠正了旧目录退出DOM影响选择器的问题，但没有修复透底。 |
| `ayla-post-edit-settled-fixed/` | V37两宽2场景12状态通过；编辑层媒体增删/保存与完全settled采样，三个底层区域hidden/inert且原DOM保留。关闭后两宽scrollTop均320→320、评论草稿保留、焦点回到“编辑”、无inert残留。0运行错误/未知API；根任务与样式owner已目视字段间隙仅有原页面背景。 |

媒体专项的最终证据位于临时目录 `C:/Users/ricer/AppData/Local/Temp/auroraqua-reference-audit-20260907/`，详细选择条件和报告hash见该目录的 `media-final-whitelist.json`。以下只计指定通过场景；完整操作与测试命令见 [媒体分页与房间控件验收](media-pagination-verification.md)。

| 媒体批次 | 结果与适用范围 |
| --- | --- |
| `ayla-owned-live-pages-visible/` | P22/V16两宽16状态：本人20→40→45、不自动读完、首尾失败保留/重试、选择第45间及控制台侧栏末项。 |
| `ayla-member-controls-scroll-verified/`，仅voice两类case | P24/V43两宽18状态：可见20→40→45、125人runtime按100+25收齐但只见20、没有全量profile扇出、真实滚动/Tab、长名/技术态/说话环、重新加入与离开。音量活动为明确合成store输入。 |
| `ayla-members-final/`、`ayla-game-wheel-final/`、`ayla-media-final-role-actions/` | V40–V44/V52–V53：分别选定20/24/8状态。语音删除确认、失败保留runtime、成功清理、403重试；桌游访客加入/成员离开、45成员真实wheel分页、后页移出/转让pending/失败/成功、删除取消/失败/成功及角色边界。 |
| `ayla-group-live-pages-final/` | V45两宽14状态，群内首错、20→40→45、尾错保留重试、选45及空态。 |
| `ayla-live-role-errors-final/`、`ayla-studio-cover-final/`、`ayla-live-control-branches-second/`仅studio-owner-actions | V49–V50分别6/8/36状态：加载/首错/403/非本人、封面校验/预览/上传失败重试，资料可见性保存、开播/停播、三类假地址复制成功/失败、删除pending/失败/成功。 |
| `ayla-player-pip-final/`仅1440、`ayla-mini-touch-final/`375 | V46/V47/V51共5+11状态：控件定时隐藏/唤醒、PiP拒绝保留画面或无能力隐藏、全屏工具；窄屏小窗真实双触点缩放至320×180/120×68，释放不误返回，拖动限界、Enter回房和关闭清理。PiP由浏览器能力fixture隔离，不代表外部画中画窗口验收。 |
| `ayla-emoji-signed-media-final/` | P29/V29两宽4场景30状态：30→60→65、首尾失败重试、部分上传保留、发送/删除失败、删除重试、权限和空态。发送前断言PNG真实解码。先前1440失败是公共fixture遗漏签名POST导致503、375点击较早；此次补齐合成签名与字节路由后全部通过，未把夹具错误当产品修复。 |
| `ayla-danmaku-input-first/`仅upload-owner、`ayla-danmaku-input-final/` | V47两宽6场景26状态：普通与全屏输入发送期间新稿保留、同tick和上传期间Enter防重复、图片上传失败可重试、发送失败沿原media_id/文字快照重试且只上传一次、换房后旧上传不发送。全屏内部错误可见，两宽已目视复核。首份仅取4个upload-owner状态，其余22个状态以final替代；0运行错误/未知API。 |

以上数量是各批原始状态记录，存在重跑、重复状态及同名截图被同批后续分支替代，不相加为独立功能或唯一图片数量。每项动作仍保留其route/viewport/结果和采样事实；最终菜单脚本已使用布局前缀保留独立图片。截图已对代表性宽窄弹层及表单错误终态作目视检查，具体分支以 V 清单逐项记录为准。

## V 状态对应

逐项状态和仍缺分支统一维护在 [当前可达状态清单](auroraqua-visible-state-acceptance.md)，本报告按批次保存实际动作、纠正过程和结果。

帖子详情评论的批次名称虽包含 V35–V39，其实际动作主要对应 V36–V39；V35 三类帖子目录必须使用独立目录分页证据，不能以评论分页代替。媒体状态注入、合成签名和 API 成功只证明当前浏览器分支，不证明真实媒体链路或正式服务。

## 补验发现的产品问题

- **资料保存规范化与草稿不一致（已修，资料专项复验通过）**：`ayla-form-branches-first/`在两视口使用末尾有空格的签名，API按当前请求的trim结果成功返回后，出现“已保存”同时保存按钮仍可点击。原`ProfilePage`只更新用户store，未同步该次已保存字段的规范化结果。现已同步未在请求期间继续修改的字段，同时保留较新的文字和头像草稿；`ayla-profile-content-pages-final/`覆盖真实pending、trim清dirty及新稿保护。早期去掉尾空格的保存测试仅覆盖其他分支。
- **实时状态横幅背景穿透（已修）**：补验看到原横幅半透明底色没有对应backdrop-filter，滚动内容文字清晰穿过。`shell.css`已将横幅接到统一玻璃滤镜/阴影，保留原告警边框；以`ayla-status-banner-glass-verified/`重验结果取代旧外观结论。

- **会话首行菜单被吸顶标签拦住（已修）**：`ayla-conversation-menu-before/`在1440和375首屏均复现；置顶按钮中心分别命中“认证消息”span和tab。原absolute向上菜单仍在滚动容器/层叠上下文内，单独提高z-index没有解决边界。现portal到body并按视口定位，相同真实命中/点击脚本与完整菜单动作已通过。快捷面板内Esc原会同时关闭背景面板，已由顶部React事件边界接管，确认框也只处理自身Escape与焦点。
- **创建请求期间Enter重复提交（已修）**：`ayla-create-enter-before/`让语音/桌游创建的合成POST保持pending，再按Enter，两者均发出第2次创建请求；按钮disabled未守住输入键盘入口。现submit入口使用同步ref锁，6项定向测试及两视口公开/锁群创建分支验证失败保留草稿、可重试、重复Enter不再发请求。
- **@成员浮层背景穿透（已修）**：`ayla-group-member-pages-final/375-mention-next-error.png`可见聊天正文清晰穿过成员名称与重试区域。原滤镜受composer祖先合成边界影响；现portal到body、继续按实际composer矩形定位并响应滚动/resize，`ayla-mention-portal-verified/`已目视及交互复验，不再仅凭computed样式判定。
- **全屏帖子编辑透出底层评论（已修）**：原V37动作通过后，根任务目视新增媒体图发现字段间隙仍清晰显示评论。再等待1600ms、确认无动画后依旧存在，排除了“截图太早”；编辑层本身透明，而底层详情和评论仍正常绘制。现保留三个底层区域DOM但在编辑时隐藏、inert并移出无障碍树，关闭后恢复。编辑按钮原有visibility过渡还会拒绝过早focus，现等待实际CSSTransition.finished并在重开/卸载时取消旧恢复。23项定向契约及两宽settled-fixed通过，没有叠加新白底、修改色板或丢失滚动/评论草稿。旧12动作PASS不再冒充修复后的视觉证据。

## 复跑入口

脚本位于本机临时目录 `C:/Users/ricer/AppData/Local/Temp/auroraqua-reference-audit-20260907/`，不提交测试账号状态或截图到仓库：

- `verify-ayla-control-states.cjs <输出目录> --widths=1440,375 --cases=game-create,group-management-controls`；也支持 `--batch=dialogs/profile/auth` 和 `--reduced`。
- `verify-ayla-media-control-states.cjs <输出目录> --widths=1440 --cases=session-activity`；媒体fixture与采集逻辑复用前一脚本。

两脚本均在 `finally` 关闭自建浏览器，当前批次已结束。后续工程改造改变接口返回时先更新合成契约，不将未知API或fixture形状不匹配误判成产品失败。
