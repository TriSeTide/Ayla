/**
 * stores/live.ts 单测（M5-4 文档 §7.1）：
 * - 弹幕按 id 去重 append；历史合并无重复；按 created_at 升序
 * - 列表定长截断（DANMAKU_MAX_ITEMS）
 * - 状态三态徽章语义（srsStatus 优先，null 用乐观兜底）
 * - 频道列表 upsert/remove；clearCurrent 退房清理
 */
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  DANMAKU_MAX_ITEMS,
  LIVE_MUTED_STORAGE_KEY,
  LIVE_OWNER_MUTED_STORAGE_KEY,
  readLiveMuted,
  useLiveStore,
  writeLiveMuted,
} from "../stores/live";
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
  localStorage.clear();
  vi.restoreAllMocks();
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

  it("频道列表排序：在播（status=live）置顶按 started_at 新→旧；曾播按 ended_at 新→旧；从未按 created_at 降序", () => {
    const mk = (
      id: number,
      status: LiveChannelDescriptor["status"],
      started_at: string | null,
      ended_at: string | null,
      created_at: string,
    ): LiveChannelDescriptor => ({ ...CHANNEL, id, title: `t${id}`, status, started_at, ended_at, created_at });
    useLiveStore.getState().setChannels([
      mk(1, "idle", null, null, "2026-08-01T00:00:00Z"), // 从未
      mk(2, "ended", "2026-08-15T00:00:00Z", "2026-08-15T01:00:00Z", "2026-08-01T00:00:00Z"), // 曾播
      mk(3, "live", "2026-09-05T10:00:00+08:00", null, "2026-08-02T00:00:00Z"), // 在播
    ]);
    expect(useLiveStore.getState().channels.map((c) => c.id)).toEqual([3, 2, 1]);
  });

  it("频道列表排序：在播内部按最近开播（started_at）新→旧", () => {
    const mk = (id: number, started_at: string): LiveChannelDescriptor => ({
      ...CHANNEL,
      id,
      title: `t${id}`,
      status: "live",
      started_at,
      ended_at: null,
      created_at: "2026-08-01T00:00:00Z",
    });
    useLiveStore.getState().setChannels([
      mk(1, "2026-09-05T09:00:00+08:00"),
      mk(2, "2026-09-05T10:00:00+08:00"),
    ]);
    expect(useLiveStore.getState().channels.map((c) => c.id)).toEqual([2, 1]);
  });

  it("REST 对账（upsertChannel）触发重排：开播带 started_at → 置顶；下播带 ended_at → 曾播区（不回落初始位）", () => {
    const mk = (id: number): LiveChannelDescriptor => ({
      ...CHANNEL,
      id,
      title: `t${id}`,
      status: "idle",
      started_at: null,
      ended_at: null,
      created_at: `2026-08-0${4 - id}T00:00:00Z`, // 1 最新 → 初始 [1,2,3]
    });
    useLiveStore.getState().setChannels([mk(1), mk(2), mk(3)]);
    expect(useLiveStore.getState().channels.map((c) => c.id)).toEqual([1, 2, 3]);
    // 3 开播：WS 帧只作失效提示，REST 详情对账 upsert 带回 started_at → 在播置顶
    useLiveStore.getState().upsertChannel({ ...mk(3), status: "live", started_at: "2026-09-05T10:00:00+08:00" });
    expect(useLiveStore.getState().channels.map((c) => c.id)).toEqual([3, 1, 2]);
    // 3 下播：对账带回 ended_at → 曾播区最前（压住从未开播的 1/2——不回落初始 3 号位）
    useLiveStore.getState().upsertChannel({ ...mk(3), status: "ended", started_at: "2026-09-05T10:00:00+08:00", ended_at: "2026-09-05T10:30:00+08:00" });
    expect(useLiveStore.getState().channels.map((c) => c.id)).toEqual([3, 1, 2]);
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

  it("频道对账：upsert 更新当前房间；删除当前房间会清空投影", () => {
    const s = useLiveStore.getState();
    s.setChannels([CHANNEL]);
    s.setCurrentChannel(CHANNEL);

    s.upsertChannel({ ...CHANNEL, title: "REST 对账后的标题", status: "live" });
    expect(useLiveStore.getState().current.channel).toMatchObject({
      title: "REST 对账后的标题",
      status: "live",
    });

    s.removeChannel(CHANNEL.id);
    expect(useLiveStore.getState().current.channel).toBeNull();
  });

  it("频道列表缓存记录 only_live 查询条件，避免过滤切换复用错误列表", () => {
    const s = useLiveStore.getState();
    s.setChannels([{ ...CHANNEL, status: "live" }], true);
    expect(useLiveStore.getState().channelsOnlyLive).toBe(true);
    s.setChannels([CHANNEL], false);
    expect(useLiveStore.getState().channelsOnlyLive).toBe(false);
  });

  it("静音偏好：readLiveMuted 只认 \"1\"；writeLiveMuted 静音写 \"1\"、取消静音删键", () => {
    expect(readLiveMuted()).toBe(false); // 无记录 = 有声音
    writeLiveMuted(true);
    expect(localStorage.getItem(LIVE_MUTED_STORAGE_KEY)).toBe("1");
    expect(readLiveMuted()).toBe(true);
    writeLiveMuted(false);
    expect(localStorage.getItem(LIVE_MUTED_STORAGE_KEY)).toBeNull();
    expect(readLiveMuted()).toBe(false);
  });

  it("静音偏好：存储不可用（隐私模式/配额耗尽）时读写都静默，默认有声音", () => {
    vi.spyOn(Storage.prototype, "getItem").mockImplementation(() => {
      throw new Error("storage denied");
    });
    vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => {
      throw new Error("storage denied");
    });
    vi.spyOn(Storage.prototype, "removeItem").mockImplementation(() => {
      throw new Error("storage denied");
    });
    // 读不到 ≠ 用户选了静音：必须回落到"有声音"，否则读不到偏好就把用户声音关掉
    expect(readLiveMuted()).toBe(false);
    expect(() => writeLiveMuted(true)).not.toThrow();
    expect(() => writeLiveMuted(false)).not.toThrow();
  });

  it("setMuted 只镜像投影、不写存储（偏好写入唯一入口是 runtime.setMuted 的用户手势）", () => {
    useLiveStore.getState().setMuted(true);
    expect(useLiveStore.getState().muted).toBe(true);
    // 关键防回归：ensureVideo/retrySound 失败分支也走这个 action，
    // 若在这里写存储就会把用户偏好改写成"静音"
    expect(localStorage.getItem(LIVE_MUTED_STORAGE_KEY)).toBeNull();

    useLiveStore.getState().setMuted(false);
    expect(useLiveStore.getState().muted).toBe(false);
    expect(localStorage.getItem(LIVE_MUTED_STORAGE_KEY)).toBeNull();
  });

  it("clearCurrent 不动静音投影；reset 回到已持久化的偏好（不是硬编码默认值）", () => {
    writeLiveMuted(true);
    useLiveStore.getState().setMuted(true);
    useLiveStore.getState().clearCurrent();
    expect(useLiveStore.getState().muted).toBe(true); // 换台/退房不清用户偏好

    useLiveStore.getState().reset();
    expect(useLiveStore.getState().muted).toBe(true); // 重置回已存偏好

    writeLiveMuted(false);
    useLiveStore.getState().reset();
    expect(useLiveStore.getState().muted).toBe(false);
  });

  it("静音偏好按端分开：观众端缺省有声、开播端缺省静音，两套键互不覆盖", () => {
    // 缺省值：两端各自的默认（这是本次需求的核心）
    expect(readLiveMuted(false)).toBe(false); // 观众端：默认有声
    expect(readLiveMuted(true)).toBe(true); // 开播端：默认静音

    // 观众端静音只写观众键
    writeLiveMuted(true, false);
    expect(localStorage.getItem(LIVE_MUTED_STORAGE_KEY)).toBe("1");
    expect(localStorage.getItem(LIVE_OWNER_MUTED_STORAGE_KEY)).toBeNull();
    expect(readLiveMuted(true)).toBe(true); // 开播端仍缺省静音

    // 开播端取消静音只动 owner 键（取消静音 = 回缺省 = 删键）
    writeLiveMuted(false, true);
    expect(localStorage.getItem(LIVE_OWNER_MUTED_STORAGE_KEY)).toBeNull();
    expect(localStorage.getItem(LIVE_MUTED_STORAGE_KEY)).toBe("1"); // 观众端偏好未被污染
    expect(readLiveMuted(false)).toBe(true);

    // 观众端取消静音：只删观众键，两端都回到各自缺省
    writeLiveMuted(false, false);
    expect(localStorage.getItem(LIVE_MUTED_STORAGE_KEY)).toBeNull();
    expect(readLiveMuted(false)).toBe(false);
    expect(readLiveMuted(true)).toBe(true);
  });

  it("静音偏好按端分开：存储不可用时两端各回退自己的缺省值", () => {
    vi.spyOn(Storage.prototype, "getItem").mockImplementation(() => {
      throw new Error("storage denied");
    });
    vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => {
      throw new Error("storage denied");
    });
    vi.spyOn(Storage.prototype, "removeItem").mockImplementation(() => {
      throw new Error("storage denied");
    });
    // 读不到 ≠ 用户选了静音：观众端必须回落到"有声音"
    expect(readLiveMuted(false)).toBe(false);
    // 开播端反过来：读不到就按缺省静音（开播界面默认不出声）
    expect(readLiveMuted(true)).toBe(true);
    expect(() => writeLiveMuted(true, false)).not.toThrow();
    expect(() => writeLiveMuted(false, true)).not.toThrow();
  });

  it("setMutedOwner 只镜像端语义、不写存储；clearCurrent 不动 muted/mutedOwner", () => {
    useLiveStore.getState().setMutedOwner(true);
    expect(useLiveStore.getState().mutedOwner).toBe(true);
    expect(localStorage.getItem(LIVE_OWNER_MUTED_STORAGE_KEY)).toBeNull();
    expect(localStorage.getItem(LIVE_MUTED_STORAGE_KEY)).toBeNull();

    useLiveStore.getState().setMuted(true);
    useLiveStore.getState().clearCurrent();
    // 退房不清端语义与投影：端语义由 runtime 在 leave/enter 显式管理
    expect(useLiveStore.getState().mutedOwner).toBe(true);
    expect(useLiveStore.getState().muted).toBe(true);

    useLiveStore.getState().reset();
    // 重置后没有会话 ⇒ 端语义回到缺省的观众端，投影回到观众端已存偏好
    expect(useLiveStore.getState().mutedOwner).toBe(false);
    expect(useLiveStore.getState().muted).toBe(false);
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
