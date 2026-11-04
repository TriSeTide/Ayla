/**
 * 直播音频：静音所有权 + 偏好持久化 + 自动恢复声音（契约测试）。
 *
 * 根因（2026-10 直播无声）：ensureVideo() 写死 video.muted=true（自动播放策略要求
 * 静音起播），但全仓没有任何地方把它设回 false，播放器也没有喇叭按钮 ⇒ 永远静音。
 *
 * 本文件锁定的契约：
 * - 起播仍静音（否则无手势 play() 会被浏览器拒绝，直播停在加载中）；
 * - 出帧（playing/canplay）后按**当前端**的用户偏好自动恢复声音；
 * - 用户手动静音/取消静音写 localStorage（"1" = 静音），跨直播间、跨进房保留；
 * - 恢复声音被拒（NotAllowedError）时回退静音播放，且**不篡改用户偏好**；
 * - leave() 不写、不重置偏好。
 *
 * 2026-11-04 追加：静音偏好**按端分开**——观众端 `ayla.live.muted`（缺省有声）、
 * 开播控制台 `ayla.live.owner.muted`（缺省静音）。两端互不污染：主播在自己控制台
 * 静音不影响他看别人直播，观众端的"有声"也不会让开播控制台自己响起来。
 *
 * jsdom 的 HTMLMediaElement.play() 返回 undefined（不是 Promise），实现必须容错；
 * 被拒分支用 vi.spyOn(video, "play") 返回 rejected Promise 驱动。
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as liveApi from "../api/live";
import { liveSessionRuntime } from "../runtime/liveSessionRuntime";
import {
  LIVE_MUTED_STORAGE_KEY,
  LIVE_OWNER_MUTED_STORAGE_KEY,
  readLiveMuted,
  useLiveStore,
  writeLiveMuted,
} from "../stores/live";
import { useSessionActivityStore } from "../stores/sessionActivity";
import { liveWS } from "../ws/live";

vi.mock("../api/live", () => ({
  getLiveChannel: vi.fn(),
  getLiveChannelStatus: vi.fn(),
  getLiveChannelViewers: vi.fn(),
  listDanmaku: vi.fn(),
}));

vi.mock("../ws/live", () => ({
  liveWS: {
    onFrame: vi.fn(() => () => {}),
    onConnectionChange: null,
    onClosedByServer: null,
    onReconnected: null,
    connect: vi.fn(),
    disconnect: vi.fn(),
  },
}));

vi.mock("../ws/chat", () => ({
  chatWS: { onFrame: vi.fn(() => () => {}) },
}));

vi.mock("../player/hls", () => ({
  HlsPlayer: class {
    attach() {
      return "hls.js";
    }
    destroy() {}
    getMode() {
      return "hls.js";
    }
    refreshToLiveEdge() {
      return true;
    }
  },
}));

const channel = {
  id: 7,
  title: "测试直播间",
  status: "live",
  owner_id: "o1",
  owner_nickname: "主播",
  is_owner: false,
  visibility: "public",
  group: null,
  group_name: null,
  stream_key: null,
  rtmp_url: null,
  hls_url: "http://h/7.m3u8",
  flv_url: "http://h/7.flv",
  started_at: null,
  ended_at: null,
  created_at: "2026-01-01T00:00:00Z",
};

/** 推进微任务队列，让 enterAsync / play().then 链落地 */
async function flush(): Promise<void> {
  for (let i = 0; i < 8; i += 1) {
    await Promise.resolve();
  }
}

/**
 * 进房 + 挂载播放器，返回 runtime 持有的 video 元素。
 * 必须走 attachPlayer()：watchdog（playing/canplay → retrySound）在 rebuildPlayer 里布防，
 * 只 enter 不 attach 就不会有 onResume，声音恢复路径根本不会被触发。
 * jsdom 的 HTMLMediaElement.play() 是 "not implemented"（返回 undefined 并打 console error），
 * 统一 stub 成 resolved Promise，让成功/被拒两个分支都能被驱动。
 */
async function enterAndGetVideo(
  channelId = 7,
  opts: { isOwnerConsole?: boolean } = {},
): Promise<HTMLVideoElement> {
  liveSessionRuntime.enter(channelId, { isOwnerConsole: opts.isOwnerConsole });
  await flush();
  const video = liveSessionRuntime.getVideoElement();
  if (!video) throw new Error("video 元素未创建");
  liveSessionRuntime.attachPlayer();
  vi.spyOn(video, "play").mockResolvedValue(undefined);
  return video;
}

/** 模拟真实出帧：派发 playing（watchdog 的 onResume 在此恢复声音） */
function firePlaying(video: HTMLVideoElement): void {
  video.dispatchEvent(new Event("playing"));
}

beforeEach(() => {
  vi.mocked(liveWS.disconnect).mockClear();
  vi.mocked(liveWS.connect).mockClear();
  vi.mocked(liveApi.getLiveChannel).mockImplementation(async (id: number) =>
    ({ ...channel, id, title: `直播${id}` }) as never,
  );
  vi.mocked(liveApi.getLiveChannelStatus).mockResolvedValue({ status: "live" } as never);
  vi.mocked(liveApi.getLiveChannelViewers).mockResolvedValue({
    channel_id: 7,
    count: 0,
    has_more: false,
    viewers: [],
  } as never);
  vi.mocked(liveApi.listDanmaku).mockResolvedValue([] as never);
  localStorage.clear();
  useLiveStore.getState().reset();
  useSessionActivityStore.getState().reset();
});

afterEach(() => {
  liveSessionRuntime.leave();
  localStorage.clear();
  vi.restoreAllMocks();
  vi.clearAllMocks();
});

describe("静音偏好持久化（stores/live）", () => {
  it("readLiveMuted：无记录 = 有声音；只认 \"1\" = 静音", () => {
    expect(readLiveMuted()).toBe(false);
    localStorage.setItem(LIVE_MUTED_STORAGE_KEY, "1");
    expect(readLiveMuted()).toBe(true);
    localStorage.setItem(LIVE_MUTED_STORAGE_KEY, "0");
    expect(readLiveMuted()).toBe(false);
  });

  it("writeLiveMuted：静音写 \"1\"，取消静音删键；存储不可用时静默", () => {
    writeLiveMuted(true);
    expect(localStorage.getItem(LIVE_MUTED_STORAGE_KEY)).toBe("1");
    writeLiveMuted(false);
    expect(localStorage.getItem(LIVE_MUTED_STORAGE_KEY)).toBeNull();

    // 存储被禁用（隐私模式/配额耗尽）→ 不抛错、不阻断播放
    const spy = vi.spyOn(Storage.prototype, "getItem").mockImplementation(() => {
      throw new Error("denied");
    });
    expect(readLiveMuted()).toBe(false);
    spy.mockRestore();
  });

  it("store.setMuted 只镜像投影、不写存储；clearCurrent 不清偏好；reset 回到已存偏好", () => {
    // setMuted 是非手势路径（ensureVideo/retrySound）也会调用的 action ⇒ 不得写存储
    useLiveStore.getState().setMuted(true);
    expect(useLiveStore.getState().muted).toBe(true);
    expect(localStorage.getItem(LIVE_MUTED_STORAGE_KEY)).toBeNull();

    // 退房（clearCurrent）不动静音投影
    useLiveStore.getState().clearCurrent();
    expect(useLiveStore.getState().muted).toBe(true);

    // 全量 reset 回到**已持久化**的偏好（不是硬编码 false）——所以先写偏好
    writeLiveMuted(true);
    useLiveStore.getState().reset();
    expect(useLiveStore.getState().muted).toBe(true);

    // 取消静音 → 偏好键被删除，reset 后回到有声音
    writeLiveMuted(false);
    useLiveStore.getState().reset();
    expect(useLiveStore.getState().muted).toBe(false);
  });
});

describe("偏好写入唯一入口 = runtime.setMuted（用户手势）；非手势路径不得污染偏好", () => {
  it("ensureVideo 不得改动 localStorage 偏好：投影静音但存储仍为 null，恢复后也不写", async () => {
    localStorage.removeItem(LIVE_MUTED_STORAGE_KEY);
    liveSessionRuntime.enter(7, {});
    await flush();
    const video = liveSessionRuntime.getVideoElement();
    if (!video) throw new Error("video 元素未创建");

    // 起播阶段：UI 投影是"静音"，但用户偏好必须保持原样（未写过 = 有声）
    expect(useLiveStore.getState().muted).toBe(true);
    expect(localStorage.getItem(LIVE_MUTED_STORAGE_KEY)).toBeNull();
    expect(readLiveMuted()).toBe(false);

    // 出帧后自动恢复声音：同样不得写偏好
    liveSessionRuntime.attachPlayer();
    vi.spyOn(video, "play").mockResolvedValue(undefined);
    firePlaying(video);
    await flush();
    expect(useLiveStore.getState().muted).toBe(false);
    expect(localStorage.getItem(LIVE_MUTED_STORAGE_KEY)).toBeNull();
  });

  it("自动恢复被拒时偏好不变：回退静音、store=true，但存储仍是 null（不是 \"1\"）", async () => {
    localStorage.removeItem(LIVE_MUTED_STORAGE_KEY);
    const video = await enterAndGetVideo();
    const notAllowed = Object.assign(new Error("blocked"), { name: "NotAllowedError" });
    vi.spyOn(video, "play").mockRejectedValue(notAllowed);

    firePlaying(video);
    await flush();

    expect(video.muted).toBe(true); // 画面优先：回退静音继续播
    expect(useLiveStore.getState().muted).toBe(true);
    // 关键：偏好仍是"有声"，浏览器拒绝出声不等于用户选择静音
    expect(localStorage.getItem(LIVE_MUTED_STORAGE_KEY)).toBeNull();
    expect(readLiveMuted()).toBe(false);
  });
});

describe("静音所有权（runtime）：起播静音 → 出帧恢复声音", () => {
  it("enter 后 video.muted=true 且 store.muted=true（自动播放策略要求静音起播）", async () => {
    const video = await enterAndGetVideo();
    expect(video.muted).toBe(true);
    expect(useLiveStore.getState().muted).toBe(true);
    expect(liveSessionRuntime.isMuted()).toBe(true);
  });

  it("默认偏好「有声」：出帧后自动取消静音（video.muted=false、store.muted=false）", async () => {
    const video = await enterAndGetVideo();
    expect(video.muted).toBe(true);
    firePlaying(video);
    await flush();
    expect(video.muted).toBe(false);
    expect(useLiveStore.getState().muted).toBe(false);
    expect(liveSessionRuntime.isMuted()).toBe(false);
    // 自动恢复不是用户动作：偏好里不该出现"静音"
    expect(localStorage.getItem(LIVE_MUTED_STORAGE_KEY)).toBeNull();
  });

  it("canplay 同样触发恢复（不同浏览器首个事件不同）；重复调用幂等", async () => {
    const video = await enterAndGetVideo();
    video.dispatchEvent(new Event("canplay"));
    await flush();
    expect(video.muted).toBe(false);
    // 再次触发（恢复/重连后的重复事件）不得把已响的声音再改回去
    liveSessionRuntime.retrySound();
    firePlaying(video);
    await flush();
    expect(video.muted).toBe(false);
    expect(useLiveStore.getState().muted).toBe(false);
  });

  it("用户静音 → localStorage \"1\" + video.muted=true + store.muted=true；重新 enter 仍是静音", async () => {
    const video = await enterAndGetVideo();
    liveSessionRuntime.setMuted(true);
    expect(localStorage.getItem(LIVE_MUTED_STORAGE_KEY)).toBe("1");
    expect(video.muted).toBe(true);
    expect(useLiveStore.getState().muted).toBe(true);

    // 出帧不得把用户手动的静音又恢复成有声
    firePlaying(video);
    await flush();
    expect(video.muted).toBe(true);
    expect(useLiveStore.getState().muted).toBe(true);

    // 重新进房（重建 video 元素）：仍是静音
    liveSessionRuntime.leave();
    const video2 = await enterAndGetVideo();
    expect(video2).not.toBe(video);
    expect(video2.muted).toBe(true);
    expect(useLiveStore.getState().muted).toBe(true);
    firePlaying(video2);
    await flush();
    expect(video2.muted).toBe(true);
  });

  it("toggleMuted 往返：静音 → 有声 → 静音，偏好与 store 同步", async () => {
    const video = await enterAndGetVideo();
    expect(video.muted).toBe(true);

    liveSessionRuntime.toggleMuted(); // → 有声
    await flush();
    expect(video.muted).toBe(false);
    expect(useLiveStore.getState().muted).toBe(false);
    expect(localStorage.getItem(LIVE_MUTED_STORAGE_KEY)).toBeNull();

    liveSessionRuntime.toggleMuted(); // → 静音
    expect(video.muted).toBe(true);
    expect(useLiveStore.getState().muted).toBe(true);
    expect(localStorage.getItem(LIVE_MUTED_STORAGE_KEY)).toBe("1");
  });

  it("恢复声音被拒（NotAllowedError）→ 回退静音播放、store 保持 true、偏好不被篡改", async () => {
    const video = await enterAndGetVideo();
    const notAllowed = Object.assign(new Error("blocked"), { name: "NotAllowedError" });
    const play = vi.spyOn(video, "play").mockRejectedValue(notAllowed);

    firePlaying(video);
    await flush();

    expect(play).toHaveBeenCalled();
    expect(video.muted).toBe(true); // 画面优先：回退静音继续播
    expect(useLiveStore.getState().muted).toBe(true);
    // 偏好仍是"有声"：用户没有选择静音，下次出帧/用户点喇叭仍应尝试恢复
    expect(localStorage.getItem(LIVE_MUTED_STORAGE_KEY)).toBeNull();

    // 解除拦截后重试 → 声音恢复（偏好未被污染，因此仍有第二次机会）。
    // 这里直接调 retrySound 而不是再派发 playing：onResume 里的 clearStallTimer()
    // 会一并卸掉 watchdog 监听（出帧即认为已恢复），下一次真实 playing 要等重建才布防。
    play.mockResolvedValue(undefined);
    liveSessionRuntime.retrySound();
    await flush();
    expect(video.muted).toBe(false);
    expect(useLiveStore.getState().muted).toBe(false);
  });

  it("leave() 不写、不重置偏好：静音选择跨直播间保留", async () => {
    await enterAndGetVideo();
    liveSessionRuntime.setMuted(true);
    liveSessionRuntime.leave();
    expect(localStorage.getItem(LIVE_MUTED_STORAGE_KEY)).toBe("1");
    expect(useLiveStore.getState().muted).toBe(true);
    expect(liveSessionRuntime.getVideoElement()).toBeNull();
    // 元素已销毁：isMuted 退到偏好，UI 不会闪成"有声音"
    expect(liveSessionRuntime.isMuted()).toBe(true);

    // 进另一个直播间：仍静音
    const video2 = await enterAndGetVideo(8);
    expect(video2).not.toBeNull();
    expect(video2.muted).toBe(true);
    expect(useLiveStore.getState().muted).toBe(true);
  });

  it("无 video 元素时 setMuted 只写偏好与 store（小窗关闭/退房后点喇叭不炸）", () => {
    expect(liveSessionRuntime.getVideoElement()).toBeNull();
    liveSessionRuntime.setMuted(true);
    expect(localStorage.getItem(LIVE_MUTED_STORAGE_KEY)).toBe("1");
    expect(useLiveStore.getState().muted).toBe(true);
    liveSessionRuntime.toggleMuted();
    expect(liveSessionRuntime.isMuted()).toBe(false);
    expect(useLiveStore.getState().muted).toBe(false);
  });
});

/**
 * 2026-11-04 需求（用户原话）：「默认把声音打开……但是 web 和 Flutter 的开播界面，
 * 默认把声音关闭。」
 * 拆成两条硬契约：观众端缺省有声、开播控制台缺省静音；两套偏好**互不污染**。
 */
describe("偏好按端分开：观众端默认有声 / 开播控制台默认静音", () => {
  it("观众端首次进房：出帧后有声，两端偏好键都仍是 null", async () => {
    const video = await enterAndGetVideo(7, { isOwnerConsole: false });
    expect(liveSessionRuntime.isOwnerConsole).toBe(false);
    firePlaying(video);
    await flush();
    expect(video.muted).toBe(false);
    expect(useLiveStore.getState().muted).toBe(false);
    expect(localStorage.getItem(LIVE_MUTED_STORAGE_KEY)).toBeNull();
    expect(localStorage.getItem(LIVE_OWNER_MUTED_STORAGE_KEY)).toBeNull();
  });

  it("开播控制台首次进房：出帧后仍然静音，两端偏好键都仍是 null", async () => {
    const video = await enterAndGetVideo(7, { isOwnerConsole: true });
    expect(liveSessionRuntime.isOwnerConsole).toBe(true);
    expect(useLiveStore.getState().mutedOwner).toBe(true);
    // 起播阶段同样静音（自动播放策略）
    expect(video.muted).toBe(true);
    firePlaying(video);
    await flush();
    // 缺省静音 ⇒ 出帧不会自己响；但这不是"用户选了静音"，所以偏好键仍为空
    expect(video.muted).toBe(true);
    expect(useLiveStore.getState().muted).toBe(true);
    expect(localStorage.getItem(LIVE_OWNER_MUTED_STORAGE_KEY)).toBeNull();
    expect(localStorage.getItem(LIVE_MUTED_STORAGE_KEY)).toBeNull();
  });

  it("在开播控制台取消静音：本次立即出声，只动 owner 键，观众端偏好完全不受影响", async () => {
    const video = await enterAndGetVideo(7, { isOwnerConsole: true });
    liveSessionRuntime.setMuted(true); // 先落一个 owner 键，验证取消静音会把它删掉
    expect(localStorage.getItem(LIVE_OWNER_MUTED_STORAGE_KEY)).toBe("1");

    liveSessionRuntime.setMuted(false);
    await flush();
    expect(video.muted).toBe(false);
    expect(useLiveStore.getState().muted).toBe(false);
    // 取消静音 = 回到缺省（开播端缺省就是静音）⇒ 删除键，不存 "0"：
    // 控制台的"开声"是这一次的操作，不是需要长期记住的偏好。
    expect(localStorage.getItem(LIVE_OWNER_MUTED_STORAGE_KEY)).toBeNull();
    expect(localStorage.getItem(LIVE_MUTED_STORAGE_KEY)).toBeNull();
    // 观众端偏好没有被写脏：主播去看别人直播依然有声音
    expect(readLiveMuted(false)).toBe(false);
  });

  it("在开播控制台静音：只写 owner 键，观众端键不受污染（主播去看别人直播仍有声）", async () => {
    await enterAndGetVideo(7, { isOwnerConsole: true });
    liveSessionRuntime.setMuted(true);
    expect(localStorage.getItem(LIVE_OWNER_MUTED_STORAGE_KEY)).toBe("1");
    expect(localStorage.getItem(LIVE_MUTED_STORAGE_KEY)).toBeNull();
    expect(readLiveMuted(false)).toBe(false); // 观众端偏好仍是"有声"

    // 切到别人的直播间（观众端语义）：仍然出声
    liveSessionRuntime.leave();
    const video2 = await enterAndGetVideo(9, { isOwnerConsole: false });
    firePlaying(video2);
    await flush();
    expect(video2.muted).toBe(false);
    expect(useLiveStore.getState().muted).toBe(false);
  });

  it("在观众端静音：只写观众键，开播端键不受污染（回控制台仍按缺省静音）", async () => {
    const video = await enterAndGetVideo(7, { isOwnerConsole: false });
    liveSessionRuntime.setMuted(true);
    expect(localStorage.getItem(LIVE_MUTED_STORAGE_KEY)).toBe("1");
    expect(localStorage.getItem(LIVE_OWNER_MUTED_STORAGE_KEY)).toBeNull();
    expect(readLiveMuted(true)).toBe(true); // 开播端缺省仍是静音

    firePlaying(video);
    await flush();
    expect(video.muted).toBe(true);
    expect(useLiveStore.getState().muted).toBe(true);
  });

  it("同频道端语义切换（观众页 ↔ 开播控制台）：按新端偏好重新应用，且不改写任何偏好", async () => {
    // 观众端进房 → 出帧有声
    const video = await enterAndGetVideo(7, { isOwnerConsole: false });
    firePlaying(video);
    await flush();
    expect(video.muted).toBe(false);

    // 同一频道切到开播控制台（showOwnerPanel 翻转 → 同频道重进分支）
    liveSessionRuntime.enter(7, { isOwnerConsole: true });
    await flush();
    expect(liveSessionRuntime.isOwnerConsole).toBe(true);
    expect(useLiveStore.getState().mutedOwner).toBe(true);
    // 元素被复用：必须按开播端缺省（静音）重新应用
    expect(video.muted).toBe(true);
    expect(useLiveStore.getState().muted).toBe(true);
    // 端语义切换不是用户手势 ⇒ 不得写偏好
    expect(localStorage.getItem(LIVE_MUTED_STORAGE_KEY)).toBeNull();
    expect(localStorage.getItem(LIVE_OWNER_MUTED_STORAGE_KEY)).toBeNull();
  });

  it("端语义不变时重复 enter 不翻动用户刚点的静音（幂等）", async () => {
    const video = await enterAndGetVideo(7, { isOwnerConsole: false });
    firePlaying(video);
    await flush();
    liveSessionRuntime.setMuted(true); // 用户手动静音
    expect(video.muted).toBe(true);

    liveSessionRuntime.enter(7, { isOwnerConsole: false }); // 同端重进
    await flush();
    expect(video.muted).toBe(true);
    expect(useLiveStore.getState().muted).toBe(true);
    expect(localStorage.getItem(LIVE_MUTED_STORAGE_KEY)).toBe("1");
  });

  it("setOwnerConsole：端语义后到（加载完成才知道 is_owner）时按新端偏好重新应用", async () => {
    // 进房时还不知道是不是自己的直播间（current.channel 被 clearCurrent 清空）
    const video = await enterAndGetVideo(7, { isOwnerConsole: false });
    firePlaying(video);
    await flush();
    expect(video.muted).toBe(false); // 先按观众端出声

    // 详情返回：这是自己的直播间 → 视图通知端语义变为开播控制台
    liveSessionRuntime.setOwnerConsole(true);
    expect(liveSessionRuntime.isOwnerConsole).toBe(true);
    expect(useLiveStore.getState().mutedOwner).toBe(true);
    expect(video.muted).toBe(true); // 控制台缺省静音：立刻安静下来
    expect(useLiveStore.getState().muted).toBe(true);
    // 端语义切换不是用户手势 ⇒ 不写偏好
    expect(localStorage.getItem(LIVE_OWNER_MUTED_STORAGE_KEY)).toBeNull();
    expect(localStorage.getItem(LIVE_MUTED_STORAGE_KEY)).toBeNull();

    // 切回观众端语义（离开控制台）：按观众端偏好恢复声音
    vi.spyOn(video, "play").mockResolvedValue(undefined);
    liveSessionRuntime.setOwnerConsole(false);
    await flush();
    expect(video.muted).toBe(false);
    expect(useLiveStore.getState().muted).toBe(false);
  });

  it("setOwnerConsole 带 channelId：转场期旧页面的通知被拒绝（不影响新会话）", async () => {
    const video = await enterAndGetVideo(7, { isOwnerConsole: true });
    expect(video.muted).toBe(true);
    // 旧页面（频道 6）在转场期仍在渲染并重算端语义：必须被拒
    liveSessionRuntime.setOwnerConsole(false, 6);
    expect(liveSessionRuntime.isOwnerConsole).toBe(true);
    expect(video.muted).toBe(true);
    // 当前会话自己的通知照常生效
    liveSessionRuntime.setOwnerConsole(true, 7);
    expect(liveSessionRuntime.isOwnerConsole).toBe(true);
  });

  it("setOwnerConsole 幂等：重复同一端语义不动用户刚点的静音", async () => {
    const video = await enterAndGetVideo(7, { isOwnerConsole: false });
    firePlaying(video);
    await flush();
    liveSessionRuntime.setMuted(true); // 用户手动静音
    expect(video.muted).toBe(true);

    liveSessionRuntime.setOwnerConsole(false); // 视图重渲染再次通知同一端
    expect(video.muted).toBe(true);
    expect(localStorage.getItem(LIVE_MUTED_STORAGE_KEY)).toBe("1");
  });

  it("存储不可用：两端各自回退自己的缺省值（观众有声 / 开播静音）", async () => {
    vi.spyOn(Storage.prototype, "getItem").mockImplementation(() => {
      throw new Error("denied");
    });
    expect(readLiveMuted(false)).toBe(false);
    expect(readLiveMuted(true)).toBe(true);

    const video = await enterAndGetVideo(7, { isOwnerConsole: true });
    firePlaying(video);
    await flush();
    expect(video.muted).toBe(true); // 开播端缺省静音
    expect(useLiveStore.getState().muted).toBe(true);
  });
});
