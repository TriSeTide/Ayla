# LiveKit 单 UDP 端口方案（frp 穿透）—— 架构、实测约束与运维手册

> **状态**：✅ **连通性方案成立**（1/3/5 人 ICE/DTLS/UDP/RTP 全绿，含 180s / 300s 长跑）；
> ⚠️ **但通话质量未达标**——隧道丢包在**修复 frpc 双实例后从 12.8%–16%（峰值 41%）降到 6.9%–8.4%**，
> 仍是 Opus 能听出断续的量级；剩余丢包随发送速率上升（队列成分），未治理。见 §1.4。
> **适用**：Ayla 语音频道媒体面从 WS 音频中继（Opus over WebSocket over TCP）切回
> LiveKit WebRTC（单 UDP 端口 ICE mux，经樱花 frp 穿透）。
> **一句话**：**连通性方案能通，但质量还没过关**。必须同时满足三条实测约束（§4），
> 否则表现为「突然全挂、重启中继也没用」；而 **frpc 双实例互踢（每 ~50s 一次 EOF 重连，日志累计 1517 次）** 与
> **隧道残留丢包 6.9%–8.4%**（§1.4）共同造成用户「断断续续」。前者已由单实例约束消除。
>
> **证据根**：`Ayla/.workbuddy/evidence/livekit-udp/`（gitignored）
> - `webrtc/RESULTS.md` —— WebRTC 进房实测报告（1/3/5 人、ICE/DTLS/candidate pair/RTP/RTT）
> - `webrtc/out/<run>/{RESULT.md,RESULT.json,client-*.json}` —— 每次运行的原始证据
> - `recon/PLAN.md` —— 代码侧只读侦察（文件:行 证据索引）
> - `udp_port_align.py` + `run_align.sh` —— 中继实现与守护脚本
>
> **服务器配置事实源**：`~/Elysia/ayla-deploy/{livekit.yaml, livekit-udp/*, nginx/nginx.conf, docker-compose.yml}`
> （服务器现状以**配置文件与实际只读检查**为准；本文所有运行态数字都标注了采集命令与时间）

---

## 1. 结论摘要

| 项 | 结论 | 证据 |
|---|---|---|
| **连通性**是否成立 | ✅ **成立**。1/3/5 人全部 ICE=connected、DTLS=connected、selected pair 为 **UDP 非 relay**、RTP 持续增长；累计 **11 次运行 / 35 个客户端 / 0 次 ICE 卡住** | `webrtc/out/REP-*`、`FINAL-*`、`STAB-3`、`LONG-5`；`RESULTS.md` §0 |
| ICE 长时稳定 | ✅ 3 人 180s、5 人 300s 全程无 `disconnected` 抖动，最大 RTT 399ms（中位 38ms） | `out/STAB-3`、`out/LONG-5` |
| ⚠️ **通话质量** | ❌ **未达标（有改善）**：frpc 双实例期间 **12.8%–16.0%**（峰值 41.3%）→ **修复后 6.9%–8.4%**；公网 baseline **0.0%**、服务器→NTP **0.0%** ⇒ 丢点在樱花隧道内部且有队列成分（随速率上升）。见 §1.4 | `RESULTS.md` §5；本机 raw echo 三轮 8.38/6.92/7.33%；`LONG-5`、`POSTFRPC-5` |
| 上次「只能 2 人」 | 根因是 **端口池(port_range) 与单端口 mux(udp_port) 用错**，不是 frp；详见 §6 | `retired/livekit.yaml.retired-20260912` 注释 |
| 2026-09-12「frp 改写 UDP 源地址」 | ❌ **误判，已实测证伪**；详见 §8（同批已改写 5 处历史文档结论） | `out/REP-3-*` 等 |
| 最大运维陷阱 | **中继重启后必须重启 ayla-livekit**，否则 ICE 永远卡 checking（§4.3） | `run_align.sh:45-49` + 时间线复现 |
| ⚠️ 新增运维缺陷 | **中继约每 6–7 分钟被重启一次，每次都连带重启 LiveKit ⇒ 周期性掐断在途通话**；死因未查明（§10.3.1） | `journalctl -t livekit-udp-align`；`docker logs ayla-livekit \| grep 'starting LiveKit server'` |

### 1.1 实测数据（复核集：运维层修复后，2026-10-27 21:10–21:14 CST）

采样 25s，`webrtc/out/REP-N-M/`，判定 **PASS**（`overall.pass=true`）：

| 人数 | 运行 | ICE | DTLS | proto / pair type | selected pair (local → remote) | rxBytes 增量 | RTT 中位 | 远端音频轨 |
|---|---|---|---|---|---|---|---|---|
| 1 | REP-1-1 | connected | connected | udp / prflx | 172.28.112.155:39443 → 218.65.97.108:27882 | 不适用（无对端） | 41 ms | 0 |
| 1 | REP-1-2 | connected | connected | udp / prflx | 172.28.112.155:38952 → 218.65.97.108:27882 | 不适用 | 41 ms | 0 |
| 1 | REP-1-3 | connected | connected | udp / prflx | 172.28.112.155:55251 → 218.65.97.108:27882 | 不适用 | 42 ms | 0 |
| 3 | REP-3-1 | 3/3 connected | 3/3 connected | udp / prflx | …:50993 / :37582 / :43108 → 27882 | 155,354 / 136,901 / 181,605 | 38–42 ms | 2 / 1 / 0 |
| 3 | REP-3-2 | 3/3 | 3/3 | udp / prflx | …:38140 / :44597 / :39954 → 27882 | 144,513 / 147,130 / 126,987 | 39–41 ms | 2 / 1 / 0 |
| 3 | REP-3-3 | 3/3 | 3/3 | udp / prflx | …:55583 / :33433 / :41599 → 27882 | 78,218 / 224,211 / 95,434 | 37–43 ms | 1 / 2 / 0 |
| 5 | REP-5-1 | 5/5 | 5/5 | udp / prflx | …:53283 … :57378 → 27882 | 228,179 – 280,577 | 39–40 ms | 4 / 3 / 3 / 1 / 0 |
| 5 | REP-5-2 | 5/5 | 5/5 | udp / prflx | …:54044 … :57895 → 27882 | 221,635 – 260,334 | 40–43 ms | 4 / 3 / 2 / 1 / 0 |
| 5 | REP-5-3 | 5/5 | 5/5 | udp / prflx | …:39696 … :51685 → 27882 | 229,049 – 246,077 | 39–44 ms | 4 / 3 / 2 / 1 / 0 |

> 「远端音频轨 0」为**测量时序**：最后一个退出的客户端在 `disconnect` 之后才 finalize，
> 订阅已被拆除，事件流里 `track-subscribed` 齐全（`RESULTS.md` §2.2 同一解释）。
> 单人无对端时 `bytesReceived=0` 是**正确结果**，不是故障（`RESULTS.md` §1.5）。

### 1.2 长时稳定性（ICE 稳定；丢包经 frpc 修复后由 12.8%–16% 降至 6.9%–8.4%）

| 运行 | 人数 | 时长 | ICE 稳定性 | rxBytes | packets | RTT 中位 / 最大 |
|---|---|---|---|---|---|---|
| `out/STAB-3` | 3 | 180 s | 全程 `connected`，**无抖动** | 941,658 – 1,272,126 | 7,454 – 11,094 | 37–38 / 282–606 |
| `out/LONG-5` | 5 | 300 s | 全程 `connected`，**无抖动**，`iceStatesEverObserved = [new, checking, connected]` | 2,993,559 – 3,184,753 | 24,506 – 25,595 | 38 / 399 |

**但 ICE 稳定 ≠ 通话质量好。** `RESULTS.md` §5 用同样的长跑数据算出
**RTP 丢包率分两个阶段**：frpc 双实例期间 12.8%–16.0%（逐区间峰值 41.3%、0 个「零收包」区间）；
**清理成单实例后降到 6.9%–8.4%**。本机到公网 UDP baseline **0.0%**、服务器→NTP **0.0%** ⇒
丢点在**樱花隧道内部**，且其中约一半来自 frpc 双实例互踢，剩余部分随发送速率上升（队列成分）。

⇒ **用户报的「断断续续、断几秒自己恢复」= frpc 每 ~50s 一次 EOF 重连（黑洞几秒）+ 残留 7%–8% 丢包**；
ICE 本身全程稳定，不是 ICE 断开
（丢了包 ICE 不会断，客户端不会重连，只是声音卡）。
**丢包治理是本次方案的下一个主战场**，详见 §1.4。

### 1.3 12:50–13:01Z 那次「全挂」不是 frp 的问题

`RESULTS.md` §4.1 的对照实验：**中继重启后、LiveKit 未重启**的那一窗（12:50–13:01Z，
15 次运行）1/3/5 人全 stuck；`docker restart ayla-livekit` 之后（13:07–13:14Z，9 次运行）
1/3/5 人全 PASS。⇒ 失败点是 **LiveKit 自己的 ICE mux 内部状态**（§4.3），
而**不是** UDP 通路（`RESULTS.md` §3 把这两层分开讲：L1 UDP 双向可达当时是通的）。

时间线（只读实测）：

- 20:56:43 CST 停掉抢隧道的 `sakurafrp-udp/guard.sh`（`~/sakurafrp-udp/run.log` 末行 `Closing...`）——**清理后仍全挂**，证明它不是根因
- 21:03:01 CST 中继重启（`livekit-udp/udp_align.log` 首行 `relay listening on 127.0.0.1:7882 -> 172.28.112.155:27882`）
- **21:04:07 CST `ayla-livekit` 重启**（`docker inspect ayla-livekit --format '{{.State.StartedAt}}'` = `2026-10-27T13:04:07Z`）——**恢复发生在这里**
- 21:10 CST 起 REP/STAB/LONG 全绿（§1.1、§1.2）

> ⚠️ **这里要纠正本文早前的一个判断**：中途一度把「frpc 双实例 `proxy conflict`」当成全挂根因，
> 但**清理后仍然全挂**，真因是 §4.3 的 ICE mux 陈旧映射（`RESULTS.md` §4.4 与 §11 也留了同样的更正）。
> `proxy conflict` 是真实存在的**叠加噪声**（会导致隧道不稳），但不是「ICE 永远连不上」的原因。

### 1.4 ⚠️ 已知硬问题：隧道丢包（12.8%–16% → 修复 frpc 后 6.9%–8.4%，仍未治理）

丢包分两个阶段。**同一套代码、同一台机器，唯一变量是 frpc 是否单实例。**

#### 阶段 A：frpc 双实例期间（2026-10-27 20:42–21:10）

| 实验 | 人数 | 时长 | 整体丢包率 | 逐区间 min / med / max | ICE 抖动 | 0 收包区间 |
|---|---|---|---|---|---|---|
| `out/STAB-3` | 3 | 180 s | **≈16%** | 8.2% / 15.0% / 24.8% | 无 | 0 |
| `out/LONG-5` c1 | 5 | 300 s | **15.95%** | 9.15% / 16.04% / **41.30%** | 无 | 0 |
| `out/LONG-5` c3 | 5 | 300 s | **12.79%** | 7.7% / 12.4% / 31.9% | 无 | 0 |

#### 阶段 B：改成单实例后（2026-10-27 21:37 之后）

| 测量 | 方式 | 结果 |
|---|---|---|
| 3 人 RTP 丢包 | harness | **7.2%–8.8%** |
| 5 人 RTP 丢包 | harness | **6.8%–8.7%** |
| raw UDP echo（50 pkt/s，三轮） | 本机 Node → `218.65.97.108:27882` | **8.38% / 6.92% / 7.33%** |
| **公网 UDP baseline** | 本机 → `ntp.aliyun.com:123`、cn.pool.ntp.org | **0.0%（60/60 全收）** |
| **服务器 → 公网 UDP baseline** | 服务器 → `ntp.aliyun.com:123` | **0.0%（60/60 全收）** |

**⇒ 丢包既不在本机公网出口、也不在服务器出口，而在樱花隧道内部。**

#### 丢包有队列成分（随发送速率上升）

| 发送速率 | 丢包 |
|---|---|
| 5 pkt/s | 5.05% |
| 15 pkt/s | 7.41% |
| 50 pkt/s（真实语音速率） | 11.52% |

→ 不是固定比例随机丢包，而是**樱花 UDP 转发有队列、高速率排队溢出**。

#### 根因之一：frpc 双实例互踢（已修）

同一 token、同一隧道的两个 frpc 进程会互踢，日志表现为
`reconnect to server error: EOF` **每 ~50 秒一次，累计 1517 次**。
每次重连期间隧道黑洞数秒 → RTP 停发 → 听感「断几秒又自己恢复」。
**这精确对应用户报的症状**；也解释了为什么「连接没断」——ICE 全程 connected，客户端不会触发重连。

修复：严格单实例。可靠检测写法见 §4.0（**注意 `pgrep -cf` 会假阳性**，必须用行首锚定的 `ps | grep`）。

#### 仍未治理的部分

剩余 **6.9%–8.4%** 丢包 + 队列成分，需下一阶段处理：

- Opus 抗丢包参数（`minptime` / `useinbandfec` / jitter buffer 上限）调优 —— **未做**
- 樱花侧配额与限速归因（当前限速 24 Mibit/s；实测 20 人语音仅 0.66 Mbps，不是限速导致）—— **未做**
- 更长窗口的丢包周期性 —— **未做**

**判据建议**：若目标是「一句话不断」，应把「隧道丢包 < 2%」当成上线 gate；压不下去就要重新评估隧道选型，
而不是继续调 Opus 参数。

---

## 2. 方案选型依据

### 2.1 为什么从 WS/TCP 换回 UDP

| 问题 | WS 音频中继（现状 / 回滚路径） | LiveKit UDP（本方案） |
|---|---|---|
| 传输语义 | Opus 帧跑在 **TCP** 上，丢包只能靠重传补齐 | UDP + Opus FEC/RED + jitter buffer，丢包由编码层吸收 |
| 队头阻塞 | 语音与 ssh / RTMP 推流 / HLS 拉流共用**同一条 frp mux TCP**（`~/frp/frpc.toml` 的 `transport.tcpMux = true`），任一条突发即顶住语音；`docs/flutter/37` §5.6 已把它列为观察点并实测 mux RTT ~44ms + 重传 | 媒体走独立 UDP 通道，与 TCP 隧道完全解耦 |
| 成簇到达 | `docs/flutter/38` §四实测服务端**帧到达是双峰的**（75.5% 挤在 <10ms，15.4% 落在 40–50ms），这是 TCP 链路上的典型表现 | 每 20ms 一个 RTP 包，节奏由 RTP 时钟决定 |
| 运行成本 | 服务端自己维护 slot 表 + `_ROOMS`（进程内，`audio_relay.py:23-28`，**不能横向扩展**） | SFU 转发，应用后端只签 token |
| 代价 | 无 | 引入中继单点 + 依赖 frp UDP 隧道（§4、§9）；**实测隧道丢包 12.8–16%，尚未治理（§1.4）** |

> **切换的只是媒体面**。应用层成员事实（`voice.state` / `members/` / `heartbeat/`）
> 与 REST 全部不变——LiveKit 的 participant 列表**不得**替代成员表
> （`web/src/livekit/client.ts:11-15` 早已写明的边界，`recon/PLAN.md` §2.4 复述）。

### 2.2 为什么不启用 TURN

退役配置 `retired/livekit.yaml.retired-20260912` 曾启用 TURN：

```yaml
turn:
  enabled: true
  domain: live.trise.top
  udp_port: 7881
  # relay 端口区间用 LiveKit 默认（30000-40000）。该区间没有经 frp 转发，
  # 因此走 TURN relay 的候选目前不可达 —— 详见 docs 里的排查记录。
```

**结论：不开 TURN。** 理由（全部可从配置与实测查到）：

1. **TURN relay 端口（30000–40000/udp）没有经 frp 转发**，写了只会让客户端拿到不可达候选；
2. 实测 selected pair 全是 **host/prflx 直连**（`out/REP-*`、`out/LONG-5` 的 `isRelay=false`），
   **没有一次**需要 relay；
3. 樱花 frps 只放行已配置的隧道端口；当前 `livekit` 隧道是 `29680036`
   （公网 27882/udp → 本机 127.0.0.1:7882），新增 port range 需要改隧道配额；
4. 开 TURN 还会引入 `forceRelay` 误用风险（退役配置注释已警告：`前端不要再开 forceRelay`）。

⇒ 现网 `~/Elysia/ayla-deploy/livekit.yaml` 中**没有 `turn:` 段**。

---

## 3. 架构与端口规划

```text
浏览器 / Flutter
  |  (1) 信令  wss://s.ayla.trise.top:26211/livekit  <- TCP，含 WebSocket Upgrade
  |        （⚠️ 不要用 frp-one.com 当信令域名：证书 SAN 只有 *.trise.top，
  |          浏览器会因证书不匹配拒绝 wss 握手。frp-one.com 只是隧道节点地址。）
  v
樱花 frps (frp-one.com = 218.65.97.108)  隧道 29680036
  |- proxy .Ayla    : 公网 26211/tcp -> 本机 127.0.0.1:443   (nginx)
  |- proxy .livekit : 公网 27882/udp -> 本机 127.0.0.1:7882  (中继)
  |
  v  服务器 172.28.112.155
nginx (host 网络, 127.0.0.1:443)   location /livekit/ -> http://127.0.0.1:7880/
  v
ayla-livekit (docker, network_mode: host, livekit/livekit-server:v1.13)
  |- 7880/tcp   信令（/rtc、/rtc/validate ...）
  |- 27882/udp  ICE mux（rtc.udp_port，bind 在各网卡 IP 上，见 §4.2）
        ^
        | 中继把隧道投递到 7882 的报文搬到 网卡IP:27882，回包原路送回
udp_port_align.py  监听 127.0.0.1:7882 -> 上游 172.28.112.155:27882（每客户端一个上游 socket）
  ^
  |  (2) 媒体  218.65.97.108:27882/udp
客户端
```

### 3.1 端口表

| 环节 | 地址 | 协议 | 证据 |
|---|---|---|---|
| 公网信令 | `wss://s.ayla.trise.top:26211/livekit` | TCP/443（frps 26211） | `nginx/nginx.conf:131-143`（443 块）+ 8080 块同名 location；证书 SAN `*.trise.top` |
| 樱花隧道（网页/信令） | 公网 26211 → `127.0.0.1:443` | TCP | `frpc-sakura.log`：`[e75**1e6.Ayla] connect to local service [tcp://127.0.0.1:443]` |
| nginx 反代 | `127.0.0.1:443` `location /livekit/` → `http://127.0.0.1:7880/` | HTTP/WS | `nginx.conf:131-143`（`proxy_buffering off`、read/send timeout 86400s） |
| LiveKit 信令 | `127.0.0.1:7880` | TCP | `livekit.yaml: port: 7880`；`ss -tln` 见 `*:7880` |
| **公网媒体** | `218.65.97.108:27882/udp` | UDP | 隧道 29680036；客户端 selected pair 全是该地址（§1.1） |
| 樱花隧道（媒体） | 公网 27882 → `127.0.0.1:7882` | UDP | `frpc-sakura.log`：`[e75**1e6.livekit] connect to local service [udp://127.0.0.1:7882]` |
| 中继 | `127.0.0.1:7882` → `172.28.112.155:27882` | UDP | `udp_align.log:1`（`relay listening on ...`） |
| LiveKit ICE mux | 各网卡 `:27882`（**无 127.0.0.1**） | UDP | `ss -uln \| grep 27882`（§4.2） |

> **信令为什么带 `/livekit` 前缀**：LiveKit 自己挂在根路径（`/rtc`），nginx 用
> `proxy_pass http://127.0.0.1:7880/` 的**尾部斜杠**剥掉前缀。所以
> `settings.LIVEKIT_WS_URL` 必须是 `wss://s.ayla.trise.top:26211/livekit`（末尾不带斜杠）；
> **不能用 `frp-one.com`**：证书 SAN 是 `*.trise.top`，域名不匹配会让浏览器拒绝 wss 握手。
> `backend/config/settings.py:302` 已写明该约束。

---


### 3.2 生产部署实参（2026-10-27 首次上线，改地址请对照本节）

> 这一节是「部署地址」的唯一事实源。踩过的坑按序号列出，每条都对应一次真实故障。

#### (1) 公网入口对照表

| 用途 | 正确地址 | 不要用 |
|---|---|---|
| 网页 / API / 信令 | `https://s.ayla.trise.top:26211` | `frp-one.com`（证书不匹配）、`ayla.trise.top`（CF 入口，非标端口不通） |
| LiveKit 信令 | `wss://s.ayla.trise.top:26211/livekit` | `wss://frp-one.com:26211/livekit` |
| 媒体（ICE） | `218.65.97.108:27882/udp`（LiveKit 自己通告，无需配置） | — |

证书 SAN 实测：`DNS:*.trise.top, DNS:s.ayla.trise.top, DNS:trise.top`。
**`frp-one.com` 不在 SAN 内** ⇒ 浏览器用它连 wss 会 TLS 校验失败，信令直接建立不了。
`frp-one.com` 只是樱花隧道节点的域名（解析到 218.65.97.108），不是对外的应用域名。

#### (2) 后端 `backend/.env` 必须项

```ini
VOICE_MEDIA_TRANSPORT=livekit                                  # 回滚改 ws_relay
VOICE_RELAY_WS_BASE=wss://s.ayla.trise.top:26211                # 中继回滚路径的绝对地址
LIVEKIT_API_KEY=ayla-livekit
LIVEKIT_API_SECRET=<必须与 livekit.yaml 的 keys 完全一致>        # ★ 见 (3)
LIVEKIT_WS_URL=wss://s.ayla.trise.top:26211/livekit
LIVEKIT_TOKEN_TTL_SECONDS=600
```

⚠️ 改完 `.env` 必须 `docker compose up -d --no-deps backend`；
**`docker restart` 不会重读 env_file**（手册同款提醒）。

#### (3) ★ 密钥一致性（最隐蔽的一个坑，本次实际踩到）

`livekit.yaml` 的 `keys:` 与 `backend/.env` 的 `LIVEKIT_API_SECRET` **必须是同一个值**。
本次上线时 `.env` 里还是退役配置留下的旧密钥，而 `livekit.yaml` 是新生成的 ——
后端签出的 token 会被 LiveKit 全部拒绝，表现为**信令能连、ICE 一直不连通**，
而且日志里只有 `401 invalid authorization token`，很容易误判成 ICE 问题。

校验命令（不打印明文）：
```bash
Y=$(grep -oP "(?<=ayla-livekit: ).*" ~/Elysia/ayla-deploy/livekit.yaml | tr -d "[:space:]")
E=$(grep -oP "(?<=^LIVEKIT_API_SECRET=).*" ~/Elysia/ayla-deploy/backend/.env | tr -d "[:space:]")
[ "$Y" = "$E" ] && echo "secret 一致" || echo "★ 不一致，必须修"
```

#### (4) nginx 两个 server 块都要有 `location /livekit/`

| 块 | 服务对象 | 缺了会怎样 |
|---|---|---|
| `listen 127.0.0.1:443 ssl` | 樱花入口（`s.ayla.trise.top:26211`） | 信令 404 / 落到 SPA |
| `listen 127.0.0.1:8080` | Cloudflare 回源（`ayla.trise.top`） | `/livekit/` 落到 SPA 兜底返回 `index.html`，WebSocket 握手必失败 |

两步验证（响应体必须是 `OK` 两字节，**不是 HTML**）：
```bash
printf "443  => "; curl -sk https://127.0.0.1/livekit/ | head -c 20; echo
printf "8080 => "; curl -s  http://127.0.0.1:8080/livekit/ | head -c 20; echo
```

#### (5) 上线后验收（顺序固定）

```bash
# ① 后端下发的 media 是否指向正确地址、token 是否裸 pk
curl -s -X POST "https://s.ayla.trise.top:26211/api/v1/voice/channels/1/join/" \
  -H "Authorization: Bearer <access>" -H 'Content-Type: application/json' -d '{}' \
  | python3 -m json.tool | grep -E 'transport|url|identity|room_name'
# 期望 transport=livekit、url=wss://s.ayla.trise.top:26211/livekit、identity 为裸数字 id

# ② 用该 token 真正建一次 WebRTC（harness）
node run.mjs --url wss://s.ayla.trise.top:26211/livekit --token <token> --room <room>
# 期望 ICE=connected、selected pair 为 udp prflx -> 218.65.97.108:27882
```

#### (6) 真实上线记录（2026-10-27）

| 项 | 值 |
|---|---|
| 后端镜像 | `ayla-backend:latest`（重建，含 `livekit-api`） |
| 容器 | `ayla-backend` 已 `up -d --no-deps` 重建并加载新 env |
| Web | `index-BrrM8zkj.js`（本地 vite 构建 → tar → 服务器 `web/dist` 原地替换） |
| 实测 | 生产 token 建联成功：ICE=connected、udp prflx→218.65.97.108:27882、RTT 38ms、建连 558ms |
| 客户端发版 | stable `1.0.29+31`（Windows x64 + Android universal） |

## 4. ★ 三条实测约束（最容易踩的坑）

### 4.1 约束一：LiveKit 把 `rtc.udp_port` **原样**写进 ICE candidate —— 不支持「通告端口 ≠ 绑定端口」

**事实**：LiveKit **没有**「对外通告端口」配置项。它把自己 bind 的 `rtc.udp_port`
原样写进 candidate，客户端据此发包。

**实测证据**（`docker logs ayla-livekit`，`rtc/room.go:1283` `participant active`）：

```json
"publisherCandidates": ["[local][selected:1][trickle] udp4 host 218.65.97.108:27882 (resolved: 218.65.97.108:27882)", ...]
```

候选里的端口 `27882` **等于** `livekit.yaml` 的 `rtc.udp_port: 27882`，一字不差。

**推论（必须遵守）**：

- 必须 `udp_port: 27882`（= 公网入口端口），**不能** bind 7882；
- 若 bind 7882，候选会变成 `218.65.97.108:7882` —— 那是**朋友 frps 的 HLS 拉流端口**
  （`~/frp/frpc.toml`：`name = "ayla-live-pull"`, `remotePort = 7882`，注释写作
  `7882 原为 LiveKit UDP，该隧道已退役`），公网虽有该端口但**指向 nginx:8443**，ICE 必然失败；
- 隧道映射固定在 `27882 → 127.0.0.1:7882`（SakuraFrp 控制面板设定，`local_port` 不能由
  v4 API 修改，见 `udp_port_align.py:9-11`），因此必须有一个**本机中继**把 7882 的报文搬到
  `网卡IP:27882`，再把回包原路送回 —— 这就是 `udp_port_align.py` 存在的唯一理由
  （文件头 `## 为什么需要它`）。

### 4.2 约束二：UDP mux **只 bind 网卡 IP，不 bind loopback** —— 中继上游必须写网卡 IP

**实测**（服务器 `ss -uln`，2026-10-27 21:19 CST）：

```text
UNCONN  172.20.0.1:27882      UNCONN  172.18.0.1:27882      UNCONN  172.17.0.1:27882
UNCONN  172.19.0.1:27882      UNCONN  172.28.112.155:27882  UNCONN  10.0.8.4:27882
UNCONN  100.64.0.2:27882      UNCONN  [fd7a:115c:a1e0::2]:27882   [2001:250:3002:82c0::1:1c6f]:27882
```

**没有 `127.0.0.1:27882`**（`udp_port_align.py:21-23` 记录了同一现象）。
`172.28.112.155` 是 `wlP9s9`（默认路由网卡）；其余是 docker 网桥 / wg0 / tailscale0 的地址。

**推论**：

- `ALIGN_UPSTREAM_HOST` 必须写默认路由网卡 IP。`udp_port_align.py` 的
  `detect_primary_ip()` 用 `connect(("8.8.8.8", 53))` 探测，实测得 `172.28.112.155`；
- **不能**写 `127.0.0.1`：报文会投递到一个没人监听的地址，表现同样是 ICE 卡 checking。

### 4.3 约束三：ICE mux 按 ufrag 缓存 peer-reflexive 地址 —— **中继重启后必须重启 ayla-livekit**

**机制**：LiveKit 的单端口 mux 按 STUN USERNAME 里的 ufrag 做多路解复用，并为每个会话
记住**源地址**（peer-reflexive）。中继重启后它的上游 socket 换了源端口，而 LiveKit
仍持有旧映射 ⇒ 新报文被当成「ufrag 不匹配」丢弃 ⇒ **所有 ICE 永远卡在 checking**。
`run_align.sh:10-14` 与 `udp_port_align.py:25-29` 都写了这条。

**时间序证据（自然实验，非受控实验）**：

| 时刻 (CST) | 事件 | 之后 1/3/5 人实测 |
|---|---|---|
| 20:40:12 | 中继从 `/tmp/relay_full.py` 换成 `udp_align.py`（`frpc-sakura.log`：`connection refused`） | — |
| 20:42–20:48 | 隧道健康窗（旧中继 `/tmp/relay_full.py` 在跑） | ✅ **ICE/DTLS/UDP/RTP 全绿**（`out/f-*`、`out/v-*`，见 §7.1 注） |
| 20:48:52 | 中继进程被替换（`relay_full.log` 停止写入）→ LiveKit 的 prflx 映射从此陈旧 | 12:50Z 起连续失败：12:50:32–12:55:03 共 15 次（1×3 + 3×3 + 5×3）**全部 ICE stuck**，12:58:38–13:01:38 又 4 次单人 **仍 stuck**（`RESULTS.md` §4.1 对照表） |
| 20:56:43 | 停掉抢隧道的 `sakurafrp-udp/guard.sh`（消除 `proxy conflict`） | 13:00:54 / 13:01:16 / 13:01:38Z 仍 **全部 stuck** |
| **21:03:01** | **中继重启**（`udp_align.log` 首行） | — |
| **21:04:07** | **`docker restart ayla-livekit`**（`State.StartedAt` = `13:04:07Z`） | 13:10Z 起 REP/STAB/LONG **全绿** |

⇒ 只停抢隧道的 frpc 不够（13:00–13:01Z 仍全 stuck），只重启中继也不够：必须**「重启中继 → 立刻重启 ayla-livekit」**成对发生。
`run_align.sh:45-49` 已把它固化为脚本行为：

```bash
# 中继换了上游 socket => LiveKit 的 ICE mux 缓存已失效，必须清空
if pgrep -f "[u]dp_port_align.py" > /dev/null 2>&1; then
  logger -t livekit-udp-align "relay started; restarting livekit to clear stale ICE mux state"
  docker restart ayla-livekit >/dev/null 2>&1
fi
```

> **脚本语义与代价**：该分支是「中继**启动**成功就重启 livekit」，即每次 cron 拉起中继
> （含机器重启、中继崩溃自愈）都会连带重启 livekit，从而**主动切断当时所有在途通话**。
> 这是**有意的取舍**：宁可断一次，也不让之后新连的人全卡死。若不想打断，应先确认无人
> 在房，再手动执行同一条命令。
>
> ⚠️ **这个取舍在实测中已经产生副作用**：2026-10-27 21:29–21:49 CST 观察到中继约每
> 6–7 分钟就被拉起一次，于是 LiveKit 也跟着每 6–7 分钟重启一次（**每一轮都掐断在途通话**）。
> 详见 §10.3.1 —— 那是**当前未修复的运维缺陷**，不是设计本意。

**排障速查**：出现「所有人都连不上、`docker logs ayla-livekit` 里没有 `dropping candidate`、
客户端 STUN `requestsSent>0 / responsesReceived=0`」时——**第一步不是抓包，而是
`docker restart ayla-livekit`**。

---

## 5. `node_ip` 与 `udp_port` 的正确写法

### 5.1 完整配置（`~/Elysia/ayla-deploy/livekit.yaml`，权限 `0600`）

```yaml
# Ayla LiveKit 生产配置（单 UDP 端口 ICE mux）
port: 7880                     # (1) 信令端口，nginx 反代到 127.0.0.1:7880

rtc:
  tcp_port: 0                  # (2) 关掉 TCP 回落候选：客户端实测 tcp host :9 候选全部不可用
  udp_port: 27882              # (3) 必须 = 公网入口端口（LiveKit 原样写进 candidate，§4.1）
  node_ip: 218.65.97.108       # (4) 公网侧可达 IP（樱花节点 = frp-one.com 的解析结果）
  use_external_ip: false       # (5) 关闭外网 IP 探测：node_ip 已显式给定，别让它被覆盖

keys:
  ayla-livekit: <LIVEKIT_API_SECRET>   # (6) 与 backend .env 的 LIVEKIT_API_KEY/SECRET 一致；本机配置，不入库

logging:
  level: info                  # (7) 排障靠 docker logs，info 足够
```

**逐行为什么**：

| # | 行 | 为什么必须这样 |
|---|---|---|
| (1) | `port: 7880` | 只 bind 本机；公网信令经 nginx `/livekit/` 剥前缀后反代过来（§3.1） |
| (2) | `tcp_port: 0` | 若开 TCP 候选，只能走 7880 的 HTTP 隧道（frp 只映射了 443→nginx）；实测客户端 tcp 候选全部 `port 9` 不可用，开着只增加噪声探测 |
| (3) | `udp_port: 27882` | **核心**。等于公网入口端口；**绝对不能同时写 `port_range_start/end`**（§6） |
| (4) | `node_ip: 218.65.97.108` | candidate 里的 IP 来自 `node_ip`。写内网 IP（如 172.28.112.155）客户端不可达；写朋友 frps 的 47.108.85.223 同理不可达 |
| (5) | `use_external_ip: false` | 开了会去外部服务探测出口 IP 并可能覆盖 `node_ip`，导致候选 IP 漂移 |
| (6) | `keys:` | 必须与 `backend/.env` 的 `LIVEKIT_API_KEY`/`LIVEKIT_API_SECRET` **一致**；只在本机，**不进仓库** |
| (7) | `logging.level: info` | `participant active` 日志里有完整 candidate 列表，是判断 §4.1/§4.2 的唯一直接证据 |

### 5.2 反例（写错会怎样）

| 错误写法 | 后果 |
|---|---|
| `udp_port: 7882`（隧道本地口） | 候选变 `218.65.97.108:7882` → 打到朋友 frps 的 HLS 端口，ICE 必失败（§4.1） |
| `udp_port` **与** `port_range_start/end` 同时写 | 回到端口池模式 / 分配冲突，重现「只能 2 人」（§6） |
| `node_ip` 写 `127.0.0.1` 或内网 IP | 候选不可达 |
| `turn.enabled: true` | relay 端口 30000–40000 未穿透，客户端拿到不可达候选（§2.2） |
| `ALIGN_UPSTREAM_HOST=127.0.0.1` | 中继把包投给没人监听的 loopback（§4.2） |
| 改完配置只重启中继 | ICE mux 缓存不失效（§4.3） |

---

## 6. 上次「只能 2 人进房」的根因

**根因：用错了模式 —— `rtc.port_range_start/end`（端口池）vs `rtc.udp_port`（单端口 mux）。**

退役配置 `~/Elysia/ayla-deploy/retired/livekit.yaml.retired-20260912` 的注释原文：

```text
# 原先 rtc 段写的是：
#     port_range_start: 7882
#     port_range_end:   7882
# 这是「传统 ICE 端口池」模式 —— 官方文档明确：该模式下**每个参与者要占 2 个 UDP 端口**。
# 范围里只有 1 个端口，所以第一个参与者把端口占满、第二个就分配不到，
# 表现为「第一人能进房、第二人起连不上」。
# 更糟的是多个参与者的 ICE 会话挤在同一个 socket 上互相踩，日志报：
#     dropping candidate with ufrag X because it doesn't match the current ufrags
```

**机制拆解**：

1. 端口池模式下每个 participant 需要 **2 个** UDP 端口，而 `[7882, 7882]` 只有 **1 个**；
2. ⇒ 第 1 人占满，第 2 人**分配不到** → 连接失败；
3. ⇒ 即便强行共用同一 socket，多会话 ufrag 互相踩 → `dropping candidate with ufrag ...`；
4. 正确做法是 **单端口 ICE mux**：`rtc.udp_port: <port>`，**且不写 `port_range_*`**
   （官方 config-sample 注释：`port_range_start & end must not be set for this config to take effect`；
   亦见 `recon/PLAN.md` §六·阶段一与 `retired` 配置注释里的同一段引用）。

**本次复核（实测）**：

- 现网 `livekit.yaml` 只有 `udp_port: 27882`，**没有** `port_range_*`；
- `docker logs ayla-livekit --since 2h | grep -c 'dropping candidate'` = **0**；
- 5 人房 5/5 connected（§1.1）⇒ 该根因已消除。

> ⚠️ 这条「只能 2 人」**与 frp 的 UDP 能力无关**，是纯 LiveKit 配置模式问题。
> 历史文档若把它归因到「frp 不支持多人」，那是错的。

---

## 7. 实测数据（引用 `webrtc/RESULTS.md`）

`RESULTS.md` 是 harness 的正式报告；判定方法学见其 §1（为什么用真实 Chromium 而不是 Pion、
为什么采样必须在 `connect()` 之前开始、为什么用「是否曾经连通过」而不是结束状态）。

### 7.1 成功窗口（RESULTS.md §2，40 s 采样，2026-10-27 20:42–20:48 CST）

| 人数 | 运行 | 结论 | 关键数字 |
|---|---|---|---|
| 1 | `out/f-1` | PASS | ICE/DTLS connected，udp prflx，RTT **35 ms**；单人无对端故 `bytesReceived` 不适用 |
| 3 | `out/f-3` / `out/v-3` | ICE 3/3、DTLS 3/3、UDP 非 relay 3/3 | rxBytes **189,048–197,695**/40s；RTT **35–42 ms**；每人订阅到另外 2 人（每房间 6 条 `track-subscribed`） |
| 5 | `out/f-5` / `out/v-5` | ICE 5/5、DTLS 5/5、UDP 非 relay 5/5 | rxBytes **279,375–372,459**/40s；RTT **34–55 ms**；每人订阅其余 4 人 |

> `RESULTS.md` 里 `f-3`/`f-5`/`v-3`/`v-5` 的 `Verdict: FAIL (phase ok)` 是
> **「最后一个退出者 `remote tracks=0`」的测量时序**导致的（`RESULTS.md` §2.2 已解释），
> **不是** ICE/DTLS/RTP 失败 —— 四个聚合断言 `allIceConnected` / `allTransportConnected` /
> `allUdpNonRelay` / `allRtpFlowing` 全为 `true`。
> 其后 `out/final-3`（200,032 / 203,481 / 203,161）与 `out/final-5`
> （402,036 / 393,925 / 385,136 / 410,281 / 405,435，RTT 40–45 ms）同样四个聚合断言全为 `true`；
> 其中 `final-3` 末位仍被 `remote tracks=0` 判红（同一时序原因），`final-5` 才是 `Verdict: PASS`。
> 若要一个**全绿**的多人数复核集，用 §1.1 的 `out/REP-*`。

### 7.2 失败窗口（RESULTS.md §4.1，12:50–13:01Z）

| 现象 | 数据 | 结论 |
|---|---|---|
| 客户端 | 7 个 host candidate 全部发出，`requestsSent=223 / responsesReceived=0` | 出向正常、回向 0 响应 |
| 服务器 | 同一时刻 `"state": "failed", requestsSent: 8, responsesReceived: 0` | LiveKit 侧也没收到带 ufrag 的 ICE STUN |
| 已排除 | Clash TUN / harness 自身 / 浏览器不发 UDP / `dropping candidate` 计数=0 / LiveKit 配置错误 | `RESULTS.md` §7 的对照实验表 |
| **真根因** | **ICE mux 的陈旧 prflx 映射**（中继重启换了上游源端口，LiveKit 仍持旧映射）⇒ 无状态可解 | `RESULTS.md` §4.1；本文 §4.3 |
| 叠加噪声（非根因） | frpc 双实例 `proxy conflict`、双 relay 抢 7882 | `RESULTS.md` §4.4：**清理后仍全挂**，重启 LiveKit 才恢复 |

⇒ 失败**既不是**「frp 不支持 UDP」，**也不是**「frpc 实例冲突」，而是 **LiveKit ICE mux 状态需要与中继生命周期绑定**（§4.3）。
这正是 §8 要纠正的历史误判之外、本文自己也要记住的一条新教训。

### 7.3 关键证据：为什么方案成立（RESULTS.md §2.4）

```text
[local][selected:1]  udp4 host 218.65.97.108:27882
[remote][selected:1] udp prflx 172.28.112.155:45912
"connectionType": "udp"
```

服务器看到的对端是**中继为每个客户端分配的上游 socket**（`172.28.112.155:<高端口>`），
客户端侧 `selectedPairLocal` 也是同一个 `172.28.112.155:xxxxx` —— 两端对同一条 pair
的认知一致，说明**中继没有做破坏性地址改写**。这也是「必须每客户端一个上游 socket」的原因：
LiveKit 按 ufrag 解复用，若所有客户端被压到同一个上游源端口，会话就会互相踩。

---

## 8. ★ 纠正历史错误结论（2026-09-12「frp 改写 UDP 源地址」是误判）

### 8.1 原结论是什么

2026-09-12 退役 LiveKit 时，仓库多处代码/文档采用同一句根因：
**「frp 穿透会改写 UDP 源地址 ⇒ WebRTC/TURN 媒体面不可用」**。

### 8.2 本次实测证伪（逐条对证）

| 「frp 改写 UDP 源地址」的前提 | 实测结果 | 证据 |
|---|---|---|
| UDP 报文过 frp 后源地址被改写，导致 ICE 无法收敛 | **不成立**。1/3/5 人全部 ICE=connected，selected pair 是 `udp prflx` | §1.1 三张表；`out/REP-*`、`out/LONG-5` |
| 服务器看到的对端地址与客户端认知不一致 | **不成立**。两端都看到 `172.28.112.155:<同端口>` | §7.3；`client-R3r1-c1.json` 的 `selectedPairHistory.key` = `172.28.112.155:50993\|218.65.97.108:27882\|udp` |
| 因此 WebRTC 不可用 | **不成立**。RTP 持续增长，300 s 无断流 | §1.2 `out/LONG-5` |

**真正的原因（当时没查出来的三层）**：

1. **配置层**：`port_range_start/end` 与单端口 mux 用错 → 「只能 2 人」（§6）。
   只有一个端口的「端口池」在 3 人房里必然失败，这与 frp 无关；
2. **地址层**：`node_ip` 广播**内网/错误 IP**。`docs/report/前端全功能点击测试报告.md:161,173`
   早已更正过一次同类错误归因：真正根因是「UDP 未映射 + `node_ip` 广播内网 IP」，
   并明确写下「早前『headless 浏览器 ICE 必然失败』是**错误归因**」；
3. **运维层**：中继重启后 LiveKit 的 ICE mux 仍持旧 prflx 映射 ⇒ 之后新连的人全部卡 checking（§4.3；frpc 双实例 `proxy conflict` 只是叠加噪声，清理后仍全挂）。

⇒ **退役是误判**。当时的失败全部由**配置 / 地址 / 实例管理**引起，与「frp 改写 UDP 源地址」无关；
frp 的 UDP 代理在本方案里**工作正常**（§1.1、§7）。

### 8.3 已改写的历史结论（按 AGENTS.md §12：直接改写原句，不让两种说法并存）

| # | 文件 | 改写后的行号 | 原句（误判） | 改写成了什么 |
|---|---|---|---|---|
| 1 | [`docs/flutter/01-web现状盘点.md`](../flutter/01-web现状盘点.md) | **:229**（标题）/:231（正文）/:233（补充） | 「LiveKit 已整体退役（2026-09-12 起）：frp 穿透下 UDP 源地址被改写，WebRTC/TURN 媒体面不可用 → 唯一传输为 WS 音频中继」 | ① :229 标题改为「语音：媒体面双路（LiveKit 单 UDP 端口 = 现网 \| WS 音频中继 = 回滚路径）」；② :231 改为「**LiveKit 基础设施已于 2026-10-27 重新部署并实测通过**…那次退役的根因**已被实测证伪**」；③ :233 新增一段「现网由 `VOICE_MEDIA_TRANSPORT` 决定，下文为回滚路径」 |
| 2 | [`docs/服务器半容器化部署方案.md`](../服务器半容器化部署方案.md) | **:275-279** | 「LiveKit 已于 2026-09-12 整体退役（UDP 源地址被 frp 改写，WebRTC/TURN 不可用），改走 ws 音频中继。LIVEKIT_* 变量不再使用」 | 改为「媒体面 = LiveKit 单 UDP 端口（公网 218.65.97.108:27882/udp，信令 wss://frp-one.com:26211/livekit），2026-10-27 实测通过」+「退役结论已证伪」+「回滚 = `VOICE_MEDIA_TRANSPORT=ws_relay`」+「仅 livekit 路需要 `LIVEKIT_*`」 |
| 3 | [`docs/flutter/02-复刻评估与方案.md`](../flutter/02-复刻评估与方案.md) | **:183** | 「备选：降级为服务端转码 WebRTC 直连（frp 限制下不可行——web 端已退役 LiveKit 的教训要尊重）」 | 改为「备选：直接接 LiveKit WebRTC——frp **已实测可承载**…」，并注明旧的「frp 限制下不可行」是 2026-09-12 的误判（同文档 §8） |
| 4 | [`docs/flutter/04-审计结论.md`](../flutter/04-审计结论.md) | **:43** | 「LiveKit 退役属实（全 src 无 livekit-client import，wsRelayRoom.ts:2『替代 livekit-client』）」 | 拆成两件事并分别定性：**①「当时全 src 无 livekit-client import」是审计时点的事实，仍成立**；**②「退役根因 = frp 改写 UDP 源地址」是误判，已证伪** |
| 5 | [`docs/flutter/05-实施提示.md`](../flutter/05-实施提示.md) | **:4** | 「语音=WS 音频中继 48kHz 单声道 Opus（LiveKit 已退役）」 | 改为「语音=媒体面双路（`VOICE_MEDIA_TRANSPORT`：livekit 走单 UDP 端口 27882 / ws_relay 走 WS 音频中继…默认 ws_relay，且它是回滚路径）」，并注明退役结论已证伪 |

> 五处均为**就地改写原句**，没有新增「另说」段落。复核方式：
> `grep -rn '源地址' Ayla/docs` —— 命中项应当只有 ① 本文（含本表引用的旧句原文）、
> ② 五处改写后的**否定式**表述（形如「…已被实测证伪」）。
> 若某处仍以**肯定语气**断言「frp 改写 UDP 源地址导致 WebRTC 不可用」，即为未收口。

> **范围说明**：本任务只写 `Ayla/docs/`。仓库里同源的过时表述还存在于
> `Ayla/docker-compose.yml:4-5`、`Ayla/deploy/README.md:41-42`、
> `Ayla/deploy/examples/docker-compose.yml.example:74-75`、
> `Ayla/deploy/examples/backend.env.example:45`、`Ayla/deploy/examples/srs.conf.example:13`、
> `Ayla/web/src/livekit/client.ts:7-9`、`Ayla/web/src/livekit/wsRelayRoom.ts:4` —— 属代码/部署
> 配置任务范围，已登记给对应负责方收口。`Ayla/backend/config/settings.py:292-293` 已由后端任务
> 先行更正并指向本文。

---

## 9. 回滚方式

**唯一全局开关：`VOICE_MEDIA_TRANSPORT=ws_relay`**（`backend/config/settings.py:294`，
**默认值就是 `ws_relay`**；改环境变量 + 重启 backend 即生效，**不需要发版、不需要重建客户端**）。

```bash
# 服务器：~/Elysia/ayla-deploy/backend/.env（或部署环境变量）
VOICE_MEDIA_TRANSPORT=ws_relay
docker restart ayla-backend
```

| 回滚对象 | 动作 | 说明 |
|---|---|---|
| 媒体传输 | 上面那一个环境变量 | 客户端从 join 响应读到 `media.transport=ws_relay`，改走 WS 中继 |
| 客户端（web） | 无需改动 | `web/src/livekit/wsRelayRoom.ts` **一行未改**，仍是完整实现 |
| 客户端（Flutter） | 无需改动 | `flutter/lib/audio/relay_client.dart` + `audio_engine.dart` 保留 |
| 服务端中继 | 无需改动 | `apps/voice/routing.py`、`audio_consumer.py`、`audio_relay.py` 未改 |
| 基础设施 | `docker stop ayla-livekit` + 从 crontab 移除 `run_align.sh` | 停掉容器与中继，避免空跑 |

> **什么情况下应该回滚**：不是「ICE 连不上」（那按 §4.3 重启即可），而是
> **§1.4 的残留丢包在可接受时间内治不好**——单实例修复后仍有 6.9%–8.4%，
> 实际听感可能仍不如 WS 中继（后者靠 TCP 重传隐藏丢包，代价是队头阻塞）。
> 回滚成本极低（一个环境变量），**不需要**因此重新评估架构。

**双下发语义**（`backend/apps/voice/media_config.py:81-99`）：
join / media-token 响应**同时**给出 `media.livekit` 与 `media.ws_relay`，`transport` 只是
服务端**建议值**。客户端在 `transport=livekit` 但连接失败时，应直接用已到手的
`media.ws_relay.url` **原地降级**（一次重试，不回后端），且**不得**因此调用 `leave/`
（媒体断线 ≠ 离开频道，`client.ts:15` 的既有契约）。

> **回滚的已知限制**：WS 中继的 `_ROOMS` 是**进程内**状态（`audio_relay.py:23-28`），
> 不能横向扩展。回滚时 backend 必须保持单 worker。

---


## 9. 2026-10-28 真机问题本地复现与诊断（音频链路）

> 起因：用户真机联测反馈「电脑→手机断断续续、手机→电脑完全没声音、音频条不灵敏、
> 静音被对方重新开麦绕过、手机端像通话不像媒体播放」。
> 本节记录**本地双端复现**（Windows 桌面 + Android 模拟器，均连生产后端）得到的实测数据。

### 9.1 复现方法（可重复执行）

`flutter/tool/voice_probe.dart` 是**不经 UI** 的调试入口：登录 → join → 连 LiveKit → 开麦。
两端用不同账号（本机建了 `probe2`），否则会因 identity 相同被 LiveKit 踢。

```bash
# 端 A（Windows）
flutter run -d windows -t tool/voice_probe.dart \
  --dart-define=VOICE_USER=test --dart-define=VOICE_PASS=12345678 \
  --dart-define=VOICE_CHANNEL=1 \
  --dart-define=AYLA_API_BASE=https://s.ayla.trise.top:26211

# 端 B（Android 模拟器；必须带 skip 参数，本仓库 Gradle 8.12 < Flutter 要求的 8.14）
flutter run -d emulator-5554 -t tool/voice_probe.dart \
  --android-skip-build-dependency-validation \
  --dart-define=VOICE_USER=probe2 --dart-define=VOICE_PASS=12345678 \
  --dart-define=VOICE_CHANNEL=1 \
  --dart-define=AYLA_API_BASE=https://s.ayla.trise.top:26211
```

两端每 3 秒打印一行 RTP 统计（`[lk] LOCAL tx ...` / `[lk] REMOTE <id> rx ...`），
这是区分「没订阅 / 没收到包 / 收到但解不出声 / 解出来但播放栈不出声」的唯一手段。

### 9.2 实测结论（同一会议，两个客户端同时在线 ~6 分钟）

| 方向 | 收包 | 丢包 | 隐藏帧(concealedSamples) | 结论 |
|---|---|---|---|---|
| Windows → Android | 16388 | **564 (~3.4%)** | 1,116,183 (~23s / 6.8%) | **持续卡顿的来源** |
| Android → Windows | 16891 | 1 | 66,763 (~1.4s / 0.4%) | 干净 |

信令稳定性（同一时段）：**Windows 重连 24 次，Android 0 次**。
Windows 侧日志交替出现 `ping timeout`、`HandshakeException: Connection terminated during handshake`、
`PEER_CONNECTION_DISCONNECTED`；服务端 nginx 无错误（WS 全部 101），
LiveKit 侧记录 `PEER_CONNECTION_DISCONNECTED`。

### 9.3 由此确定的三个真实缺陷（已修）

1. **音频条不灵敏**：原实现读 `Participant.audioLevel`（服务端 speaker 电平，~1.5s 粒度）。
   改为读 `RemoteAudioTrack.getReceiverStats()` 的 `totalAudioEnergy` /
   `totalSamplesDuration` 增量算 RMS（`sqrt(ΔE/ΔD)`，200ms 一拍）。
   本地实测电平已能跟随真实语音（0.2~0.75 连续变化）。
2. **本地静音被「对方重新开麦」绕过**：关麦语义是 unpublish ⇒ 对方再开麦是新 publication，
   SDK autoSubscribe 会订阅回来；原实现没有记住成员级音量。
   已改为按 identity 记忆并在 `TrackSubscribed` 重新施加（web 与 Flutter 同步修）。
3. **手机端是通话语义**：改用 `AudioSessionOptions.mediaPlayback` + 移动端强制外放。

另外补了一个**发布重试**：Windows 实测出现 `TrackPublishException: Failed to publish track`，
发生在连接正在 resume 的瞬间；原实现直接抛错 ⇒ 整场没有麦克风。现在重试一次（间隔 800ms）。

### 9.4 尚未解决：需要网络侧处理

- **隧道单方向丢包 3.4% + 6.8% 隐藏帧**（Windows→Android 方向）。此前多轮测量公网基线为 0%，
  服务器↔NTP 基线为 0%，丢包发生在樱花隧道内部，且带队列成分。
  客户端已用 32 kbps + RED + 关 DTX，参数侧没有余量；**要根治必须换网络路径**（公网 IP 直连或换隧道节点）。
- **Windows 客户端信令频繁重连**（`ping timeout`）。Android 同隧道 0 次重连，说明与客户端栈/本机网络栈相关；
  待进一步定位（下一步：关掉本机 Clash TUN 做对照）。

### 9.5 排查纪律（复用）

- 不要只看「音频条在动」判断有声：旧电平来自服务端 speaker 事件，与本地播放无关；
  现在用收包侧统计才能区分故障层次。
- 同一账号在两个客户端同时进同一房间会被 LiveKit 以 `DUPLICATE_IDENTITY` 互踢，
  表现为「连接正常但声音一直断」。复现/测试必须用不同账号。
- 给 `flutter run` 打开 LiveKit 全量日志（`setLoggingLevel(kALL)`）会每秒刷上千行，
  **反过来把 ICE 刷到超时**；排查时用 kWARNING，需要细节再临时开。
### 9.6 ★ Windows 端「听不到远端声音」的真正原因：播到了默认通信设备

**现象**：手机说话，Windows 端音频条在动、RTP 统计显示收包正常，但完全听不到。

**实测方法**（可复现）：
1. 用 `tone_pub.cjs` 让一个客户端发布 **440Hz 正弦波**（确定性声源，不是人声）；
2. 用 CoreAudio `IAudioMeterInformation` 读 Windows **三种角色**的默认输出设备峰值。

结果（同一时刻）：

| 终点角色 | 峰值 | 说明 |
|---|---|---|
| Console（默认设备） | 0.0001 | 静音 |
| Multimedia（默认设备） | 0.0001 | 静音 |
| **Communications（默认通信设备）** | **0.4302** | **音频在这里** |

对照基线：静音 0 / 本地播 440Hz 文件 0.3662 —— 说明测量方法与阈值可信。

本机的端点分配：
```
扬声器 (Steam Streaming Speakers)
扬声器 (Realtek(R) Audio)        <== 默认通信设备
扬声器 (MIXLINE)
虚拟扬声器 (VB-Audio Cable A)
耳机 (vivo TWS 3i)               <== 默认设备（多媒体）
```

**结论**：WebRTC 按设计把远端音频渲染到系统的**默认通信设备**，
而用户通常把「默认设备」（多媒体）当成自己该听的设备。两者是**不同物理端点**时，
就会出现「包收到了、音频条在动、设备也在放，但人听不到」。
这与 App 代码无关，也与手机端无关。

**修复（用户侧，10 秒）**：把默认通信设备改成与默认设备一致。
Windows 11：设置 → 系统 → 声音 → 全部声音设备/更多声音设置 → 播放 →
选中目标设备 → 「设为默认通信设备」；或控制面板 → 声音 → 播放 → 同操作。

**App 侧可选改进（未做，登记）**：`flutter_webrtc` 在桌面端实现了
`SelectAudioOutput → ADM.SetPlayoutDevice`（`common/cpp/src/flutter_media_stream.cc:480`），
所以可以在语音面板里加「输出设备」选择器让用户显式指定；
但**无法**从 App 判断哪个端点才是用户的「默认设备」，因此不能靠自动选取根治。



## 10. 运维手册

### 10.1 组件与启停

| 组件 | 启停 | 备注 |
|---|---|---|
| `ayla-livekit` 容器 | `docker start ayla-livekit` / `docker restart ayla-livekit` | **不在 compose 默认 profile 里**（`docker-compose.yml` 的 livekit 服务是 `profiles: ["retired"]`），`docker compose up` **不会**拉起它，必须显式 start/restart；`network_mode: host`；镜像 tag 见下 |
| UDP 对齐中继 | `~/Elysia/ayla-deploy/livekit-udp/run_align.sh`（crontab `* * * * *`） | flock 互斥 + pgrep 去重；启动成功后**自动 `docker restart ayla-livekit`**（§4.3） |
| 樱花 frpc（网页 + livekit 隧道） | `~/frp/keepalive.sh`（crontab `* * * * *`）拉起 `~/sakurafrp/frpc -f <token>` | 一条 frpc 承载 `.Ayla`(26211→443) 与 `.livekit`(27882/udp→7882) 两个 proxy |
| nginx | `docker restart ayla-nginx`（或容器内 `nginx -s reload`） | `/livekit/` 块见 `nginx.conf:127-143` |

**镜像 tag 说明**：`docker-compose.yml` 写的是 `livekit/livekit-server:v1.13`，而当前运行容器的
OCI label 为 `v1.13.6`（`docker inspect ayla-livekit --format '{{json .Config.Labels}}'`）——
同一 major 下的实际补丁版本。

### 10.2 每次改动的标准动作（顺序不能反）

1. 改 `livekit.yaml`；
2. `docker restart ayla-livekit`；
3. 若同时动过中继：`pkill -f udp_port_align.py` → 等 cron 拉起（或直接跑 `run_align.sh`）；
4. 按 §10.3 逐项验证；
5. 用 harness 复测（§10.4）。

### 10.3 排障检查表

```bash
# (1) 中继在听、上游是网卡 IP（不能是 127.0.0.1）
ss -uln | grep 7882
tail -3 ~/Elysia/ayla-deploy/livekit-udp/udp_align.log
#   期望：relay listening on 127.0.0.1:7882 -> 172.28.112.155:27882

# (2) LiveKit 在 27882 上、且没有 loopback 监听
ss -uln | grep 27882
#   期望：172.28.112.155:27882 等网卡地址；出现 127.0.0.1:27882 说明看错了进程

# (3) 信令通、候选端口正确
curl -sS -o /dev/null -w '%{http_code}\n' https://s.ayla.trise.top:26211/livekit/rtc/validate
docker logs ayla-livekit --since 10m 2>&1 | grep -o 'udp4 host [0-9.]*:[0-9]*' | sort -u
#   期望：只有 218.65.97.108:27882

# (4) 没有 ufrag 冲突（§6 旧故障特征）
docker logs ayla-livekit --since 2h 2>&1 | grep -c 'dropping candidate'
#   期望：0

# (5) 隧道侧没在报错
grep -E '\[e75\*\*1e6\.(livekit|Ayla)\]' ~/sakurafrp/frpc-sakura.log | tail -5
grep -c 'proxy conflict' ~/sakurafrp/frpc-sakura.log      # 期望：0
```

| 症状 | 最可能原因 | 处置 |
|---|---|---|
| 全员 ICE 卡 checking，STUN `respRecv=0` | ICE mux 缓存失效（§4.3）/ 中继没在跑 / 隧道断 | **先 `docker restart ayla-livekit`**；再查 (1)(5) |
| 只有第 2 人起连不上 + `dropping candidate ... ufrag` | `port_range_*` 与 `udp_port` 混用（§6） | 只保留 `udp_port` |
| 候选是 `218.65.97.108:7882` 或内网 IP | `udp_port` / `node_ip` 写错（§5） | 按 §5.1 修正 |
| 信令 502/404 | nginx `/livekit/` 块与 `port: 7880` 不一致 | 查 `nginx.conf:127-143` + `ss -tln \| grep 7880` |
| 日志出现 `proxy conflict` | 有第二个 frpc 抢同一隧道 | 只留 `keepalive.sh` 管的那一个；确认 `sakurafrp-udp/guard.sh` **已停** |
| media-token 返回 503 | backend 侧 `LIVEKIT_*` 未配齐，或 `VOICE_MEDIA_TRANSPORT` 仍是 `ws_relay` | 用 `media_config.configured_transport()` 与 `.env` 对齐 |

#### 10.3.1 ⚠️ 已复现的运维缺陷：中继被反复拉起，每次都连带重启 LiveKit

这一条是**本次实测发现、尚未修复**的问题，必须写进排障手册，否则会被误当成「ICE 又挂了」。

**观测（2026-10-27 21:03–21:59 CST，只读）**：

```
$ journalctl -t livekit-udp-align --no-pager -o short-iso | tail -5
21:03:01  relay started
21:29:03  relay started; restarting livekit to clear stale ICE mux state
21:36:03  relay started; restarting livekit to clear stale ICE mux state
21:42:03  relay started; restarting livekit to clear stale ICE mux state
21:49:29  relay started; restarting livekit to clear stale ICE mux state
```

`docker logs ayla-livekit --since 2h | grep 'starting LiveKit server'` 也**一一对应**地在
13:29 / 13:36 / 13:42 / 13:49 UTC（= 21:29 / 21:36 / 21:42 / 21:49 CST）各重启一次 ——
即**中继每一次被拉起，都真的把 LiveKit 重启了**（这正是 §4.3 脚本设计的预期行为，
但在这里被一个非预期的中继重启周期反复触发）。

**时间间隔**：21:03 那次中继存活 26 min（21:03→21:29）；21:29 之后变成
**21:29 → 21:36（7 min）→ 21:42（6 min）→ 21:49（7 min）** 的密集周期。

**后果**：按 §4.3 的语义，这等于**每 6–7 分钟把所有在途通话掐断一次**。
如果线上真的跑 LiveKit，这会是比丢包更严重的可用性问题。

**已核实 / 未核实**：

| 项 | 状态 |
|---|---|
| 中继确实被反复重启 | ✅ 已核实（journal 5 次 `relay started`；`ps etimes` 佐证） |
| 每次重启都连带重启 LiveKit | ✅ 已核实（livekit `starting LiveKit server` 时间戳一一对应） |
| 中继**为什么**会死 | ❌ **未查明**。`dmesg`/`journal` 无 OOM 或 kill 记录；`udp_align.log` 里没有 `relay stopped`（正常退出会打这行）⇒ 属**非正常终止**，原因待查 |
| `udp_align.log` 里 11 条 `Address already in use` | ⚠️ 这些是**启动失败**的 traceback（cron 在旧进程仍持有 7882 时又拉起了一个），**不是**中继死因；它们说明 `run_align.sh` 的 `pgrep` 去重存在时间窗漏洞 |
| 现状是否仍在循环 | ⚠️ 21:49:26 起的那个中继到 **22:00:27** 已存活 **11 min**（`ps -o etimes` = 659 s，超过 6–7 min 周期），**当前未再复现**；journal 也无 21:49 之后的新条目 ⇒ 是**间歇性**而非稳定周期，**根因未消除** |

**建议的收敛方向**（未实施，供后续任务）：

1. 中继改成 **systemd 服务**（`Restart=always` + `RestartSec`），而不是 cron 每分钟盲拉起 ——
   这样重启事件有 unit 日志、有退出码、可 `systemctl status` 查死因；
2. 把「重启 livekit」从 `run_align.sh` **挪到一个显式动作**（或加 `--ensure` 幂等判断），
   避免任何一次意外拉起都切断通话；
3. 复现时抓 `journalctl -o short-iso` 全量 + `ulimit -n` / fd 计数，确认是否 fd 耗尽
   （`udp_port_align.py` 的 `MAX_SESSIONS=200`、`IDLE_TIMEOUT=300`，长跑累积 fd 可疑）。

> **frpc 双实例**：21:19 CST 曾观察到两个同参数 `frpc -f` 进程（PID 2401464 + 2401488，均持
> `116.153.47.201:8088` ESTAB、写同一份日志）；21:59 CST 复查**已降为 1 个**（PID 2539922）。
> `proxy conflict` 计数 0。收敛判据仍是 `pgrep -cf 'frpc -f' = 1`。

### 10.4 用 harness 复测

```bash
cd Ayla/.workbuddy/evidence/livekit-udp/webrtc/probe
# api-secret 从服务器 ~/Elysia/ayla-deploy/livekit.yaml 的 keys 段取（不入库）
node run.mjs --url wss://s.ayla.trise.top:26211/livekit \
  --api-key ayla-livekit --api-secret <secret> \
  --room "ayla-probe-$(date +%s)" --clients 3 --duration 25000 --out ../out/repro-3

# 长时 + 丢包统计（§1.4 的复现条件）：5 人 300 s，逐区间统计
node run.mjs --url wss://s.ayla.trise.top:26211/livekit \
  --api-key ayla-livekit --api-secret <secret> \
  --room "ayla-probe-$(date +%s)" --clients 5 --duration 300000 --sample-ms 3000 \
  --out ../out/repro-5-long
```

退出码：`0` 全通过 / `2` 有客户端未通过 / `3` STUN 探测失败。

判定与读数纪律（两条都不能省）：

1. **只看 `overall.*` 的四个聚合断言 + `anyIceStuck`**，不要只看单客户端 `pass`
   ——末位退出者的 `remote tracks=0` 会把它判红（见 §7.1 注）；
2. **必须同时看逐区间丢包率**（`intervals` / `totalPkts` / `lost` / `per-interval loss%`），
   因为 ICE 通不代表通话能听（§1.4）——只看 ICE 会得出「全绿」的错误结论。

### 10.5 已知未覆盖项（不要当成已验证）

| 项 | 状态 |
|---|---|
| 真实麦克风 / 真实 `<audio>` 播放（非 fake media） | **未验证**（`RESULTS.md` §6.3 明确本工具用 fake media） |
| 听感质量、jitter buffer、丢包隐藏 | **未验证** |
| 分钟级以上长稳 | 仅覆盖 180 s / 300 s 窗口，更长**未验证** |
| 中继反复重启的根因 | ✅ **已查明是误判**：2026-10-27 那 4 次重启全部来自人工排查时的 `pkill`，不是自发死亡。现已由 cron + flock 单实例守护；**但「relay 重启会连带重启 livekit」的设计耦合仍是风险**（§10.3.1） |
| **隧道丢包治理** | ⚠️ **部分解决**（§1.4）：frpc 单实例把 12.8%–16% 降到 **6.9%–8.4%**；残留部分已定位在樱花隧道内部且有队列成分（随速率上升），但**未做** Opus FEC/`minptime`/jitter buffer 调优，也**未**归因到樱花限额或链路拥塞 |
| 用户报「断几秒自己恢复」的真因 | **已定位**（§1.4）：frpc 双实例每 ~50s 一次 EOF 重连（隧道黑洞数秒）+ 残留 7%–8% 丢包。前者已修，后者未治理；**尚未做端到端真实听感验证** |
| 真实家宽（非本机 Clash TUN 出口）路径 | **未验证**（`RESULTS.md` §6.1-6.2） |
| 20 人以上房 | **未验证**（带宽推算见 `docs/flutter/39` §三） |
| 客户端（web / Flutter）LiveKit 接入 | ✅ **已实现**（2026-10-27）：后端 `apps/voice/{livekit,media_config}.py` + `POST /voice/channels/<id>/media-token/`（79/79 测试）；web `web/src/livekit/livekitRoom.ts` + `client.ts` 工厂分支（tsc 干净、90/90 测试）；Flutter `flutter/lib/audio/{livekit_voice_backend,livekit_room_adapter,voice_media_config}.dart`（`dart analyze lib` 零告警、3079 项测试全通过）。**真实麦克风/听感仍未验证** |

---

## 11. 引用与相关文档

| 文档 | 本文引用了什么 |
|---|---|
| [`docs/flutter/37-语音卡顿-服务端背压审计.md`](../flutter/37-语音卡顿-服务端背压审计.md) | §5.6 frp 隧道观察点（**tcpMux 队头阻塞**、24 Mibit/s 限速、mux RTT ~44ms + 重传）；§零③「**不能把服务端日志当丢帧证据**」的方法学 |
| [`docs/flutter/38-语音房条子不跳与断续-根因与修复.md`](../flutter/38-语音房条子不跳与断续-根因与修复.md) | §四 服务端实测**帧到达是双峰的**（75.5% <10ms、15.4% 落 40–50ms）——TCP 链路的典型表现，也是换 UDP 的量化动机；§零① 孤儿 `events` 教训 |
| [`docs/flutter/39-语音持续播放-speaking门控设计缺陷.md`](../flutter/39-语音持续播放-speaking门控设计缺陷.md) | **★ speaking 门控结论**：`speaking` 只是 **UI 事实**，**绝不可**当作媒体门控；`muted` 是唯一硬门控；带宽实测（持续发送每人 ~2.0 KB/s、20 人房 ~6.3 Mbps ≪ 隧道 24 Mibit/s）⇒ 切换后**禁止**用 LiveKit 的 `isSpeaking`/`activeSpeakers` 门控 publish/subscribe |
| [`docs/report/前端全功能点击测试报告.md`](../report/前端全功能点击测试报告.md) | :154-173 历史真机跑通记录 + :161,173 两处「错误归因已更正」（UDP 未映射 + `node_ip` 广播内网 IP，而非 headless 浏览器） |
| [`docs/architecture/voice-session-switching.md`](../architecture/voice-session-switching.md) | 媒体所有权 / generation 取消契约（切换后仍适用） |
| `Ayla/.workbuddy/evidence/livekit-udp/recon/PLAN.md` | 代码侧改造清单与全部 `文件:行` 证据索引 |
| `Ayla/.workbuddy/evidence/livekit-udp/webrtc/RESULTS.md` | 本文 §1.1 / §1.2 / **§1.4 丢包** / §7 的原始实测数据与判定方法学（其 §5 为丢包分析、§4 为三条运维陷阱） |
| `Ayla/.workbuddy/evidence/livekit-udp/udp_port_align.py` / `run_align.sh` | 中继设计说明与三条踩坑注释（本文 §4 的事实来源） |

### 11.1 speaking 门控的落地检查点（继承自 39 号文档）

切到 LiveKit 后，**必须**在 code review 里逐条确认：

1. 新增的 room 实现里 `isSpeaking` / `activeSpeakers` **只能**用于 UI（音量条 / 辉光），
   **不得**出现在「是否 publish / 是否发帧」的条件里；
2. 音量条仍是 `audioLevel > 0.02` 的前端阈值判定（`flutter/lib/widgets/voice/voice_member_row.dart:161`、
   `web/src/components/voice/VoiceMemberRow.tsx:134-135`），不用服务端 speaking 帧替代；
3. 关麦必须是 `unpublish + track.stop()`（真正释放设备、熄灭硬件指示灯），不是只 `mute` ——
   对齐 `wsRelayRoom.ts:802-807` 的隐私语义；
4. 回归手法照抄 39 号 §2.2：把门控加回去，测试必须**立即变红**。

---

## 附录：本文所有可复核的采集命令

| 事实 | 命令 |
|---|---|
| 公网入口 IP | `getent hosts frp-one.com` → `218.65.97.108` |
| 中继监听与上游 | `ss -uln \| grep 7882`；`tail -3 ~/Elysia/ayla-deploy/livekit-udp/udp_align.log` |
| ICE mux 绑定的地址集 | `ss -uln \| grep 27882` |
| 候选里的 IP:PORT | `docker logs ayla-livekit --since 10m 2>&1 \| grep -o 'udp4 host [0-9.]*:[0-9]*' \| sort -u` |
| ufrag 冲突计数 | `docker logs ayla-livekit --since 2h 2>&1 \| grep -c 'dropping candidate'` |
| 容器启动时刻 / 网络模式 | `docker inspect ayla-livekit --format '{{.State.StartedAt}} \| {{.HostConfig.NetworkMode}}'` |
| 镜像版本 | `docker inspect ayla-livekit --format '{{json .Config.Labels}}'` |
| 隧道 proxy 状态 | `grep -E '\[e75\*\*1e6\.(livekit\|Ayla)\]' ~/sakurafrp/frpc-sakura.log \| tail -5` |
| 隧道冲突计数 | `grep -c 'proxy conflict' ~/sakurafrp/frpc-sakura.log` |
| frpc 实例数 | `pgrep -f 'frpc -f <token>' \| wc -l` |
| cron 守护项 | `crontab -l`（`keepalive.sh` 与 `run_align.sh` 各一条 `* * * * *`） |
| 中继重启历史（含 LiveKit 是否被连带重启） | `journalctl -t livekit-udp-align --no-pager -o short-iso` |
| LiveKit 实际重启次数 | `docker logs ayla-livekit --since 8h 2>&1 \| grep -c 'starting LiveKit server'` |
| 中继当前存活时长 | `ps -o pid,etimes -p $(pgrep -f '[u]dp_port_align.py' \| head -1)` |

---

*2026-10-27｜文档任务 task-6｜只写 `Ayla/docs/`，未改任何代码、未执行 git 写操作*
