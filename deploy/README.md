# Ayla 服务器部署 · 配置说明

> 本文描述 **实际生产环境**（Jetson `ayerelysia`，frp 半容器化）的配置全貌。
> 示例配置见 [`examples/`](./examples/)；从零部署流程见 [部署运行手册](./部署运行手册.md)。
> **将来拿到公网后脱离 Cloudflare 的预案**见 [脱离Cloudflare迁移方案](./脱离Cloudflare迁移方案.md)。
> 设计期方案（历史归档）见 `docs/服务器半容器化部署方案.md`。

---

## 1. 部署形态总览

```
                        公网
   ┌──────────────────────┼───────────────────────────┐
   │                      │                           │
[Sakura frps]        [Cloudflare]               [朋友 frps]
 frp-one.com          trise.top(NS 在 CF)        frp.volx.top
   :26211                  │                          │
   │  TCP 隧道              │ CF Tunnel                │ TCP 隧道 ×4
   │  （按端口路由，          │ （橙云，回源 8080）         │
   │    任意 SNI 都通）       │                          │
   └──────────┬─────────────┴──────────┬───────────────┘
              │                        │
        ┌─────▼────────────────────────▼──────────────────────────┐
        │              Jetson ayerelysia（host 网络）              │
        │  nginx 127.0.0.1:443   网页 + /api/ /ws/ /minio/         │
        │  nginx 127.0.0.1:8443  仅 /live/*.m3u8|flv|ts（拉流隔离） │
        │  nginx 127.0.0.1:8080  纯 HTTP（CF Tunnel 回源）          │
        │  daphne 127.0.0.1:8100 backend（Django ASGI）            │
        │  mysql 3306 · redis 6379 · minio 9000/9001              │
        │  srs 1935(RTMP) / 8089(HTTPS-FLV/HLS) / 1985(API)       │
        │  Elysium（宿主进程）127.0.0.1:18000 —— backend 桥接      │
        └─────────────────────────────────────────────────────────┘
```

要点：

- **两套穿透并存且职责不同**：樱花 frp 负责「网页直连入口」（26211，国内快、无 CF 绕行）；
  朋友 frp 负责「大流量与低延迟」（推流 / 拉流 / 语音 WS）。
- **CF Tunnel 是网页入口的兜底/免端口通道**（仅 443），依赖橙云；樱花是主直连通道。
- **LiveKit 已于 2026-09-12 整体退役**：语音改走 ws 音频中继（Opus over WebSocket over
  TCP）。原因是 frp 穿透会改写 UDP 源地址，WebRTC/TURN 媒体面不可用。

---

## 2. 仓库 ↔ 线上 路径映射

| 仓库（`Ayla/`） | 线上路径 | 说明 |
| --- | --- | --- |
| `backend/` | `~/Elysia/Elysium/Ayla/backend`（镜像 build context） | 服务器只放 git 仓库，用于构建镜像 |
| `web/`（源码） | — | 服务器**不构建**前端（工具链不全），本地构建后推送 dist |
| `deploy/examples/nginx.conf.example` | `~/Elysia/ayla-deploy/nginx/nginx.conf` | 文件级 bind-mount，改后原地覆盖 |
| `deploy/examples/docker-compose.yml.example` | `~/Elysia/ayla-deploy/docker-compose.yml` | — |
| `deploy/examples/srs.conf.example` | `~/Elysia/ayla-deploy/srs.conf` | — |
| `deploy/examples/frpc.toml.example` | `~/frp/frpc.toml` | **含 token，不入库** |
| `deploy/examples/keepalive.sh.example` | `~/frp/keepalive.sh` | cron 每分钟守护 |
| — | `~/Elysia/ayla-deploy/web/dist` | 前端构建产物（nginx 静态根） |
| — | `~/Elysia/ayla-deploy/.env` | compose 变量（**不入库**） |
| — | `~/Elysia/ayla-deploy/backend/.env` | 后端环境变量（**不入库**） |

> 注意：**线上 `ayla-deploy/` 不是 git 仓库**，是手工维护的部署目录；配置改动需
> 同步回 `deploy/examples/` 才算留痕。

---

## 3. 公网入口矩阵

| 入口 | 域名 / 地址 | DNS | 证书 | 用途 |
| --- | --- | --- | --- | --- |
| 网页（主直连） | `frp-one.com:26211` | 樱花节点 | trise 证书（SAN `ayla.trise.top`） | 低延迟直连，任意 SNI 可达 |
| 网页（别名） | `s.ayla.trise.top:26211` | **Cloudflare**（A → 樱花节点 IP，灰云） | trise 证书（SAN 已含 `s.ayla.trise.top`） | 同上，域名更友好 |
| 网页（CF Tunnel） | `ayla.trise.top`（443） | Cloudflare 橙云 → Tunnel → 8080 | CF 边缘 | 免端口/兜底，跨境绕行较慢 |
| 拉流 | `live.trise.top:7882`（HLS/FLV） | 灰云 A | trise 证书（SAN `live.trise.top`） | 观众侧播放 |
| 语音 WS | `live.trise.top:7881` | 灰云 A | 同上 | `wss://…:7881/ws/voice/audio/?channel=<id>` |
| 推流 | `live.trise.top:1935` | 灰云 A | 无（RTMP 明文） | OBS `rtmp://live.trise.top:1935/live/{key}` |

**DNS 关键约束（踩过坑）**

- `trise.top` 的 NS 已托管 **Cloudflare**（`elaine/benedict.ns.cloudflare.com`）。
  **在阿里云控制台加 trise.top 的解析不生效**——权威服务器是 CF，必须去 CF 加。
- CF 橙云只支持固定端口（443/2053/2083/2087/2096/8443）；非标端口（26211/7881/7882/1935）
  必须**灰云（DNS only）**。
- CF Tunnel 必须橙云。

---

## 4. 隧道矩阵

### 4.1 朋友 frps（`frp.volx.top:2101`，配置 `~/frp/frpc.toml`）

| name | remote | local | 用途 |
| --- | --- | --- | --- |
| `ssh` | 6020 | 22 | 运维直连 |
| `ayla-srs-rtmp` | 1935 | 1935 | OBS 推流 |
| `ayla-live-pull` | 7882 | 8443 | 拉流（nginx 独立入口） |
| `ayla-voice-ws` | 7881 | 443 | 语音 WS（nginx TLS 终结） |

> 历史：`3443` 被阿里云安全组 drop（SYN 超时），拉流改 `7882`；LiveKit 的
> `7882/tcp`、`7881/udp` 隧道已删除，端口让位。

### 4.2 樱花 frps（`frp-one.com`，`frpc -f <token>`，配置 `~/sakurafrp/`）

| remote | local | 用途 |
| --- | --- | --- |
| 26211（TCP） | 443 | 网页直连入口 |

> 实测：樱花节点对该隧道**按端口路由，不校验 SNI**——`curl --resolve any.domain:26211:<樱花IP>`
> 均返回 200。因此 `s.ayla.trise.top` 只需 DNS 指到樱花 IP + 证书 SAN 覆盖即可。

---

## 5. 本机端口占用

| 端口 | 进程 / 容器 | 绑定 | 暴露方式 |
| --- | --- | --- | --- |
| 80 / 443 | nginx | 127.0.0.1 | frpc（443→7881 语音、樱花 26211→443 网页） |
| 8443 | nginx | 127.0.0.1 | frpc（→7882 拉流） |
| 8080 | nginx | 127.0.0.1 | cloudflared 回源 |
| 8100 | daphne / backend | 127.0.0.1 | nginx 反代 |
| 18000 | **Elysium（宿主进程）** | 127.0.0.1 | backend 桥接，**不外网** |
| 1935 / 8089 / 1985 | srs | 127.0.0.1 | 1935→frpc；8089→nginx；1985 内网 |
| 3306 / 6379 / 9000 / 9001 | mysql / redis / minio | 127.0.0.1 | 仅本机 |
| 7400 | frpc 管理面板（朋友） | 127.0.0.1 | 仅本机 |

---

## 6. 环境变量

两套，互不相干：

1. **`~/Elysia/ayla-deploy/.env`** —— 供 `docker compose` 插值（MySQL/Redis/MinIO 密码）。
   模板：[`examples/compose.env.example`](./examples/compose.env.example)
2. **`~/Elysia/ayla-deploy/backend/.env`** —— 供 backend 容器 `env_file` 注入。
   模板：[`examples/backend.env.example`](./examples/backend.env.example)

关键取值（现网）：

```dotenv
# backend/.env 片段
DB_HOST=127.0.0.1            # host 网络：直连 compose 映射端口
ELYSIA_BASE_URL=http://127.0.0.1:18000
S3_ENDPOINT_URL=http://127.0.0.1:9000
SRS_API_URL=http://127.0.0.1:1985
SRS_RTMP_URL=rtmp://live.trise.top:1935/live
SRS_PLAY_URL=https://live.trise.top:7882/live
# LiveKit 变量已废弃（退役），不要再设置
```

> **改动 `.env` 后必须 `docker compose up -d --no-deps backend` 重建**，
> 仅 `restart` 不会重读 env_file。

---

## 7. 证书与自动续签

- 文件：`~/Elysia/ayla-deploy/nginx/certs/trise-{cert,key}.pem`
  （`trise-cert.pem` = fullchain，`trise-key.pem` = EC P-256 私钥）。
- **SAN 覆盖**：`trise.top`、`*.trise.top`、`s.ayla.trise.top`。
  ⚠️ `*.trise.top` **覆盖不了** `s.ayla.trise.top`（两级子域），必须单列。
- 到期：**2026-12-11**（`notAfter Dec 11 15:09:11 2026 GMT`）。
  这张证书同时撑 **语音 7881 / 拉流 7882 / 樱花入口 26211**——覆盖名少的每一个都会
  变成浏览器拦截，所以改 SAN 前务必三处都核对。
- 签发：acme.sh v3.1.5（`~/.acme.sh`）+ Let's Encrypt **DNS-01**，
  证书目录 `~/.acme.sh/trise.top_ecc/`，`Le_Webroot='dns_cf'`。
- 凭据（`~/.acme.sh/account.conf`，权限 600）：
  `SAVED_CF_Token`（CF API Token，**仅 Zone:DNS:Edit、作用域 trise.top**）、
  `SAVED_CF_Zone_ID`。
- **自动续签已启用**：crontab `17 3 * * * … acme.sh --cron …`，日志 `~/.acme.sh/cron.log`。
  下次续签时间见 `trise.top_ecc/trise.top.conf` 的 `Le_NextRenewTimeStr`（约 2026-11-10）。
- 装载：`--install-cert` 的 `--reloadcmd "docker exec ayla-nginx nginx -s reload"`
  （已存入 `trise.top_ecc/trise.top.conf` 的 `Le_ReloadCmd`）。acme.sh 用 `cat > file`
  重定向写目标文件 → **保 inode**，与文件级 bind-mount 兼容。
- 手动/强制验证：
  ```bash
  ~/.acme.sh/acme.sh --renew -d trise.top --ecc --force
  ```
- 脚本模板：[`examples/acme-cert-renew.sh.example`](./examples/acme-cert-renew.sh.example)
- **将来脱离 CF 的完整预案**：[脱离Cloudflare迁移方案.md](./脱离Cloudflare迁移方案.md)

> 为什么不能用阿里云 API 续签（除非买新域名或迁 NS）：
> `trise.top` 的权威 NS 在 CF，写在阿里云的记录不生效；而 **CF 免费版不服务子域 NS 委派**
> （实测 `delegtest.trise.top/NS` → `ENODATA`），所以也无法"只把 `_acme-challenge` 交给阿里云"。
> 详见迁移方案 §0.3。

---

## 8. 已知坑位（务必记住）

1. **文件级 bind-mount 的 inode 陷阱**
   `docker-compose.yml` 里 `./nginx/nginx.conf:/etc/nginx/conf.d/default.conf:ro` 与
   `./web/dist:/usr/share/nginx/html:ro` 都是**文件/目录级挂载**。用 `mv`/`rm+新建`
   替换源文件会产生新 inode，容器仍读旧 inode → “改了没生效”。
   正确做法：**原地覆盖**（`cp new old` / `cat new > old`，只删内容不删目录）。
2. **本地沙箱 `https_proxy` 污染 curl**
   本机跑 `curl` 时务必加 `--noproxy '*'`；否则走本地代理，遇到 NXDOMAIN 会返
   `502 Bad Gateway`，极易误判成“服务挂了”。
3. **DNS 加错权威服务器**
   `trise.top` 的权威在 Cloudflare，别在阿里云加解析。
4. **`.env` 改动不 `up` 不生效**：`restart` 不重读 `env_file`。
5. **两个 frpc 都要活**：只靠 `keepalive.sh`（cron 每分钟）；确认 `crontab -l` 里有它。
6. **SRS 8080 未映射**：compose 只映射 `8089/1985/1935`，SRS 内部 `http_server 8080`
   不对外，播放只走 8089（HTTPS）。
7. **CF 控制台的 API「只能读不能写」**
   在 CF 页面上下文里 `fetch('/api/v4/...', {method:'POST'|'DELETE'})` 会返回
   **403 + Cloudflare 拦截页**（WAF/CSRF），`GET` 正常。
   ⇒ 想改 CF 的 DNS 记录**只能走 UI 点击**，写脚本批量改是行不通的。
8. **别信本地解析缓存**
   刚创建的名字在 `192.168.1.1` / `223.5.5.5` 上可能是**陈旧的 NXDOMAIN**。
   判断"记录生效没有"要去查**权威 NS**，不要靠本机递归解析器。
9. **`nginx -s reload` 之后立刻取证书可能读到旧的**
   graceful reload 期间旧 worker 仍在服务在途连接。等 1~2 秒重试，
   或直接比对指纹：`md5sum certs/trise-cert.pem` vs
   `docker exec ayla-nginx md5sum /etc/nginx/certs/trise-cert.pem`。
10. **acme.sh 是「精简安装」**
    服务器上这份 acme.sh 原本**连 `dnsapi/` 目录都没有**（签发是手工贴 TXT 做的）。
    `dns_cf.sh` / `dns_ali.sh` 都是后来手工 curl 进去的；换机或重装时记得补：
    ```bash
    mkdir -p ~/.acme.sh/dnsapi && cd ~/.acme.sh/dnsapi
    curl -fsSL -O https://raw.githubusercontent.com/acmesh-official/acme.sh/master/dnsapi/dns_cf.sh
    chmod +x dns_cf.sh
    ```

---

## 9. 示例配置索引

| 文件 | 对应线上 |
| --- | --- |
| [`examples/frpc.toml.example`](./examples/frpc.toml.example) | `~/frp/frpc.toml` |
| [`examples/keepalive.sh.example`](./examples/keepalive.sh.example) | `~/frp/keepalive.sh` |
| [`examples/docker-compose.yml.example`](./examples/docker-compose.yml.example) | `~/Elysia/ayla-deploy/docker-compose.yml` |
| [`examples/nginx.conf.example`](./examples/nginx.conf.example) | `~/Elysia/ayla-deploy/nginx/nginx.conf` |
| [`examples/srs.conf.example`](./examples/srs.conf.example) | `~/Elysia/ayla-deploy/srs.conf` |
| [`examples/compose.env.example`](./examples/compose.env.example) | `~/Elysia/ayla-deploy/.env` |
| [`examples/backend.env.example`](./examples/backend.env.example) | `~/Elysia/ayla-deploy/backend/.env` |
| [`examples/acme-cert-renew.sh.example`](./examples/acme-cert-renew.sh.example) | 证书签发/续签脚本 |
