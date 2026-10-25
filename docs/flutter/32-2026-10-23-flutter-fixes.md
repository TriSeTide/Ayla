# Flutter 三轮实报修复（2026-10-23）

用户三条实报：

> 1. 修复 Ayla Flutter 的群内群外语音房窄屏界面中部内容区上下左右不留空的问题
> 2. 修复所有界面尤其是群内界面返回键的问题，是返回到上一级而不是返回到主页，要跟 web 一样就行
> 3. 修复手机端群聊界面不显示别人的头像的问题，私信没这个问题

三条都是「单测与 analyze 全绿、只有真机才炸」的类型。本文记录根因、证据、修法与验证，
供下一个 agent 复核而不必重新调查。事实源一律为 Ayla/web/src 与当前代码，行号即证据。

---

## 一、群聊不显示别人的头像 / 昵称

### 现象与排查分叉

「私信没问题、群聊只有别人的没有」这一点排除了媒体签名、AylaResourceImage、
AylaAvatarHalo 渲染本身（私信走同一套组件）。真因在数据：
气泡的头像/昵称唯一来源是 conversation.members
（web MessageList.tsx:360-369 的 memberAvatars；Flutter
widgets/chat/message_list.dart:939-950 的 _memberAvatars）。

### 根因：成员页与 metadata 的响应顺序竞态

后端 ConversationMetadataSerializer.get_members 有意对群返回空数组
（backend/apps/chat/serializers.py：群成员独立分页），会话目录同样为空
=> 群成员必须靠「全量拉成员页 + 合并进 chatState」这一步才有。

修复前 group_chat_page.dart 的 _bootstrap() 把
_loadMembers() 与 getConversationMetadata() 并发跑，而 _loadMembers 结束时要求
byId(groupId) != null 才写。手机慢网下两条响应顺序一反过来：

| 步骤 | 结果 |
|---|---|
| 1. 成员页先回、群摘要还没进 chatState | current == null => 成员被整批丢弃 |
| 2. metadata 之后才 upsert | 写回 members: [] + members_complete: false |
| 3. _loadMembers 已跑完 | 没有第二次机会 => 成员永远为空 |

成员为空 => 气泡拿不到 senderAvatarUrl / senderAvatarLabel
=> showSenderHalo == false => 别人的头像与昵称全不显示。
自己的消息本来就不画头像（MessageBubble 的 isSelf 分支）=> 症状正是「只有别人的没有」。

私信为什么没事：ConversationMetadataSerializer 对非群返回完整 members[:2]
（前端 stores/chat.ts:127-133 还额外从 members 推导 peer）=> 内联在响应里，无竞态。

web 为什么没事：GroupChat.tsx:159-194 的成员 effect 依赖
activeConv?.members_complete -- metadata upsert 后该依赖变化 => effect 重跑，
天然有第二次机会。Flutter 的 addPostFrameCallback 一次性调用没有这个重跑语义。

### 修法（lib/pages/group_chat_page.dart）

1. 把 _bootstrap() 拆成两个可独立调用的步骤
   （_loadConversationMetadata / _ensureMembersLoaded），成员合并挂在 metadata 之后；
   历史加载仍与二者并发（web 的三个 effect 也是并发的，不能因为修竞态把首屏拖慢）。
2. _loadMembers() 收尾不再静默 return：群摘要缺席时补一份最小群摘要占位
   （只写 id/type/title/members/membersComplete，不伪造 my_role / unread / last_message），
   让成员有落点；之后 metadata / 目录摘要 upsert 时按
   chat_state.dart:104-114 的 members_complete 守卫保留已加载成员。

### 回归锁

flutter/test/group_chat_avatars_test.dart（4 例，假 HTTP adapter 控制两条响应的延迟）：

| # | 时序 | 断言 |
|---|---|---|
| 1 | 成员页快于 metadata（修复前正是这条丢失） | 气泡画出头像 + 昵称 |
| 2 | 成员页慢于 metadata（对照档） | 同上（两条时序都锁死） |
| 3 | 冷启动直链（chatState 里还没有该群） | 成员仍落库（members.length == 2） |
| 4 | 成员页失败一次 | 不崩、聊天照常（缺头像可接受，web 同） |

---

## 二、窄屏语音房「中部内容区四周不留空」

### 根因：漏了 .voice-room-voice-card 的 margin: var(--sp-4)

web/src/styles/voice.css:23-30（默认断点、无媒体查询）：

    .voice-room-voice-card { flex: 1; min-height: 0; display: flex; ...; margin: var(--sp-4); }

唯一重置点是 voice.css:372-375，在 @media (min-width: 769px) 内
（margin: 0; padding: var(--sp-4)）
=> 窄屏必须是 16px 外边距，宽屏才是 0 外边距 + 16 内边距。

Flutter 的 _buildVoiceCard 只实现了宽屏档；窄屏分支返回裸 ColoredBox
=> 四边各少 16px（宽 -32 / 高 -32），面板直接贴头部下沿、屏幕左右边与聊天卡上沿。

已排除的干扰项（逐条核过，不是根因）：

- auroraqua.css:583-591 是 @media (max-width: 768px)，只清
  background/box-shadow/backdrop-filter，不含盒模型属性；
- .voice-room-body 窄屏无 padding（voice.css:9-14；padding: var(--sp-4) 只在
  318-323 的 >=769 档）；
- .voice-room-layout 窄屏 gap: 0（gap: 16 只在 354 行的 >=769 档）
  => 不能给 layout 加 spacing，会与 margin 叠加；
- chat card 是通栏条（voice.css:55-66，无 margin）=> 不要给它加。

### 修法（lib/widgets/voice/voice_room_body.dart）

窄屏分支包一层 Padding(padding: EdgeInsets.all(AylaSpacing.sp4))
（等价 CSS margin；本件在 Expanded 槽内，四边内缩与 margin 同效）。
群内 / 群外是同一个 AylaVoiceRoomBody（voice_support.dart 的 host 两处共用）
=> 一处修两处生效，与 web 两侧同源一致。

### 回归锁

flutter/test/voice_room_body_test.dart 的窄屏用例改为用 tester.getRect(panel) 量几何：
左/右各 16、与聊天卡上沿间距 >= 16、顶部不贴边。原用例标题「无 padding」是错的，
已就地订正为「voice card 四边内缩 16」并补上几何断言（只改标题而不加断言等于没锁）。

---

## 三、返回键「回到主页而不是上一级」

### 机制前提（必须先理解，否则改必错）

- web 的 navigate(x) 默认 push（建历史），navigate(-1) 是历史回退；
- Flutter 的 context.go(x) 是替换（不建栈）、context.push 才建栈；
- 群页 5 条路由共用同一个 kAylaGroupShellPageKey（router/app_router.dart:113-121，
  为的是切场景不重建整页）=> 群内任何路由都不能 push：
  2026-10-23 实测 push('/group/g1') 后立即 push('/group/g1/voice') 抛
  !keyReservation.contains(key)（既有锁 test/no_group_push_test.dart 也禁止）。
=> 群内的历史层只能用 GroupPage._sceneHistory 复刻。

### 缺口 A：群内「列表 -> 房内 / 详情」不写场景历史

_sceneHistory 此前只有 _goScene 会写。而群内四条「进下一级」路径直接 context.go：

| 触发点 | 目标 | web 依据（都是 push） |
|---|---|---|
| GroupVoicePage 点房卡 | /group/:id/voice/:cid | GroupVoice.tsx:114-119 |
| 宽屏侧栏点语音房行 | 同上 | GroupPage.tsx:300-306 |
| 宽屏侧栏点直播间行 | /group/:id/live/:cid | GroupPage.tsx:309-315 |
| GroupPostsPage 点帖子卡 | /group/:id/posts/:pid | GroupPosts.tsx:426-432 |

后果：进房/进详情后按返回，_popScene() 拿到的是更早的场景（甚至空栈）
=> 第一下跳过列表、第二下 go('/group') 回主页。

修法：

- GroupPage 新增 _rememberScene（只入栈不导航，同场景不重复入栈）与
  _openGroupChild(path, scene)（先记历史再 go）；
- GroupVoicePage.onOpenChannel / GroupPostsPage.onOpenPost 两个注入回调
  -- 子页只上报意图，场景历史的唯一 owner 仍是 GroupPage
  （回调为 null 时退回原子页 context.go，保证单测/画布样张不变）；
- _openVoiceChannel / _openLiveChannel 进入前同样记历史。

### 缺口 B：场景根之下没有「先回列表」这一档

进房不改变场景（voice 仍是 voice），所以场景栈里那条是「上一个场景」而不是「列表」。
新增 _popToSceneRoot() 作为返回键的第 0 档（排在场景历史栈之前）：
停在子路由（postId / voiceChannelId / liveChannelId 非空）=> 先回对应列表。
与 web 一致：web 的返回键就是历史回退，栈顶正是列表那条 entry。

### 缺口 C：第 3 档无条件回 /group

原实现「场景栈空 + 路由栈空 => go('/group')」。冷启动直达
/group/g1/voice（分享链接）时第一下返回就回主页 -- 正是用户描述的字面现象。

修法：第 3 档先判当前场景 -- 不在 chat => 回本群聊天场景 /group/:id；
只有已在 chat 时才回群列表 /group。
（与 web 的登记差异：web 冷启动直达时历史里没有群聊天那条、navigate(-1) 会离开站点；
原生客户端不能让用户「退出应用」，故收敛到群壳。）

### 缺口 D：群外「进入下一级」丢来源

context.go 不建栈 => 栈空时一律 goHome。web 对应路径都是 navigate（push）。
新增一层极薄的「上一级页面」记忆（layout/app_back.dart）：

- aylaRememberEntryOrigin(path) 记录、takeEntryOrigin(currentPath) 消费（读一次即失效）；
- 只记一层（后写覆盖，对齐浏览器历史不该无限回溯的直觉）；
- 拒收非绝对路径与 /login /register（认证流程不作为返回目标）；
- 回到自己 => 丢弃（防死循环）；
- 新增 AylaBackAction.popEntryOrigin 档，优先级：
  groupScene -> popRoute（真历史）-> popEntryOrigin（来源）-> goHome -> homeExit；
- onGoHome / 群列表收敛时 aylaClearEntryOrigin()，不跨一级页与登录周期残留。

已接来源记录的入口：主页群卡（home_page.dart:451）、搜索页 _openPath（search_page.dart:1300）。

### 缺口 E：群内帖子详情的栈底兜底跳出一级大厅

PostDetailPage._goBack() 的栈底此前恒 go(from=='mine' ? '/posts/mine' : '/posts')
-- 群内详情也走这条 => 跳出群到一级 /posts。
web 事实源 PostDetailPage.tsx:70-74：
fromGroup ? /group/:id/posts : fromMine ? /posts/mine : /posts。
修法：新增 PostDetailPage.fromGroupId，_goBack 补第一档（group_posts_page.dart 传入）。

### 缺口 F：头像点击跳个人主页用 go（web 是 push）

web utils/navigation.ts:24-35 的 goUserProfile 走 navigateTo -> registerNavigate(navigate)
=> push。Flutter 侧 5 处「自己 -> /profile」用 go => 个人页返回回主页。
修法：search_page.dart（2 处）/ voice_support.dart / live_support.dart 改 context.push。

刻意不动：一级 tab（底栏 / TopNav 模块 / logo / 消息入口）继续用 go
-- web 侧它们是 Link，但本仓 2026-10-20 已定稿「一级主页再按返回 = 提示退出」，
改成 push 会让主页变成「回上一个 tab」而永远退不出去，与用户原话冲突。

### 缺口 G：voice_support.dart 三层嵌套的死 if

_runDelete 里连写三层 if (context.canPop()) { pop } else { ... }，三个分支条件与动作
完全相同（复制粘贴产物，行为虽对但读起来像有三级兜底）。收敛成与 _onBack / _onLeave
一致的单一形态。

### 回归锁

- flutter/test/group_back_navigation_test.dart（6 例，真 appRouterProvider + 真 AppShell
  + tester.binding.handlePopRoute()，与真机同一条返回键通道）：
  1 直达房内 => 回语音列表；2 直达帖子详情 => 回帖子列表；3 直达直播间 => 回直播列表；
  4 真实链路「进语音场景 -> 进房 -> 返回列表 -> 返回群聊」全程不离开群；
  5 冷启动直达房内：第二下回群壳而不是 /group；6 无来源时仍回主页（旧行为保留）。
- flutter/test/back_button_exit_test.dart：新增 popEntryOrigin 档的优先级断言
  （能 pop 时来源让位真历史；群场景仍最优先）+ 来源记忆的三条语义锁
  （只记一层 / 消费即失效 / 拒收登录页与非绝对路径 / 回主页时清空）。
- GroupPage._handleSystemBack 的第 0 档与 _popToSceneRoot 的判据不同，不要合并：
  前者按「URL 是否停在子路由」，后者按「场景历史栈」。

---

## 验证

| 项 | 结果 |
|---|---|
| dart analyze lib | No issues found |
| flutter test test/group_chat_avatars_test.dart | 4 passed |
| flutter test test/group_back_navigation_test.dart | 6 passed |
| flutter test test/voice_room_body_test.dart | 23 passed |
| flutter test test/back_button_exit_test.dart | 14 passed |
| 定向 6 个测试文件（含既有 group_page_shell / no_group_push） | 65 passed |
| 全量 flutter test --concurrency 1 | 2824 passed / 7 failed（见下方说明） |

### 关于全量测试的 7 个失败（已核实，与本改动无关）

全量跑期间另一个会话正在改 lib/，dart 边编译边读 ⇒ 报 Failed to load ... 的
**加载期**失败而不是断言失败。7 个受影响文件（group_apply_test /
group_apply_wiring_test / group_back_navigation_test / group_chat_avatars_test 等）
**单独复跑全部通过**。⇒ 与既有纪律一致：跑全量前先冻结代码；
看到 loading ... [E] 先判是不是编译错，别当逻辑 bug 查。

### 反向验证（确认回归锁不是「写完就绿」的假锁）

三处修复各自做了一次「改回缺陷 ⇒ 应变红 ⇒ 恢复 ⇒ 变绿」：

| 变异 | 结果 |
|---|---|
| 删掉 if (hasEntryOrigin) return AylaBackAction.popEntryOrigin; | 期望 popEntryOrigin、实得 goHome ⇒ 红 |
| 语音房窄屏 padding 改回 0 | 期望 16.0±0.5、实得 0.0 ⇒ 红 |
| _bootstrap 退回「成员页与 metadata 并发」 | 头像数 0（正是原 bug 现场）⇒ 红 |

---

## 发版

已随 **Ayla 1.0.18 + build 20**（stable，windows + android）发布，并一并部署后端。
发布后自检三项通过：

- 清单：manifest ok: channel=stable latest=1.0.18+20 (zip)
- 更新接口：旧版 1.0.17/19 ⇒ update_available=true；同版本 ⇒ up_to_date
- 产物可下载：windows/zip 与 android/apk 的 Range 请求均 206

**仍未做真机验收**：三条都是布局/导航类改动，判据已由单测覆盖，
但触感与观感（尤其窄屏 16px 留白的视觉平衡）需用户在真实设备上确认。
发布说明见 docs/releases-1.0.18.md。
