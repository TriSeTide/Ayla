# 直播、语音与桌游目录分页

本契约由 `backend/apps/common/catalog_pagination.py` 与三个目录 GET 视图实现。它只限制目录传输与查询工作量，不改变对象可见性、加入权限、媒体生命周期或状态真实性。

## 请求与兼容

| 接口 | 保留的过滤条件 | 分页参数 |
| --- | --- | --- |
| `/api/v1/voice/channels/` | `scope=group:<id>` | `limit`、`cursor`、`group_id` |
| `/api/v1/live/channels/` | `scope`、`only_live=1`、`owner` | 同上 |
| `/api/v1/boardgame/rooms/` | `scope`、`mine=1`、`owner` | 同上 |

- 只有显式出现 `limit` 或 `cursor` 才启用分页；没有二者时继续返回原数组和原后端默认顺序，兼容个人页与既有详情消费者。
- `limit` 默认20，合法范围1–100；空值、非整数、越界和重复参数返回400。`cursor`为空、损坏、签名失败或与当前条件不匹配也返回400，不静默回到首页。
- `group_id`是原`scope=group:<id>`的别名，按`allowed_groups`多群白名单过滤；不是按归属`group`外键过滤。二者同时提供却不一致时返回400。
- `owner`沿用用户主键的字符串精确筛选。实际`User.id`为`CharField(max_length=32)`，不能把用户id误验为正整数；频道/房间/群id与用户id属于不同契约。
- 每页先调用原`visible_queryset`并应用scope/owner/状态/成员条件，然后才执行SQL限量；未登录保持原认证错误，旧详情与加入权限保持。

分页响应为：

```json
{
  "results": [],
  "next_cursor": null,
  "has_more": false,
  "total": 0
}
```

`total`是本次完整权限过滤目录的对象数量，不是本页条数或cursor后剩余条数。语音分页另有`total_member_count`，通过完整可见目录的成员SQL子查询计数得到；侧栏不能把首屏20个频道的`member_count`之和当作总人数。成员统计与列表都使用同一scope。无参数旧数组不增加外层结构。

## 全局排序与游标

分页前在数据库中复现`web/src/utils/sortChannels.ts`的现有全局排序，避免先取20条旧后端默认顺序再由浏览器局部排序：

| 目录 | 第一顺序 | 各区内部时间倒序 |
| --- | --- | --- |
| 语音 | 有人、曾进入但当前无人、从未进入 | `last_occupied_at`、`last_vacant_at`、`created_at` |
| 直播 | 在播、曾播但当前未播、从未开播 | `started_at`、`ended_at`、`created_at` |
| 桌游 | 同一区 | `created_at` |

所有目录最后以不可变`id DESC`处理同一时间的并列。语音“有人”来自实际成员表的`Exists`，曾进入来自原两个活动时间字段；直播仍使用原乐观`status`标记，没有把目录排序解释成SRS真实健康判定。空活动时间采用原前端零时间排序；SQL `Coalesce`的epoch参数显式`Cast`为`DateTimeField`，兼容MySQL类型转换。

游标以Django签名封装版本、请求用户、资源类型、排序配方、过滤条件和最后一项的rank/time/id。下一页使用严格keyset边界并只读取`limit+1`条模型记录，额外一条只判断`has_more`，不返回或序列化；不使用offset，也不先取全量Python列表再切片。语音成员数和本人是否在频道只批量查询实际本页id。

这是动态目录位置，不是跨请求静态快照。新项目插入游标之前时可能需要刷新首页才能获取；删除不会造成offset式跳项。每页重验当前可见性，权限撤销后不能凭旧cursor继续读取。已知成员进入/离开、开播/下播改变排序rank/time时，客户端按原语音/直播排序函数即时重排当前查询已经加载的卡片，继续沿原cursor加载并按ID去重；正常活动更新本身不弹出刷新提示或阻断后续页。动态排序项跨页边界移动不提供静态快照完整性保证，需要全目录对账时刷新首页。重排复用原卡片DOM，不重播入场，也不把未加载的全局缓存对象补进部分目录；不能把每条聊天帧都变成清空列表/自动跳顶。源store里的一页缓存不能被称为完整目录，群内目录必须以自身scope分页。

前端目录分页状态按用户与查询条件隔离；目录保存已加载页和cursor，全局descriptor缓存只供已知对象更新，不代表完整目录。详情按对象id独立读取，不能因其不在首屏20条就判断不存在。WS真实sortIdentity变化即时重排该查询已加载项；普通metadata/count更新不重排，两者均不使cursor失效。迟到页中的重复项不能覆盖请求之后实时更新的descriptor或人数。创建等事件先取得授权REST descriptor，再依据allowed_group_ids/onlyLive判断当前查询归属：已完整加载的查询直接增删并更新总数；部分加载的查询只有真实成员集合或过滤归属变化才失效并提供明确刷新入口，异群事件与未知删除不干扰。分页追加保持服务端顺序，只让新DOM卡片进入，不能把每次新增页重新全量sort造成旧卡跳动。业务活动变化触发即时排序和分页追加保持旧卡顺序是两个独立契约。

分页错误/重试/加载共用StablePaginationFooter，以本次挂载测得的最高高度防止底部滚动范围先缩后长。主内容列表终页保留该空间；紧凑语音/直播侧栏明确传retainCompletedSpace=false，确认无加载、错误、后续页或失效状态后移除footer，不留下80px空尾。语音侧栏所有已加载房间处于同一稳定UL，前三项折叠边界按92px裁剪，隐藏项同时退出交互与tab顺序；真实排序使用300ms位置FLIP，原排序立即生效，不等待动画或改写scrollTop。

## 验证与运维边界

契约测试位于`backend/apps/common/tests/test_catalog_pagination.py`，覆盖旧数组、多页同刻/无重复、SQL限量、头部插入/删除、活动分区排序与空时间、scope与多群ACL、权限撤销、cursor跨用户/资源/条件误用、参数错误、完整总数与语音总人数。SQL查询断言通过`connection.ops.quote_name`兼容MySQL与SQLite，不能硬编码数据库引号。

本次没有schema迁移、运行配置修改或服务启动。验收使用隔离测试数据库，具体执行结果与清理证据记录在[迁移报告](../report/auroraqua-style-migration.md)，不把测试设置当成正式服务已重启验收。
