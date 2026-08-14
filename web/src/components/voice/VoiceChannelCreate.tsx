/**
 * VoiceChannelCreate —— 建语音频道（M5-3 §1）。空名称前端拦截不发。
 */
import { useState } from "react";
import * as voiceApi from "../../api/voice";
import { useVoiceStore } from "../../stores/voice";

export function VoiceChannelCreate({
  group,
}: {
  /** 群内创建时归属的群 id（一级 tab 创建为 null，R-F2） */
  group?: string | null;
}) {
  const [name, setName] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const submit = async () => {
    const trimmed = name.trim();
    if (!trimmed) {
      setError("频道名称不能为空");
      return;
    }
    setBusy(true);
    setError(null);
    try {
      const ch = await voiceApi.createVoiceChannel(trimmed, group);
      const store = useVoiceStore.getState();
      store.setChannels([{ ...ch, mine: false }, ...store.channels]);
      setName("");
    } catch (e) {
      setError(e instanceof Error ? e.message : "创建失败");
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="voice-channel-create">
      <input
        className="voice-create-input"
        placeholder="新语音频道名称"
        value={name}
        maxLength={64}
        onChange={(e) => setName(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Enter") void submit();
        }}
      />
      <button
        type="button"
        className="btn btn-primary"
        disabled={busy}
        onClick={() => void submit()}
      >
        建频道
      </button>
      {error && <span className="voice-create-error">{error}</span>}
    </div>
  );
}
