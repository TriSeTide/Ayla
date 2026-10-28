/**
 * ws/presence.ts 心跳间隔契约（跨仓库同值锁）。
 *
 * ## 背景（2026-10-28 真 bug）
 * flutter/lib/core/ws/ws_manager.dart 的 kPingIntervalMs 在删除 ws_relay 中继时
 * 被误写成 15000，而本文件对应的 ws/presence.ts 是 25_000 —— 两侧 presence
 * 心跳节奏不同源，成员进出 / 静音 / 头像在线光环等热更新异常。
 *
 * ## 为什么现有的 presence-ws.test.ts 不够
 * 它用 advanceTimersByTime(25_000) 断言 web 一侧的定时行为，属于单侧行为锁；
 * 真正的缺口是没有任何断言把「web 的常量」和「flutter 的常量」绑在一起 ——
 * 两边各自自洽但互相不一致时，两边的测试都全绿（本次事故正是如此）。
 *
 * ## 本文件锁什么
 * 唯一真值源是两侧的实际源码文本；flutter 侧由
 * test/ws_heartbeat_contract_test.dart 读同一份 presence.ts 做反向比对，
 * 任何一侧改动都会让其中一边变红。
 */
import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const HERE = dirname(fileURLToPath(import.meta.url));
const WEB_SRC = resolve(HERE, "..");
// HERE = <repo>/web/src/vitest → WEB_SRC = <repo>/web/src → flutter 在 <repo>/flutter
const FLUTTER_ROOT = resolve(WEB_SRC, "..", "..", "flutter");

/** presence 心跳期望值（ms）：与 flutter kPingIntervalMs 同值。 */
const EXPECTED_PRESENCE_MS = 25_000;
/** chat / voice / live 三通道的心跳期望值（ms）。 */
const EXPECTED_OTHER_MS = 30_000;

/** 从 TS 源码抽出 HEARTBEAT_INTERVAL_MS 的数值（容忍 25_000 数字分隔符）。 */
function heartbeatMs(relPath: string): number | null {
  const src = readFileSync(resolve(WEB_SRC, relPath), "utf8");
  const m = /HEARTBEAT_INTERVAL_MS\s*=\s*([0-9_]+)/.exec(src);
  // 用 replace(/g) 而非 replaceAll：本仓库 tsconfig 的 lib 目标低于 es2021，
  // replaceAll 在类型检查里不存在（实测 tsc --noEmit 报 TS2550）。
  return m ? Number(m[1].replace(/_/g, "")) : null;
}

/** 从 Dart 源码抽出 const int kPingIntervalMs = <n>; 的数值。 */
function flutterPingMs(): number | null {
  const src = readFileSync(
    resolve(FLUTTER_ROOT, "lib/core/ws/ws_manager.dart"),
    "utf8",
  );
  const m = /const int kPingIntervalMs = ([0-9]+);/.exec(src);
  return m ? Number(m[1]) : null;
}

describe("WS 心跳间隔契约", () => {
  it("presence.ts HEARTBEAT_INTERVAL_MS == 25_000（须小于服务端 presence TTL 60s）", () => {
    expect(heartbeatMs("ws/presence.ts")).toBe(EXPECTED_PRESENCE_MS);
  });

  it("chat.ts / voice.ts / live.ts 均为 30_000", () => {
    for (const rel of ["ws/chat.ts", "ws/voice.ts", "ws/live.ts"]) {
      expect(heartbeatMs(rel), rel).toBe(EXPECTED_OTHER_MS);
    }
  });

  it("跨仓库同值：flutter kPingIntervalMs == presence.ts HEARTBEAT_INTERVAL_MS", () => {
    const flutter = flutterPingMs();
    expect(flutter, "flutter ws_manager.dart 必须仍定义 kPingIntervalMs").not.toBeNull();
    // vitest 的 expect 第二个参数是「消息」；断言失败提示要放在 expect(...).toBe 之前，
    // 不能当第三个参数传（tsc 报 TS2554: Expected 1-2 arguments, but got 3）。
    expect(flutter, "flutter 与 web 的 presence 心跳间隔必须同值（2026-10-28 曾误写 15000）").toBe(
      heartbeatMs("ws/presence.ts"),
    );
    expect(flutter).toBe(EXPECTED_PRESENCE_MS);
  });
});
