# 媒体房间与表情列表分页

本契约覆盖可增长列表清单的 P22–P30。服务端先按当前账号及资源可见性过滤，再执行带稳定主键的 keyset 查询；分页只限制传输和可见投影，不删除历史、改变消息归属或推断成员权限。无需数据库迁移。

## 页面协议

分页响应统一为 `{results, next_cursor, has_more, total}`。`total` 是本次读取时完整授权范围的计数，不是本页长度；它不是跨请求的原子快照。`limit` 为 1–100 的十进制整数，SQL 读取 `limit + 1` 条判断是否还有下一页。签名 cursor 绑定账号、资源、父对象或查询以及排序；错误签名、重复参数、参数范围错误和跨范围 cursor 返回 400。每页重新检查访问权限，失去权限返回 403。

| 入口 | 分页请求 | 默认/界面页大小 | 顺序与返回内容 |
| --- | --- | --- | --- |
| 开播选择器、控制台本人频道 | `GET /live/channels/?owner=<user>&limit=20&cursor=...` | 20 | 复用直播目录活动排序；owner 在 SQL 分页前过滤 |
| 语音房聊天历史 | `GET /voice/channels/<id>/messages/?pagination=cursor&limit=50&cursor=...` | 50 | 查询按 `created_at,id` 降序取更早页；单页返回正序消息 |
| 语音房可见成员 | `GET /voice/channels/<id>/members/?pagination=cursor&limit=20&cursor=...` | 20 | `joined_at,id` 升序；只给成员 descriptor |
| 直播弹幕历史 | `GET /live/channels/<id>/danmaku/?pagination=cursor&limit=50&cursor=...` | 50 | 与语音历史相同；原文和媒体引用保留 |
| 桌游房成员 | `GET /boardgame/rooms/<id>/members/?limit=20&cursor=...` | 20 | `seat,id` 升序；新接口始终分页 |
| 个人/系统表情包目录 | `GET /emoji/packs/?pagination=cursor&limit=20&cursor=...` | 20 | 系统包优先，其内按 `created_at,id` 降序；包摘要没有内嵌 `items` |
| 个人/系统包内表情 | `GET /emoji/packs/<id>/items/?pagination=cursor&limit=30&cursor=...` | 30 | `created_at,id` 降序；每页重新检查包可见性 |
| 群表情条目 | `GET /emoji/groups/<id>/pack/items/?limit=30&cursor=...` | 30 | 同上；新 GET 接口始终分页，每页检查群成员身份 |
| 表情搜索 | `POST /emoji/search/?pagination=cursor&limit=30&cursor=...`，body `{keyword}` | 30 | 授权包内按 tag/包名匹配；全局条目分页，返回平铺条目及 `pack_id/pack_name/is_system`；cursor 绑定 keyword |

`GET /emoji/groups/<id>/pack/?summary=1` 只读取包摘要、完整 `item_count` 与 `can_upload/can_delete/allow_member_upload`。上传策略 PATCH 的前端调用也使用 `summary=1`。群不存在或无权访问仍显式失败；只有明确的 `group_pack_not_found` 404 代表尚未创建包。

## 历史窗口与实时流

`useCursorHistory` 持有每个账号及房间独立的历史窗口，最多保留 500 条。首次读取期间到达的 WS 消息按 ID 合并，不被迟到的第一页覆盖；同时间戳使用稳定 ID 排序。同一房间发送等待期间继续编辑的草稿保持原样，旧房发送或上传完成不能清空新房草稿。

向上读取时保存第一条可见消息的 ID 与像素偏移，前插之后恢复该锚点。超过窗口预算时优先释放较新的行；如果本次释放会移除正在看的锚点，就保留旧窗口与 cursor，要求先滚到顶部再继续。窗口释放的是可重读的 UI 投影，完整原文仍在后端。

实时跟随达到 500 条后，最旧显示项会被释放。此时旧 cursor 已不再对应窗口左边界，下一次上翻改用 `before_id=<当前最旧显示项>`。服务端从当前授权房间查出这个精确锚点，再进行 keyset 查询；不允许跨房锚点、已删除锚点或同时提供 cursor。单独给 `before_id` 也进入分页契约，不会静默退回最近消息数组。

阅读旧页时，实时到达只设置“返回最新消息”提示，不强制插入或滚动。返回最新只有在请求成功后替换窗口，失败保留原文、锚点和继续读取位置。`has_more=true` 却缺失、重复 cursor 或返回空页属于协议失败，明确给出重试，不伪装成末页。

直播 runtime 持有 WS 和播放器；分页历史由 `useDanmaku` 独立持有，任何初次历史或继续读取的旧页都不写回实时弹幕队列，因此不会重播到 overlay。实时队列保持 500 条时，订阅按新增 ID 判断到达，不依赖数组长度变化。WS 重连后 runtime 通知当前视图历史需要补读，显示“返回最新消息”；若重连发生于历史请求期间，迟到结果不会抹去该提示。补读失败继续保留原窗口，媒体播放与实时 WS 不因此停止。

## 可见成员与运行事实

语音成员界面每次取 20 条，昵称、按钮及音量只渲染已加载成员；完整在线人数与本地播放状态来自当前语音 runtime，不能用已显示的行数替代。成员加入/离开使目录继续位置失效，界面提示刷新，已知离开项立即移除；更新期间的旧页不能复活离开项。

语音成员区受当前房间卡片高度约束并独立滚动；房名、完整人数、错误与离开/重新加入控件保留在列表外，不因长列表被裁切。桌游房的占位内容区独立滚动，页头不随成员列表离开视口；房主行在窄屏可换行，后页操作不依赖程序滚动隐藏祖先。

语音连接自身需要完整成员事实来对账。`listVoiceChannelMembers` 是明确的非展示消费例外：每次最多取 100 条，顺序收集、按用户去重、检查 cursor 前进，全部成功后才返回完整结果，由既有 session revision/channel 检查后一次 `enterChannel/reconcileMembers`。任一页失败不返回部分成功；重连对账失败保留旧成员表，初次加入失败继续走既有回收路径。账号变化会停止后续取页。遍历不是原子快照，期间成员变化仍由既有 WS/后续对账处理；UI 不使用这项全量遍历自动填满可见列表。

完整 runtime 对账不预热全员 profile；可见成员行按需读取 profile，当前用户资料仍由既有本人初始化路径加载。成员总数和对账批次不会放大成全员资料请求。

桌游详情中的 `members` 为最多 20 人的显式预览，`members_has_more` 标明可继续读取。`member_count` 和 `is_member` 使用独立计数/存在性查询，当前用户在预览外也能正确退出。房主操作列表独立读取成员页，支持对后续页成员移出或转让；返回的所有权字段决定权限，不能根据预览推断。切房时成员 revision 与房间 scope 同时重置，新房首屏不受旧房签名变化影响，迟到旧页也不能写入新房。

## 目录、表情与并发

`usePagedMediaList` 的请求、cursor 和错误属于账号/资源 scope；重复触底共用忙锁。下一页失败保留已有条目和 cursor，刷新失败仍保留原列表，重试会重做真正失败的请求类型。切账号、切群和切房立即隐藏旧 scope 数据，迟到请求不能覆盖新 scope。

本人直播目录仅将全局 store 作为已加载卡片的更新来源，不能因为某个频道未出现在全局首页就认定它被删除。WS 目录事件、已确认的新建或删除使当前继续位置失效；如果事件发生在页请求期间，迟到页被显式拒绝并保留已知新状态。刷新成功且期间没有更新后才能继续翻页。

群表情网格按 30 条加载，包权限先由 summary 读取。上传/删除保持当前群、账号与权限归属；上传等待期间切群会停止后续添加，旧请求不能刷新或提示新群。删除成功先移除已知条目，再刷新元信息和当前条目页；发送失败在面板内显示。分页不会改变既有 emoji 消息类型、媒体权限、群内/子群投递目标或 GIF 引用。

语音/桌游创建用同步请求锁约束同tick和pending期间的Enter重入，创建失败保留草稿并允许重试。语音删除失败在当前房间的告警区展示，失败不清理runtime或移除频道；重新打开确认时清除旧操作错误。直播播放器的PiP能力跟随runtime持有的实际video元素复核，首次挂载时没有video不代表永久不支持；窄屏依旧使用应用内小窗。

普通弹幕与全屏弹幕输入分别持有当前账号/频道的草稿revision和同步提交锁。发送期间仍可编辑，成功仅清除未再次编辑的发送快照；同tick Enter与上传期间Enter不会重入。普通图片在选择时绑定文字快照，上传失败保留文件，上传成功但发送失败保留media_id和原快照，重试只重发该媒体，不重复上传或吞掉后写的文字。切房、换账号或卸载后，旧上传不得继续发送，旧成功不得修改新草稿或恢复旧重试；useDanmaku也在发起HTTP前拒绝旧owner回调。全屏输入owner切换仅重建输入，不重建video宿主；同owner退出再进入全屏保留草稿，发送错误在全屏内部可见并可重试。媒体上传成功不等于消息发送成功；已完成上传对象的存储生命周期仍由既有媒体服务管理。

## 兼容与验收边界

原无分页语音历史、弹幕、表情包、包条目及搜索数组协议为旧消费者保留。当前 P22–P30 的可见消费者使用新分页/summary；原 `getGroupEmojiPack`、`listDanmaku`、`listVoiceChatMessages` 仅保留函数定义，不用于该范围的界面或 runtime。个人/系统表情目录、包条目和搜索当前没有独立可见页面，只提供分页 API 契约，不虚构新产品入口。

定向测试位于 `backend/apps/common/tests/test_media_pagination.py`、`backend/apps/emoji/tests/test_pagination.py`，覆盖实际 MySQL keyset、SQL LIMIT、同时间戳、账号/父对象/查询绑定、权限变化、总数与预览外成员。前端 `cursor-history.test.tsx`、`media-pages.test.tsx` 及既有语音/直播/群表情用例覆盖迟到响应、首屏期间 WS、500 条窗口继续读取、失败保留、草稿、runtime 成员分批与历史/overlay 分离。实际浏览器的多页、失败与滚动证据登记在 `docs/report/`；测试数量只记录于本次验收记录，不作为永久契约。
