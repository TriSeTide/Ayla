/**
 * useVoiceRecorder —— 浏览器麦克风录音（M5 语音消息发送）。
 *
 * 基于 MediaRecorder：
 * - 录音格式：优先 audio/webm;codecs=opus，其次浏览器默认音频格式；
 * - 点击式：start() 开始 → stop() 停止并 resolve 录音结果；
 * - 导出 formatDuration 供 UI 显示已录制时长；
 * - 权限失败 / 不支持的浏览器如实报错，不伪造录音成功。
 */
import { useEffect, useRef, useState } from "react";

export interface VoiceRecording {
  /** 录音 Blob（audio/webm 等浏览器默认格式） */
  blob: Blob;
  /** 录音时长（秒） */
  duration: number;
  /** 实际录制的 MIME 类型 */
  mimeType: string;
}

/** 是否支持 MediaRecorder + getUserMedia（不支持时输入框隐藏录音入口） */
export function isVoiceRecordingSupported(): boolean {
  return (
    typeof navigator !== "undefined" &&
    typeof navigator.mediaDevices?.getUserMedia === "function" &&
    typeof window !== "undefined" &&
    typeof window.MediaRecorder !== "undefined"
  );
}

/** 时长 → m:ss（录音计时 / 语音消息展示共用） */
export function formatDuration(totalSeconds: number): string {
  const s = Math.max(0, Math.round(totalSeconds));
  const m = Math.floor(s / 60);
  return `${m}:${(s % 60).toString().padStart(2, "0")}`;
}

function pickMimeType(): string {
  const candidates = ["audio/webm;codecs=opus", "audio/webm", "audio/mp4"];
  for (const c of candidates) {
    if (typeof window !== "undefined" && window.MediaRecorder && window.MediaRecorder.isTypeSupported(c)) {
      return c;
    }
  }
  return "";
}

export function useVoiceRecorder() {
  const [recording, setRecording] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [elapsed, setElapsed] = useState(0);
  const recorderRef = useRef<MediaRecorder | null>(null);
  const streamRef = useRef<MediaStream | null>(null);
  const chunksRef = useRef<Blob[]>([]);
  const mimeRef = useRef<string>("");
  const startedAtRef = useRef<number>(0);
  const timerRef = useRef<number | null>(null);

  // 卸载时清理资源
  useEffect(() => {
    return () => {
      if (timerRef.current != null) window.clearInterval(timerRef.current);
      recorderRef.current?.state !== "inactive" && recorderRef.current?.stop();
      streamRef.current?.getTracks().forEach((t) => t.stop());
    };
  }, []);

  /** 开始录音：请求麦克风 → 启动 MediaRecorder → 计时。 */
  const start = async (): Promise<void> => {
    if (recording) return;
    setError(null);
    setElapsed(0);
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      streamRef.current = stream;
      const mime = pickMimeType();
      const recorder = mime
        ? new MediaRecorder(stream, { mimeType: mime })
        : new MediaRecorder(stream);
      mimeRef.current = recorder.mimeType || mime || "audio/webm";
      chunksRef.current = [];
      recorder.ondataavailable = (e) => {
        if (e.data && e.data.size > 0) chunksRef.current.push(e.data);
      };
      recorderRef.current = recorder;
      startedAtRef.current = Date.now();
      recorder.start();
      setRecording(true);
      timerRef.current = window.setInterval(() => {
        setElapsed((Date.now() - startedAtRef.current) / 1000);
      }, 250);
    } catch (err) {
      streamRef.current?.getTracks().forEach((t) => t.stop());
      streamRef.current = null;
      setError(
        err instanceof DOMException && err.name === "NotAllowedError"
          ? "麦克风权限被拒绝"
          : "无法访问麦克风",
      );
      throw err;
    }
  };

  /** 停止录音：resolve 录音结果；未在录音时 resolve null。 */
  const stop = (): Promise<VoiceRecording | null> => {
    return new Promise((resolve) => {
      const recorder = recorderRef.current;
      if (!recorder || recorder.state === "inactive") {
        resolve(null);
        return;
      }
      const duration = (Date.now() - startedAtRef.current) / 1000;
      recorder.onstop = () => {
        if (timerRef.current != null) {
          window.clearInterval(timerRef.current);
          timerRef.current = null;
        }
        setRecording(false);
        setElapsed(0);
        streamRef.current?.getTracks().forEach((t) => t.stop());
        streamRef.current = null;
        recorderRef.current = null;
        const blob = new Blob(chunksRef.current, { type: mimeRef.current });
        chunksRef.current = [];
        resolve({
          blob,
          duration: Math.max(0.1, duration),
          mimeType: mimeRef.current,
        });
      };
      // 静音片段防抖：时长过短仍保留（由调用方决定是否发送）
      recorder.stop();
    });
  };

  /** 放弃本次录音（不发送）：停止并清理。 */
  const cancel = (): void => {
    const recorder = recorderRef.current;
    if (!recorder || recorder.state === "inactive") return;
    recorder.onstop = () => {
      if (timerRef.current != null) {
        window.clearInterval(timerRef.current);
        timerRef.current = null;
      }
      setRecording(false);
      setElapsed(0);
      streamRef.current?.getTracks().forEach((t) => t.stop());
      streamRef.current = null;
      recorderRef.current = null;
      chunksRef.current = [];
    };
    recorder.stop();
  };

  return { recording, error, elapsed, start, stop, cancel, clearError: () => setError(null) };
}
