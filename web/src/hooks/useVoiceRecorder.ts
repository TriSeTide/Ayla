/**
 * useVoiceRecorder —— 浏览器麦克风录音（M5 语音消息发送）。
 *
 * 基于 MediaRecorder：
 * - 录音格式：优先 audio/webm;codecs=opus，其次浏览器默认音频格式；
 * - 点击式：start() 开始 → stop() 停止并 resolve 录音结果；
 * - 导出 formatDuration 供 UI 显示已录制时长；
 * - 权限失败 / 不支持的浏览器如实报错，不伪造录音成功。
 */
import { useCallback, useEffect, useRef, useState } from "react";

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

type RecorderPhase = "idle" | "starting" | "recording" | "stopping";
interface RecorderOwner {
  stream: MediaStream;
  recorder: MediaRecorder;
  chunks: Blob[];
  mimeType: string;
  startedAt: number;
  timer: number | null;
  deadline: number | null;
  discarded: boolean;
  stopPromise: Promise<VoiceRecording | null> | null;
  resolveStop: ((value: VoiceRecording | null) => void) | null;
}

/** Release every owned track even if one browser track reports a stop error. */
function releaseTracks(stream: MediaStream): void {
  for (const track of stream.getTracks()) {
    try { track.stop(); } catch { /* Continue releasing the remaining owned tracks. */ }
  }
}

export function useVoiceRecorder() {
  const [phase, setPhase] = useState<RecorderPhase>("idle");
  const [error, setError] = useState<string | null>(null);
  const [elapsed, setElapsed] = useState(0);
  const phaseRef = useRef<RecorderPhase>("idle");
  const ownerRef = useRef<RecorderOwner | null>(null);
  const active = useRef(true);
  const requestRevision = useRef(0);

  const movePhase = useCallback((next: RecorderPhase) => {
    phaseRef.current = next;
    if (active.current) setPhase(next);
  }, []);

  const finish = useCallback((owner: RecorderOwner, result: VoiceRecording | null) => {
    if (ownerRef.current !== owner) return;
    ownerRef.current = null;
    if (owner.timer != null) window.clearInterval(owner.timer);
    if (owner.deadline != null) window.clearTimeout(owner.deadline);
    owner.recorder.ondataavailable = null;
    owner.recorder.onstop = null;
    owner.recorder.onerror = null;
    releaseTracks(owner.stream);
    owner.chunks = [];
    movePhase("idle");
    if (active.current) setElapsed(0);
    owner.resolveStop?.(result);
    owner.resolveStop = null;
  }, [movePhase]);

  const fail = useCallback((owner: RecorderOwner, message: string) => {
    if (ownerRef.current !== owner) return;
    if (active.current) setError(message);
    finish(owner, null);
  }, [finish]);

  useEffect(() => {
    active.current = true;
    return () => {
      active.current = false;
      requestRevision.current += 1;
      const owner = ownerRef.current;
      if (owner) {
        // Detach callbacks before stopping: unmount may never produce a usable
        // recording, and an eventual event must not settle another owner's work.
        finish(owner, null);
        try { if (owner.recorder.state !== "inactive") owner.recorder.stop(); } catch { /* Owned tracks were already stopped. */ }
      } else movePhase("idle");
    };
  }, [finish, movePhase]);

  /** Permission, constructor and start failures are visible state, never an unhandled rejection. */
  const start = useCallback(async (): Promise<void> => {
    if (!active.current || phaseRef.current !== "idle") return;
    if (!isVoiceRecordingSupported()) { setError("当前浏览器不支持录音"); return; }
    const request = ++requestRevision.current;
    movePhase("starting");
    setError(null);
    setElapsed(0);
    let acquired: MediaStream | null = null;
    try {
      acquired = await navigator.mediaDevices.getUserMedia({ audio: true });
      if (!active.current || request !== requestRevision.current) {
        releaseTracks(acquired);
        return;
      }
      const mime = pickMimeType();
      const recorder = mime ? new MediaRecorder(acquired, { mimeType: mime }) : new MediaRecorder(acquired);
      const owner: RecorderOwner = { stream: acquired, recorder, chunks: [], mimeType: recorder.mimeType || mime || "audio/webm",
        startedAt: Date.now(), timer: null, deadline: null, discarded: false, stopPromise: null, resolveStop: null };
      ownerRef.current = owner;
      recorder.ondataavailable = (event) => {
        if (ownerRef.current === owner && event.data?.size > 0) owner.chunks.push(event.data);
      };
      recorder.onerror = () => fail(owner, "录音失败，请重试");
      recorder.onstop = () => {
        if (ownerRef.current !== owner) return;
        if (phaseRef.current !== "stopping") { fail(owner, "录音意外停止，请重试"); return; }
        const result = owner.discarded ? null : { blob: new Blob(owner.chunks, { type: owner.mimeType }),
          duration: Math.max(0.1, (Date.now() - owner.startedAt) / 1000), mimeType: owner.mimeType };
        finish(owner, result);
      };
      recorder.start();
      if (ownerRef.current !== owner) return;
      movePhase("recording");
      owner.timer = window.setInterval(() => {
        if (ownerRef.current === owner && active.current) setElapsed((Date.now() - owner.startedAt) / 1000);
      }, 250);
    } catch (cause) {
      if (!active.current || request !== requestRevision.current) { if (acquired) releaseTracks(acquired); return; }
      const owner = ownerRef.current;
      if (owner) finish(owner, null);
      else { if (acquired) releaseTracks(acquired); movePhase("idle"); }
      setError(cause instanceof DOMException && cause.name === "NotAllowedError" ? "麦克风权限被拒绝" : "无法启动录音，请重试");
    }
  }, [fail, finish, movePhase]);

  /** A stop operation has one promise and a finite deadline; every outcome releases tracks. */
  const stop = useCallback((): Promise<VoiceRecording | null> => {
    if (phaseRef.current === "starting") {
      requestRevision.current += 1;
      movePhase("idle");
      return Promise.resolve(null);
    }
    const owner = ownerRef.current;
    if (!owner) return Promise.resolve(null);
    if (owner.stopPromise) return owner.stopPromise;
    movePhase("stopping");
    const promise = new Promise<VoiceRecording | null>((resolve) => { owner.resolveStop = resolve; });
    owner.stopPromise = promise;
    owner.deadline = window.setTimeout(() => fail(owner, "停止录音超时，请重试"), 5000);
    try { owner.recorder.stop(); }
    catch { fail(owner, "停止录音失败，请重试"); }
    return promise;
  }, [fail, movePhase]);

  const cancel = useCallback(() => {
    const owner = ownerRef.current;
    if (owner) owner.discarded = true;
    void stop();
  }, [stop]);

  return { recording: phase === "recording" || phase === "stopping", starting: phase === "starting", stopping: phase === "stopping",
    error, elapsed, start, stop, cancel, clearError: () => setError(null) };
}
