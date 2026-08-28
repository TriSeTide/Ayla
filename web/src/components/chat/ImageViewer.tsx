/**
 * ImageViewer —— 聊天图片/视频全屏查看器（QQ 式点击打开 + 可保存）。
 *
 * 视觉（design.md §6 模态层级）：indigo 压暗遮罩 + 玻璃质感关闭钮，
 * 原图/视频 object-fit contain 居中；底部玻璃胶囊操作条（保存 + 多图计数）。
 * 行为：ESC / 点击遮罩空白关闭；打开即 focus 关闭按钮（键盘可达）；←/→ 或
 * 多条目内容区横滑（跟手 + 边缘阻尼 + 过 1/3 或速度达标切换吸附，方案 §3.2）切换多图；
 * 单条目横滑不切图（保留既有关闭交互）；多条目松手判定统一走 useSwipeCommit：
 * 净位移 ≥ 容器 1/3，或同向甩动 ≥300px/s 且净位移 ≥40px，交叉轴占优让位，pointercancel 只回弹。
 * 图片经 ResourceImage 加载（短时签名 URL 直连，渐进解码秒开）；
 * 视频渲染 <video controls autoPlay>（签名 URL 原生 Range 流式播放，
 * 即点即播不再全量下载）；保存用签名 URL + a[download]（同源生效，
 * 浏览器原生下载流式写盘）。
 * 乐观消息（未上传）的本地预览（localUrl）只展示，不可保存。
 */
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { AnimatePresence, motion } from "framer-motion";
import type { PanHandler, PanInfo } from "framer-motion";
import type { MediaDescriptor } from "../../api/types";
import { getSignedMediaUrl, mediaContentUrl, takeWarmVideoElement } from "../../api/media";
import { resolveSwipeCommit } from "../../hooks/useSwipeCommit";
import { useTouchAxisGuard } from "../../hooks/useTouchAxisGuard";
import { ResourceImage } from "../ResourceImage";
import { IconClose, IconDownload } from "../icons";

/** 查看器条目：服务端媒体或乐观本地预览 */
export interface ViewerItem {
  media: MediaDescriptor | null;
  /** 乐观消息本地预览（未上传；只展示不保存） */
  localUrl?: string;
  /** 本地预览为视频（服务端媒体按 media.kind 判断） */
  isVideo?: boolean;
  alt: string;
}

/** 横滑切图（方案 §3.2）：等价 tokens.css --ease-out / --ease-in（framer-motion ease 需 cubic-bezier 元组） */
const EASE_OUT: [number, number, number, number] = [0.22, 0.61, 0.36, 1];
const EASE_IN: [number, number, number, number] = [0.4, 0, 1, 1];
/** 切换滑入/滑出时长 250ms（design.md §7：150–300ms） */
const SWIPE_SLIDE_DURATION = 0.25;
/** drag 约束（钉在原点，配合 dragElastic 提供边缘阻尼 + 松手回弹） */
const DRAG_CONSTRAINTS = { left: 0, right: 0 };
/** 跟手弹性：0.8 = 80% 跟手 + 20% 边缘阻尼（接近 1:1，避免拖过头） */
const DRAG_ELASTIC = 0.8;

function prefersReducedMotion(): boolean {
  return (
    typeof window !== "undefined" &&
    typeof window.matchMedia === "function" &&
    window.matchMedia("(prefers-reduced-motion: reduce)").matches
  );
}

/** MIME → 下载扩展名 */
function extFromMime(mime: string): string {
  const table: Record<string, string> = {
    "image/png": "png",
    "image/jpeg": "jpg",
    "image/jpg": "jpg",
    "image/pjpeg": "jpg",
    "image/gif": "gif",
    "image/webp": "webp",
    "image/avif": "avif",
    "image/heic": "heic",
    "image/heif": "heif",
    "image/bmp": "bmp",
    "image/x-ms-bmp": "bmp",
    "image/tiff": "tiff",
    "image/x-icon": "ico",
    "image/vnd.microsoft.icon": "ico",
    "image/svg+xml": "svg",
    "video/mp4": "mp4",
    "video/webm": "webm",
    "video/quicktime": "mov",
    "video/x-m4v": "m4v",
    "video/x-matroska": "mkv",
    "video/3gpp": "3gp",
    "video/3gpp2": "3g2",
  };
  return table[mime] ?? (mime.startsWith("video/") ? "mp4" : "png");
}

/** 触发浏览器保存（签名 URL + a[download]，同源生效；原生下载流式写盘零内存） */
async function downloadMedia(media: MediaDescriptor): Promise<void> {
  const url = await getSignedMediaUrl(media.media_id);
  const a = document.createElement("a");
  a.href = url;
  const prefix = media.kind === "video" ? "ayla-video" : "ayla-image";
  a.download = `${prefix}-${media.media_id.slice(0, 8)}.${extFromMime(media.mime_type)}`;
  document.body.appendChild(a);
  a.click();
  a.remove();
}

/**
 * 查看器内视频播放器：签名 URL 直连，原生 Range 流式播放（即点即播）。
 *
 * 秒开链路（三层）：
 * 1. 预热接管：hover/tap 或详情页挂载时已创建 detached <video> 开始缓冲
 *    （warmVideoPool），本组件挂载时优先接管该元素——缓冲与点击决策时间窗
 *    重叠，点开即播；
 * 2. 无预热兜底：签名后自建 <video preload=auto>；
 * 3. 画面全程无黑块：有海报帧时等待期显示海报 <img>，<video poster> 挂同一
 *    张海报（缓冲中与起播前画面同帧无跳变）；autoPlay 被浏览器策略拦截时
 *    停在海报帧而非黑屏。
 * video 元素为命令式管理（React 外挂载），卸载时显式释放资源。
 */
function VideoPlayer({ media }: { media: MediaDescriptor }) {
  const hostRef = useRef<HTMLDivElement | null>(null);
  const [elementReady, setElementReady] = useState(false);
  const [thumbUrl, setThumbUrl] = useState<string | null>(null);
  const [failed, setFailed] = useState(false);
  const hasPoster = Boolean(media.thumbnail);
  const thumbUrlRef = useRef<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    getSignedMediaUrl(media.media_id, "thumb")
      .then((url) => {
        if (cancelled) return;
        thumbUrlRef.current = url;
        setThumbUrl(url);
      })
      .catch(() => {});
    return () => {
      cancelled = true;
    };
  }, [hasPoster, media.media_id]);

  useEffect(() => {
    let cancelled = false;
    let el: HTMLVideoElement | null = null;
    const mount = async () => {
      try {
        const url = await getSignedMediaUrl(media.media_id);
        if (cancelled) return;
        // 优先接管预热元素（已在缓冲）；无则新建并开始加载
        const warm = takeWarmVideoElement(media.media_id);
        el = warm ?? document.createElement("video");
        if (!warm) el.src = url;
        el.className = "image-viewer-video";
        el.controls = true;
        el.autoplay = true;
        el.playsInline = true;
        el.preload = "auto";
        if (thumbUrlRef.current) el.poster = thumbUrlRef.current;
        hostRef.current?.appendChild(el);
        setElementReady(true);
        try {
          const p = el.play();
          if (p && typeof p.catch === "function") p.catch(() => {});
        } catch {
          /* jsdom/受限环境 play 不可用时静默（用户可手点播放） */
        }
      } catch {
        if (!cancelled) setFailed(true);
      }
    };
    void mount();
    return () => {
      cancelled = true;
      if (el) {
        try {
          el.pause();
          el.removeAttribute("src");
          el.load();
          el.remove();
        } catch {
          /* 清理失败可忽略（元素即将丢弃） */
        }
      }
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [media.media_id]);

  if (failed) return <span className="image-viewer-fallback">视频加载失败</span>;
  return (
    <div ref={hostRef} className="image-viewer-video-host">
      {!elementReady &&
        (thumbUrl ? (
          <img
            src={thumbUrl}
            alt=""
            className="image-viewer-video image-viewer-video-poster"
          />
        ) : (
          <span className="media-frame-skeleton image-viewer-video-skeleton" />
        ))}
    </div>
  );
}

/** 本地预览（乐观消息，未上传）：图片或视频原样展示 */
function LocalPreview({ item }: { item: ViewerItem }) {
  if (item.isVideo) {
    return (
      <video src={item.localUrl} className="image-viewer-video" controls playsInline />
    );
  }
  return <img src={item.localUrl} alt={item.alt} className="image-viewer-img" />;
}

export function ImageViewer({
  media,
  alt,
  items,
  initialIndex = 0,
  onClose,
}: {
  /** 单条目模式（兼容旧调用） */
  media?: MediaDescriptor | null;
  alt?: string;
  /** 多条目模式：同消息的图片/视频列表（左上右切换） */
  items?: ViewerItem[];
  initialIndex?: number;
  onClose: () => void;
}) {
  const list: ViewerItem[] =
    items && items.length > 0
      ? items
      : [{ media: media ?? null, alt: alt ?? "图片" }];
  const [index, setIndex] = useState(Math.min(Math.max(initialIndex, 0), list.length - 1));
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState(false);
  const closeRef = useRef<HTMLButtonElement | null>(null);

  const current = list[index];
  const isLocal = current.localUrl != null && current.media == null;

  const stageRef = useRef<HTMLDivElement | null>(null);
  const [reducedMotion] = useState(prefersReducedMotion);
  // 横向查看器也要在起步阶段阻止浏览器垂直滚动抢走 pointer 流；交叉轴手势让位。
  useTouchAxisGuard(stageRef, "x");

  // 横滑方向追踪（render 阶段）：index 变化时计算本次切换方向（1=下一张左滑 / -1=上一张右滑）
  const prevIndexRef = useRef(index);
  const directionRef = useRef<1 | -1 | 0>(0);
  if (prevIndexRef.current !== index) {
    directionRef.current = index > prevIndexRef.current ? 1 : -1;
    prevIndexRef.current = index;
  }
  const direction = directionRef.current;

  const close = useCallback(() => onClose(), [onClose]);

  // 横滑松手判定（方案 §3.2）：统一走 useSwipeCommit；系统 pointercancel
  // 只回弹不切图，交叉轴位移占优时让位给页面/系统滚动。
  const handleDragEnd: PanHandler = useCallback(
    (event, info: PanInfo) => {
      if (event.type === "pointercancel") return;
      const width = stageRef.current?.clientWidth ?? window.innerWidth;
      const commit = resolveSwipeCommit({
        net: info.offset.x,
        cross: info.offset.y,
        velocity: info.velocity.x,
        size: width,
      });
      if (commit === 1) {
        setIndex((i) => Math.min(list.length - 1, i + 1));
      } else if (commit === -1) {
        setIndex((i) => Math.max(0, i - 1));
      }
    },
    [list.length],
  );

  // 条目切换变体：direction 由 index 变化方向决定；reduced-motion 直切（仅透明度）
  const itemVariants = useMemo(
    () =>
      reducedMotion
        ? {
            enter: { opacity: 1 },
            center: { opacity: 1 },
            exit: { opacity: 0 },
          }
        : {
            enter: (dir: number) => ({
              x: dir === 0 ? 0 : `${dir * 40}%`,
              opacity: 1,
              transition: { duration: SWIPE_SLIDE_DURATION, ease: EASE_OUT },
            }),
            center: { x: 0, opacity: 1 },
            exit: (dir: number) => ({
              x: dir === 0 ? 0 : `${dir * -30}%`,
              opacity: 0,
              transition: { duration: SWIPE_SLIDE_DURATION, ease: EASE_IN },
            }),
          },
    [reducedMotion],
  );

  // 仅多条目且非 reduced-motion 才启用横滑 drag（单条目保留既有关闭交互，不误触发切图）
  const canSwipe = list.length > 1 && !reducedMotion;

  useEffect(() => {
    closeRef.current?.focus();
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
      if (e.key === "ArrowLeft") setIndex((i) => Math.max(0, i - 1));
      if (e.key === "ArrowRight") setIndex((i) => Math.min(list.length - 1, i + 1));
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose, list.length]);

  const save = async () => {
    if (!current.media || saving) return;
    setSaving(true);
    setSaveError(false);
    try {
      await downloadMedia(current.media);
    } catch {
      setSaveError(true);
    } finally {
      setSaving(false);
    }
  };

  // Portal 挂载到 body：脱离消息气泡的层叠上下文——祖先的 backdrop-filter/
  // transform 会把 position:fixed 的包含块降级为该祖先，导致查看器被困在气泡内。
  return createPortal(
    <div
      className="image-viewer"
      role="dialog"
      aria-modal="true"
      aria-label={list.length > 1 ? `图片查看：${index + 1}/${list.length}` : alt ? `图片查看：${alt}` : "图片查看"}
      onClick={close}
    >
      <button
        type="button"
        className="image-viewer-close"
        onClick={close}
        aria-label="关闭查看"
        ref={closeRef}
      >
        <IconClose width={22} height={22} />
      </button>
      <div className="image-viewer-stage" ref={stageRef} onClick={(e) => e.stopPropagation()}>
        <AnimatePresence custom={direction} mode="sync" initial={false}>
          <motion.div
            key={index}
            className="image-viewer-stage-item"
            custom={direction}
            variants={itemVariants}
            initial="enter"
            animate="center"
            exit="exit"
            drag={canSwipe ? "x" : false}
            dragDirectionLock
            dragConstraints={DRAG_CONSTRAINTS}
            dragElastic={DRAG_ELASTIC}
            dragMomentum={false}
            onDragEnd={handleDragEnd}
          >
            {current.localUrl && current.media == null ? (
              <LocalPreview item={current} />
            ) : current.media?.kind === "video" ? (
              <VideoPlayer media={current.media} />
            ) : current.media ? (
              <ResourceImage
                src={mediaContentUrl(current.media.media_id)}
                alt={current.alt || "图片原图"}
                className="image-viewer-img"
                loading="eager"
                fallback={<span className="image-viewer-fallback">图片加载失败</span>}
              />
            ) : (
              <span className="image-viewer-fallback">媒体不可用</span>
            )}
          </motion.div>
        </AnimatePresence>
      </div>
      {list.length > 1 && (
        <>
          <button
            type="button"
            className="image-viewer-nav prev"
            onClick={(e) => {
              e.stopPropagation();
              setIndex((i) => Math.max(0, i - 1));
            }}
            aria-label="上一张"
            disabled={index === 0}
          >
            ‹
          </button>
          <button
            type="button"
            className="image-viewer-nav next"
            onClick={(e) => {
              e.stopPropagation();
              setIndex((i) => Math.min(list.length - 1, i + 1));
            }}
            aria-label="下一张"
            disabled={index === list.length - 1}
          >
            ›
          </button>
        </>
      )}
      <div className="image-viewer-actions" onClick={(e) => e.stopPropagation()}>
        {list.length > 1 && <span className="image-viewer-counter">{index + 1}/{list.length}</span>}
        <button
          type="button"
          className="image-viewer-save"
          onClick={() => void save()}
          disabled={saving || isLocal || !current.media}
        >
          <IconDownload width={16} height={16} style={{ verticalAlign: "-2px", marginRight: 6 }} />
          {saving ? "保存中…" : isLocal ? "发送后可保存" : "保存"}
        </button>
      </div>
      {saveError && (
        <div className="image-viewer-error" role="alert">保存失败，请重试</div>
      )}
    </div>,
    document.body
  );
}
