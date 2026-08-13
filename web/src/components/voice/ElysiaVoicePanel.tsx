/**
 * ElysiaVoicePanel —— 爱莉语音面板（M5-3 §4.5，控制面闭环）。
 *
 * - 打开时创建/复用 Voice Live 通话（reused=true 正常接入，不报错）；
 * - 状态每 5s 轮询；转写投影每 10s 触发（语音页只显示"已投影 N 条"中性计数，
 *   爱莉发言在聊天链渲染——单一渲染源，不双写）；
 * - 文本注入：空文本前端拦截；502 → "爱莉侧不可用"；
 * - 结束幂等，重复点击安全；
 * - 主体性铁律：本组件不生成任何爱莉第一人称内容；状态只渲染中性技术标签。
 */
import { useEffect, useState } from "react";
import { useElysiaVoice } from "../../hooks/useElysiaVoice";

/** 爱莉通话 state → 中性技术标签 */
export function callStateLabel(state: string): string {
  switch (state) {
    case "connecting":
      return "连接中";
    case "active":
    case "connected":
      return "通话中";
    case "ended":
      return "已结束";
    case "failed":
      return "连接失败";
    default:
      return state;
  }
}

export function ElysiaVoicePanel() {
  const [open, setOpen] = useState(false);
  const [text, setText] = useState("");
  const {
    call,
    busy,
    error,
    reused,
    projectedTotal,
    isTerminal,
    clearError,
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

      {error && (
        <div className="chat-notice" role="alert" onClick={clearError}>
          {error}（点击关闭）
        </div>
      )}

      {!call ? (
        <div className="voice-list-empty">{busy ? "接入中…" : "等待接入"}</div>
      ) : (
        <>
          <div className="elysia-voice-status">
            <span className={`status-dot ${call.connected ? "online" : "offline"}`} />
            {callStateLabel(call.state)}
            {reused && <span className="voice-ws-state"> · 已接入进行中的通话</span>}
            <span className="voice-ws-state"> · 已投影 {projectedTotal} 条到聊天</span>
          </div>

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
