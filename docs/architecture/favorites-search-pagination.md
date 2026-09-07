# 收藏与聚合搜索的游标分页

收藏页与搜索页从服务器分批取得数据，不先下载完整列表再切片。旧调用方的无分页契约继续可用；网页列表显式选择新契约。页面快照属于可丢弃的会话内展示缓存，不持久化到本地存储，不替代服务器权限与数据。

## 收藏接口

`GET /api/v1/favorites/` 与 `GET /api/v1/favorites/?type=post` 继续返回收藏数组。依赖完整集合的旧调用方不会因为页面启用分页而收到截断集合。

新调用显式提供 `limit` 或 `cursor`：

```text
GET /api/v1/favorites/?limit=20
GET /api/v1/favorites/?type=post&limit=20&cursor=<上一页 next_cursor>
```

响应为：

```json
{
  "results": [],
  "next_cursor": null,
  "has_more": false,
  "total": 0
}
```

- `type` 保持原有 `message/post/live/voice/game/group` 过滤语义，省略代表全部。
- 复用 `apps.common.catalog_pagination.paginate_catalog`，按 `created_at DESC, id DESC` 取 SQL `limit + 1`，只序列化本页。
- `limit` 缺省 20，范围 1–100。签名游标绑定用户、资源、类型过滤和排序；换用户或换分类必须重新取首页。
- `total` 是本次请求时该用户及类型的全部收藏数，包含目标已经不可用但收藏记录仍存在的条目，不是剩余页数。
- 参数非法、空/损坏游标、跨用户或分类复用游标返回 400，不静默重置到首页。
- 每次序列化重新检查目标权限：消息仍要求会话成员身份，帖子、直播、语音和桌游复用 `can_view`。失去权限或目标删除时保留收藏记录，`target` 返回 `null`；不会把收藏本身解释成永久查看授权。群收藏沿用群可被登录用户发现的既有规则。

`web/src/api/favorites.ts` 分别提供旧 `listFavorites` 与新 `listFavoritesPage`。**单个页面不得调用 `PostsStore.loadFavorites` 替换完整索引**；分页页面仅为本页已知帖子逐项更新 `setFavorite`，取消收藏时移除明确的一项。

## 可见目标的收藏状态

网页初始化、帖子列表/详情与通用收藏按钮不再枚举完整收藏集合。按钮按当前渲染的目标调用 `POST /api/v1/favorites/status/`，请求为 `{target_type, target_ids: string[]}`，最多 100 项；响应为 `{target_type, statuses: {目标ID: 收藏ID或null}}`。每个请求严格返回所请求目标的本人状态；不返回其他收藏，也不加载或披露目标正文。已删除或失去权限的目标仍可查询本人保留的收藏记录，查询结果不授予查看目标的权限。

`favoriteStatus` 是可丢弃的共享投影，按类型和目标 ID 记录已知收藏、已知未收藏、未知、加载中和错误。缺失目标或请求失败不会变成未收藏；未知按钮等待状态，错误按钮仅重试状态，不能因一次读取失败而执行新增收藏。已知状态刷新失败保持最后已知值。

同一轮挂载的目标合并为最多 100 ID 的请求，最多两个请求同时进行；同目标请求去重，最多保留 1024 个可驱逐的离屏缓存记录，仍挂载的目标不驱逐。缓存新鲜期 60 秒，刷新只更新本次明确请求的目标。账号或登录状态变化清空缓存、队列并使旧请求失效；缓存不保存 token。每个目标的 revision 使读取期间发生的本地操作或 `favorite.changed` 优先于迟到的旧状态响应。

`FavoriteButton` 和 `PostCard` 共用此状态及错误重试。帖子 WS 的既有 `PostsStore.setFavorite` 同步到该投影；兼容 `loadFavorites` 不再有网页生产调用，旧 REST 数组仅保留外部契约兼容。

## 搜索接口

旧 `GET /api/v1/search/?q=...&types=...&limit=...` 保持每组 `{items, total}`：默认每组 10 条，上限 50，原有 `types` 解析兼容规则不变。

新模式显式设置 `pagination=cursor`：

```text
GET /api/v1/search/?q=冰樱&pagination=cursor&limit=3
GET /api/v1/search/?q=冰樱&pagination=cursor&types=user&limit=20&cursor=<users.next_cursor>
```

首屏仍按请求类型返回 `users/groups/posts/lives/games`，每组独立包含：

```json
{
  "items": [],
  "total": 0,
  "next_cursor": null,
  "has_more": false
}
```

- 新模式 `limit` 必须为 1–50 的整数，默认 10；不会继承旧调用方对非法数值的静默夹紧行为。
- 一个 `cursor` 续页请求必须明确指定单一 `types`。用户组游标不能拿去续群聊组，聚合首页返回的五个游标各自独立。
- `apps.search.pagination` 对用户使用 `date_joined DESC, pk DESC`，其他类型使用 `created_at DESC, pk DESC`。用户主键按实际模型的字符串字段处理，其他类型按整数主键处理。
- 游标签名绑定当前用户、去除首尾空白后的查询词、结果类型、排序和版本。时间戳相同时，主键仍提供稳定的全序；页大小可以改变，不影响游标身份。
- 查询和可见性过滤先于计数与 keyset，之后 SQL 最多取得 `limit + 1` 条。帖子、直播和桌游每页重新应用 `visible_queryset`；用户公开资料和群发现沿用原有权限语义。
- 群结果附带服务端 `is_member`：对当前 `request.user` 使用成员表 `Exists`，独立于前端已经加载了多少群目录。前端优先使用该事实；仅旧响应缺少该字段时兼容现有本地目录。本人加入/离群事件即时更新它，且请求途中发生的事件不会被较早生成的响应覆盖。
- 损坏/越界游标、错误模式、重复分页参数或跨条件重放返回 400；不会将失败当成空结果。

两类游标都表示当前排序中的位置，不是跨请求冻结的快照。新对象如果排在已读位置之前，通过重新取首页看到；续页不会因为前面新增或删除一条而产生 offset 式位移。已删除或失去可见性的对象不出现在后续请求中。

## 网页状态与生命周期

收藏页首屏和后续页均为 20 条。分类进入 URL `?type=`，因此从详情返回保留分类。列表按账号/登录会话/分类保存已加载项、下一游标与状态；账号变化或退出登录立即清空页面快照。最多保留 14 个会话内列表记录。

搜索页首屏每组 3 条，各组“查看更多”只请求该组后续 20 条。每组分别持有 busy/error/cursor，一个组加载不阻塞其他组；新查询、清空查询、账号变化和卸载使旧响应失效。最多保留 12 个按账号/登录会话/查询词隔离的会话内结果记录。

两页的共同约束：

- 已加载项与新增项按稳定 id 去重；成功追加保留旧 DOM 和已有列归属。页面使用原有 `useListEntryMotion`，只为新增 DOM 播放入场；减少动态效果时直接呈现。
- 初次失败显示可重试错误；续页失败保留已加载项及原 cursor；重试仍请求失败的那一页。游标未推进或缺失时显示诊断，不循环拉取同一页。
- 请求结果必须仍属于当前账号、页面作用域和请求 revision 才能写入状态或缓存；旧响应既不能覆盖新页面，也不能写回帖子收藏索引。
- 列表与游标快照配合 `useScrollRestore` 恢复详情返回位置。恢复期间不重播原有卡片入场；恢复后的新追加页继续正常入场。
- 收藏列表内容由子组件管理、滚动宿主由父组件管理。父 ref 绑定后通过显式 `pageReady` 通知恢复逻辑，避免缓存命中的子 layout effect 先执行而丢失首次滚动恢复。
- 收藏分页底部复用 `DirectoryLoadMore` 与 `StablePaginationFooter`；搜索组底部复用 `StablePaginationFooter`。错误/加载/完成切换保留底部已占高度，避免列表末尾跳动。
- 页面快照超过 60 秒时显示重新加载入口，不自动丢弃用户已展开的后页。用户主动刷新才替换首页；新页成功追加不会清除既有更新提示。

收藏 `favorite.changed/removed` 立即移除对应记录，并记录当前列表的删除标记，阻止较早发起的响应使其复活；重复移除事件幂等。新增收藏保留用户当前已展开的页，显示“收藏有更新，刷新列表”，由用户决定刷新时机。当前会话内其他已缓存分类也被标记为需要刷新。

搜索的入群审批与 `group.joined` 仍即时更新成员按钮；这些事件只提示重新搜索，不用三条首页覆盖已经展开的组。账号或查询变化时关闭旧资料/申请弹窗，旧异步申请回执不能导航当前页面。

收藏目标 `null` 在界面显示“内容不可用”，目标入口禁用，取消收藏仍可用。搜索中的桌游结果直接进入 `/games/:id`。

## 定向验收

后端测试入口：

- `apps/favorites/tests/test_favorites_pagination.py`：旧数组兼容、SQL LIMIT、相同时间戳全量遍历、跨用户/分类游标拒绝、边界新增/删除、权限撤销后摘要为空、非法参数。
- `apps/favorites/tests/test_favorite_status.py`：本人/类型/目标边界、100 项上限、重复 ID、空请求、非法参数与身份要求。
- `apps/search/tests/test_search_pagination.py`：五组分别完整遍历、独立游标、旧聚合结构、用户字符串主键、查询/用户/类型绑定、SQL LIMIT 与每页权限复查。

前端测试入口：

- `src/vitest/favorites-api.test.ts`、`src/vitest/search-api.test.ts`：新旧请求兼容与游标编码。
- `src/vitest/favorite-status.test.ts`、`src/vitest/favorite-button.test.tsx`：100 项分批、两个并发请求、去重、局部更新、迟到读取与 WS 的先后关系、未知/错误/重试和账号隔离。
- `src/vitest/favorites-page.test.tsx`：追加/去重/焦点与 DOM 保留、页外收藏索引、续页与首页重试、删除后迟到响应、筛选/账号隔离、不可用目标、详情返回多页/分类/滚动恢复及新增 DOM 入场。
- `src/vitest/search-page.test.tsx`：各组独立续页、原 DOM 保留、同 cursor 重试、查询清空/变更、账号切换、详情返回已加载组和滚动、新 DOM 入场、目录未加载时的成员事实、请求期间加入/离群，以及既有资料/群申请行为。

测试只使用隔离测试数据库及模拟网络，不启动或重启 Elysium。浏览器布局和真实服务启动验收属于外层交付记录，不由单元测试结果代替。
