/**
 * LiveOwnerPanel —— 开播控制台资料与开播区（M5-4，文档 §4.5）。
 *
 * 仅 owner 渲染：顶部一条紧凑的资料栏（封面缩略图 + 标题/介绍 + 保存），
 * 开播/下播按钮放在资料区右侧；推流地址与删除频道分别移到视频下方和侧栏。
 */
import { useRef, useState } from "react";
import * as liveApi from "../../api/live";
import { mediaContentUrl, uploadMediaFile, validateAvatarFile } from "../../api/media";
import type { LiveChannelDescriptor } from "../../api/types";
import { useLiveStore } from "../../stores/live";
import { ResourceImage } from "../ResourceImage";

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
  const coverInputRef = useRef<HTMLInputElement>(null);

  const run = async (action: () => Promise<LiveChannelDescriptor>) => {
    setBusy(true);
    setError(null);
    try {
      const updated = await action();
      useLiveStore.getState().setCurrentChannel(updated);
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
      const updated = await liveApi.updateLiveChannel(channel.id, {
        title: nextTitle,
        description: description.trim(),
        cover,
      });
      useLiveStore.getState().setCurrentChannel(updated);
      useLiveStore.getState().upsertChannel(updated);
      setCoverFile(null);
      setCoverPreview(updated.cover || null);
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
          accept="image/png,image/jpeg,image/gif,image/webp"
          onChange={(e) => {
            const file = e.target.files?.[0];
            if (!file) return;
            const invalid = validateAvatarFile(file);
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

      {error && <div className="live-form-error">{error}</div>}
    </div>
  );
}
