/**
 * EmojiPackPanel —— 群表情包面板（任务 03）。
 *
 * 交互：
 * - 展示本群表情包网格（群内所有成员可见，点击即作为 emoji 消息发送）；
 * - 加号框：can_upload 时显示（群主/管理员，或群主开启"允许普通成员上传"后的成员），
 *   点它选图（含 GIF 动图）→ 三步上传 kind=emoji → 加入群表情包；
 * - 删除：can_delete（群主/管理员）时悬停表情显示 ×，点击删除；
 * - 包未创建（GET 404）时按空态渲染，加号显示按 myRole 兜底（owner/admin）。
 *
 * 展开方向由父组件控制（宽屏向上弹窗 / 窄屏向下展开），本组件只渲染内容。
 * 发送复用现有 emoji 消息链路（sendMessage type=emoji + media_id），
 * 不引入新消息类型（AGENTS.md：群表情包本质仍是图片/动图消息）。
 */
import { useCallback, useEffect, useRef, useState } from "react";
import { ApiError } from "../../api/client";
import { sendMessage } from "../../hooks/useChat";
import { uploadMediaFile, validateImageFile, mediaContentUrl } from "../../api/media";
import { ResourceImage } from "../ResourceImage";
import {
  addGroupEmojiItem,
  deleteGroupEmojiItem,
  getGroupEmojiPackSummary,
  listGroupEmojiItemsPage,
  type GroupEmojiPackSummaryPayload,
} from "../../api/emoji";
import type { EmojiItem } from "../../api/types";
import { IconClose, IconPlus } from "../icons";
import { useAuthStore } from "../../stores/auth";
import { usePagedMediaList } from "../../hooks/usePagedMediaList";
import { DirectoryLoadMore } from "../DirectoryLoadMore";

interface EmojiPackPanelProps {
  convId: string;
  /** 当前用户在群中的角色（owner/admin/member）；包未创建时用于兜底加号显示 */
  myRole?: string;
  /** 群聊子群归属（可选；不传时消息归默认组） */
  subgroupId?: string | null;
  onClose: () => void;
}

export function EmojiPackPanel({ convId, myRole, subgroupId, onClose }: EmojiPackPanelProps) {
  const userId = useAuthStore((state) => state.currentUser?.id ?? "");
  const scope = `group-emoji:${userId}:${convId}`;
  const currentScope = useRef(scope);
  currentScope.current = scope;
  const metaGeneration = useRef(0);
  const [metadata, setMetadata] = useState<{ scope: string; payload: GroupEmojiPackSummaryPayload | null; loaded: boolean; error: string | null }>({
    scope, payload: null, loaded: false, error: null,
  });
  const metadataCurrent = metadata.scope === scope;
  const payload = metadataCurrent ? metadata.payload : null;
  const metaLoaded = metadataCurrent && metadata.loaded;
  const metaError = metadataCurrent ? metadata.error : null;
  const [uploading, setUploading] = useState(false);
  /** 多选上传进度（"2/3"）；单张上传时为空 */
  const [uploadProgress, setUploadProgress] = useState("");
  const [error, setError] = useState<string | null>(null);
  const fileRef = useRef<HTMLInputElement>(null);

  const canUpload = payload ? payload.can_upload : metaLoaded && !metaError && (myRole === "owner" || myRole === "admin");
  const canDelete = payload?.can_delete ?? false;
  const fetchItems = useCallback((cursor: string | null) => listGroupEmojiItemsPage(convId, { cursor, limit: 30 }), [convId]);
  const pages = usePagedMediaList(`${scope}:${payload?.pack.id ?? "missing"}`, fetchItems, Boolean(payload));
  const items = pages.items;

  const load = useCallback(async () => {
    const generation = ++metaGeneration.current;
    setMetadata((previous) => ({ ...previous, scope, error: null }));
    try {
      const data = await getGroupEmojiPackSummary(convId);
      if (currentScope.current !== scope || generation !== metaGeneration.current) return;
      setMetadata({ scope, payload: data, loaded: true, error: null });
      return data;
    } catch (e) {
      if (currentScope.current !== scope || generation !== metaGeneration.current) return;
      const missing = e instanceof ApiError && e.status === 404 && e.message === "group_pack_not_found";
      setMetadata((previous) => ({ scope, payload: previous.scope === scope ? previous.payload : null,
        loaded: true, error: missing ? null : e instanceof Error ? e.message : "加载群表情包失败" }));
    }
  }, [convId, scope]);

  const refresh = useCallback(async () => {
    const updated = await load();
    if (updated && currentScope.current === scope && updated.pack.id === payload?.pack.id) await pages.refresh();
  }, [load, scope, payload?.pack.id, pages.refresh]);

  useEffect(() => {
    setMetadata({ scope, payload: null, loaded: false, error: null });
    setUploading(false); setUploadProgress(""); setError(null);
    void load();
    return () => { metaGeneration.current += 1; };
  }, [load, scope]);

  /**
   * 选图（支持多选）→ 逐张三步上传 kind=emoji → 加入群表情包 → 刷新。
   * 单张失败不阻塞其余；全部完成后统一刷新列表。
   */
  const handlePick = async (files: FileList | File[]) => {
    const list = Array.from(files);
    if (list.length === 0 || uploading) return;
    const skipped = list.filter((f) => validateImageFile(f) != null).length;
    const valid = list.filter((f) => validateImageFile(f) == null);
    if (skipped > 0) setError(`已跳过 ${skipped} 个非图片文件`);
    if (valid.length === 0) return;
    setUploading(true);
    setError(null);
    let done = 0;
    const errors: string[] = [];
    for (const file of valid) {
      if (currentScope.current !== scope) return;
      try {
        const uploaded = await uploadMediaFile(file, "emoji");
        if (currentScope.current !== scope) return;
        await addGroupEmojiItem(convId, uploaded.media_id);
      } catch (e) {
        errors.push(e instanceof Error ? e.message : "上传失败");
      }
      if (currentScope.current !== scope) return;
      done += 1;
      setUploadProgress(valid.length > 1 ? `${done}/${valid.length}` : "");
    }
    setUploading(false);
    setUploadProgress("");
    if (errors.length > 0) {
      setError(`部分表情上传失败：${errors[0]}`);
    }
    await refresh();
  };

  /**
   * 点击表情 → 直接发送 emoji 消息（复用图片链路，GIF 动图保真）。
   * 发送后不自动收起面板（用户要求：连发多个表情时面板保持打开）。
   */
  const handleSend = (item: EmojiItem) => {
    if (!item.media) return;
    void sendMessage(convId, "", {
      type: "emoji",
      mediaId: item.media.media_id,
    }, subgroupId).catch((reason: unknown) => {
      if (currentScope.current === scope) setError(reason instanceof Error ? reason.message : "发送表情失败");
    });
  };

  const handleDelete = async (item: EmojiItem) => {
    if (!canDelete) return;
    setError(null);
    try {
      await deleteGroupEmojiItem(convId, item.id);
      if (currentScope.current !== scope) return;
      pages.updateItems((rows) => rows.filter((row) => row.id !== item.id));
      await refresh();
    } catch (e) {
      if (currentScope.current === scope) setError(e instanceof Error ? e.message : "删除表情失败");
    }
  };

  return (
    <div className="emoji-pack-panel" role="dialog" aria-label="群表情包">
      <header className="emoji-pack-head">
        <span className="emoji-pack-title">群表情包</span>
        <button type="button" className="icon-btn-32" onClick={onClose} aria-label="关闭表情面板">
          <IconClose width={16} height={16} />
        </button>
      </header>

      {error && (
        <p className="emoji-pack-error" role="alert">{error}</p>
      )}

      <div className="emoji-pack-grid" role="list" aria-label="群表情列表">
        {items.map((item) => (
          <div key={item.id} className="emoji-pack-cell" role="listitem">
            <button
              type="button"
              className="emoji-pack-item"
              onClick={() => handleSend(item)}
              aria-label="发送表情"
              title="点击发送"
            >
              {item.media && (
                <ResourceImage
                  src={mediaContentUrl(item.media.media_id)}
                  alt="群表情"
                  className="emoji-pack-img"
                  loading="lazy"
                  fallback={<span className="emoji-pack-img-fallback" />}
                />
              )}
            </button>
            {canDelete && (
              <button
                type="button"
                className="emoji-pack-remove"
                onClick={() => void handleDelete(item)}
                aria-label="删除表情"
                title="删除表情"
              >
                <IconClose width={10} height={10} />
              </button>
            )}
          </div>
        ))}

        {canUpload && (
          <div className="emoji-pack-cell">
            <button
              type="button"
              className="emoji-pack-add"
              onClick={() => fileRef.current?.click()}
              aria-label="添加群表情"
              title="上传图片/动图到群表情包"
              disabled={uploading}
            >
              {uploading ? (
                <span className="emoji-pack-uploading" role="status">
                  {uploadProgress ? `上传中 ${uploadProgress}` : "上传中…"}
                </span>
              ) : (
                <IconPlus width={20} height={20} />
              )}
            </button>
          </div>
        )}
      </div>

      <DirectoryLoadMore {...pages} loading={!metaLoaded || pages.loading} error={metaError ?? pages.error}
        invalidated={false} refresh={refresh} loadMore={metaError ? refresh : pages.loadMore} retainCompletedSpace={false} />

      {metaLoaded && !metaError && !pages.loading && !pages.error && items.length === 0 && (
        <p className="emoji-pack-empty">
          {canUpload ? "还没有表情，点加号上传" : "群内还没有表情包"}
        </p>
      )}

      <input
        ref={fileRef}
        type="file"
        accept="image/*"
        multiple
        hidden
        onChange={(e) => {
          // 必须先 Array.from 拷贝再清空 value：FileList 是 live 集合，
          // 先清空会让已持有的引用同步变空（真实浏览器行为，jsdom 不模拟）。
          const files = Array.from(e.target.files ?? []);
          e.target.value = "";
          if (files.length > 0) void handlePick(files);
        }}
      />
    </div>
  );
}
