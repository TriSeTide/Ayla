/**
 * CreateFAB —— 右下 56px 主 CTA（design.md §12.5，两形态都有）。
 *
 * 动作随当前场景（shellConfig.resolveFabAction，需求文档 §3.5）；
 * 面板项 = 当前场景创建动作 + 次级「创建群聊」（布局文档 §4：全场景可达）。
 *
 * F1 阶段只接线"弹面板"机制（开发步骤 F1 要点）：
 * - 场景创建动作点击后提示该表单落地的步骤（F2-F7 逐一步替换为真表单）；
 * - 「创建群聊」为真实动作：跳转 /chat（M5-1 会话页侧栏已有建群入口）。
 *
 * 窄屏 = 底部上滑面板（圆角 24px 上沿 + 背景压暗）；宽屏 = FAB 上方浮层。
 */
import { useEffect, useRef, useState } from "react";
import { useNavigate } from "react-router-dom";
import { GameRoomCreate } from "../components/boardgame/GameRoomCreate";
import { IconClose, IconPlus, IconUsers } from "../components/icons";
import { LiveCreate } from "../components/live/LiveCreate";
import { PostEditor } from "../components/posts/PostEditor";
import { VoiceChannelCreate } from "../components/voice/VoiceChannelCreate";
import type { FabAction } from "./shellConfig";

export function CreateFab({ action }: { action: FabAction }) {
  const [open, setOpen] = useState(false);
  const [hint, setHint] = useState<string | null>(null);
  const navigate = useNavigate();
  const panelRef = useRef<HTMLDivElement>(null);

  // 场景切换（action 变化）时收起面板、清提示
  useEffect(() => {
    setOpen(false);
    setHint(null);
  }, [action.key]);

  // ESC 关闭
  useEffect(() => {
    if (!open) return;
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === "Escape") setOpen(false);
    };
    document.addEventListener("keydown", onKeyDown);
    return () => document.removeEventListener("keydown", onKeyDown);
  }, [open]);

  // 直播创建（F4 已落地）：群内归属该群，一级 tab 公开
  const handleLiveCreated = (channel: { id: number }) => {
    setOpen(false);
    if (action.groupId) {
      navigate(`/group/${action.groupId}/live`);
    } else {
      navigate(`/live/${channel.id}`);
    }
  };

  const isLiveCreate = action.handler === "live";
  const isVoiceCreate = action.handler === "voice";
  const isPostCreate = action.handler === "post";
  const isGameCreate = action.handler === "game";

  return (
    <>
      {open && (
        <div className="fab-mask" onClick={() => setOpen(false)} aria-hidden="true" />
      )}
      <div className="create-fab-wrap" ref={panelRef}>
        {open && (
          <div className="fab-panel" role="menu" aria-label="创建面板">
            {isLiveCreate ? (
              <LiveCreate onCreated={handleLiveCreated} group={action.groupId} />
            ) : isVoiceCreate ? (
              <VoiceChannelCreate group={action.groupId} />
            ) : isPostCreate ? (
              <PostEditor
                group={action.groupId}
                onCreated={(post) => {
                  setOpen(false);
                  navigate(action.groupId ? `/group/${action.groupId}/posts` : `/posts/${post.id}`);
                }}
              />
            ) : isGameCreate ? (
              <GameRoomCreate
                group={action.groupId}
                onCreated={() => {
                  setOpen(false);
                  navigate(action.groupId ? `/group/${action.groupId}/games` : "/games");
                }}
              />
            ) : (
              <button
                type="button"
                role="menuitem"
                className="fab-panel-item"
                onClick={() =>
                  setHint(`「${action.label}」表单将随 ${action.plannedStep} 步骤落地`)
                }
              >
                <IconPlus width={18} height={18} />
                <span>{action.label}</span>
              </button>
            )}
            {action.key !== "create-group" && (
              <button
                type="button"
                role="menuitem"
                className="fab-panel-item"
                onClick={() => {
                  setOpen(false);
                  navigate("/chat");
                }}
              >
                <IconUsers width={18} height={18} />
                <span>创建群聊</span>
              </button>
            )}
            {hint && (
              <p className="fab-panel-hint" role="status">
                {hint}
              </p>
            )}
          </div>
        )}
        <button
          type="button"
          className="create-fab"
          aria-label={open ? "关闭创建面板" : action.label}
          aria-expanded={open}
          onClick={() => {
            setOpen((v) => !v);
            setHint(null);
          }}
        >
          {open ? <IconClose width={24} height={24} /> : <IconPlus width={24} height={24} />}
        </button>
      </div>
    </>
  );
}
