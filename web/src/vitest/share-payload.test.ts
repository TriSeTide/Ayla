/**
 * sharePayload 纯函数组装测试：六类来源 → SharePayload 契约。
 */
import { describe, expect, it } from "vitest";
import {
  boardgameSharePayload,
  groupSharePayload,
  liveSharePayload,
  postSharePayload,
  userSharePayload,
  voiceSharePayload,
} from "../utils/sharePayload";

describe("sharePayload 组装", () => {
  it("群分享：id/标题/头像/成员数/加入方式", () => {
    const p = groupSharePayload({ id: "g1", title: "技术群", avatar: "/api/v1/media/m1/content", member_count: 12, join_policy: "public" });
    expect(p).toEqual({
      share_type: "group",
      target_id: "g1",
      title: "技术群",
      cover: "/api/v1/media/m1/content",
      subtitle: "12 人",
      extra: { member_count: 12, join_policy: "public" },
    });
    expect(groupSharePayload({ id: "g2", title: "群" }).extra?.join_policy).toBeUndefined();
  });

  it("语音房分享：人数与群归属", () => {
    const p = voiceSharePayload({ id: "vc2", name: "深夜聊天", member_count: 3, group_id: "g9" });
    expect(p).toEqual({
      share_type: "voice",
      target_id: "vc2",
      title: "深夜聊天",
      cover: null,
      subtitle: "3 人",
      extra: { group_id: "g9" },
    });
    expect(voiceSharePayload({ id: "vc3", name: "空房", member_count: null, group_id: null }).subtitle).toBeNull();
    expect(voiceSharePayload({ id: "vc3", name: "空房", member_count: 0, group_id: null }).extra).toBeNull();
  });

  it("直播间分享：标题/封面/主播/群归属", () => {
    const p = liveSharePayload({ id: "lc7", title: "爱莉在线", cover: "/api/v1/media/m2/content", owner_name: "爱莉", group_id: null });
    expect(p).toEqual({
      share_type: "live",
      target_id: "lc7",
      title: "爱莉在线",
      cover: "/api/v1/media/m2/content",
      subtitle: "爱莉",
      extra: null,
    });
  });

  it("帖子分享：标题/摘要/首图/群归属", () => {
    const p = postSharePayload(
      { id: 42, title: "今日份快乐", body: "这是一段很长的正文内容，超过二十四字会被截断加省略号", group: "g5" },
      "/api/v1/media/m3/thumbnail",
    );
    expect(p.share_type).toBe("post");
    expect(p.target_id).toBe("42");
    expect(p.title).toBe("今日份快乐");
    expect(p.cover).toBe("/api/v1/media/m3/thumbnail");
    expect(p.extra).toEqual({ group_id: "g5" });
    expect(p.subtitle!.endsWith("…")).toBe(true);
  });

  it("桌游室分享：房名/游戏类型/群归属", () => {
    const p = boardgameSharePayload({ id: 7, name: "狼人杀之夜", group: "g8", game_type: "boardgame" });
    expect(p).toEqual({
      share_type: "boardgame",
      target_id: "7",
      title: "狼人杀之夜",
      cover: null,
      subtitle: "boardgame",
      extra: { group_id: "g8", game_type: "boardgame" },
    });
  });

  it("用户分享：昵称优先/头像", () => {
    const p = userSharePayload({ id: "u9", nickname: "小汐", username: "xixi", avatar: "/api/v1/media/m4/content" });
    expect(p).toEqual({
      share_type: "user",
      target_id: "u9",
      title: "小汐",
      cover: "/api/v1/media/m4/content",
      subtitle: null,
      extra: null,
    });
    expect(userSharePayload({ id: "u10", username: "anon" }).title).toBe("anon");
  });

  it("cover 归一化：外部 URL/空值 → null，站内相对路径保留", () => {
    const p1 = liveSharePayload({ id: "x", title: "t", cover: "https://evil.example/a.png" });
    expect(p1.cover).toBeNull();
    const p2 = liveSharePayload({ id: "x", title: "t", cover: "" });
    expect(p2.cover).toBeNull();
    const p3 = liveSharePayload({ id: "x", title: "t", cover: "/api/v1/media/m9/content" });
    expect(p3.cover).toBe("/api/v1/media/m9/content");
  });
});
