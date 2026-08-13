/**
 * DanmakuInput —— 弹幕输入（M5-4，文档 §4.4）。
 *
 * 长度校验（前端拦截空文本与 >200 字符）；发送走 REST POST，
 * 成功后不乐观插入（等 WS 回帧渲染，单一数据流）；慢网络下显示"发送中"态。
 */
import { useState } from "react";
import { DANMAKU_MAX_LENGTH } from "../../hooks/useDanmaku";

export function DanmakuInput({
  sending,
  error,
  onSend,
}: {
  sending: boolean;
  error: string | null;
  onSend: (content: string) => Promise<boolean>;
}) {
  const [text, setText] = useState("");

  const submit = async () => {
    const ok = await onSend(text);
    if (ok) setText("");
  };

  return (
    <div className="danmaku-input-area">
      <div className="danmaku-input-row">
        <input
          className="danmaku-input"
          placeholder="发条弹幕吧"
          value={text}
          maxLength={DANMAKU_MAX_LENGTH * 2}
          disabled={sending}
          onChange={(e) => setText(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter" && !e.nativeEvent.isComposing) void submit();
          }}
        />
        <button
          type="button"
          className="btn btn-glow"
          disabled={sending || !text.trim()}
          onClick={() => void submit()}
        >
          {sending ? "发送中…" : "发送"}
        </button>
      </div>
      <div className="danmaku-input-meta">
        {error ? (
          <span className="live-form-error">{error}</span>
        ) : (
          <span className="danmaku-counter">
            {text.trim().length}/{DANMAKU_MAX_LENGTH}
          </span>
        )}
      </div>
    </div>
  );
}
