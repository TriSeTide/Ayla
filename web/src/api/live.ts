/**
 * 直播 REST 封装（M5-4，对齐 backend/apps/live/views.py + urls.py）。
 *
 * 契约要点：
 * - 挂载根 /api/v1/live/；action 路径是冒号写法 `<id>:start/` / `<id>:stop/`；
 * - 频道 id 为 int；GET 列表返回裸数组；`?only_live=1` 过滤乐观 status=live；
 * - stream_key / rtmp_url 仅 owner 可见（他人为 null），属正常契约；
 * - /status/ 是 SRS 实时判定（live/idle/degraded），degraded ≠ 未在播；
 * - 弹幕发送走 REST（落库后服务端广播 WS），GET 历史返回裸数组、升序、无分页游标。
 */
import { apiRequest } from "./client";
import type {
  DanmakuItem,
  LiveChannelDescriptor,
  LiveStatusResult,
} from "./types";

/** POST /live/channels/ —— 创建频道（创建者即 owner；201 回显 stream_key/rtmp_url，仅本次） */
export function createLiveChannel(
  title: string,
  group?: string | null,
  payload: { description?: string; cover?: string } = {},
) {
  return apiRequest<LiveChannelDescriptor>("/live/channels/", {
    method: "POST",
    body: { title, ...(group ? { group } : {}), ...payload },
  });
}

/** PATCH /live/channels/<id>/ —— owner 修改标题、介绍、封面 */
export function updateLiveChannel(
  channelId: number,
  payload: { title?: string; description?: string; cover?: string },
) {
  return apiRequest<LiveChannelDescriptor>(`/live/channels/${channelId}/`, {
    method: "PATCH",
    body: payload,
  });
}

/** GET /live/channels/ —— 频道列表（裸数组）；onlyLive=true 时带 ?only_live=1 */
export function listLiveChannels(onlyLive = false) {
  const query = onlyLive ? "?only_live=1" : "";
  return apiRequest<LiveChannelDescriptor[]>(`/live/channels/${query}`);
}

/** GET /live/channels/<id>/ —— 频道详情（owner 可见 stream_key/rtmp_url，他人为 null） */
export function getLiveChannel(channelId: number) {
  return apiRequest<LiveChannelDescriptor>(`/live/channels/${channelId}/`);
}

/** POST /live/channels/<id>:start/ —— 乐观开播（不校验 SRS 真实流）；非 owner → 403 */
export function startLiveChannel(channelId: number) {
  return apiRequest<LiveChannelDescriptor>(`/live/channels/${channelId}:start/`, {
    method: "POST",
  });
}

/** POST /live/channels/<id>:stop/ —— 乐观下播；非 owner → 403 */
export function stopLiveChannel(channelId: number) {
  return apiRequest<LiveChannelDescriptor>(`/live/channels/${channelId}:stop/`, {
    method: "POST",
  });
}

/** DELETE /live/channels/<id>/ —— 删除频道；非 owner → 403；直播中（乐观 live）→ 400 */
export function deleteLiveChannel(channelId: number) {
  return apiRequest<{ deleted: boolean }>(`/live/channels/${channelId}/`, {
    method: "DELETE",
  });
}

/** GET /live/channels/<id>/status/ —— SRS 实时判定（权威）；degraded = SRS 不可用 */
export function getLiveChannelStatus(channelId: number) {
  return apiRequest<LiveStatusResult>(`/live/channels/${channelId}/status/`);
}

/** POST /live/channels/<id>/danmaku/ —— 发弹幕；空/超长（>200）→ 400 */
export function sendDanmaku(channelId: number, content: string) {
  return apiRequest<DanmakuItem>(`/live/channels/${channelId}/danmaku/`, {
    method: "POST",
    body: { content },
  });
}

/**
 * GET /live/channels/<id>/danmaku/?limit= —— 最近历史（裸数组、升序）。
 * limit 缺省 50，clamp 到 [1, 200]；无分页游标。
 */
export function listDanmaku(channelId: number, limit = 50) {
  return apiRequest<DanmakuItem[]>(
    `/live/channels/${channelId}/danmaku/?limit=${limit}`,
  );
}
