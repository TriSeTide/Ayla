# 认证页与直播输入按钮补齐记录

日期：2026-09-08。起点：Ayla `dca9967`。范围为 `/login`、`/register` 与普通/全屏直播输入按钮；不调整认证接口、账号校验、登录跳转、弹幕发送快照、媒体重试或房间/账号归属。

## 已核对的原因与更正

认证卡此前已经使用 `.78` 强玻璃、24px blur、20px 圆角和 modal 阴影，字段与主按钮也继承全局材质，不能表述成“登录注册完全没有迁移”。旧的[控件验收记录](auroraqua-control-state-browser-acceptance.md)已记录两种宽度的认证 42 个状态及真实切页链接 4 个状态。因此，本次最初提出的“此前只覆盖登录态页面”判断不成立，特此更正。

实际遗留是认证页仍沿用早期单卡结构、400px 宽度和固定 padding，独立路由没有短视口验收，切页仅为普通文字链接，未采用其他页面的完整按钮触达与反馈。此次将其作为一组公开路由单独收敛，增加 375×600 的顶部/底部可达证据。

直播按钮有可定位的旧样式：普通发送使用 `btn-glow`，全屏发送使用独立 24×24px 圆形深色规则。虽然全屏按钮已列入共用缩放反馈选择器，其自身尺寸和背景仍覆盖主按钮配方，造成普通、全屏和其他编辑器不一致。图片入口原为带隐藏 file input 的 label，不能直接通过 Tab 聚焦。

## 变更后的行为

- 认证规则集中到 `web/src/styles/auth.css`，由 `main.tsx` 导入；`app.css` 中对应认证独占规则已移除，共用 `.field-error` 与玻璃降级规则保留。认证卡宽度上限 440px，保持强玻璃和 20px 圆角；header/form 都是透明布局，不叠卡片材料。
- 窄屏与低高度视口使用 16px 页面外沿、24px 卡片内沿。`.auth-page` 持有竖向滚动，卡片不被压缩；短屏初始可见标题，滚动可到注册和登录入口。主操作与 ghost 切页入口至少 44px 高，继续使用既有颜色、按钮动效与焦点配方。
- 注册本地错误以 `aria-invalid` 和 `aria-describedby` 关联原错误文案，等待中的 form 标注 `aria-busy`。原生必填/email 校验、密码规则、接口参数和成功跳转保持原契约。
- 普通与全屏弹幕发送复用 `btn btn-primary`：40px 高、12px 圆角、原 indigo 主色。普通发送仍按内容保持宽度，全屏图标发送为 40×40px；全屏输入外框至少 50px 高，并按可用宽度收缩，保留左右播放器控制空间。
- 图片入口复用 `btn btn-ghost`，40×40px 原生按钮通过同一个隐藏 file input 选择图片。Enter/空格可触发选择，pending 时真实禁用；原上传、重试、发送和草稿状态未改写。

## 验证

以下均为当前源文件上的本次结果，不把旧轮的测试总数当成本次验收。浏览器连接已有 Vite 服务，HTTP/WS/媒体响应全部隔离为合成 fixture，实际网络写入为 0；没有启动、停止或重启 Elysium/后端服务。

| 验证 | 结果 | 覆盖 |
| --- | --- | --- |
| `auth.test.ts` | 7 通过 | 登录、注册、会话恢复、退出的原接口/store 契约 |
| `auth-pages.test.tsx` | 3 通过 | pending/失败保留字段、错误可访问关联、重试与原注册参数 |
| `danmaku-input.test.tsx` | 8 通过 | 新草稿不被旧成功清除、图片重试复用媒体、同轮重复 Enter、账号/房间归属 |
| `live-player.test.tsx` | 14 通过 | 播放器原行为、全屏草稿/异常反馈、owner 变化与视频宿主保留 |
| TypeScript | 通过 | `tsc -b --noEmit` |
| 认证真实浏览器 | 3 场景、33 状态通过 | 1440×900、375×812、375×600；required、Tab/Enter、401/503、注册本地校验、pending、保留字段、真实滚轮与切页 |
| 直播输入真实浏览器 | 6 场景、26 状态通过 | 1440/375；普通/全屏发送快照、图片上传失败、媒体复用重试、旧房间迟到上传 |
| 直播按钮真实浏览器 | 2 场景、10 状态通过 | 1440/375；空态禁用、键盘打开原生文件选择、主按钮 hover/focus、40px/12px实测、全屏输入与两侧控件不重叠 |

一次定向运行共 **4 文件、32 项测试通过**。浏览器三份报告共 **11 场景、69 状态通过**，均无页面运行异常、未识别 API 或失败项。已目视核对 375×600 注册页顶部/底部、宽屏登录失败、窄屏普通输入与原生容器全屏输入截图。这里的全屏和文件选择是实际浏览器交互；视频使用合成载体，不表示验证了真实推流或音视频解码。

前端命令在 `Ayla/web` 使用 Windows Node：

```powershell
& 'E:/nodejs/node.exe' node_modules/vitest/vitest.mjs run src/vitest/auth-pages.test.tsx src/vitest/auth.test.ts src/vitest/danmaku-input.test.tsx src/vitest/live-player.test.tsx --minWorkers=1 --maxWorkers=1 --silent
& 'E:/nodejs/node.exe' node_modules/typescript/bin/tsc -b --noEmit
git diff --check
```

本机证据根目录为 `%LOCALAPPDATA%/Temp/auroraqua-reference-audit-20260907/`；每个输出目录包含 `control-states-report.json` 与对应截图：

| 脚本 | 输出目录 |
| --- | --- |
| `verify-ayla-auth-style.cjs` | `auth-style-final/` |
| `verify-ayla-danmaku-input.cjs` | `live-input-style-final/` |
| `verify-ayla-live-input-buttons.cjs` | `live-input-buttons-final/` |

源文件及上述报告的存在性/hash 清单为同一证据目录下 `auth-live-style-delivery.json`。截图、fixture 与清单留在工作区外，禁止打包或提交真实凭据/运行数据。

## 可逆性与边界

修改仅涉及前端工程资产，没有迁移或写入权威数据。回滚时可按本次精确文件 diff 恢复样式与 markup，认证接口和弹幕运行时无需数据恢复。此分工不执行暂存、提交或推送；最终整体验收与提交由当前总控负责。设计规范由总控同步到 `docs/design.md`。
