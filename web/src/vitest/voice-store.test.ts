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
      { user_id: "u1", joined_at: "t", last_seen_at: "t", muted: false, volume: 80 },
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
      { user_id: "u1", joined_at: "t0", last_seen_at: "t0", muted: false, volume: 100 },
      { user_id: "u2", joined_at: "t0", last_seen_at: "t0", muted: false, volume: 100 },
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
      ["joined_at", "last_seen_at", "muted", "user_id", "volume"].sort(),
    );
  });
});
