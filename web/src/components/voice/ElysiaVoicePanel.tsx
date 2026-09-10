/**
 * ElysiaVoicePanel —— 爱莉语音面板（M5-3 §4.5，控制面闭环）。
 *
 * - 打开时创建/复用 Voice Live 通话（reused=true 正常接入，不报错）；
 * - 通话状态与转写投影由后端 observer WS 事件驱动（elysia.voice.call.status /
 *   elysia.voice.projected 帧），本面板只消费事件；创建后一次性 poll 对账兜底；
 * - 文本注入：空文本前端拦截；502 → "爱莉侧不可用"；
 * - 结束幂等，重复点击安全；
 * - 主体性铁律：本组件不生成任何爱莉第一人称内容。
 */
import { useEffect, useState } from "react";
import { useElysiaVoice } from "../../hooks/useElysiaVoice";

export function ElysiaVoicePanel() {
  const [open, setOpen] = useState(false);
  const [text, setText] = useState("");
  const {
    call,
    busy,
    isTerminal,
    ensureCall,
    sendText,
    endCall,
  } = useElysiaVoice(open);

  // 打开面板 → 创建/复用通话
  useEffect(() => {
    if (open && !call) void ensureCall();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open]);

  const submit = async () => {
    const ok = await sendText(text);
    if (ok) setText("");
  };

  if (!open) {
    return (
      <section className="elysia-voice-panel collapsed">
        <button type="button" className="btn btn-glow" onClick={() => setOpen(true)}>
          爱莉语音
        </button>
      </section>
    );
  }

  return (
    <section className="elysia-voice-panel">
      <header className="elysia-voice-head">
        <h3 className="voice-panel-title">爱莉语音</h3>
        <button type="button" className="msg-action-btn" onClick={() => setOpen(false)}>
          收起
        </button>
      </header>

      {!call ? (
        <div className="voice-list-empty">{busy ? "接入中…" : "等待接入"}</div>
      ) : (
        <>
          {!isTerminal && (
            <div className="elysia-voice-input">
              <input
                className="voice-create-input"
                placeholder="对爱莉说的话（文本注入，爱莉发言在聊天页查看）"
                value={text}
                maxLength={2000}
                onChange={(e) => setText(e.target.value)}
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
                发送
              </button>
            </div>
          )}

          <div className="elysia-voice-actions">
            {isTerminal ? (
              <button
                type="button"
                className="btn btn-primary"
                disabled={busy}
                onClick={() => void ensureCall()}
              >
                重新发起
              </button>
            ) : (
              <button
                type="button"
                className="btn voice-leave-btn"
                disabled={busy}
                onClick={() => void endCall()}
              >
                结束通话
              </button>
            )}
          </div>
        </>
      )}
    </section>
  );
}
