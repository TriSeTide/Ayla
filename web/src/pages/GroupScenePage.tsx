/**
 * GroupScenePage —— /group/:id/:scene 群内子场景（voice/live/posts/games/info）。
 *
 * F1 阶段为占位路由：校验 scene 枚举，非法场景回退群聊天；
 * 合法场景渲染占位页并给「返回群聊天」行动，本体由 F3-F7 落地。
 */
import { Link, Navigate, useParams } from "react-router-dom";
import { PlaceholderPage } from "./PlaceholderPage";

const SCENES = {
  voice: { title: "群内语音", step: "F5" },
  live: { title: "群内直播", step: "F4" },
  posts: { title: "群内帖子", step: "F6" },
  games: { title: "群内桌游", step: "F7" },
  info: { title: "群信息", step: "F3" },
} as const;

type SceneKey = keyof typeof SCENES;

export function GroupScenePage() {
  const { id, scene } = useParams<{ id: string; scene: string }>();
  const meta = scene && scene in SCENES ? SCENES[scene as SceneKey] : null;

  if (!meta) {
    return <Navigate to={id ? `/group/${id}` : "/home"} replace />;
  }

  return (
    <PlaceholderPage title={meta.title} step={meta.step} description="群聊场景子界面">
      {id && (
        <Link className="btn btn-ghost" to={`/group/${id}`}>
          返回群聊天
        </Link>
      )}
    </PlaceholderPage>
  );
}
