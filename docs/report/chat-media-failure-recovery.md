# 聊天媒体恢复补验记录

2026-09-08，当前控件状态补验发现四类明确失败没有完整恢复入口：文件签名失败后 `href` 长期为空，点击仅提示准备中；无海报视频签名失败只显示文字；查看器视频签名失败也仅显示文字；语音 `audio.play()` 拒绝只回退播放状态，没有设置可见错误。

证据来自补验 agent 对 `MediaContent.tsx`、`ImageViewer.tsx` 的逐分支读取，以及合成签名 503、音频 blob 成功后播放 Promise 拒绝的定向复现。修复增加明确错误/重试，覆盖原生视频/音频 error，语音重试释放旧 object URL 并守住卸载/迟到响应边界。没有修改媒体权限、后端、签名格式或正常的原生播放/下载通道，也没有操作正式数据；回滚可限定这两个组件及新增错误布局，不涉及数据迁移。稳定契约见 [聊天媒体失败与恢复](../architecture/chat-media-failure-recovery.md)。

新增 `media-recovery` 7 项通过；和原 `media-content` 18 项、`image-viewer-swipe` 3 项合计 28 项通过。覆盖文件签名恢复与迟到旧响应、气泡/查看器签名及解码错误重建、音频读取/播放/解码错误、旧 URL 释放、旧事件隔离、卸载中的请求和跨消息播放互斥。新增测试在清理浏览器元素后还原媒体 stub，单独重跑无运行警告；原媒体测试批次仍有 jsdom 不实现原生视频 API 及既有 React act 警告，未把这些日志当成真实媒体失败。

独立 Chromium 在 375px 与 1440px 已通过 8 个聊天场景、70 个截图状态和 6 组真实 hover/mousedown/键盘焦点检查。其中每宽 13 个媒体状态覆盖 descriptor、附件、音频读取、原生 play 拒绝、暂停与 seek、视频签名与查看器原生 error 后恢复。视频由 canvas 产生有效 WebM，音频为有效静音 WAV，实际经过浏览器原生解码；所有 HTTP API 与 WebSocket 都终止于合成夹具，没有使用真实麦克风、媒体服务或正式数据。运行记录为本机可视化目录 `ayla-chat-input-states-final/control-states-report.json`，0 pageerror、0 未处理 API。

## 录音、取消和图片边界的后续发现

同一轮浏览器先复现麦克风拒绝/stop 抛错产生未处理异常，以及 stop 异常后 track 未释放。useVoiceRecorder 改为单 owner 状态机，权限迟到、取消、卸载、停止失败/超时均能释放资源；MessageInput 按会话隔离语音上传，并复用已上传语音的 media_id、幂等键和回复目标。10 个录音契约及 5 个语音 owner 契约通过。

上传补验发现：原乐观消息直到 XHR 首次进度才出现取消按钮，建会话期间只有发送等待态；创建/complete 未传取消信号，已取消信号也能开始 PUT。修复从 0% 开始呈现可取消状态，贯通 create/PUT/complete/首帧解码/seek/poster 的信号，并在每阶段和提交消息前检查取消。API 的 401 重放同样尊重信号。撤回失败后成功仍留旧 notice 的问题由 PrivateChatPane 在再次撤回开始时清除本操作错误修复。

补充浏览器 `ayla-chat-recall-cancel-states-final/control-states-report.json` 两宽 2 个场景、8 个状态通过：失败撤回保留正文、重试成功无旧错误、建会话挂起时取消入口可见、取消后迟到成功不发消息且不复活气泡。0 pageerror、0 未处理 API。挂起由夹具显式释放，未以短延时竞速冒充取消验证。

最后有限分支 `ayla-chat-final-branches/control-states-report.json` 两宽 4 场景、12 状态通过：查看器保存 pending 禁用、签名失败、重试后触发原生合成下载事件；本地未发送媒体禁保存；携带真实 File/DataTransfer 的浏览器粘贴事件生成待发送图片且未插入 HTML；群禁言时编辑区和发送按钮禁用。下载事件只证明浏览器接受了保存请求，不宣称磁盘落盘完成。原 70 状态脚本在引用截图之后实际点击取消并断言 quote-bar 消失，引用取消无需另计截图状态。

ResourceImage 原有错误重试嵌套于图片按钮内，后续修正复用父控件时又在组合回归发现装饰头像接管搜索结果行。最终以已有 HTML 空 alt 装饰语义保持父行行为，描述性内容图片继续在原控件重试。ResourceImage 8 项与 SearchPage 21 项组合验证通过，帖子/评论/群表情重试路径另有两宽证据。

帖子、搜索、收藏、录音和消息输入的 22 个文件首轮共 177 项通过；编辑背景隔离追加 1 项并通过详情定向回归，该范围唯一用例共 178 项。后续客户端 11 项、媒体 API 18 项和乐观消息 18 项通过，共 25 个不重复文件、225 项。中间重复运行的 MessageInput、语音 owner 与详情测试不重复计数。最终 TypeScript 与 git diff 检查通过。具体文件清单及全组去重以最终 [控件浏览器验收](auroraqua-control-state-browser-acceptance.md) 为准。此次修复均是工程代码，回滚无需数据迁移；没有启动、重启或停止用户运行的 Elysium。
