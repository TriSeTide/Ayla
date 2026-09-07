# 媒体分页与房间控件验收

2026-09-08，针对当前共享工作树的 P22–P30，以及 V40–V53 中受媒体分页影响的真实入口。稳定协议见 [媒体房间与表情列表分页](../architecture/media-list-pagination.md)。本记录不代表真实音视频传输、麦克风采集或外部推流服务已验收。

## 隔离与证据位置

浏览器使用真实 Chromium，1440×1000 与 375×812，正常动效。HTTP API、WebSocket 和媒体适配器均在合成 fixture 边界内；写请求、上传字节和复制值只包含合成内容。没有连接真实账号、语音或推流服务。播放器及 runtime 使用当前产品代码，连接媒体的边界使用既有可注入适配器。

本次证据根目录为 `C:/Users/ricer/AppData/Local/Temp/auroraqua-reference-audit-20260907/`。各子目录的 `control-states-report.json` 保存请求、错误、实际操作、控件状态、视口和截图引用。早期其他控件报告保存在 [控件状态补验记录](auroraqua-control-state-browser-acceptance.md) 登记的可视化根目录。两处均是本机验收证据，不提交账号状态或截图到仓库。

| 批次 | 通过的范围 |
| --- | --- |
| `ayla-emoji-signed-media-final` | P29 两宽4场景、30状态通过。群表情30→60→65，首错/尾错重试、部分上传成功保留、发送/删除失败、关闭以及只读/仅上传/空包权限分支。媒体签名POST和PNG字节均显式拦截；发送前断言首项图片完整解码。替代旧P29批次，0运行错误、0未知API。 |
| `ayla-owned-live-pages-visible` | P22 两宽2场景、16状态通过。本人目录首错重试后20条，等待1秒不自动取后页；尾错保留20，重试40、末页45；选择第45间进入控制台，工作台侧栏第45项实际滚入可见区。替代旧`ayla-media-list-pages-verified`的P22部分。 |
| `ayla-member-controls-scroll-verified` | P24 两宽成员20→40→45、尾错/重试、末页、长昵称/技术标签/说话量和真实Tab焦点、实际重新加入及离开通过。另两宽125人使用100+25批次完整对账，可见首屏20，每宽只请求18个可见他人profile，无第21人以后profile预热。该批桌游宽屏pending采样由后续明确挂起响应的批次替代。 |
| `ayla-members-final` | V41 两宽删除确认取消、失败保留当前房间、重试成功清理runtime通过；V53 访客加入pending/失败/重试、成员离开pending/失败/成功两宽通过。桌游房主宽屏第一次wheel后的250ms采样不足，房主管理由后续wheel批次替代。 |
| `ayla-game-wheel-final` | 桌游房主两宽24状态通过，使用真实wheel和400ms滚动结算等待；20→40→45、尾错保留、非首页移出/转让pending/失败/成功、删除确认取消和删除失败。替代宽屏过早采样及旧机械滚动批次。 |
| `ayla-media-final-role-actions` | 两宽8状态通过：语音403拒绝后未伪造活动runtime，非本人无删除控件，重试后连接及可见成员恢复；桌游房主确认删除成功返回大厅。 |
| `ayla-group-live-pages-final` | 群内直播两宽14状态通过：首错重试、20→40→45、尾错保留和重试、选第45间、空态创建入口；宽屏通过群侧栏，窄屏通过直播房侧栏。 |
| `ayla-live-role-errors-final`、`ayla-studio-cover-final` | 两宽分别6与8状态通过：直播详情首错/403/非本人无主播或推流信息；封面文件类型失败、真实预览、上传失败保留预览、重试成功保存当前房间。 |
| `ayla-live-control-branches-second` | V49/V50 两宽主播动作36状态通过：空标题校验、长标题/简介/可见性、资料保存pending/失败/成功、开播/下播pending/失败/成功、三类合成长地址复制失败/成功、删除pending/失败/成功空态。其播放器脚本的定位/控件唤醒问题由后续批次替代。 |
| `ayla-player-pip-final`（仅1440）、`ayla-mini-touch-final`（375） | V46/V51 最终共16状态通过：控件显示/3秒隐藏/唤醒，实际全屏进入与按钮退出；宽屏支持PiP时按钮可用、合成API拒绝不打断画面；窄屏原生PiP隐藏，离开直播间形成小窗。窄屏通过Chromium双触点输入验证缩放上限320×180、下限120×68、释放不误返回，再验证真实拖动边界、Enter回房、关闭清理runtime。0运行错误、0未知API；后者替代旧375批次。 |
| `ayla-danmaku-input-first`（仅`danmaku-upload-owner`）、`ayla-danmaku-input-final` | V47新增两宽6场景26状态通过：普通/全屏pending新草稿保留、重复Enter不重入、上传失败保留与重试、发送失败后复用同一media_id和原文字且不再次上传、切房后旧上传不发送/不改新草稿，全屏内错误可见并重试成功。第一批只计两宽owner场景4状态；图片分支的脚本精确文本定位由最终批次替代，其余22状态使用最终批次及最终错误样式。 |

P23/P25 的50→100→120、多页锚点、旧窗口与实时消息隔离及返回最新失败保留由主验收记录中的 `ayla-media-history-pages-verified`、`ayla-live-history-reconnect-verified` 覆盖。重连通过真实关闭合成WS再连接触发，不能据此声称外部服务或实际媒体网络稳定。

## 修复与被替代的早期判断

- **媒体成员不可滚动**：首次P24浏览器中，20条语音成员超过父卡片后被裁切，后页和离开控件不可达。`.voice-member-list` 现在是受卡片约束的独立滚动区，头部/错误/VoiceControls不随列表滚走。桌游长成员区现在在内容区内滚动并保留页头，成员行可换行。早期脚本`scrollIntoView`能机械滚动隐藏祖先，不能证明用户可滚；最终证据改用真实wheel。
- **语音删除失败不可见**：实际合成DELETE 503后，`VoiceHubPage`只更新大厅`listError`，房内渲染仅接收`joinError`；群内对应`error`也未展示。两个入口现在把当前操作错误传入房内告警区，重新打开删除确认时清除旧错误。失败不清理runtime，也不移除频道。`ayla-voice-delete-before`的失败由`ayla-members-final`替代。
- **PiP能力被首次空ref锁死**：首次挂载时runtime尚未创建video，原检测仅依赖稳定的videoRef；后续即使浏览器支持且video拥有请求API，按钮仍隐藏。`LivePlayer`现在依赖实际video元素身份复核能力。早期`ayla-player-mini-branches-verified`把该宽屏状态记为能力不可用并不准确，已用实测`pictureInPictureEnabled=true`、video和API存在的证据纠正；`ayla-player-pip-final`是修复后证据。
- **创建请求重入**：语音/桌游创建按钮禁用仍无法拦截输入框pending Enter，同tick也可能重入。两个submit入口加同步ref锁，失败释放锁并保留草稿；已有名称/可见性语义不变。定向测试覆盖同tick重复Enter、pending Enter、失败保留和一次重试；创建页其余分支由主验收记录接续。
- **桌游切房误拒首屏**：成员签名原在新房请求启动后才改变revision，可能把新房首屏误当旧页。现在scope改变时同步重设签名/revision，新房首屏可落地，迟到旧房结果被隔离。定向测试覆盖该次序。
- **脚本问题不计产品缺陷**：P22最早用文本定位查第45间，但控制台房名实际是input value；图片确认房间已正确载入，已修正断言。直播删除按钮实际class为`live-rail-del-btn`；播放器controls会自动隐藏，必须真实唤醒再点全屏。固定延时pending合成响应会早于截图返回，现用明确挂起、采样后释放。上述失败由各对应最终批次替代。
- **表情图片签名夹具缺口**：新版ResourceImage复验时，1440分页上传后发送失败断言未触发。原因是公共脚本把未单独登记的签名POST返回503，图片进入明确重试态，外层按钮正确执行图片重试；旧375通过发生在该延迟503之前，不能证明图片成功。`ayla-emoji-resource-final`与`ayla-emoji-resource-wide-final`均被替代。最终脚本为合成表情登记签名响应与PNG字节，并在发送前等待`img.complete && naturalWidth > 0`，两宽30状态全部通过；此问题未修改产品代码。
- **弹幕输入覆盖新草稿与图片发送失败无重试**：普通输入的`await onSend`成功后原先无条件清空文字；图片上传成功后若发送返回false，原逻辑不会恢复`failedFile`。全屏输入有同样的草稿覆盖，并缺少全屏内部错误展示。先新增定向复现：普通输入两项均失败，全屏新草稿一项也失败。修复后按账号/频道隔离输入实例，以revision清理发送快照；图片发送失败保留media_id和原文字，重试不重复上传；同步锁拦截重入，旧owner发送前拒绝。全屏新增输入上方错误提示，输入owner更换不重建视频。最终关联4文件40项与两宽26浏览器状态通过；已上传但未发送对象不由前端静默删除。

## API与组件定向验证

后端使用Windows项目虚拟环境和独立MySQL测试库 `test_ayla_all_lists_media_20260908`，不使用正式库或共享默认测试库。指定六个文件合计74项通过：`apps/common/tests/test_media_pagination.py`、`apps/emoji/tests/test_pagination.py`、`apps/boardgame/tests/test_room_api.py`、`apps/live/tests/test_danmaku.py`、`apps/emoji/tests/test_emoji_api.py`、`apps/emoji/tests/test_group_emoji_api.py`。覆盖真实SQL LIMIT、相同时间戳、账号/资源/查询绑定、权限变化、before_id边界、总数和预览外本人状态。一次已知asgiref兼容警告不影响结果。

前端分页与媒体首轮使用Windows Node与单worker Vitest检查17文件137项。15文件120项在首批通过；EmojiPackPanel的图片解码边界需从分页/发送单元测试独立隔离，GroupLive旧mock需补登录用户与owner过滤，这两个测试文件适配后17项全部通过。最后V47修复新增12项，相关4文件40项全部通过；各文件最后一次结果合计18文件149项，不是一次全量执行的计数。真实图片仍通过浏览器和ResourceImage专项验证，未以mock替代媒体解码验收。最后V47修改后的TypeScript检查通过，`git diff --check`无错误（仅Windows换行提示）。数量只描述本次证据，不能作为永久验收条件。

P27/P28/P30当前没有独立可见页面，已验API分页契约，不伪造产品入口。V47没有独立“开关弹幕”控件；V51没有独立“展开/收起”按钮，实际为返回、关闭、拖动和双指缩放。真实源代码入口以当前V清单为准。

## 最终白名单与复现命令

同一证据根目录的 `media-final-whitelist.json` 是最终机器可读白名单：14份JSON、36个选中场景、222个选中状态全部通过；逐项验证报告文件、选中场景和截图存在，保存报告SHA-256、精确场景/宽度筛选及替代关系。混合报告中未选中的失败场景不计为通过，不按整份报告推断。该计数仅描述本次验收截图，不代表独立功能数量。`finalize-media-whitelist.cjs`可重新核对文件和状态。源码精确路径和共享边界单独登记在`media-source-whitelist.json`，不把浏览器产物作为源码提交。

V43的当前证据为`ayla-member-controls-scroll-verified`中`voice-visible45`的`voice-member-speaking-longname-technical`和`voice-slider-real-keyboard-focus`：长昵称、音量环、爱莉技术态“通话中”，以及实际Tab/Shift+Tab焦点。声音强度来自公开store的合成audio-level输入，不声称已采集真实麦克风。V45使用`ayla-group-live-pages-final`，为新分页接口的两宽首错/尾错和20→40→45实测。

前端工作目录 `E:/Elysium-AyerElysia/Elysium/Ayla/web`：

```powershell
E:/nodejs/node.exe node_modules/vitest/vitest.mjs run src/vitest/cursor-history.test.tsx src/vitest/media-pages.test.tsx src/vitest/voice-room-body.test.tsx src/vitest/emoji-pack-panel.test.tsx src/vitest/voice-api.test.ts src/vitest/use-voice-channel.test.tsx src/vitest/use-voice-channel-switching.test.tsx src/vitest/live-session-runtime.test.ts src/vitest/live-room-body-swipe.test.tsx src/vitest/group-voice.test.tsx src/vitest/group-live.test.tsx src/vitest/boardgame-api.test.ts src/vitest/voice-channel-create.test.tsx src/vitest/room-create-reentry.test.tsx src/vitest/voice-delete-feedback.test.tsx src/vitest/live-player.test.tsx src/vitest/voice-hub-page.test.tsx --minWorkers=1 --maxWorkers=1 --silent
E:/nodejs/node.exe node_modules/vitest/vitest.mjs run src/vitest/emoji-pack-panel.test.tsx src/vitest/group-live.test.tsx --minWorkers=1 --maxWorkers=1 --silent
E:/nodejs/node.exe node_modules/vitest/vitest.mjs run src/vitest/danmaku-input.test.tsx src/vitest/live-player.test.tsx src/vitest/media-pages.test.tsx src/vitest/live-room-body-swipe.test.tsx --minWorkers=1 --maxWorkers=1 --silent
E:/nodejs/node.exe node_modules/typescript/bin/tsc -b --noEmit
```

第一条执行中15文件120项通过，两个旧mock适配后第二条17项通过；不能把第一条历史执行写成137项同批通过。

第三条为最后V47修复的关联4文件40项：普通输入8、播放器14、媒体页7、直播滑动与宿主11。其中新增12项覆盖新草稿、图片上传/发送分层重试、同tick Enter、输入法确认、切房/换账号/卸载归属、全屏错误及video不重建。浏览器使用`verify-ayla-danmaku-input.cjs`，第一批只选`danmaku-upload-owner`，最终批次选`danmaku-draft-image-retry,danmaku-fullscreen-draft`；两宽均通过，旧脚本把含“重试图片”按钮的容器当成精确“图片发送失败”文本，定位更正后并未改动产品来适配脚本。

后端工作目录 `E:/Elysium-AyerElysia/Elysium/Ayla/backend`，独立测试库由执行入口显式指定：

```powershell
.venv/Scripts/python.exe -c 'import os; os.environ["DJANGO_SETTINGS_MODULE"]="config.settings_test_mysql"; from django.conf import settings; settings.DATABASES["default"]["TEST"]={"NAME":"test_ayla_all_lists_media_20260908"}; import pytest; raise SystemExit(pytest.main(["apps/common/tests/test_media_pagination.py","apps/emoji/tests/test_pagination.py","apps/boardgame/tests/test_room_api.py","apps/live/tests/test_danmaku.py","apps/emoji/tests/test_emoji_api.py","apps/emoji/tests/test_group_emoji_api.py","-o","addopts=","-q","--reuse-db"]))'
```

浏览器脚本位于前述证据根目录；所有命令的精确`--cases`与宽度参数保存在白名单`commands.browser`中。脚本使用已存在的用户启动前端，HTTP/WS/上传/媒体连接终止于合成路由。没有启动或停止Elysium，没有更改正式数据库、真实账号或外部媒体服务。
