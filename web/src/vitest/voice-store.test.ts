/**
 * stores/voice.ts 单测（M5-3 §7.1）：
 * - voice.state joined/left/muted/unmuted/heartbeat 合并正确
 * - 非当前频道的 voice.state 帧被忽略
 * - 离开频道清空成员与当前频道
 * - reconcileMembers 以对账结果为权威，保留本地音量偏好
 * - 爱莉条目只是普通成员（按 user_id 识别，无特殊数据源）
 */
import { beforeEach, describe, expect, it } from "vitest";
import { useVoiceStore } from "../stores/voice";

beforeEach(() => {
  useVoiceStore.getState().reset();
});

describe("voice store voice.state 合并", () => {
  it("setChannels/upsertChannel 按稳定频道 id 幂等去重，避免重复卡片和 duplicate key", () => {
    const channel = {
      id: "vc-1",
      name: "重复验证房",
      owner_id: "u1",
      group: "g1",
      allowed_group_ids: [],
      visibility: "group" as const,
      status: "idle" as const,
      member_count: 0,
      room_name: "重复验证房",
      group_name: "群一",
      created_at: "2026-08-20T00:00:00Z",
      mine: false,
    };
    useVoiceStore.getState().setChannels([channel, { ...channel, name: "重复验证房（旧投影）" }]);
    expect(useVoiceStore.getState().channels).toHaveLength(1);
    useVoiceStore.getState().upsertChannel({ ...channel, name: "重复验证房（更新）" });
    expect(useVoiceStore.getState().channels).toHaveLength(1);
    expect(useVoiceStore.getState().channels[0].name).toBe("重复验证房（更新）");
  });

  it("setChannels 排序：全空房（无 last_* 投影）回落 created_at 降序（新的在前）", () => {
    const mk = (id: string, created_at: string) => ({
      id,
      name: id,
      owner_id: "u1",
      group: null,
      allowed_group_ids: [],
      visibility: "public" as const,
      status: "idle" as const,
      member_count: 0,
      room_name: id,
      group_name: null,
      created_at,
      mine: false,
    });
    useVoiceStore.getState().setChannels([
      mk("old", "2026-08-01T00:00:00Z"),
      mk("new", "2026-08-20T00:00:00Z"),
      mk("mid", "2026-08-10T00:00:00Z"),
    ]);
    expect(useVoiceStore.getState().channels.map((c) => c.id)).toEqual(["new", "mid", "old"]);
  });

  it("setChannels 排序：有人区（member_count>0）整体置顶按 last_occupied_at 新→旧；无人区曾进入压住从未进入", () => {
    const mk = (
      id: string,
      member_count: number,
      last_occupied_at: string | null,
      last_vacant_at: string | null,
    ) => ({
      id,
      name: id,
      owner_id: "u1",
      group: null,
      allowed_group_ids: [],
      visibility: "public" as const,
      status: "idle" as const,
      member_count,
      room_name: id,
      group_name: null,
      created_at: `2026-08-0${4 - Number(id) === 1 ? 1 : 4 - Number(id)}T00:00:00Z`,
      mine: false,
      last_occupied_at,
      last_vacant_at,
    });
    useVoiceStore.getState().setChannels([
      mk("never", 0, null, null),
      mk("vacant", 0, "2026-09-02T08:00:00+08:00", "2026-09-03T08:00:00+08:00"),
      mk("occ-old", 1, "2026-09-05T09:00:00+08:00", null),
      mk("occ-new", 2, "2026-09-05T10:00:00+08:00", null),
    ]);
    expect(useVoiceStore.getState().channels.map((c) => c.id)).toEqual([
      "occ-new", "occ-old", "vacant", "never",
    ]);
  });

  it("patchChannel 触发重排：有人进入 → 实时置顶；变空回落无人区最前（不回落初始位）", () => {
    const mk = (id: string) => ({
      id,
      name: id,
      owner_id: "u1",
      group: null,
      allowed_group_ids: [],
      visibility: "public" as const,
      status: "idle" as const,
      member_count: 0,
      room_name: id,
      group_name: null,
      created_at: `2026-08-0${4 - Number(id)}T00:00:00Z`, // 1 最新 → 初始 [1,2,3]
      mine: false,
    });
    useVoiceStore.getState().setChannels([mk("1"), mk("2"), mk("3")]);
    expect(useVoiceStore.getState().channels.map((c) => c.id)).toEqual(["1", "2", "3"]);
    // 3 有人（WS 帧带 last_occupied_at）→ 有人区置顶
    useVoiceStore.getState().patchChannel("3", { member_count: 1, last_occupied_at: "2026-09-05T10:00:00+08:00" });
    expect(useVoiceStore.getState().channels.map((c) => c.id)).toEqual(["3", "1", "2"]);
    // 3 变空（帧带 last_vacant_at）→ 无人区曾进入最前，压住从未进入的 1/2——不回落初始 3 号位
    useVoiceStore.getState().patchChannel("3", { member_count: 0, last_vacant_at: "2026-09-05T10:05:00+08:00" });
    expect(useVoiceStore.getState().channels.map((c) => c.id)).toEqual(["3", "1", "2"]);
  });

  it("排序投影字段：patchChannel 更新 member_count 与 last_occupied_at/last_vacant_at（后端 WS 帧携带）", () => {
    useVoiceStore.getState().setChannels([{
      id: "vc-1",
      name: "排序投影房",
      owner_id: "u1",
      group: null,
      allowed_group_ids: [],
      visibility: "public" as const,
      member_count: 0,
      room_name: "排序投影房",
      group_name: null,
      created_at: "2026-08-20T00:00:00Z",
      mine: false,
    }]);
    // 有人进入（WS 帧带 last_occupied_at）→ 频道字段被 patch
    useVoiceStore.getState().patchChannel("vc-1", { member_count: 1, last_occupied_at: "2026-09-05T10:00:00+08:00", last_vacant_at: null });
    let ch = useVoiceStore.getState().channels.find((c) => c.id === "vc-1");
    expect(ch?.member_count).toBe(1);
    expect(ch?.last_occupied_at).toBe("2026-09-05T10:00:00+08:00");
    // 最后一人离开（帧带 last_vacant_at，member_count=0）
    useVoiceStore.getState().patchChannel("vc-1", { member_count: 0, last_vacant_at: "2026-09-05T10:05:00+08:00" });
    ch = useVoiceStore.getState().channels.find((c) => c.id === "vc-1");
    expect(ch?.member_count).toBe(0);
    expect(ch?.last_vacant_at).toBe("2026-09-05T10:05:00+08:00");
    // last_occupied_at 保留（曾有人进入的事实不因变空而清空——排序不回落）
    expect(ch?.last_occupied_at).toBe("2026-09-05T10:00:00+08:00");
  });

  it("joined → 写入成员；left → 移除；muted/unmuted → 更新标记；heartbeat → 只刷新 last_seen", () => {
    const s = useVoiceStore.getState();
    s.enterChannel("ch1", []);

    useVoiceStore.getState().applyVoiceState("ch1", "u1", "joined", "t1");
    let members = useVoiceStore.getState().members;
    expect(members["u1"]).toMatchObject({ user_id: "u1", muted: false, volume: 100 });

    useVoiceStore.getState().applyVoiceState("ch1", "u1", "muted", "t2");
    expect(useVoiceStore.getState().members["u1"].muted).toBe(true);

    useVoiceStore.getState().applyVoiceState("ch1", "u1", "unmuted", "t3");
    expect(useVoiceStore.getState().members["u1"].muted).toBe(false);

    useVoiceStore.getState().applyVoiceState("ch1", "u1", "heartbeat", "t9");
    expect(useVoiceStore.getState().members["u1"].last_seen_at).toBe("t9");
    // heartbeat 不改其他字段
    expect(useVoiceStore.getState().members["u1"].joined_at).toBe("t1");

    useVoiceStore.getState().applyVoiceState("ch1", "u1", "left", "t10");
    expect(useVoiceStore.getState().members["u1"]).toBeUndefined();
  });

  it("非当前频道的 voice.state 帧被忽略", () => {
    useVoiceStore.getState().enterChannel("ch1", []);
    useVoiceStore.getState().applyVoiceState("ch2", "u9", "joined", "t1");
    expect(useVoiceStore.getState().members["u9"]).toBeUndefined();
  });

  it("muted/unmuted 对未加入成员不产生条目（不伪造成员）", () => {
    useVoiceStore.getState().enterChannel("ch1", []);
    useVoiceStore.getState().applyVoiceState("ch1", "ghost", "muted", "t1");
    expect(useVoiceStore.getState().members["ghost"]).toBeUndefined();
  });

  it("离开频道清空成员与当前频道（幂等）", () => {
    const s = useVoiceStore.getState();
    s.enterChannel("ch1", [
      { user_id: "u1", joined_at: "t", last_seen_at: "t", muted: false, volume: 80, audioLevel: 0, locallyMuted: false },
    ]);
    useVoiceStore.getState().leaveChannelLocal();
    expect(useVoiceStore.getState().currentChannelId).toBeNull();
    expect(useVoiceStore.getState().members).toEqual({});
    expect(useVoiceStore.getState().livekit).toBe("idle");
    // 再调一次不报错
    useVoiceStore.getState().leaveChannelLocal();
  });
});

describe("voice store reconcileMembers 对账", () => {
  it("以服务端 members/ 为权威全量替换；保留本地音量偏好", () => {
    const s = useVoiceStore.getState();
    s.enterChannel("ch1", [
      { user_id: "u1", joined_at: "t0", last_seen_at: "t0", muted: false, volume: 100, audioLevel: 0, locallyMuted: false },
      { user_id: "u2", joined_at: "t0", last_seen_at: "t0", muted: false, volume: 100, audioLevel: 0, locallyMuted: false },
    ]);
    useVoiceStore.getState().setMemberVolume("u1", 55);

    // 对账：u2 已离开，u3 新加入
    useVoiceStore.getState().reconcileMembers([
      { user_id: "u1", joined_at: "t0", last_seen_at: "t5" },
      { user_id: "u3", joined_at: "t4", last_seen_at: "t4" },
    ]);
    const members = useVoiceStore.getState().members;
    expect(Object.keys(members).sort()).toEqual(["u1", "u3"]);
    expect(members["u1"].volume).toBe(55); // 本地偏好保留
    expect(members["u1"].last_seen_at).toBe("t5"); // 权威时间更新
    expect(members["u3"].volume).toBe(100);
  });

  it("爱莉条目按 profile user_id 识别，只是普通成员（无特殊数据源）", () => {
    useVoiceStore.getState().enterChannel("ch1", []);
    useVoiceStore.getState().applyVoiceState("ch1", "elysia-user", "joined", "t1");
    const m = useVoiceStore.getState().members["elysia-user"];
    expect(m).toBeDefined();
    expect(m.user_id).toBe("elysia-user");
    // 无任何"爱莉发言内容"字段——主体性：store 不持有爱莉语义内容
    expect(Object.keys(m).sort()).toEqual(
      ["audioLevel", "joined_at", "last_seen_at", "locallyMuted", "muted", "user_id", "volume"].sort(),
    );
  });
});
