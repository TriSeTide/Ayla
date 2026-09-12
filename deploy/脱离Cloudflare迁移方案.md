# 脱离 Cloudflare 迁移方案

> **定位**：这是一份**预案**，不是现在就执行的操作。触发条件是——
> 汐汐拿到「可对外提供服务、且能绑定 80/443 的公网」。
> 到那天，把这份文档交给执行者，照着第 5 节的顺序做即可。
>
> 相关事实与踩坑依据见 [README.md](./README.md) §3 / §7 / §8。
> 当前状态由 `~/Elysia/ayla-deploy/`（线上）与 [examples/](./examples/)（模板）共同描述。

---

## 0. CF 现在到底承担了什么，以及为什么现在脱不掉

### 0.1 CF 承担的 4 件事

| # | 职责 | 现网证据 | 摆脱它需要什么 |
| --- | --- | --- | --- |
| 1 | **权威 DNS**（`trise.top` 全部解析） | NS = `elaine/benedict.ns.cloudflare.com`（注册局实测，TTL 21600） | 把 NS 改回阿里云云解析（注册商就在阿里云，可自行改） |
| 2 | **免端口网页入口** `https://ayla.trise.top` | `CNAME ayla.trise.top → <uuid>.cfargotunnel.com`（橙云）→ cloudflared → 本机 `127.0.0.1:8080` | 一个**能绑 443 的公网 IP** |
| 3 | **边缘 TLS 证书**（`ayla.trise.top`） | CF Universal SSL，自动 | 不需要替代——入口改用自己 nginx 终结即可 |
| 4 | **DNS-01 续签通道** | acme.sh `Le_Webroot='dns_cf'` + CF API Token | NS 迁走后换 `dns_ali` |

### 0.2 为什么"现在脱不掉"

- **Jetson 在 NAT 后**，没有公网 IP，80/443 无从谈起。
- **两台 frps 都不提供 80/443**：
  - 朋友那台 `47.108.85.223` 是**中国大陆阿里云 ECS** —— 未备案域名用 80/443 对外服务会被拦截，这正是整套方案一直在用非标端口（1935/7881/7882/26211）的根本原因；
  - 樱花 `frp-one.com` 是共享节点，不给 80/443。
- ⇒ 免端口只能靠一个**境外边缘代理**实现；而 CF Tunnel 的 hostname 路由**要求域名托管在 CF 账户内** ⇒ **NS 必须留在 CF**。

> 换句话说：「免端口入口」和「NS 离开 CF」在现阶段互斥。这两件事都想要，就必须先有公网。

### 0.3 一条被实测封死的"捷径"（别再试）

「保留 NS 在 CF，只把 `_acme-challenge` 子域委派给阿里云」——**CF 免费版做不到**：

```
CF 控制台里能建 NS 记录（Type 下拉有 NS，保存成功），但权威层不吐：
  查 172.64.35.205 / 173.245.59.1 / 108.162.192.1（三台 CF 任播一致）
    _delegtest.trise.top/NS  → ENODATA
    delegtest.trise.top/NS   → ENODATA     （换掉下划线也一样，排除干扰项）
    trise.top/SOA            → benedict.ns.cloudflare.com   （确认查的就是 CF 权威）
```

**结论**：只要 NS 还在 CF，DNS-01 就必须通过 CF 完成（CF API Token 或人工贴 TXT）。
想用阿里云 API 续签，只有两条路：**买一个新域名做挑战别名**，或者**把 NS 迁回阿里云**（本方案）。

---

## 1. 三个阶段

| 阶段 | 前提 | 免端口入口 | 权威 DNS | 续签通道 | 还在为 CF 付什么代价 |
| --- | --- | --- | --- | --- | --- |
| **0 · 现在** | 无公网 | CF Tunnel | Cloudflare | `dns_cf` | 网页绕行 CF 边缘（实测走洛杉矶，慢） |
| **1 · 有公网 443** | 有公网 IP 且 80/443 可用<br>（境外/中国港澳台机房，或大陆已备案） | **直连自己 IP** | Cloudflare（可保留） | `dns_cf` | **只剩 DNS 托管**，不再承载流量 |
| **2 · 彻底脱离** | 阶段 1 + 愿意迁 NS | 直连自己 IP | 阿里云云解析 | `dns_ali` | 无 |

> **阶段 1 就能解决"CF 很卡"**——因为 CF 不再代理任何流量。阶段 2 才谈得上"完全不用 CF"。
> 如果公共入口能一步到位（备案已下 / 机房在境外），也可以直接跳阶段 2。

---

## 2. 阶段 1：网页入口改直连（CF 只留 DNS）

假设新公网地址为 `<PUBLIC_IP>`（本机可绑 443，或经自己的 frps 映射到 443）。

### 2.1 证书 SAN 先补齐

新入口要用同一个域名，所以 SAN 不用改——现证书已经覆盖：

```
$ openssl x509 -in ~/Elysia/ayla-deploy/nginx/certs/trise-cert.pem -noout -ext subjectAltName
    DNS:*.trise.top, DNS:s.ayla.trise.top, DNS:trise.top
```

如果你的新入口用了**第三个名字**（如 `new.trise.top`），必须先把它加进 SAN 再切 DNS。
加 SAN 的做法：`~/.acme.sh/trise.top_ecc/trise.top.conf` 里的 `Le_Alt` 追加
`,new.trise.top`，然后 `acme.sh --renew -d trise.top --ecc --force`。

### 2.2 DNS 记录改向（在 Cloudflare 面板）

| 记录 | 现在 | 改成 |
| --- | --- | --- |
| `ayla`（CNAME → cfargotunnel） | 橙云 Proxied | **删掉**，新建 `A ayla → <PUBLIC_IP>`，**灰云 DNS only** |
| `live`（A → 47.108.85.223） | 灰云 | 视新入口而定；若语音/拉流也搬到新 IP，改指向 |
| `s.ayla`（A → 117.162.35.233） | 灰云 | 保留作备用入口，或删 |

**三个硬约束（踩过）**：
- 非标端口必须**灰云**（CF 代理只支持 443/2053/2083/2087/2096/8443）；
- 要免端口就必须**灰云 + 自己的 443**；
- 只要还有任何一条记录是**橙云**，那条就仍然走 CF。

### 2.3 nginx 侧

`ayla.trise.top` 现在回源到 `127.0.0.1:8080`（纯 HTTP，给 cloudflared 用）。
改成直连后必须让它回源到 **443 的 TLS server** 并正确选证书：

- nginx 里 443 的 `server` 用的是 `server_name _` + `certs/trise-cert.pem`，已覆盖
  `ayla.trise.top`，**通常无需改动**；
- 若你希望 `ayla.trise.top` 走独立 server 块（例如想拆开日志/限流），再加 `server_name`。

### 2.4 验证

```bash
# 1. 解析是否已切（直查权威，别信本地缓存）
nslookup -type=a ayla.trise.top 8.8.8.8
nslookup -type=a ayla.trise.top 223.5.5.5

# 2. 证书是否覆盖 + 是否真免端口
curl -sSI --noproxy '*' https://ayla.trise.top/ | head -3
echo | openssl s_client -connect ayla.trise.top:443 -servername ayla.trise.top 2>/dev/null \
  | openssl x509 -noout -subject -dates

# 3. 确认没有再经过 CF（响应头不应有 cf-ray / server: cloudflare）
curl -sSI --noproxy '*' https://ayla.trise.top/ | grep -iE 'cf-ray|server'
```

### 2.5 可选：顺手把非标端口收掉

脱离 CF 之后，**没有"端口是否为 CF 支持端口"的约束了**，可以考虑简化：
把 `wss://live.trise.top:7881`（语音）与 `https://live.trise.top:7882`（拉流）
合并到 443 上用路径区分（nginx 443 块已有 `location /ws/`；`/live/` 目前只在 8443 块里）。

> ⚠️ 当初把 `/live/` 拆到 8443 是**有意的**：让视频胖流量与网页/信令物理隔离。
> 合并能让入口变干净、证书只需要管一个端口，代价是丢失这层隔离。**按需取舍，别默认合并。**

---

## 3. 阶段 2：NS 迁回阿里云（彻底脱离 CF）

### 3.1 一次性准备：阿里云 RAM 用户 + AccessKey

DNS-01 需要凭据。**不要用主账号 AccessKey**，建一个最小权限 RAM 用户：

1. 阿里云控制台 → 访问控制 RAM → 用户 → 创建用户（勾选 **OpenAPI 访问**）
2. 只授两条权限：`AliyunDNSFullAccess`（或更细的 `AliyunDNSReadOnlyAccess` +
   自定义只写 `trise.top` 的策略）
3. 拿到 `AccessKey ID` / `AccessKey Secret`

### 3.2 acme.sh 切到 `dns_ali`

服务器上（**`dns_ali.sh` 已经装好了**，`~/.acme.sh/dnsapi/dns_ali.sh`）：

```bash
A=~/.acme.sh
cp -a $A/account.conf $A/account.conf.bak-$(date +%Y%m%d-%H%M%S)

# 写入凭据（acme.sh 会自动以 SAVED_ 前缀持久化）
printf "\nSAVED_Ali_Key='<AccessKey ID>'\n"     >> $A/account.conf
printf "SAVED_Ali_Secret='<AccessKey Secret>'\n" >> $A/account.conf
chmod 600 $A/account.conf

# 把 webroot 从 dns_cf 切成 dns_ali
CONF=$A/trise.top_ecc/trise.top.conf
cp -a $CONF $CONF.bak-$(date +%Y%m%d-%H%M%S)
sed -i "s|^Le_Webroot=.*|Le_Webroot='dns_ali'|" $CONF

# 强制续签一次验证（会真的写 TXT → LE 验证 → 装证书 → reload nginx）
$A/acme.sh --renew -d trise.top --ecc --force
```

**关键差异**：NS 回到阿里云后，`trise.top` 就是自己可控的权威区
⇒ **不需要 `--challenge-alias`，不需要任何 CNAME，也不需要 `CF_Zone_ID`**。
比 `dns_cf` 更干净。

> 若 `dns_ali.sh` 因故丢失（acme.sh 是精简装的，原本连 `dnsapi/` 目录都没有）：
> ```bash
> mkdir -p ~/.acme.sh/dnsapi
> curl -fsSL -o ~/.acme.sh/dnsapi/dns_ali.sh \
>   https://raw.githubusercontent.com/acmesh-official/acme.sh/master/dnsapi/dns_ali.sh
> chmod +x ~/.acme.sh/dnsapi/dns_ali.sh
> ```

### 3.3 在阿里云云解析建全记录（**必须在改 NS 之前完成**）

`trise.top` 在阿里云云解析里已经有一个**僵尸托管区**（控制台能看到，但因为权威在 CF，
在那加记录不生效）。阶段 2 就是把它"激活"。

逐条对照（以现网为准，迁移前请重新 `CF` 面板核对一遍）：

| 名字 | 类型 | 值 | 代理/备注 |
| --- | --- | --- | --- |
| `ayla` | A | `<PUBLIC_IP>` | 阶段 1 后应已是这样 |
| `live` | A | `<语音/拉流入口 IP>` | 或指向新的 frps |
| `s.ayla` | A | `<备用入口 IP>` | 可选，不需要就删 |
| `_acme-challenge` | TXT | （签名时临时写） | **不用预建**，`dns_ali` 会自己加/删 |

> CF 里那两条你看不见的 `_acme-challenge.trise.top` TXT 是 **CF 自己给边缘证书做 DCV** 用的隐藏记录。
> NS 迁走后它们自然消失，无需处理。

### 3.4 改 NS（在阿里云域名控制台，不是云解析）

注册商是阿里云（万网），NS 就在**域名控制台**改：

- 现在：`elaine.ns.cloudflare.com` / `benedict.ns.cloudflare.com`
- 改成：控制台在云解析里给该 zone 分配的 NS（通常形如 `ns1.alidns.com` / `ns2.alidns.com`，
  **以控制台显示为准**）

**顺序很重要**，见下一节。

---

## 4. 切换顺序（防中断版）

```
[提前 1 天] ① 阿里云云解析里把记录全部建好（值 = 现网值），但先别改 NS
[提前 1 天] ② CF 里把所有记录的 TTL 降到 60（等旧 TTL 过期，减少切换空窗）
[切换当天] ③ 阶段 1 已完成后，网页入口此时已直连，对 CF 的依赖只剩 DNS
[切换当天] ④ 阿里云域名控制台改 NS → alidns
[切换当天] ⑤ 等：原 NS 的 TTL 是 21600（6h），最长 6 小时后全球生效
[生效后]   ⑥ 三处交叉验证（见第 5 节）
[全绿后]   ⑦ acme.sh 切 dns_ali 并强制续签验证
[全绿后]   ⑧ 观察 24h，再清理 CF 侧
```

**为什么先做阶段 1 再迁 NS**：阶段 1 把流量从 CF 摘走，迁 NS 时就只剩"解析"这一件事，
出问题时影响面小得多。反过来（先迁 NS）会让免端口入口和解析同时处于不确定状态。

---

## 5. 验收清单

```bash
# ① 权威是否已换（注册局层，最可信）
nslookup -type=ns trise.top 8.8.8.8
nslookup -type=ns trise.top 223.5.5.5
# 期望：ns1.alidns.com / ns2.alidns.com（不再是 cloudflare）

# ② 关键记录解析
for n in trise.top ayla.trise.top live.trise.top s.ayla.trise.top; do
  echo "--- $n"; nslookup -type=a $n 223.5.5.5
done

# ③ 三个入口端到端
curl -sSI --noproxy '*' https://ayla.trise.top/            | head -2   # 网页（免端口）
curl -sSI --noproxy '*' https://live.trise.top:7882/live/x.m3u8 | head -2  # 拉流
echo | openssl s_client -connect live.trise.top:7881 -servername live.trise.top 2>/dev/null \
  | openssl x509 -noout -dates                                          # 语音 WS 的证书

# ④ 证书续签链路（最容易漏）
grep -E "^Le_Webroot=|^Le_NextRenewTimeStr=" ~/.acme.sh/trise.top_ecc/trise.top.conf
~/.acme.sh/acme.sh --cron --home ~/.acme.sh 2>&1 | tail -8
# 期望：不再出现 dns_cf 相关报错；trise.top 显示下一次续签时间
```

**重点项**：`ayla.trise.top` 这条**免端口入口是整个方案里唯一"没有非标端口兜底"的路径**，
它一旦挂就没有备用入口（原来靠 CF Tunnel 兜底，迁走后兜底消失）。
所以如果 `s.ayla.trise.top:26211` 还在，**保留它作为备用入口**是值得的。

---

## 6. 回滚

NS 迁移的回滚代价很低，因为**阿里云的记录和 CF 的记录可以同时存在**：

1. 回到阿里云域名控制台，把 NS 改回 `elaine.ns.cloudflare.com` / `benedict.ns.cloudflare.com`
2. 等 6 小时（CF 那侧的记录**先别删**，保留至少 7 天）
3. 确认 `nslookup -type=ns trise.top 8.8.8.8` 回到 CF

> **因此第 8 步的"清理 CF"至少要在全绿 7 天后再做。**

---

## 7. 收尾清理（全绿 7 天后）

| 对象 | 操作 | 位置 |
| --- | --- | --- |
| CF DNS 记录 | 全部删除 | CF 控制台 → trise.top → DNS |
| CF Tunnel | 删除 tunnel + cloudflared 服务 | CF Zero Trust → Networks → Tunnels；服务器上停用 `cloudflared` |
| CF API Token | **吊销**（`acme-dns-renew` / `Edit zone DNS`） | CF → My Profile → API Tokens |
| 服务器 cloudflared | `systemctl disable --now cloudflared`（若装了） | Jetson |
| nginx 8080 块 | 删掉（原来只服务 CF Tunnel 回源） | `~/Elysia/ayla-deploy/nginx/nginx.conf` |
| nginx 443 块 | 视情况合并 `location /ws/`、`location /live/` | 同上 |
| acme.sh 残留 | `acme.sh --remove -d ayla.trise.top --ecc`（已摘；目录可删） | `~/.acme.sh/` |
| 本方案文档 | 把"阶段 2 已完成"写回 [README.md](./README.md) §3/§7 | 本仓库 |

> 别忘了：**改完线上配置必须回灌 [examples/](./examples/)**，否则 `deploy/` 就失去留痕意义。

---

## 8. 沿途踩过的坑（迁移时还会遇到）

1. **CF 免费版不服务子域 NS 委派** —— 见 §0.3，实测数据在里面。
2. **CF 面板的 API 只能读不能写** —— 在页面上下文里 `fetch('/api/v4/...', {method:'POST'|'DELETE'})`
   会返回 **403 + Cloudflare 拦截页**（WAF/CSRF）；`GET` 正常。
   所以改 CF 记录**只能走 UI 点击**，不能靠脚本。
3. **别信本地解析缓存** —— 本机 `192.168.1.1` / `223.5.5.5` 会对刚创建的名字返回
   陈旧 NXDOMAIN。判断"记录有没有生效"要去查权威 NS。
4. **沙箱 `https_proxy` 污染 curl** —— 一律加 `--noproxy '*'`，否则 NXDOMAIN 会被代理
   变成 `502 Bad Gateway`，极易误判成服务故障。
5. **证书 reload 的优雅切换** —— `nginx -s reload` 之后立刻 `openssl s_client` 可能
   仍读到**旧证书**（旧 worker 还在服务在途连接）。等 1-2 秒重试，或比对
   `md5sum` 宿主机文件 vs `docker exec ayla-nginx md5sum /etc/nginx/certs/...`。
6. **文件级 bind-mount 的 inode 陷阱** —— 证书与 nginx.conf 都是文件级挂载，
   替换必须**原地覆盖**（`cat > file`），不能 `mv`+新建。acme.sh 的 `--install-cert`
   天然用重定向写，安全。
7. **大陆机房的 80/443 与备案** —— 未备案域名在大陆 ECS 上用 80/443 对外服务会被拦。
   要么备案，要么把入口放在境外/中国港澳台机房。这是阶段 1 能否成立的前提。

---

## 9. 一页速查

```
现在（阶段 0）：NS=CF ｜ 免端口=CF Tunnel ｜ 续签=dns_cf+CF Token
                └ 到期 2026-12-11，cron `17 3 * * *` 自动续签，已实测通过

有公网 443 后（阶段 1）：把 ayla 从 CNAME(cfargotunnel,橙云)
                        改成 A <PUBLIC_IP>(灰云) → CF 不再代理流量
                        （续签仍 dns_cf，因为 NS 还在 CF）

愿意迁 NS 后（阶段 2）：阿里云建全记录 → TTL 降到 60 → 改 NS 为 alidns
                        → 6h 后验证 → acme.sh 换 dns_ali → 观察 7 天 → 清 CF
```
