# 语音会话切换与连接所有权

语音房路由、用户最后选择的房间、后端成员关系和已经连接的媒体房间分别有自己的状态。导航已显示房间C，不代表一个早先开始的A连接已经取消；旧请求回包不能重新把活动会话切回A。

本文件记录前端的运行所有权与取消契约。成员事实仍以原REST/WS协议为准，媒体静音与连接事件仍属于LiveKit层；目录活动排序见[目录分页](catalog-pagination.md)，不能为等待动画而延迟真实排序或连接决策。

## 选择、会话与显示状态

| 状态 | owner与含义 |
| --- | --- |
| 路由中的voiceChannelId | 用户当前选择；侧栏立即按该路由高亮，不等待网络或媒体连接 |
| runtime selection revision | 共享运行时中的最新选择授权；跨hook实例生效，过时工作不能提交 |
| runtime mediaChannel | 当前客户端所持媒体的归属标记；可能仍在连接、尚未成为已建立会话 |
| voice store currentChannelId | 已完成成员铺底的活动会话；不是导航选中项的来源 |
| heartbeat revision | 已建立会话的心跳owner，独立防止旧心跳回包影响重启后的同房或新房 |

选择C时，已经建立的A媒体可以暂时保留到C的REST join成功；因此过渡期间路由C与活动会话A并不自动表示错误。真正的失败是旧工作完成后反向提交A，或者所有请求结算后仍未到达最后选择。目标失败留在目标页面明确显示错误并提供按路由id重试，不能把旧currentChannelId当作重试目标。

侧栏行位置过渡由稳定`motion.li`持有，语音房选中背景使用`AuroraquaNavHighlight(sharedLayout=false)`随父行移动，避免两层共享投影相互抵消。滚动根登记`layoutScroll`并禁用原生滚动锚定。该显示契约不决定媒体owner，也不延迟目录活动排序；完整视觉规则见[设计规范](../design.md)。

## 共享选择与串行编排

`web/src/runtime/voiceSessionRuntime.ts`持有selection、revision和唯一`transitionTail`。`selectChannel(owner, id)`在owner或目标改变时同步推进revision；同一owner的同一选择不重复推进。`cancelSelection()`撤销选择并推进revision。`runJoin()`对同一selection revision合并进行中的工作，被取代但尚未开始的目标跳过REST；`runExclusive()`保证加入、显式离开和登出的REST离开共用串行边界，前一次完成或失败后才运行下一次。

`web/src/hooks/useVoiceChannel.ts`在路由`useLayoutEffect`中登记目标，早于详情descriptor完成；直接调用join时也同步登记。正在执行的操作得到`isCurrent()`校验函数，每个异步阶段同时检查选择revision、发起账号与挂载状态。runtime不会把已经发送的REST请求假装取消：已发出的join必须等待真实回执，如果过时且已产生成员关系，再等待该频道补偿leave请求结算，才允许后续队列工作开始。

有效加入按以下顺序执行：目标REST join → 旧已建立房间停止心跳/退订、REST leave、定向断开及清投影 → 目标LiveKit连接 → 恢复播放与默认关麦 → 目标members铺底 → 提交currentChannelId/mine/活动会话 → 启动唯一心跳与WS订阅。每个阶段后的归属检查都在提交下一阶段之前；成员迟到不会覆盖新房间成员。

临时媒体与已建立媒体分别处理。若换目标时`mediaChannel`尚未成为store中的currentChannelId，立即撤销该临时媒体并调用客户端disconnect，使挂起SDK连接收到`AbortError`；已建立媒体继续按上一段的REST确认顺序释放。上层只清理它捕获的频道，客户端只清理它捕获的room，这两层不能互相用“当前全局对象”替代旧工作的真实owner。

显式leave先撤销选择并进入共享队列。服务器拒绝leave时保留原媒体、心跳和成员投影，由调用方展示错误；服务器确认后才收本地资源。被踢、房间删除、心跳过期则只清理事件所属频道：若用户已选择另一个目标，保留新的selection，不能用旧房间left/expiry取消新加入。

## 账号与迟到结果

加入开始时捕获账号id及当次access token。旧加入的补偿和登出的REST leave使用该闭包内的原账号凭据，`leaveVoiceChannel(id, originalToken)`明确关闭自动附加当前认证和401刷新重试；旧凭据失效时返回原401，不借用后来登录账号的token重放，不清改新账号认证。

登出立即撤销selection、停止心跳、断开媒体与Voice WS、重置本地语音状态；已经建立会话的REST leave进入同一串行队列，待返回旧join由其原操作补偿。token只在该请求闭包中保留到结算，不持久化或输出。补偿被拒绝或网络失败不能宣称服务端成员已删除；本地撤权与服务端补偿成功是两个独立事实。

重新对账捕获currentChannelId与revision，两者仍匹配才应用members。麦克风失败回滚也匹配原频道与revision，旧操作不能反转新房间的开麦状态。普通返回已有健康会话不重建连接；明确恢复失败媒体使用force加入。心跳stop/start推进独立revision，旧同房心跳的403/404不能终止新的心跳owner；当前403/404仍分别触发移出/删除处理。

## 媒体客户端所有权

`web/src/livekit/client.ts`中的`VoiceLiveKitClient`为每次`connect()`创建独立`RoomOwner`，保存generation、该请求的room、当前清理Promise和取消回调。客户端只允许一个当前owner，事件与异步完成必须同时匹配owner身份和generation。

`connect(wsUrl, token): Promise<void>`保持原签名，流程如下：

1. 同步建立新owner并撤销前一个owner；旧连接立即收到`AbortError`。
2. 等待当时已取得的旧room清理，校验当前归属后调用捕获的factory。
3. factory产物只写回该请求自己的owner；再次校验，随后调用捕获的局部`room.connect()`。
4. SDK连接完成后再次校验。只有仍有效的owner能够完成本次连接。
5. 失败或过时仅清理本owner的room。当前请求保留原始错误，过时请求归一为`AbortError`。

取消结果与资源清理进度是两个边界。`connect()`使用取消Promise与实际连接工作竞争，因而不会等待尚未返回的工厂或不响应取消的SDK才结束。底层工作以后返回时仍执行归属检查与定向清理：过时工厂产物不再开始连接；若旧SDK在首次断开之后仍晚完成，再次断开该旧room，避免留下后来建立的旧媒体连接。

`disconnect()`同步撤销当前owner、推进generation并取消对应连接，再等待它当时持有的room清理。它不在`await`后重新读取活动room，所以旧disconnect晚完成不能清空或断开后来建立的新owner。同一owner的并发清理共享一个Promise；该次清理结束后允许晚完成连接再次清理。重复调用且已无当前owner时保持幂等。

## 事件与媒体操作

工厂收到该次连接的事件快照及受owner约束的回调。以下七类事件只有当前owner能够转发：连接状态、参与者进入、参与者离开、轨道静音、活跃说话者、本地音量、远端音量快照。旧room被撤权后，即使仍触发事件，也不能回写当前store。

麦克风启停、恢复播放和本地音量操作捕获准确owner与room，并在执行前和`await`后校验归属。操作期间换房时，结果为`AbortError`，上层必须忽略旧会话的成功、失败和UI回滚。同步远端音量也使用捕获的room，逐轨道检查owner，不把一次滑块操作转交给后来连接的房间。

本次改动仅包裹客户端生命周期边界，没有修改`createLiveKitRoom()`内部的轨道挂载、音量分析器、SDK事件名称或音频处理实现。token只传给该次连接，不进入诊断正文或持久化状态。

## 验证与事故证据

客户端定向测试覆盖工厂迟到、SDK迟到、连接失败、断开中途、新旧关闭交错、所有旧事件失效和异步媒体操作归属。与真实适配器的既有契约测试一起验证，执行批次和结果记录在[迁移与验收报告](../report/auroraqua-style-migration.md)，不在稳定架构文档中固定持续变化的测试数量。

上层契约测试覆盖共享队列合并、A运行时B/C只提交最后C、跨hook实例、取消queued选择、同房心跳重启、旧members/静音迟到、leave/登出、原账号补偿及目标失败重试。浏览器分别门控join、members、media connect、旧leave，再真实点击后续房间，并覆盖详情迟到、旧left与503后重试；只有释放门控并等待结算后验证最终owner一致，不能将显式释放门控的测试解释成无限悬挂REST也能继续推进。

真实浏览器诊断使用隔离HTTP/WS与注入的媒体适配器，验证前端实际路由、store、心跳、选中项与媒体owner的一致性；这不代替真实LiveKit服务器传输或物理设备声音验收。
