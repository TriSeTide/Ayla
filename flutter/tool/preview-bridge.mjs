/**
 * Widget Preview 预览桥（Windows 侧，纯用户态，无需管理员/UAC）。
 *
 * 为什么需要：`flutter widget-preview start --web-server` 的预览页面里写死了
 * `ws://127.0.0.1:<调试端口>`（模块加载 + 预览列表通道）。浏览器若不在 Windows 上
 * （例如 DSH/Playwright 跑在 WSL 里），连不到 Windows 的 127.0.0.1 → 白屏。
 * 本脚本把 flutter 的 loopback 端口在 0.0.0.0 上再监听一份，WSL 侧用 Windows
 * 局域网 IP 即可访问。
 *
 * 用法：
 *   node tool/preview-bridge.mjs detect          # {"web": 预览页端口, "all":[需桥接端口]}
 *   node tool/preview-bridge.mjs scan            # 同上（诊断用，含 dart 端口）
 *   node tool/preview-bridge.mjs start <port>... # 为每个端口起 0.0.0.0:<port> → 127.0.0.1:<port>
 */
import net from 'node:net';
import { execSync } from 'node:child_process';

const [, , cmd, ...args] = process.argv;

function netstat() {
  return execSync('netstat -ano', { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
}

/** 临时端口段（flutter 随机端口所在）内所有 LISTENING 端口 */
function listeningTempPorts() {
  const ports = new Set();
  for (const line of netstat().split(/\r?\n/)) {
    const m = line.match(/^\s*TCP\s+(?:127\.0\.0\.1|0\.0\.0\.0):(\d+)\s+\S+\s+LISTENING\s+(\d+)\s*$/);
    if (!m) continue;
    const p = Number(m[1]);
    if (p >= 49152 && p <= 65535) ports.add(p);
  }
  return [...ports].sort((a, b) => a - b);
}

/** dart.exe 的 PID 集合（flutter 工具链进程） */
function dartPids() {
  const out = execSync('tasklist /fi "imagename eq dart.exe" /fo csv /nh', { encoding: 'utf8' });
  const pids = new Set();
  for (const line of out.split(/\r?\n/)) {
    const m = line.match(/^"dart\.exe","(\d+)"/);
    if (m) pids.add(Number(m[1]));
  }
  return pids;
}

/** dart.exe 监听的端口（VM service / DTD / tooling daemon 等调试通道） */
function dartPorts() {
  const pids = dartPids();
  const ports = new Set();
  for (const line of netstat().split(/\r?\n/)) {
    const m = line.match(/^\s*TCP\s+(?:127\.0\.0\.1|0\.0\.0\.0):(\d+)\s+\S+\s+LISTENING\s+(\d+)\s*$/);
    if (!m) continue;
    if (pids.has(Number(m[2]))) ports.add(Number(m[1]));
  }
  return [...ports].sort((a, b) => a - b);
}

/**
 * 需要桥接的端口 = dart 调试服务端口。
 * 判别特征：这些端口对普通 HTTP 请求返回 403 "missing or invalid authentication code"
 * （Dart VM Service / DTD 的鉴权响应）——正是预览页要连的 ws 目标。
 */
function bridgeTargets() {
  const targets = [];
  for (const p of dartPorts()) {
    try {
      const body = execSync(`curl -s --max-time 2 http://127.0.0.1:${p}/`, {
        encoding: 'utf8',
        maxBuffer: 1024 * 1024,
      });
      if (body.includes('missing or invalid authentication code')) targets.push(p);
    } catch {
      /* 非调试服务端口，跳过 */
    }
  }
  return targets;
}

/** 探测预览页端口：只有 flutter web 服务提供 /flutter_bootstrap.js（200） */
function detectWebPort() {
  for (const p of listeningTempPorts()) {
    try {
      const out = execSync(
        `curl -s --max-time 2 -o NUL -w "%{http_code}" http://127.0.0.1:${p}/flutter_bootstrap.js`,
        { encoding: 'utf8', maxBuffer: 1024 * 1024 },
      );
      if (out.trim() === '200') return p;
    } catch {
      /* 不是 flutter web 端口，跳过 */
    }
  }
  return null;
}

function startBridge(port) {
  const server = net.createServer((client) => {
    const upstream = net.connect({ host: '127.0.0.1', port }, () => {
      client.pipe(upstream);
      upstream.pipe(client);
    });
    const kill = () => {
      client.destroy();
      upstream.destroy();
    };
    client.on('error', kill);
    upstream.on('error', kill);
  });
  server.listen({ host: '0.0.0.0', port }, () => {
    console.log(`bridge 0.0.0.0:${port} -> 127.0.0.1:${port}`);
  });
  server.on('error', (e) => console.error(`bridge ${port} error: ${e.message}`));
}

if (cmd === 'detect') {
  console.log(JSON.stringify({ web: detectWebPort(), all: bridgeTargets() }));
} else if (cmd === 'scan') {
  console.log(
    JSON.stringify({ web: detectWebPort(), bridge: bridgeTargets(), dart: dartPorts() }),
  );
} else if (cmd === 'start') {
  const ports = args.map(Number).filter(Boolean);
  if (!ports.length) {
    console.error('usage: start <port> [port...]');
    process.exit(2);
  }
  for (const p of ports) startBridge(p);
  // 常驻：桥需一直活着（Ctrl+C 退出）
} else {
  console.error('usage: detect | scan | start <port> [port...]');
  process.exit(2);
}
