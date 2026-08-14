/**
 * 群状态角标纯函数测试（需求 R-H5：优先级 未读 > 直播 > 语音 > 桌游，最多 3 个）。
 */
import { describe, expect, it } from "vitest";
import { MAX_BADGES, resolveBadges } from "../components/home/badges";

describe("resolveBadges", () => {
  it("空状态 → 无角标", () => {
    expect(resolveBadges({})).toEqual([]);
  });

  it("未读 > 0 生成数字徽标（99+ 截断）", () => {
    const [b] = resolveBadges({ unread: 5 });
    expect(b.kind).toBe("unread");
    expect(b.label).toBe("5");

    const [big] = resolveBadges({ unread: 120 });
    expect(big.label).toBe("99+");
  });

  it("未读为 0 / undefined 不生成未读角标", () => {
    expect(resolveBadges({ unread: 0 })).toEqual([]);
    expect(resolveBadges({ unread: undefined })).toEqual([]);
  });

  it("按优先级排序：未读 > 直播 > 语音 > 桌游", () => {
    const badges = resolveBadges({ live: true, voice: true, game: true });
    expect(badges.map((b) => b.kind)).toEqual(["live", "voice", "game"]);
  });

  it("Boolean 状态 false 视为无", () => {
    const badges = resolveBadges({ live: false, voice: true });
    expect(badges.map((b) => b.kind)).toEqual(["voice"]);
  });

  it("最多 MAX_BADGES 个（未读+直播+语音+桌游 → 前 3）", () => {
    const badges = resolveBadges({ unread: 3, live: true, voice: true, game: true });
    expect(badges).toHaveLength(MAX_BADGES);
    expect(badges.map((b) => b.kind)).toEqual(["unread", "live", "voice"]);
  });

  it("图标类角标 label 为 null，未读有数字文本", () => {
    const badges = resolveBadges({ unread: 2, live: true });
    expect(badges[0].label).toBe("2");
    expect(badges[1].label).toBeNull();
  });

  it("图标类角标带无障碍描述", () => {
    const badges = resolveBadges({ voice: true });
    expect(badges[0].ariaLabel).toBe("群内有语音房");
  });
});
