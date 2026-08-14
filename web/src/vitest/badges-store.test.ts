/**
 * badges store 测试（F8 B9）：messageBadge 聚合（私信未读 + 好友申请 + 群邀请 + 待审批）。
 * 群未读不进消息中心红点（群未读属群角标）。
 */
import { beforeEach, describe, expect, it, vi } from "vitest";
import * as accountsApi from "../api/accounts";
import { useBadgesStore } from "../stores/badges";

vi.mock("../api/accounts", () => ({
  getBadges: vi.fn(),
}));

beforeEach(() => {
  useBadgesStore.getState().reset();
  vi.mocked(accountsApi.getBadges).mockResolvedValue({
    private_unread: 3,
    group_unread: 5,
    friend_requests: 2,
    group_invites: 1,
    join_requests_pending: 4,
  });
});

describe("badges store", () => {
  it("fetch 拉取 badges", async () => {
    await useBadgesStore.getState().fetch();
    expect(useBadgesStore.getState().badges).toEqual({
      private_unread: 3,
      group_unread: 5,
      friend_requests: 2,
      group_invites: 1,
      join_requests_pending: 4,
    });
  });

  it("messageBadge 聚合 = 私信未读 + 好友申请 + 群邀请 + 待审批（不含群未读）", async () => {
    await useBadgesStore.getState().fetch();
    expect(useBadgesStore.getState().messageBadge()).toBe(3 + 2 + 1 + 4);
  });

  it("无 badges 时 messageBadge 为 0", () => {
    expect(useBadgesStore.getState().messageBadge()).toBe(0);
  });

  it("fetch 失败保持原状态（不伪造清零）", async () => {
    await useBadgesStore.getState().fetch();
    vi.mocked(accountsApi.getBadges).mockRejectedValueOnce(new Error("boom"));
    await useBadgesStore.getState().fetch();
    expect(useBadgesStore.getState().badges?.private_unread).toBe(3);
  });
});
