/**
 * CreateFAB —— 右下 56px 主 CTA（design.md §12.5，两形态都有）。
 *
 * 需求：去掉多动作面板气泡——点加号直接开始创建当前场景的对应表单。
 * 动作随当前场景（shellConfig.resolveFabAction，需求文档 §3.5）：
 * - 主页 → GroupCreateDialog（建群，自带浮层）
 * - 语音/直播/帖子/桌游 → 对应表单包在通用 CreateSheet 浮层
 * - 群内 voice/live/games → 归属该群创建
 * 每个界面只出现各自功能，不再有「创建群聊」次级项。
 */
import { useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import { GameRoomCreate } from "../components/boardgame/GameRoomCreate";
import { GroupCreateDialog } from "../components/GroupCreateDialog";
import { IconPlus } from "../components/icons";
import { LiveCreate } from "../components/live/LiveCreate";
import { PostEditor } from "../components/posts/PostEditor";
import { VoiceChannelCreate } from "../components/voice/VoiceChannelCreate";
import type { FabAction } from "./shellConfig";
import { CreateSheet } from "./CreateSheet";

export function CreateFab({ action }: { action: FabAction }) {
  const [open, setOpen] = useState(false);
  const navigate = useNavigate();

  // 场景切换（action 变化）时收起浮层
  useEffect(() => {
    setOpen(false);
  }, [action.key]);

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
  const isGroupCreate = action.handler === "group";

  return (
    <>
      <div className="create-fab-wrap">
        <button
          type="button"
          className="create-fab"
          aria-label={action.label}
          onClick={() => setOpen((v) => !v)}
        >
          <IconPlus width={24} height={24} />
        </button>
      </div>

      {open && isGroupCreate && (
        <GroupCreateDialog onClose={() => setOpen(false)} />
      )}
      {open && isVoiceCreate && (
        <CreateSheet title={action.label} onClose={() => setOpen(false)}>
          <VoiceChannelCreate group={action.groupId} />
        </CreateSheet>
      )}
      {open && isLiveCreate && (
        <CreateSheet title={action.label} onClose={() => setOpen(false)}>
          <LiveCreate onCreated={handleLiveCreated} group={action.groupId} />
        </CreateSheet>
      )}
      {open && isPostCreate && (
        <CreateSheet title={action.label} onClose={() => setOpen(false)}>
          <PostEditor
            group={action.groupId}
            onCreated={(post) => {
              setOpen(false);
              navigate(action.groupId ? `/group/${action.groupId}/posts` : `/posts/${post.id}`);
            }}
          />
        </CreateSheet>
      )}
      {open && isGameCreate && (
        <CreateSheet title={action.label} onClose={() => setOpen(false)}>
          <GameRoomCreate
            group={action.groupId}
            onCreated={() => {
              setOpen(false);
              navigate(action.groupId ? `/group/${action.groupId}/games` : "/games");
            }}
          />
        </CreateSheet>
      )}
    </>
  );
}
