# 2026-10-01 事故：Windows portproxy 自环导致 Django 全链路 500

> 一次性事故记录。结论已同步到 `Ayla/backend/.env` 的 SRS 段注释。
> 复现环境：Windows 宿主机 + WSL2(NAT) + Docker Desktop，Ayla 后端为宿主手动 `runserver`。

## 1. 现象

后端接口成片 500，异常栈统一为：

```
django.db.utils.OperationalError: (2003, "Can't connect to MySQL server on 'localhost'
([WinError 10048] 通常每个套接字地址(协议/网络地址/端口)只允许使用一次。)")
```

- 触发点看起来随机，实际是**周期性**：每次爆发持续约 120 秒（TIME_WAIT 超时窗口），随后恢复，过几分钟再次爆发。
- 期间**整机**所有新建出站 TCP 连接失败（不只是 Ayla：诊断脚本自身也复现了同一个 10048）。
- MySQL 本身健康（`mysqld` 正常监听 3306），并非数据库故障。

## 2. 根因

Windows 上存在 4 条 **指向自身的 `netsh interface portproxy` 规则**：

```
Listen on ipv4:             Connect to ipv4:
0.0.0.0  1935  ->  127.0.0.1  1935
0.0.0.0  1985  ->  127.0.0.1  1985     <-- 转发目标正是规则自身的监听
0.0.0.0  8080  ->  127.0.0.1  8080
0.0.0.0  8088  ->  127.0.0.1  8088
```

规则监听 `0.0.0.0:1985`，转发目标又写 `127.0.0.1:1985` —— 连接被规则自己再次接住，
形成**无限递归**。单次访问即制造约 14000 个 TCP 连接。

Windows 动态端口范围 `49152-65535` 共 16384 个，扣掉 Hyper-V/WSL/Docker 的
`excludedportrange` 保留段（实测约 2365 个）后**仅约 14000 个可用**，被一次自环风暴
精确打满。端口池满后，任何新建出站连接（含 Django→MySQL）都拿不到本地端口 → 10048。

### 规则来源

- 防火墙规则名 `Docker-SRS-PoC`（1935/1985/8080/8088/8089/8443）与 portproxy 端口完全一致。
- 时间对应 **2026-09-17 的 Flutter PoC 交付**（提交 `93cc2e9`，含 nginx 拉流入口）。
  当天为让 Android 模拟器/手机跨设备拉流，先加了防火墙入站放行 + portproxy 转发，
  随后又因 mirrored 模式下 Docker 端口映射失效，把 `.wslconfig` 从 `mirrored` 切回 `default(NAT)`。
- **切回 NAT 后 Docker 已能自行监听 `0.0.0.0`，这些 portproxy 规则从"补丁"变成了"自环"，但没有被清理。**

## 3. 关键证据

| 观察 | 数值 |
|---|---|
| TIME_WAIT 指向 `127.0.0.1:1985` | 峰值 13952 / 13975 / 13980（≈ 可用端口总数） |
| 本地端口形态 | 从 49152 起连续分配，典型批量特征 |
| 动态端口范围 / 保留段 | 16384 / 约 2365 → 可用约 14000 |
| 捕获到的连接方 PID | `6456`(Ayla 后端 python)、`6076`(iphlpsvc，即 portproxy 承载者) |
| 受影响的端口 | 仅 1935/1985/8080/8088（有 portproxy 规则）；6379/9000/9001 完好 |

### 路径对照实验（同一时刻实测）

| 路径 | 结果 | TIME_WAIT 增量 |
|---|---|---|
| Windows `127.0.0.1:1985` | 失败 / 连接被重置 | **+14000** |
| Windows `[::1]:1985`（IPv6 回环，wslrelay 处理） | 200 | +2 |
| Windows `<WSL_IP>:1985` | 200 | +1 |
| Windows 新发布端口 `18099`（无 portproxy 规则） | 200 | +1 |
| WSL 内 `127.0.0.1:1985` | 200 | 0 |

## 4. 诊断过程中被推翻的错误结论

**曾判定为「WSL mirrored→NAT 切换后 iphlpsvc 抢占 IPv4 监听导致回环」。此结论是错的。**

- `iphlpsvc` 只是**承载 portproxy 规则**的服务（规则由它执行），不是自行抢占；
- 依据是 `netsh interface portproxy show all` 直接打印出了指向自身的规则；
- 也据此解释了"为什么只有 4 个端口坏、redis/minio 好"——差异是**有无 portproxy 规则**，不是 iphlpsvc 的随机竞争；
- `wsl --shutdown` 重启后 iphlpsvc 仍持有同样的 4 个端口，正是因为规则仍在，而非竞争巧合。

## 5. 已执行的操作

| # | 操作 | 权限 | 可逆性 |
|---|---|---|---|
| 1 | `netsh interface portproxy delete v4tov4` 删除 1935/1985/8080/8088 四条自环规则 | 管理员（UAC 提权） | 可逆：重新 add 即回退（但**不应**回退） |
| 2 | `wsl --shutdown` 重启 WSL（重建端口转发） | 普通 | 可逆（WSL 自动重启） |
| 3 | `docker restart` **全部 4 个**发布端口的容器（`ayla-nginx`/`elysia-srs`/`elysia-redis`/`elysia-minio`）——重建 Docker 端口转发代理 | 普通 | 可逆 |
| 4 | `Ayla/backend/.env`：`SRS_PLAY_URL`/`SRS_RTMP_URL` 的局域网 IP 修正为 `192.168.1.4`；`SRS_API_URL` 事故期间临时用 `http://[::1]:1985`，**根因消除后已改回标准 `http://127.0.0.1:1985`** | 文件 | 可逆 |
| 5 | 触发后端 autoreload（touch `apps/live/srs.py` 的 mtime，**未改内容**）使新配置生效 | 普通 | 可逆 |
| 6 | `Ayla/backend/.env`：清理 LiveKit 退役死配置 4 项（`LIVEKIT_API_KEY`/`SECRET`/`WS_URL`/`TOKEN_TTL_SECONDS`，含失效旧 IP `192.168.1.2`）；经 grep 确认 `backend/**.py` 已无 `LIVEKIT` 引用 | 文件 | 可逆（可从 Git 历史恢复） |

> 注：第 2、3 步为顺序依赖——单独 `wsl --shutdown` 后 Docker 端口转发代理不会自动恢复，
> **必须再 restart 容器**才能重新建立转发；且必须覆盖**全部发布端口的容器**，不能只重启用到的那个。
> 实测：先只重启 nginx/srs 时，Redis `PING` 无响应、MinIO 9000/9001 返回 `Empty reply`，
> 补齐 restart 后恢复为 `+PONG` / `403` / `200`。

## 6. 验证方法与结果

```powershell
# 1) 端口路径全部恢复
curl.exe -sS http://[::1]:1985/api/v1/versions      # 200
curl.exe -sS http://127.0.0.1:1985/api/v1/versions  # 200（回环消失）
curl.exe -sS http://192.168.1.4:8080/               # 200（局域网路径恢复）
curl.exe -k -sS https://192.168.1.4:8088/live/      # 404（nginx 正常拒绝目录索引）

# 2) 端到端：走真实后端链路查一次直播状态（SRS_API_URL 改回 127.0.0.1 后复测）
/tmp> POST /api/v1/auth/login/ -> GET /api/v1/live/channels/143/status/
# 返回 {"status":"idle","source":"srs","detail":null} ，耗时 0.44s（修复前为 degraded / 2s 超时）
# TIME_WAIT(:1985) 0 -> 1（仅 +1）；全机 TIME_WAIT 总量 214（风暴期为 16000+）
# 实测连接形态 TCP 127.0.0.1:62817 -> 127.0.0.1:1985 TIME_WAIT，确认走 IPv4（而非事故期间的应急 [::1]）

# 2b) 其余容器端口（WSL 重启后须一并 restart 容器才恢复）
# redis  PING      -> +PONG
# minio  9000/9001 -> 403 / 200

# 3) 规则确认
netsh interface portproxy show all   # 自环规则已消失
```

同时用 web 端打开同一直播间复核，不再触发后端 500。

## 7. 待决 / 注意事项

1. **不要再添加 `0.0.0.0:X -> 127.0.0.1:X` 形式的 portproxy 规则**（转发目标等于自身监听 = 自环）。
   跨设备访问 Docker 端口，NAT 模式下 Docker 已直接监听 `0.0.0.0`，无需 portproxy。
2. `Ayla/backend/.env` 的 `SRS_API_URL` 已用回标准 `http://127.0.0.1:1985`（自环规则删除后实测 200 / 0.12s）。
   若该故障模式再次出现（有人重新添加自环 portproxy），应急可临时改 `http://[::1]:1985`——
   IPv6 回环走 wslrelay，不经过 portproxy，实测同样可用。
3. **重启 WSL 后必须 restart 全部发布端口的容器**（`ayla-nginx`/`elysia-srs`/`elysia-redis`/`elysia-minio`），
   否则 Docker 的端口转发代理不会自动重建；只重启用到的那个会留死角（本次实测 Redis `PING` 无响应、
   MinIO 9000/9001 `Empty reply`，补齐后才恢复）。
4. 另有 3 条**无关**的第三方 portproxy 规则（`54038→54037`、`51570→51569`、`54317→54316`）
   指向的是**不同端口**，不构成自环，本次未改动；如需清理请先确认其来源工具。
5. 宿主机 WLAN 局域网 IP 会变化（本次 `192.168.1.8 → 192.168.1.4`），
   `SRS_PLAY_URL`/`SRS_RTMP_URL` 需随之更新，否则手机/模拟器拉流与 OBS 推流地址会失效。
6. `Ayla/backend/.env` 与本文档均未提交；是否提交由仓库 owner 决定。
7. **局域网 IP 变更后必须重签 TLS 证书**，否则直播黑屏（2026-10-01 实测）：
   `Ayla/certs/cert.pem` 由 mkcert 签发，SAN 必须包含当前局域网 IP。本次黑屏即因 SAN 仍是旧 IP
   （`192.168.1.8`/`192.168.1.2`/`192.168.110.29`），浏览器校验报 `SEC_E_WRONG_PRINCIPAL` 拒绝加载 HLS。
   重签命令（**CAROOT 不变**即可保留浏览器已建立的信任关系）：

   ```powershell
   mkcert -cert-file certs/cert.pem -key-file certs/key.pem localhost 127.0.0.1 "::1" <当前局域网IP> 192.168.1.8 192.168.1.2 192.168.110.29
   docker restart ayla-nginx
   ```

   旧证书备份在 `certs/cert.pem.bak-20261001` / `certs/key.pem.bak-20261001`。
   根治建议：给宿主机做 DHCP 保留固定 IP，或改用稳定域名 + 泛域名证书，避免每隔一段时间重签。
