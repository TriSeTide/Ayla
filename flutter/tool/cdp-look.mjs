/**
 * CDP 页面查看器（Windows 侧 Chrome，不需要桥、不干扰用户桌面）。
 *
 * 用法（Windows 侧 node）：
 *   node tool/cdp-look.mjs info                  # 页面标题/URL/是否有 flutter 画面/视口与 DPR
 *   node tool/cdp-look.mjs reload [url]          # 重载预览页（可选先导航到新 URL）并等待 flutter 挂载
 *   node tool/cdp-look.mjs text                  # 读取页面可见文本（含 flutter semantics）
 *   node tool/cdp-look.mjs shot <out.png> [full] # 截图（full=按文档尺寸截全）
 *   node tool/cdp-look.mjs viewport <w> <h> [dsf] # 设置视口尺寸与缩放
 *   node tool/cdp-look.mjs semantics             # 开启 flutter 语义树并 dump 元素
 *   node tool/cdp-look.mjs fields                # 读页面所有文本节点的几何（位置/尺寸）
 *   node tool/cdp-look.mjs eval "<js>"           # 执行任意 JS
 *   node tool/cdp-look.mjs evalfile <path.js>    # 执行 JS 文件（避开 shell 引号地狱）
 *
 * 前置：Chrome 以 --remote-debugging-port=9333 启动（见 preview-up.sh）。
 *
 * 2026-09-18 适配 Chrome 153：**必须先连浏览器级端点再 Target.attachToTarget(flatten)**。
 * 实测 Chrome 153 的 page 级 ws 端点（/devtools/page/<id>）连上后不再回包（握手成功但
 * 所有命令无响应）；浏览器级端点 + attachToTarget(flatten:true) + sessionId 路由可用。
 */
import fs from 'node:fs';
import http from 'node:http';
import crypto from 'node:crypto';

const CDP_HOST = process.env.CDP_HOST ?? '127.0.0.1';
const CDP_PORT = Number(process.env.CDP_PORT ?? 9333);
const [, , cmd, ...args] = process.argv;

function httpGet(path) {
  return new Promise((resolve, reject) => {
    http
      .get({ host: CDP_HOST, port: CDP_PORT, path }, (res) => {
        let body = '';
        res.on('data', (d) => (body += d));
        res.on('end', () => resolve(body));
      })
      .on('error', reject);
  });
}

/** 极简 CDP 客户端（WebSocket over node 的 net/http upgrade），flatten 会话路由 */
class CDP {
  constructor(wsUrl) {
    this.wsUrl = wsUrl;
    this.id = 0;
    this.pending = new Map();
    this.sessionId = null;
    this.buf = Buffer.alloc(0);
  }

  connect() {
    const url = new URL(this.wsUrl);
    return new Promise((resolve, reject) => {
      const req = http.request({
        host: url.hostname,
        port: url.port,
        path: url.pathname,
        headers: {
          Connection: 'Upgrade',
          Upgrade: 'websocket',
          'Sec-WebSocket-Key': crypto.randomBytes(16).toString('base64'),
          'Sec-WebSocket-Version': '13',
        },
      });
      req.on('upgrade', (res, socket) => {
        this.socket = socket;
        socket.on('data', (chunk) => this._onData(chunk));
        resolve();
      });
      req.on('error', reject);
      req.end();
    });
  }

  _onData(chunk) {
    this.buf = Buffer.concat([this.buf, chunk]);
    for (;;) {
      if (this.buf.length < 2) return;
      const opcode = this.buf[0] & 0x0f;
      let len = this.buf[1] & 0x7f;
      let off = 2;
      if (len === 126) {
        if (this.buf.length < 4) return;
        len = this.buf.readUInt16BE(2);
        off = 4;
      } else if (len === 127) {
        if (this.buf.length < 10) return;
        len = Number(this.buf.readBigUInt64BE(2));
        off = 10;
      }
      if (this.buf.length < off + len) return;
      const payload = this.buf.subarray(off, off + len);
      this.buf = this.buf.subarray(off + len);
      if (opcode === 0x1) {
        let msg;
        try {
          msg = JSON.parse(payload.toString('utf8'));
        } catch {
          continue;
        }
        const p = this.pending.get(msg.id);
        if (p) {
          this.pending.delete(msg.id);
          msg.error ? p.reject(new Error(JSON.stringify(msg.error))) : p.resolve(msg.result);
        }
      } else if (opcode === 0x8) {
        this.socket.end();
        return;
      }
    }
  }

  send(method, params = {}, sessionId = this.sessionId) {
    const id = ++this.id;
    const message = { id, method, params };
    if (sessionId) message.sessionId = sessionId;
    const payload = Buffer.from(JSON.stringify(message));
    const mask = crypto.randomBytes(4);
    const masked = Buffer.alloc(payload.length);
    for (let i = 0; i < payload.length; i++) masked[i] = payload[i] ^ mask[i % 4];
    let header;
    if (payload.length < 126) {
      header = Buffer.from([0x81, 0x80 | payload.length]);
    } else if (payload.length < 65536) {
      header = Buffer.alloc(4);
      header[0] = 0x81;
      header[1] = 0x80 | 126;
      header.writeUInt16BE(payload.length, 2);
    } else {
      header = Buffer.alloc(10);
      header[0] = 0x81;
      header[1] = 0x80 | 127;
      header.writeBigUInt64BE(BigInt(payload.length), 2);
    }
    this.socket.write(Buffer.concat([header, mask, masked]));
    return new Promise((resolve, reject) => this.pending.set(id, { resolve, reject }));
  }

  /** 连到浏览器级端点并 attach 到预览页目标（Chrome 153 必需）。 */
  async attachToPage() {
    const ver = JSON.parse(await httpGet('/json/version'));
    await this.connect();
    const targets = await this.send('Target.getTargets', {}, null);
    const page = targets.targetInfos.find(
      (t) => t.type === 'page' && !t.url.startsWith('chrome://') && !t.url.startsWith('devtools://'),
    );
    if (!page) throw new Error('没有可用的页面目标（Chrome 是否已打开预览页？）');
    const att = await this.send('Target.attachToTarget', { targetId: page.targetId, flatten: true }, null);
    this.sessionId = att.sessionId;
    this.pageUrl = page.url;
    return page;
  }

  close() {
    try {
      this.socket?.end();
    } catch {
      /* 忽略关闭期错误 */
    }
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const main = async () => {
  const cdp = new CDP(null);
  // connect 需要 ws url：先取浏览器级端点
  const ver = JSON.parse(await httpGet('/json/version'));
  cdp.wsUrl = ver.webSocketDebuggerUrl;
  const page = await cdp.attachToPage();
  await cdp.send('Page.enable', {}, cdp.sessionId);

  if (cmd === 'info') {
    const r = await cdp.send('Runtime.evaluate', {
      expression: `JSON.stringify({
        title: document.title,
        url: location.href,
        flutterView: !!document.querySelector('flutter-view'),
        canvasCount: document.querySelectorAll('canvas').length,
        bodyTextLen: (document.body.innerText||'').length,
        viewport: { w: innerWidth, h: innerHeight, dpr: devicePixelRatio },
        scroll: { w: document.documentElement.scrollWidth, h: document.documentElement.scrollHeight },
      })`,
      returnByValue: true,
    });
    console.log(r.result.value);
  } else if (cmd === 'reload') {
    const target = args[0];
    if (target) {
      await cdp.send('Page.navigate', { url: target }, cdp.sessionId);
      console.log('navigated to ' + target);
    } else {
      await cdp.send('Page.reload', { ignoreCache: true }, cdp.sessionId);
      console.log('reloaded ' + page.url);
    }
    // 等 flutter 挂载（预览器首帧可能数十秒）
    const timeoutMs = Number(args[1] ?? 90000);
    const started = Date.now();
    for (;;) {
      await sleep(1500);
      let ok = false;
      try {
        const r = await cdp.send('Runtime.evaluate', {
          expression: "!!document.querySelector('flutter-view')",
          returnByValue: true,
        }, cdp.sessionId);
        ok = r.result.value === true;
      } catch {
        ok = false;
      }
      if (ok) {
        // 再多等一拍让首帧绘制稳定
        await sleep(2500);
        console.log('flutter mounted after ' + Math.round((Date.now() - started) / 1000) + 's');
        break;
      }
      if (Date.now() - started > timeoutMs) {
        console.log('flutter NOT mounted within ' + Math.round(timeoutMs / 1000) + 's');
        break;
      }
    }
  } else if (cmd === 'viewport') {
    const w = Number(args[0] ?? 1600);
    const h = Number(args[1] ?? 1200);
    const dsf = args[2] ? Number(args[2]) : undefined;
    await cdp.send('Emulation.setDeviceMetricsOverride', {
      width: w,
      height: h,
      deviceScaleFactor: dsf ?? 1,
      mobile: false,
      ...(dsf !== undefined ? { scale: dsf } : {}),
    }, cdp.sessionId);
    console.log(`viewport set to ${w}x${h}${dsf !== undefined ? ` (dsf=${dsf})` : ''}`);
  } else if (cmd === 'text') {
    const r = await cdp.send('Runtime.evaluate', {
      expression: `(function(){const walk=(n,acc)=>{if(!n||!n.querySelectorAll)return acc;acc.push(n.innerText||'');for(const k of n.querySelectorAll('*')){if(k.shadowRoot)walk(k.shadowRoot,acc);}return acc;};return walk(document,[]).filter(Boolean).join('\\n').slice(0,4000);})()`,
      returnByValue: true,
    }, cdp.sessionId);
    console.log(r.result.value || '(空——flutter canvas 渲染时 DOM 无文本，属正常；用 semantics 命令开语义树)');
  } else if (cmd === 'shot') {
    const out = args[0] ?? 'preview.png';
    const full = args[1] === 'full';
    const params = { format: 'png' };
    if (full) {
      const m = await cdp.send('Page.getLayoutMetrics', {}, cdp.sessionId);
      const css = m.cssContentSize ?? m.contentSize;
      params.clip = { x: 0, y: 0, width: Math.ceil(css.width), height: Math.ceil(css.height), scale: 1 };
      params.captureBeyondViewport = true;
    }
    const r = await cdp.send('Page.captureScreenshot', params, cdp.sessionId);
    fs.writeFileSync(out, Buffer.from(r.data, 'base64'));
    console.log(`saved ${out} (${fs.statSync(out).size} bytes${full ? ', fullpage' : ''})`);
  } else if (cmd === 'semantics') {
    const enable = `
      (function(){
        var ph = document.querySelector('flt-semantics-placeholder');
        if (ph) { ph.click(); }
        var host = document.querySelector('flt-semantics-host');
        var n = 0;
        if (host) {
          n += host.querySelectorAll('flt-semantics').length;
          if (host.shadowRoot) n += host.shadowRoot.querySelectorAll('flt-semantics').length;
        }
        return JSON.stringify({placeholder: !!ph, semNodes: n});
      })()`;
    const e1 = await cdp.send('Runtime.evaluate', { expression: enable, returnByValue: true }, cdp.sessionId);
    console.log('enable:', e1.result.value);
    await sleep(1500);
    const e2 = await cdp.send('Runtime.evaluate', { expression: enable, returnByValue: true }, cdp.sessionId);
    console.log('after:', e2.result.value);
  } else if (cmd === 'fields') {
    const expr = `
      (function(){
        var out = [];
        function push(el, src){
          var t = (el.getAttribute && (el.getAttribute('aria-label') || el.getAttribute('role'))) || el.textContent || '';
          t = String(t).trim();
          if (!t || t.length > 80) return;
          var b = el.getBoundingClientRect();
          if (b.width <= 0 || b.height <= 0) return;
          out.push({ t: t.slice(0, 50), x: Math.round(b.x), y: Math.round(b.y), w: Math.round(b.width), h: Math.round(b.height), src: src });
        }
        function walk(root, src, depth){
          if (!root || depth > 4 || !root.querySelectorAll) return;
          var nodes = root.querySelectorAll('flt-semantics, [role], [aria-label], span, p, div');
          for (var i = 0; i < nodes.length; i++) {
            var el = nodes[i];
            if (el.childElementCount === 0) push(el, src);
          }
          var all = root.querySelectorAll('*');
          for (var j = 0; j < all.length; j++) {
            if (all[j].shadowRoot) walk(all[j].shadowRoot, src + '>shadow', depth + 1);
          }
        }
        walk(document, 'doc', 0);
        var uniq = [], seen = {};
        for (var k = 0; k < out.length; k++) {
          var key = out[k].t + '@' + out[k].x + ',' + out[k].y;
          if (!seen[key]) { seen[key] = 1; uniq.push(out[k]); }
        }
        return JSON.stringify({ count: uniq.length, items: uniq.slice(0, 60) });
      })()`;
    const r = await cdp.send('Runtime.evaluate', { expression: expr, returnByValue: true }, cdp.sessionId);
    console.log(r.result.value);
  } else if (cmd === 'click') {
    // 合成真实鼠标点击（host 的 Flutter canvas 无法用 DOM 事件驱动）
    const x = Number(args[0]);
    const y = Number(args[1]);
    await cdp.send('Input.dispatchMouseEvent', { type: 'mouseMoved', x, y, pointerType: 'mouse' }, cdp.sessionId);
    await cdp.send('Input.dispatchMouseEvent', { type: 'mousePressed', x, y, button: 'left', clickCount: 1, pointerType: 'mouse' }, cdp.sessionId);
    await cdp.send('Input.dispatchMouseEvent', { type: 'mouseReleased', x, y, button: 'left', clickCount: 1, pointerType: 'mouse' }, cdp.sessionId);
    console.log('click ' + x + ',' + y);
  } else if (cmd === 'wheel') {
    // 合成滚轮（flutter canvas 内滚动唯一可行路径）
    const dx = Number(args[0] ?? 0);
    const dy = Number(args[1] ?? 600);
    const cx = Number(args[2] ?? 640);
    const cy = Number(args[3] ?? 500);
    await cdp.send('Input.dispatchMouseEvent', { type: 'mouseWheel', x: cx, y: cy, deltaX: dx, deltaY: dy, pointerType: 'mouse' }, cdp.sessionId);
    console.log('wheel dx=' + dx + ' dy=' + dy + ' at ' + cx + ',' + cy);
  } else if (cmd === 'eval') {
    const r = await cdp.send('Runtime.evaluate', { expression: args.join(' '), returnByValue: true }, cdp.sessionId);
    console.log(JSON.stringify(r.result.value));
  } else if (cmd === 'evalfile') {
    const src = fs.readFileSync(args[0], 'utf8');
    const r = await cdp.send('Runtime.evaluate', { expression: src, returnByValue: true }, cdp.sessionId);
    console.log(typeof r.result.value === 'string' ? r.result.value : JSON.stringify(r.result.value));
  } else {
    console.error('usage: info | reload [url] | text | shot <out.png> [full] | viewport <w> <h> [dsf] | semantics | fields | eval <js> | evalfile <path.js> | click <x> <y> | wheel <dx> <dy> [x y]');
    process.exit(2);
  }
  cdp.close();
  process.exit(0);
};

main().catch((e) => {
  console.error('cdp-look failed:', e.message);
  process.exit(1);
});
