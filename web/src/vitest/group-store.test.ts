/**
 * group store 测试：activeScene 单一状态源 + currentGroupId。
 */
import { beforeEach, describe, expect, it } from "vitest";
import { GROUP_SCENE_ORDER, useGroupStore } from "../stores/group";

describe("group store", () => {
  beforeEach(() => {
    useGroupStore.getState().reset();
  });

  it("默认 chat 场景、无当前群", () => {
    expect(useGroupStore.getState().activeScene).toBe("chat");
    expect(useGroupStore.getState().currentGroupId).toBeNull();
  });

  it("setActiveScene / setCurrentGroup 更新状态", () => {
    useGroupStore.getState().setActiveScene("live");
    useGroupStore.getState().setCurrentGroup("g1");
    expect(useGroupStore.getState().activeScene).toBe("live");
    expect(useGroupStore.getState().currentGroupId).toBe("g1");
  });

  it("reset 归位", () => {
    useGroupStore.getState().setActiveScene("posts");
    useGroupStore.getState().setCurrentGroup("g1");
    useGroupStore.getState().reset();
    expect(useGroupStore.getState().activeScene).toBe("chat");
    expect(useGroupStore.getState().currentGroupId).toBeNull();
  });

  it("五子界面顺序：语音|直播|聊天|帖子|桌游（聊天居中）", () => {
    expect(GROUP_SCENE_ORDER).toEqual(["voice", "live", "chat", "posts", "games"]);
  });
});
