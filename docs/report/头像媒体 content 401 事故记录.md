# 头像媒体 content 401 事故记录

## 现象与时间线

- 2026-08-17，用户上传并保存用户头像、群头像后，页面请求 `/api/v1/media/<media_id>/content` 返回 HTTP 401。
- 后端日志记录了两个头像媒体 content GET 401；上传三步接口与头像 PATCH 并非同一失败点。
- 复现链路：保存头像得到内部 content URL；头像组件使用 `<img src="/api/v1/media/.../content">`；浏览器原生图片请求不会读取前端内存中的 Bearer token。

## 根因

Ayla 前端的 `ResourceImage` 将内部媒体 URL 直接交给 `<img src>`。Ayla 媒体 content 接口要求登录认证，且前端 access token 只保存在 Zustand 内存状态、不会自动变成 Cookie。因此该独立图片请求没有 `Authorization` 头，后端按未认证请求返回 401。

这不是头像保存数据丢失，也不是 `Conversation.avatar` 迁移或媒体访问控制本身拒绝了群成员；它是已保存资源的读取方式缺少认证。

## 修复

- `web/src/api/client.ts` 新增 `apiRequestBlob`：复用现有 Bearer 注入、401 refresh 与会话失效语义，返回二进制 Blob。
- `web/src/components/ResourceImage.tsx`：内部 `/api/v1/media/` 资源先去掉 API_PREFIX，再以 `/media/...` 相对路径调用 `apiRequestBlob`，避免客户端再次拼接成 `/api/v1/api/v1/...`；返回 Blob 后通过 `URL.createObjectURL` 交给 `<img>`；外部资源保持原生加载路径；组件卸载或 URL 变化时释放对象 URL。
- 新增 `web/src/vitest/resource-image.test.tsx` 回归覆盖：内部媒体走鉴权二进制请求、外部资源保持原生路径、失败可重试。

## 验证方法

- 前端 `npm run test -- --run src/vitest/resource-image.test.tsx`：3 项通过。
- 前端 `npm run typecheck`：通过。
- 真实验收时：登录后重新进入个人页和群信息页，头像 content 请求应携带 `Authorization: Bearer <access>`；access 过期时应先 refresh 再重试，refresh 失败才回登录页。

## 可逆性与待决项

本修复只改变前端媒体读取方式，不改数据库中的头像 URL、不改媒体权限规则、不删除历史媒体；回滚 `apiRequestBlob` 与 `ResourceImage` 两处代码即可恢复旧行为。仍需用户在当前运行的 Ayla Web 构建中完成一次真实用户头像和群头像验收；若运行的是旧构建，需按部署流程重建/刷新 Web。

## 归属

- 根因与代码修复：Ayla Web 前端。
- 真实运行验收：用户手动执行，需确认请求头和头像显示。
- 数据库与媒体访问控制：本次无 schema 或权限策略变更。
