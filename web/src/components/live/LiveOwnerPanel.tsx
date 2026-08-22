/**
 * LiveOwnerPanel —— 开播控制台资料与开播区（M5-4，文档 §4.5）。
 *
 * 仅 owner 渲染：顶部一条紧凑的资料栏（封面缩略图 + 标题/介绍 + 保存），
 * 开播/下播按钮放在资料区右侧；推流地址与删除频道分别移到视频下方和侧栏。
 */
import { useRef, useState } from "react";
import * as liveApi from "../../api/live";
import { mediaContentUrl, uploadMediaFile, validateImageFile } from "../../api/media";
import type { LiveChannelDescriptor } from "../../api/types";
import { useLiveStore } from "../../stores/live";
import { useAuthStore } from "../../stores/auth";
import { useSessionActivityStore } from "../../stores/sessionActivity";
import { ResourceImage } from "../ResourceImage";
import { VisibilitySelector, type VisibilitySelection } from "../VisibilitySelector";

export function LiveOwnerPanel({
  channel,
}: {
  channel: LiveChannelDescriptor;
}) {
  const [savingSettings, setSavingSettings] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [title, setTitle] = useState(channel.title);
  const [description, setDescription] = useState(channel.description ?? "");
  const [coverFile, setCoverFile] = useState<File | null>(null);
  const [coverPreview, setCoverPreview] = useState<string | null>(channel.cover || null);
  // 将后端单值转换为多选格式
  const hasGroups = (channel.allowed_group_ids?.length ?? 0) > 0;
  const initialVisibility: VisibilitySelection = {
    public: channel.visibility === "public",
    friends: channel.visibility === "friends",
    group: channel.visibility === "group" || hasGroups,
  };
  const [visibility, setVisibility] = useState<VisibilitySelection>(initialVisibility);
  const [selectedGroupIds, setSelectedGroupIds] = useState<string[]>(channel.allowed_group_ids ?? []);
  const coverInputRef = useRef<HTMLInputElement>(null);

  const run = async (action: () => Promise<LiveChannelDescriptor>) => {
    setBusy(true);
    setError(null);
    try {
      const updated = await action();
      useLiveStore.getState().setCurrentChannel(updated);
      const active = updated.status === "live";
      useAuthStore.getState().setMediaActivity({
        kind: "live",
        active,
        roomId: active ? updated.id : null,
      });
      if (active) {
        const current = useSessionActivityStore.getState().liveSession;
        useSessionActivityStore.getState().upsert({
          kind: "live",
          sessionId: String(updated.id),
          sourceRoute: current?.sourceRoute ?? window.location.pathname,
          owner: updated.owner_id ?? null,
          title: updated.title,
          status: "connected",
          lastError: null,
        });
      } else {
        useSessionActivityStore.getState().clear("live", "idle");
      }
      useLiveStore.getState().upsertChannel(updated);
    } catch (e) {
      setError(e instanceof Error ? e.message : "操作失败");
    } finally {
      setBusy(false);
    }
  };

  const saveSettings = async () => {
    const nextTitle = title.trim();
    if (!nextTitle) {
      setError("标题不能为空");
      return;
    }
    setSavingSettings(true);
    setError(null);
    try {
      let cover = channel.cover ?? "";
      if (coverFile) {
        const uploaded = await uploadMediaFile(coverFile, "image");
        cover = mediaContentUrl(uploaded.media_id);
      }
      // 将多选转换为后端格式
      const backendVisibility = visibility.public ? "public" : visibility.friends ? "friends" : "group";
      const updated = await liveApi.updateLiveChannel(channel.id, {
        title: nextTitle,
        description: description.trim(),
        cover,
        visibility: backendVisibility,
        allowed_group_ids: selectedGroupIds,
      });
      useLiveStore.getState().setCurrentChannel(updated);
      useLiveStore.getState().upsertChannel(updated);
      setCoverFile(null);
      setCoverPreview(updated.cover || null);
      // 用后端回显刷新可见范围（后端可能规范化 allowed_group_ids）
      const refreshedVisibility: VisibilitySelection = {
        public: updated.visibility === "public",
        friends: updated.visibility === "friends" || (updated.allowed_group_ids?.length ?? 0) > 0,
        group: (updated.allowed_group_ids?.length ?? 0) > 0,
      };
      setVisibility(refreshedVisibility);
      setSelectedGroupIds(updated.allowed_group_ids ?? []);
    } catch (e) {
      setError(e instanceof Error ? e.message : "保存直播间资料失败");
    } finally {
      setSavingSettings(false);
    }
  };

  return (
    <div className="live-owner-panel">
      <div className="live-owner-settings">
        {/* 封面缩略图（点击更换） */}
        <button
          type="button"
          className="live-cover-picker"
          onClick={() => coverInputRef.current?.click()}
          aria-label={coverPreview ? "更换直播间封面" : "设置直播间封面"}
        >
          {coverPreview ? (
            <ResourceImage src={coverPreview} alt="当前直播间封面" className="live-cover-preview-img" />
          ) : (
            <span className="live-cover-empty">封面</span>
          )}
        </button>
        <input
          ref={coverInputRef}
          className="visually-hidden"
          type="file"
          accept="image/*"
          onChange={(e) => {
            const file = e.target.files?.[0];
            if (!file) return;
            const invalid = validateImageFile(file);
            if (invalid) {
              setError(invalid);
              return;
            }
            setError(null);
            setCoverFile(file);
            setCoverPreview(URL.createObjectURL(file));
          }}
        />

        {/* 标题 + 介绍（同一行） */}
        <div className="live-owner-fields">
          <input
            className="field live-title-input"
            value={title}
            maxLength={128}
            placeholder="直播间标题"
            aria-label="直播间标题"
            onChange={(e) => setTitle(e.target.value)}
          />
          <input
            className="field live-desc-input"
            value={description}
            maxLength={2000}
            placeholder="直播间介绍（可选）"
            aria-label="直播间介绍"
            onChange={(e) => setDescription(e.target.value)}
          />
        </div>

        {/* 按钮组：开播/下播 + 保存 */}
        <div className="live-owner-start">
          {channel.status !== "live" ? (
            <button
              type="button"
              className="btn btn-glow live-owner-start-btn"
              disabled={busy}
              onClick={() => void run(() => liveApi.startLiveChannel(channel.id))}
            >
              开播
            </button>
          ) : (
            <button
              type="button"
              className="btn live-owner-start-btn"
              disabled={busy}
              onClick={() => void run(() => liveApi.stopLiveChannel(channel.id))}
            >
              下播
            </button>
          )}
          <button
            type="button"
            className="msg-action-btn"
            disabled={savingSettings || busy}
            onClick={() => void saveSettings()}
          >
            {savingSettings ? "保存中…" : "保存"}
          </button>
        </div>
      </div>

      {/* 可见范围：公开 / 好友可见 / 指定群可见（群内创建的直播间锁定为群可见） */}
      <div className="live-owner-visibility">
        <VisibilitySelector
          value={visibility}
          onChange={setVisibility}
          selectedGroupIds={selectedGroupIds}
          onSelectedGroupIdsChange={setSelectedGroupIds}
          initialGroupId={channel.group}
        />
      </div>

      {error && <div className="live-form-error">{error}</div>}
    </div>
  );
}
