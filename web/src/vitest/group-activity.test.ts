/**
 * groupActivity 单元测试（M5 群"新内容"排序与事件描述）：
 * - hasGroupActivity：窗口内任一事件（消息/开播/语音房/桌游房/帖）即"新内容"；
 * - sortGroupsByActivity：置顶优先 → 有新内容按最近事件时间新→旧 → 无新内容保持稳定；
 * - 事件文本：消息=「发送者：内容」等。
 */
import { describe, expect, it } from "vitest";
import {
  hasGroupActivity,
  sortGroupsByActivity,
  type GroupActivity,
  type NewEvent,
} from "../components/home/groupActivity";

function group(id: string, isPinned = false) {
  return { id, is_pinned: isPinned };
}

function event(at: number, kind: NewEvent["kind"] = "message", text = "x"): NewEvent {
  return { kind, at, text };
}

function act(lastNewAt = 0, lastEvent: NewEvent | null = null): GroupActivity {
  return { lastNewAt, lastEvent };
}

describe("hasGroupActivity", () => {
  it("窗口内任一事件即新内容；无事件为 false", () => {
    expect(hasGroupActivity(act(1_000_000, event(1_000_000, "voice")))).toBe(true);
    expect(hasGroupActivity(act(1_000_000, event(1_000_000, "message")))).toBe(true);
    expect(hasGroupActivity(act(0, null))).toBe(false);
  });
});

describe("sortGroupsByActivity", () => {
  it("无新内容时保持传入顺序（稳定）", () => {
    const list = [group("a"), group("b"), group("c")];
    const key = () => act();
    const sorted = sortGroupsByActivity(list, key);
    expect(sorted.map((g) => g.id)).toEqual(["a", "b", "c"]);
  });

  it("有新内容的群排到无新内容群之前，组内按最近事件时间降序", () => {
    const now = 1_000_000;
    const list = [
      group("a"), // 无新内容
      group("b"), // 新语音房（较早）
      group("c"), // 无新内容
      group("d"), // 新开播（较晚）
      group("e"), // 无新内容
    ];
    const key = (g: { id: string }) => {
      if (g.id === "b") return act(now - 5_000, event(now - 5_000, "voice"));
      if (g.id === "d") return act(now - 1_000, event(now - 1_000, "live"));
      return act();
    };
    const sorted = sortGroupsByActivity(list, key);
    expect(sorted.map((g) => g.id)).toEqual(["d", "b", "a", "c", "e"]);
  });

  it("新消息（最后一条消息，含自己的）参与排序", () => {
    const now = 1_000_000;
    const list = [group("a"), group("b")];
    const key = (g: { id: string }) =>
      g.id === "b" ? act(now - 10_000, event(now - 10_000, "message", "我：你好")) : act();
    const sorted = sortGroupsByActivity(list, key);
    expect(sorted.map((g) => g.id)).toEqual(["b", "a"]);
  });

  it("置顶组在最前，组内亦按新内容时间排；非置顶组同规则", () => {
    const now = 1_000_000;
    const list = [
      group("a"), // 无新内容
      group("p1", true), // 置顶 + 新语音房（较早）
      group("b"), // 无新内容
      group("p2", true), // 置顶 + 新开播（较晚）
      group("c"), // 无新内容
    ];
    const key = (g: { id: string }) => {
      if (g.id === "p1") return act(now - 5_000, event(now - 5_000, "voice"));
      if (g.id === "p2") return act(now - 1_000, event(now - 1_000, "live"));
      return act();
    };
    const sorted = sortGroupsByActivity(list, key);
    // 置顶组：p2(live 新) 在 p1(voice 旧) 前；非置顶组全无新内容，保持原顺序 a,b,c
    expect(sorted.map((g) => g.id)).toEqual(["p2", "p1", "a", "b", "c"]);
  });

  it("新帖事件同样参与排序", () => {
    const now = 1_000_000;
    const list = [group("a"), group("b")];
    const key = (g: { id: string }) =>
      g.id === "b"
        ? act(now - 1_000, event(now - 1_000, "post", "阿蓝 发了新帖 你好"))
        : act();
    const sorted = sortGroupsByActivity(list, key);
    expect(sorted.map((g) => g.id)).toEqual(["b", "a"]);
  });
});