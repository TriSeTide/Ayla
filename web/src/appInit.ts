/**
 * 应用初始化门：进入网页 / 浏览器刷新 / 登录成功后，核心数据预加载完成前
 * 由 App 渲染全屏加载界面，完成后才进入实际页面。
 *
 * 状态机：idle（未触发）→ loading（预加载中）→ ready（完成，幂等短路）。
 * 登出后 reset 回 idle，下一位用户登录时重新预加载（数据 store 按用户隔离）。
 *
 * 覆盖范围与 main.tsx 既有 loadCoreData 一致：群列表、语音/直播/游戏目录、
 * 帖子信息流、私聊列表——各 hub 页进入即秒开，符合 App.tsx
 * 「登录后全局预加载核心数据 + 组件同步渲染」的既定策略。
 */
import { listPosts } from "./api/posts";
import { usePostsStore } from "./stores/posts";
import { useAuthStore } from "./stores/auth";
import { loadDirectory } from "./stores/directory";
import { loadSocial } from "./stores/social";

type InitStatus = "idle" | "loading" | "ready";

/** 预加载硬上限：正常情况等待全部完成；个别请求异常挂起时不能永远卡在全屏加载界面 */
const INIT_TIMEOUT_MS = 20000;

const listeners = new Set<() => void>();
let status: InitStatus = "idle";
let promise: Promise<void> | null = null;

function notify() {
  listeners.forEach((fn) => fn());
}

async function loadCoreData(): Promise<void> {
  // 失败不阻断流程（catch 后 resolve），用户访问对应页面时会重试
  try {
    const [, , , posts] = await Promise.all([
      loadSocial("conversations", { type: "group" }),
      loadDirectory("voice"),
      loadDirectory("live"),
      listPosts({ scope: "feed", limit: 20 }),
      loadDirectory("game"),
      loadSocial("conversations", { type: "private" }),
    ]);
    usePostsStore.getState().setPage(posts.results, posts.next_cursor, posts.has_more);
  } catch (err) {
    console.error("[预加载] 核心数据加载失败", err);
  }
}

export const appInit = {
  get status(): InitStatus {
    return status;
  },
  subscribe(fn: () => void): () => void {
    listeners.add(fn);
    return () => {
      listeners.delete(fn);
    };
  },
  /** 幂等：ready 或已有在途 promise 时直接复用；否则启动预加载 */
  run(): Promise<void> {
    if (promise) return promise;
    status = "loading";
    notify();
    promise = Promise.race([
      loadCoreData(),
      new Promise<void>((resolve) => setTimeout(resolve, INIT_TIMEOUT_MS)),
    ]).finally(() => {
      status = "ready";
      notify();
    });
    return promise;
  },
  /** 登出后重置：下一位用户登录时重新预加载 */
  reset(): void {
    status = "idle";
    promise = null;
  },
};

// 订阅登出：任何路径（UI 菜单直接调 store.logout、useAuth.logout、
// refresh 401 拦截、restoreSession 失败）清空 token 时都重置预加载门，
// 下一位用户登录时重新预加载。单向依赖 auth → appInit 反向成环，故放这里。
useAuthStore.subscribe((state, prev) => {
  if (prev.accessToken && !state.accessToken) {
    appInit.reset();
  }
});
