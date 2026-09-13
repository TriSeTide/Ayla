/**
 * LiveViewerSheet —— 直播间「正在观看」名单弹层（需求）。
 *
 * - 宽屏：居中浮层（复用 CreateSheet 的 modal 规格）；
 * - 窄屏：底部上滑，**高度 60% 屏**（需求指定；其余材料/圆角沿用 CreateSheet 配方）；
 * - 内容：头像 + 昵称一行一位，点击整行跳个人主页（自己 → /profile，他人 → /user/:id）；
 * - 数据：打开时按权限拉 `GET /live/channels/<id>/viewers/` 权威名单；先用弹幕 WS 的
 *   预览（最多 12 位）打底，避免空白等待。presence 存储不可用（503）→ 明示
 *   "暂时读不到在看名单"，**不回落到空名单冒充没人看**。
 *
 * 弹层 portal 到 body（CreateSheet 内已处理）——侧栏的 backdrop-filter 会创建
 * stacking context，把 fixed 后代裁剪在容器内。
 */
import { useEffect, useMemo, useState } from "react";
import { getLiveChannelViewers } from "../../api/live";
import type { LiveViewerItem } from "../../api/types";
import { getElysiaProfile } from "../../api/elysia";
import { useAuthStore } from "../../stores/auth";
import { CreateSheet } from "../../layout/CreateSheet";
import { Avatar } from "../Avatar";
import { goUserProfile } from "../../utils/navigation";

/** 名单一次最多渲染多少行（后端已按 200 截断并给 has_more，这里不再重复限制） */
const ROW_SKELETON_COUNT = 6;

export function LiveViewerSheet({
  channelId,
  preview,
  onClose,
}: {
  channelId: number;
  /** 弹幕 WS 的预览名单（打底用；权威名单到达后替换） */
  preview: LiveViewerItem[];
  onClose: () => void;
}) {
  const me = useAuthStore((s) => s.currentUser?.id ?? null);
  const [viewers, setViewers] = useState<LiveViewerItem[] | null>(null);
  const [count, setCount] = useState<number | null>(null);
  const [hasMore, setHasMore] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [reloadToken, setReloadToken] = useState(0);
  const [elysiaUserId, setElysiaUserId] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    setError(null);
    getLiveChannelViewers(channelId)
      .then((res) => {
        if (cancelled) return;
        setViewers(res.viewers);
        setCount(res.count);
        setHasMore(res.has_more);
      })
      .catch((reason: unknown) => {
        if (cancelled) return;
        setError(
          reason instanceof Error && reason.message
            ? reason.message
            : "暂时读不到在看名单",
        );
      });
    return () => {
      cancelled = true;
    };
  }, [channelId, reloadToken]);

  useEffect(() => {
    let cancelled = false;
    getElysiaProfile()
      .then((profile) => {
        if (!cancelled) setElysiaUserId(profile.enabled ? profile.user.id : null);
      })
      .catch(() => {
        /* 爱莉档案不可用：名单照常展示，仅不标注爱莉光环 */
      });
    return () => {
      cancelled = true;
    };
  }, []);

  const rows = viewers ?? (error ? [] : preview);
  const total = count ?? rows.length;
  const title = useMemo(
    () => (count === null && error ? "正在观看" : `正在观看 · ${total} 人`),
    [count, error, total],
  );

  return (
    <CreateSheet title={title} onClose={onClose} className="live-viewer-sheet-card">
      <div className="live-viewer-sheet-body">
        {error ? (
          <div className="live-viewer-sheet-state" role="alert">
            <p className="live-viewer-sheet-error">{error}</p>
            <button
              type="button"
              className="btn btn-ghost"
              onClick={() => setReloadToken((value) => value + 1)}
            >
              重试
            </button>
          </div>
        ) : viewers === null && rows.length === 0 ? (
          <ul className="live-viewer-list" aria-hidden="true">
            {Array.from({ length: ROW_SKELETON_COUNT }, (_, index) => (
              <li key={index} className="live-viewer-row is-skeleton">
                <span className="skeleton live-viewer-skeleton-avatar" />
                <span className="skeleton live-viewer-skeleton-name" />
              </li>
            ))}
          </ul>
        ) : rows.length === 0 ? (
          <p className="live-viewer-sheet-state">还没有人在看</p>
        ) : (
          <>
            <ul className="live-viewer-list">
              {rows.map((viewer) => (
                <li key={viewer.user_id}>
                  <button
                    type="button"
                    className="live-viewer-row"
                    onClick={() => {
                      goUserProfile(me, viewer.user_id);
                      onClose();
                    }}
                    aria-label={`查看 ${viewer.nickname || "用户"} 的个人主页`}
                  >
                    <Avatar
                      label={viewer.nickname}
                      size={36}
                      online
                      isElysia={elysiaUserId != null && viewer.user_id === elysiaUserId}
                      imageUrl={viewer.avatar || null}
                    />
                    <span className="live-viewer-row-name">{viewer.nickname || "用户"}</span>
                  </button>
                </li>
              ))}
            </ul>
            {hasMore && (
              <p className="live-viewer-sheet-hint">仅显示前 {rows.length} 位</p>
            )}
          </>
        )}
      </div>
    </CreateSheet>
  );
}
