/**
 * stores/live.ts 单测（M5-4 文档 §7.1）：
 * - 弹幕按 id 去重 append；历史合并无重复；按 created_at 升序
 * - 列表定长截断（DANMAKU_MAX_ITEMS）
 * - 状态三态徽章语义（srsStatus 优先，null 用乐观兜底）
 * - 频道列表 upsert/remove；clearCurrent 退房清理
 */
import { afterEach, describe, expect, it } from "vitest";
import { DANMAKU_MAX_ITEMS, useLiveStore } from "../stores/live";
import type { DanmakuItem, LiveChannelDescriptor } from "../api/types";

function danmaku(id: string, createdAt: string, content = "hi"): DanmakuItem {
  return {
    id,
    sender: { user_id: "u1", nickname: "n", avatar: "" },
    content,
    created_at: createdAt,
  };
}

const CHANNEL: LiveChannelDescriptor = {
  id: 1,
  title: "t",
  status: "idle",
  owner_id: "u1",
  owner_nickname: "爱莉",
  is_owner: true,
  visibility: "public",
  group: null,
  group_name: null,
  stream_key: "k",
  rtmp_url: "rtmp://h/live/k",
  hls_url: "http://h/live/k.m3u8",
  flv_url: "http://h/live/k.flv",
  started_at: null,
  ended_at: null,
  created_at: "2026-08-13T00:00:00Z",
};

afterEach(() => {
  useLiveStore.getState().reset();
});

describe("live store", () => {
  it("appendDanmaku：按 id 去重", () => {
    const s = useLiveStore.getState();
    s.appendDanmaku(danmaku("1", "2026-08-13T00:00:01Z"));
    s.appendDanmaku(danmaku("1", "2026-08-13T00:00:01Z"));
    s.appendDanmaku(danmaku("2", "2026-08-13T00:00:02Z"));
    const list = useLiveStore.getState().current.danmaku;
    expect(list).toHaveLength(2);
    expect(list.map((d) => d.id)).toEqual(["1", "2"]);
  });

  it("mergeDanmakuHistory：重连对账合并无重复，按 created_at 升序", () => {
    const s = useLiveStore.getState();
    // 实时已收到 3、5
    s.appendDanmaku(danmaku("3", "2026-08-13T00:00:03Z"));
    s.appendDanmaku(danmaku("5", "2026-08-13T00:00:05Z"));
    // 重连对账拉回 2、3、4（3 与实时重复）
    useLiveStore.getState().mergeDanmakuHistory([
      danmaku("4", "2026-08-13T00:00:04Z"),
      danmaku("2", "2026-08-13T00:00:02Z"),
      danmaku("3", "2026-08-13T00:00:03Z"),
    ]);
    const list = useLiveStore.getState().current.danmaku;
    expect(list.map((d) => d.id)).toEqual(["2", "3", "4", "5"]);
  });

  it("弹幕列表定长：超出 DANMAKU_MAX_ITEMS 丢弃最旧", () => {
    const s = useLiveStore.getState();
    for (let i = 0; i < DANMAKU_MAX_ITEMS + 10; i += 1) {
      s.appendDanmaku(
        danmaku(String(i), `2026-08-13T00:${String(Math.floor(i / 60)).padStart(2, "0")}:${String(i % 60).padStart(2, "0")}Z`),
      );
    }
    const list = useLiveStore.getState().current.danmaku;
    expect(list).toHaveLength(DANMAKU_MAX_ITEMS);
    // 最旧的 0..9 被丢弃，保留最新窗口
    expect(list[0].id).toBe("10");
    expect(list[list.length - 1].id).toBe(String(DANMAKU_MAX_ITEMS + 9));
  });

  it("状态三态：srsStatus live/idle/degraded 独立保存，null 表示未查询", () => {
    const s = useLiveStore.getState();
    expect(useLiveStore.getState().current.srsStatus).toBeNull();
    s.setSrsStatus("live");
    expect(useLiveStore.getState().current.srsStatus).toBe("live");
    s.setSrsStatus("degraded");
    expect(useLiveStore.getState().current.srsStatus).toBe("degraded");
    s.setSrsStatus("idle");
    expect(useLiveStore.getState().current.srsStatus).toBe("idle");
  });

  it("频道列表：setChannels / upsertChannel / removeChannel", () => {
    const s = useLiveStore.getState();
    s.setChannels([CHANNEL]);
    expect(useLiveStore.getState().channels).toHaveLength(1);

    // upsert 已存在 → 更新
    s.upsertChannel({ ...CHANNEL, status: "live" });
    expect(useLiveStore.getState().channels).toHaveLength(1);
    expect(useLiveStore.getState().channels[0].status).toBe("live");

    // upsert 不存在 → 追加
    s.upsertChannel({ ...CHANNEL, id: 2 });
    expect(useLiveStore.getState().channels).toHaveLength(2);

    s.removeChannel(1);
    expect(useLiveStore.getState().channels.map((c) => c.id)).toEqual([2]);
  });

  it("频道列表缓存记录 only_live 查询条件，避免过滤切换复用错误列表", () => {
    const s = useLiveStore.getState();
    s.setChannels([{ ...CHANNEL, status: "live" }], true);
    expect(useLiveStore.getState().channelsOnlyLive).toBe(true);
    s.setChannels([CHANNEL], false);
    expect(useLiveStore.getState().channelsOnlyLive).toBe(false);
  });

  it("clearCurrent：退房清当前直播间与 WS 状态，保留大厅列表", () => {
    const s = useLiveStore.getState();
    s.setChannels([CHANNEL]);
    s.setCurrentChannel(CHANNEL);
    s.setSrsStatus("live");
    s.setWsConnection("online");
    s.appendDanmaku(danmaku("1", "2026-08-13T00:00:01Z"));

    s.clearCurrent();
    const state = useLiveStore.getState();
    expect(state.current.channel).toBeNull();
    expect(state.current.srsStatus).toBeNull();
    expect(state.current.danmaku).toHaveLength(0);
    expect(state.wsConnection).toBe("offline");
    expect(state.channels).toHaveLength(1);
  });
});
