/**
 * ChannelSidebar —— 宽屏频道侧栏（design.md §12.4，布局文档 §3.2）。
 *
 * 240–280px 玻璃：群名头（点击进群信息 R-G9 入口）+ 五场景项
 * （聊天/语音/直播/帖子/桌游，选中 rgba(157,191,230,0.35) 胶囊底）+ 返回主页（无，宽屏本就在主页）。
 * 状态标识（语音在麦人数/直播 LIVE/帖子未读）随 F4/F5/F6 接入，F3 不渲染。
 * 群信息入口仅群名头一处（R-G9），侧栏底部不再放重复入口。
 *
 * 子群（群聊子群功能）：
 * - 「聊天」场景项下展开子群列表（默认展开，可收起）；
 * - 子群行显示未读红点（子群独立未读）与当前选中态，点击切换子群；
 * - 群主/管理员：聊天行展开键左侧有编辑笔，点击进入/退出编辑态；
 *   编辑态显示【+】添加按钮，每个子群行内出现编辑笔 → 弹窗改名/删除（默认组不可删）。
 */
import { auroraquaIndicatorTransition, disclosureVariants, panelVariants } from "../components/motion/auroraquaMotion";
import { AuroraquaNavHighlight } from "../components/motion/AuroraquaNavHighlight";
import { usePrefersReducedMotion } from "../hooks/usePrefersReducedMotion";
import { useSidebarContentClip } from "../hooks/useSidebarContentClip";
import { Fragment, useCallback, useId, useLayoutEffect, useRef, useState } from "react";
import { AnimatePresence, motion, useIsPresent } from "framer-motion";
import * as chatApi from "../api/chat";
import * as liveApi from "../api/live";
import type { SubGroup } from "../api/types";
import { ConfirmDialog } from "../components/ConfirmDialog";
import { ResourceImage } from "../components/ResourceImage";
import { CreateSheet } from "./CreateSheet";
import { SubGroupDialog, type SubGroupDialogState } from "../components/group/SubGroupDialog";
import { VoiceChannelCreate } from "../components/voice/VoiceChannelCreate";
import { LiveStartSheet } from "../components/live/LiveStartSheet";
import { IconChat, IconGame, IconMic, IconPlus, IconPost, IconVideo } from "../components/icons";
import type { GroupScene } from "../stores/group";
import { useGroupStore } from "../stores/group";
import { useDirectoryPage } from "../hooks/useDirectoryPage";
import { DirectoryLoadMore } from "../components/DirectoryLoadMore";
import { useSocialPage } from "../hooks/useSocialPage";
import { useChatStore } from "../stores/chat";
import { sortSubgroupsByActivity, subgroupKey, useSubGroupStore } from "../stores/subgroup";

const SCENE_META: Array<{ key: GroupScene; label: string; icon: typeof IconMic }> = [
  { key: "chat", label: "聊天", icon: IconChat },
  { key: "voice", label: "语音", icon: IconMic },
  { key: "live", label: "直播", icon: IconVideo },
  { key: "posts", label: "帖子", icon: IconPost },
  { key: "games", label: "桌游", icon: IconGame },
];

interface ChannelSidebarProps {
  /** Current route group, supplied by a persistent workspace shell. */
  groupId?: string | null;
  groupName: string;
  activeScene: GroupScene;
  onSelectScene: (scene: GroupScene) => void;
  onOpenInfo: () => void;
  /** 切换当前子群（宽屏侧栏点击子群行） */
  onSelectSubgroup: (subgroupId: string) => void;
  /** 点击侧栏语音房行：进入该语音房（宽屏） */
  onSelectVoiceChannel?: (channelId: string) => void;
  /** 当前群内页面的语音房路由；高亮不等待成员加入或媒体连接。 */
  activeVoiceChannelId?: string | null;
  /** 点击侧栏直播间行：进入该直播间（宽屏） */
  onSelectLiveChannel?: (channelId: number) => void;
  /** 当前直播间 id（路由 liveChannelId，用于高亮） */
  activeLiveChannelId?: string | null;
  /** 开播：进入开播控制台（由 GroupPage 提供 navigate） */
  onNavigateLiveStart?: (channelId: number) => void;
}

/** Keep the column's space stable while the old group panel exits before the next enters. */
export function ChannelSidebar(props: ChannelSidebarProps) {
  const storedGroupId = useGroupStore((state) => state.currentGroupId);
  const groupId = props.groupId === undefined ? storedGroupId : props.groupId;
  return (
    <div className="channel-sidebar-slot">
      <AnimatePresence mode="wait" propagate>
        <ChannelSidebarPanel key={groupId} {...props} groupId={groupId} />
      </AnimatePresence>
    </div>
  );
}

function ChannelSidebarPanel(props: ChannelSidebarProps & { groupId: string | null }) {
  const reduced = usePrefersReducedMotion();
  const present = useIsPresent();
  const ref = useRef<HTMLElement>(null);
  useLayoutEffect(() => {
    ref.current?.toggleAttribute("inert", !present);
  }, [present]);
  return (
    <motion.aside
      ref={ref}
      className="channel-sidebar"
      aria-label="群内场景"
      aria-hidden={!present || undefined}
      data-motion-panel="group-channels"
      data-group-owner={props.groupId}
      data-motion-state={present ? "active" : "exiting"}
      style={{ pointerEvents: present ? undefined : "none" }}
      inherit={false}
      initial={reduced ? false : "enter"}
      animate="center"
      exit="exit"
      variants={panelVariants(reduced, "left")}
    >
      <ChannelSidebarContent {...props} />
    </motion.aside>
  );
}

function ChannelSidebarContent({
  groupId: currentGroupId,
  groupName,
  activeScene,
  onSelectScene,
  onOpenInfo,
  onSelectSubgroup,
  onSelectVoiceChannel,
  activeVoiceChannelId,
  onSelectLiveChannel,
  activeLiveChannelId,
  onNavigateLiveStart,
}: ChannelSidebarProps & { groupId: string | null }) {
  const present = useIsPresent();
  const selectionId = useId();
  const voiceDirectory = useDirectoryPage("voice", { groupId: currentGroupId ?? undefined }, present && currentGroupId != null);
  const liveDirectory = useDirectoryPage("live", { groupId: currentGroupId ?? undefined }, present && currentGroupId != null);
  const voiceChannels = voiceDirectory.items;
  const voiceCount = voiceDirectory.totalMemberCount ?? 0;
  const liveChannels = liveDirectory.items;
  const hasLive = liveChannels.some((channel) => channel.status === "live");
  // 群内未读帖子数（浏览与已读同源）：>0 时帖子场景项显示红点
  const postUnread = useChatStore((state) => state.conversations
    .find((c) => c.id === currentGroupId)?.post_unread_count ?? 0);

  // ---- 子群状态 ----
  const subgroupList = useSubGroupStore((state) => state.byGroup[currentGroupId ?? ""] ?? []);
  const subgroupPage = useSocialPage("subgroups", { groupId: currentGroupId ?? undefined }, !!currentGroupId);
  const subgroups = sortSubgroupsByActivity(subgroupList);
  const activeSubgroupId = useSubGroupStore((state) => state.activeByGroup[currentGroupId ?? ""] ?? null);
  const unreadByKey = useSubGroupStore((state) => state.unreadByKey);
  const myRole = useChatStore((state) => state.conversations
    .find((c) => c.id === currentGroupId)?.my_role ?? null);
  const canManage = myRole === "owner" || myRole === "admin";

  const [subgroupsOpen, setSubgroupsOpen] = useState(true);
  // 子群列表默认最多显示 3 个；超过时显示「展开更多」按钮
  const [subgroupsExpanded, setSubgroupsExpanded] = useState(false);
  const [editing, setEditing] = useState(false);
  const [dialog, setDialog] = useState<SubGroupDialogState>(null);
  const [busy, setBusy] = useState(false);
  const [dialogError, setDialogError] = useState<string | null>(null);
  const [confirmDelete, setConfirmDelete] = useState<SubGroup | null>(null);

  // 中部滚动列表 ref：点击场景选项卡时把列表滚到该行自身的吸顶位
  const sceneListRef = useRef<HTMLDivElement>(null);
  useSidebarContentClip(sceneListRef);

  // 点击聊天/语音/直播：滚到该行自己的 sticky 吸顶位（chat 0 / voice 44 / live 88，与 group.css 吸附位一致）。
  // sticky 元素吸附/吸底期间 offsetTop 会随滚动漂移（返回含吸附位移的盒位置），
  // 因此先瞬时取消 sticky 量取真实文档流位置，再算目标 scrollTop = 流位置 - 吸顶偏移。
  // 内容不足以滚到吸顶位（数据不多）时，scrollTo 会被容器自然 clamp，只滚动到能到的尽头。
  const scrollSceneRowToPin = useCallback((scene: GroupScene) => {
    const container = sceneListRef.current;
    if (!container) return;
    const row = container.querySelector<HTMLElement>(`.channel-scene-row--${scene}`);
    if (!row) return;
    const pinTop = scene === "chat" ? 0 : scene === "voice" ? 44 : 88;
    const prevPosition = row.style.position;
    row.style.position = "static"; // 临时取消 sticky（同步回流一次，不触发绘制）
    const flowTop = row.offsetTop;
    row.style.position = prevPosition;
    container.scrollTo({ top: Math.max(0, flowTop - pinTop), behavior: "smooth" });
  }, []);

  // ---- 语音房下拉状态 ----
  const [voiceOpen, setVoiceOpen] = useState(true);
  const [voiceExpanded, setVoiceExpanded] = useState(false);
  const [showVoiceCreate, setShowVoiceCreate] = useState(false);

  // ---- 直播下拉状态 ----
  const [liveOpen, setLiveOpen] = useState(true);
  const [liveExpanded, setLiveExpanded] = useState(false);
  const [showLiveCreate, setShowLiveCreate] = useState(false);
  const [creatingLive, setCreatingLive] = useState(false);
  const [liveCreateError, setLiveCreateError] = useState<string | null>(null);

  // Existing disclosure ownership with Auroraqua's 300ms ease-out cadence.
  const reduceMotion = usePrefersReducedMotion();
  const collapseVariants = disclosureVariants(reduceMotion);

  const handleCreated = useCallback((sg: SubGroup) => {
    useSubGroupStore.getState().upsertSubgroup(sg.conversation_id, sg);
  }, []);

  const handleDeleted = useCallback((convId: string, subgroupId: string) => {
    useSubGroupStore.getState().removeSubgroup(convId, subgroupId);
    const active = useSubGroupStore.getState().activeByGroup[convId];
    if (active === subgroupId) {
      const list = useSubGroupStore.getState().byGroup[convId] ?? [];
      const defaultSg = list.find((sg) => sg.is_default);
      useSubGroupStore.getState().setActiveSubgroup(convId, defaultSg?.id ?? null);
    }
  }, []);

  const runDialogAction = useCallback(async (action: () => Promise<unknown>) => {
    setBusy(true);
    setDialogError(null);
    try {
      await action();
      setDialog(null);
    } catch (e) {
      setDialogError(e instanceof Error ? e.message : "操作失败");
    } finally {
      setBusy(false);
    }
  }, []);

  const confirmDeleteSubgroup = useCallback(async () => {
    if (!confirmDelete || !currentGroupId) return;
    setBusy(true);
    setDialogError(null);
    try {
      await chatApi.deleteSubgroup(currentGroupId, confirmDelete.id);
      handleDeleted(currentGroupId, confirmDelete.id);
      setConfirmDelete(null);
      setDialog(null);
    } catch (e) {
      setDialogError(e instanceof Error ? e.message : "删除失败");
    } finally {
      setBusy(false);
    }
  }, [confirmDelete, currentGroupId, handleDeleted]);

  // 侧栏 + 开播：选择已有直播间进入控制台，或新建直播间
  const handleLiveStarted = useCallback((channel: { id: number }) => {
    setShowLiveCreate(false);
    onNavigateLiveStart?.(channel.id);
  }, [onNavigateLiveStart]);

  const handleCreateNewLive = useCallback(async () => {
    setCreatingLive(true);
    setLiveCreateError(null);
    try {
      const created = await liveApi.createLiveChannel("新直播间", currentGroupId);
      setShowLiveCreate(false);
      onNavigateLiveStart?.(created.id);
    } catch (e) {
      setLiveCreateError(e instanceof Error ? e.message : "创建直播间失败");
    } finally {
      setCreatingLive(false);
    }
  }, [currentGroupId, onNavigateLiveStart]);

  // 展开更多按钮：基础 3 条 + 追加部分（追加部分复用 collapseVariants 展开收起动画）
  const showMore = !editing && Math.max(subgroups.length, subgroupPage.total) > 3;
  const showVoiceMore = voiceDirectory.total > 3 || voiceChannels.length > 3;
  const showLiveMore = liveDirectory.total > 3 || liveChannels.length > 3;

  // 三个可展开选项卡（聊天/语音/直播）的行是滚动容器的直接子元素，sticky 依次吸顶，
  // 下拉内容（子群/语音房/直播间）随整列滚动，展开收起带高度动画（collapseVariants）。
  const renderSceneItem = (scene: (typeof SCENE_META)[number]) => {
    const Icon = scene.icon;
    const active = activeScene === scene.key;
    if (scene.key === "voice") {
      return (
        <Fragment key={scene.key}>
          <div className={`channel-scene-row channel-scene-row--${scene.key}`}>
            <button type="button" className={`channel-scene has-auroraqua-highlight ${active ? "is-active" : ""}`} onClick={() => { onSelectScene("voice"); scrollSceneRowToPin("voice"); }} aria-current={active ? "true" : undefined}>
              {active && <AuroraquaNavHighlight id={`${selectionId}-scene`} />}
              <Icon width={20} height={20} />
              <span>{scene.label}</span>
              {voiceCount > 0 && <span className="channel-scene-status">{voiceCount}</span>}
            </button>
            {voiceOpen && (
              <button type="button" className="channel-scene-voice-add" onClick={() => setShowVoiceCreate(true)} aria-label="创建语音房" title="创建语音房">
                <IconPlus width={14} height={14} />
              </button>
            )}
            <button type="button" className={`channel-scene-voice-toggle${voiceOpen ? " is-open" : ""}`} onClick={() => setVoiceOpen((o) => !o)} aria-label={voiceOpen ? "收起语音房" : "展开语音房"} aria-expanded={voiceOpen}>
              <IconChevronDown width={14} height={14} />
            </button>
          </div>
          <AnimatePresence initial={false}>
            {voiceOpen && (
              <motion.div
                key="voice-rooms"
                className="channel-voice-rooms"
                variants={collapseVariants}
                initial="closed"
                animate="open"
                exit="closed"
              >
              {/* One stable parent preserves each row when immediate activity sorting
                  moves it across the first-three / expanded boundary. */}
              <motion.ul
                className="channel-voice-room-list"
                initial={false}
                animate={{ height: voiceExpanded ? "auto" : Math.max(0, Math.min(3, voiceChannels.length) * 31 - 1) }}
                transition={reduceMotion ? { duration: 0 } : auroraquaIndicatorTransition}
                style={{ overflow: "hidden", flexShrink: 0 }}
              >
                {voiceChannels.map((ch, index) => {
                  const isActive = activeScene === "voice" && String(ch.id) === String(activeVoiceChannelId);
                  const hidden = !voiceExpanded && index >= 3;
                  return (
                    <motion.li
                      key={ch.id}
                      className={`channel-voice-room-item${isActive ? " is-active" : ""}`}
                      layout={reduceMotion ? false : "position"}
                      initial={false}
                      transition={{ layout: reduceMotion ? { duration: 0 } : auroraquaIndicatorTransition }}
                      style={{ flexShrink: 0 }}
                      aria-hidden={hidden || undefined}
                      {...(hidden ? { inert: "" } : {})}
                    >
                      <button type="button" className="channel-voice-room has-auroraqua-highlight" disabled={hidden} tabIndex={hidden ? -1 : undefined} onClick={() => { onSelectScene("voice"); onSelectVoiceChannel?.(ch.id); }} aria-current={isActive ? "true" : undefined}>
                        {/* The row owns its reorder transform; a second shared projection
                            would cancel that movement and detach the active background. */}
                        {isActive && <AuroraquaNavHighlight id={`${selectionId}-voice`} sharedLayout={false} />}
                        <span className="channel-voice-room-name">{ch.name}</span>
                        {ch.member_count > 0 && <span className="channel-voice-room-count">{ch.member_count}</span>}
                      </button>
                    </motion.li>
                  );
                })}
              </motion.ul>
              {showVoiceMore && (
                <button type="button" className="channel-voice-more" onClick={() => setVoiceExpanded((v) => !v)} aria-expanded={voiceExpanded}>
                  {voiceExpanded ? "收起" : `展开更多（${Math.max(voiceDirectory.total, voiceChannels.length) - 3}）`}
                </button>
              )}
              {voiceExpanded && <DirectoryLoadMore {...voiceDirectory} retainCompletedSpace={false} />}
              </motion.div>
            )}
          </AnimatePresence>
        </Fragment>
      );
    }
    if (scene.key === "live") {
      return (
        <Fragment key={scene.key}>
          <div className={`channel-scene-row channel-scene-row--${scene.key}`}>
            <button type="button" className={`channel-scene has-auroraqua-highlight ${active ? "is-active" : ""}`} onClick={() => { onSelectScene("live"); scrollSceneRowToPin("live"); }} aria-current={active ? "true" : undefined}>
              {active && <AuroraquaNavHighlight id={`${selectionId}-scene`} />}
              <Icon width={20} height={20} />
              <span>{scene.label}</span>
              {hasLive && <span className="channel-scene-status">LIVE</span>}
            </button>
            {liveOpen && (
              <button type="button" className="channel-scene-live-add" onClick={() => { setLiveCreateError(null); setShowLiveCreate(true); }} aria-label="创建直播" title="创建直播">
                <IconPlus width={14} height={14} />
              </button>
            )}
            <button type="button" className={`channel-scene-live-toggle${liveOpen ? " is-open" : ""}`} onClick={() => setLiveOpen((o) => !o)} aria-label={liveOpen ? "收起直播" : "展开直播"} aria-expanded={liveOpen}>
              <IconChevronDown width={14} height={14} />
            </button>
          </div>
          <AnimatePresence initial={false}>
            {liveOpen && (
              <motion.div
                key="live-rooms"
                className="channel-live-rooms"
                variants={collapseVariants}
                initial="closed"
                animate="open"
                exit="closed"
              >
              <ul className="channel-live-room-list">
                {liveChannels.slice(0, 3).map((ch) => {
                  const isActive = activeScene === "live" && String(ch.id) === String(activeLiveChannelId);
                  return (
                    <li key={ch.id} className={`channel-live-room-item${isActive ? " is-active" : ""}`}>
                      <button type="button" className="channel-live-room has-auroraqua-highlight" onClick={() => { onSelectLiveChannel?.(ch.id); }} aria-current={isActive ? "true" : undefined}>
                        {isActive && <AuroraquaNavHighlight id={`${selectionId}-live`} />}
                        <span className="channel-live-cover">
                          {ch.cover ? <ResourceImage src={ch.cover} alt="" className="channel-live-cover-image" fallback={<IconVideo width={16} height={16} aria-hidden="true" />} /> : <IconVideo width={16} height={16} aria-hidden="true" />}
                          {ch.status === "live" && <span className="channel-live-dot" aria-label="直播中" />}
                        </span>
                        <span className="channel-live-room-title">{ch.title}</span>
                      </button>
                    </li>
                  );
                })}
              </ul>
              {/* 「展开更多」追加的直播间：复用选项卡展开收起动画（collapseVariants） */}
              <AnimatePresence initial={false}>
                {liveExpanded && (
                  <motion.div
                    key="live-rooms-more"
                    variants={collapseVariants}
                    initial="closed"
                    animate="open"
                    exit="closed"
                  >
                    <ul className="channel-live-room-list">
                      {liveChannels.slice(3).map((ch) => {
                        const isActive = activeScene === "live" && String(ch.id) === String(activeLiveChannelId);
                        return (
                          <li key={ch.id} className={`channel-live-room-item${isActive ? " is-active" : ""}`}>
                            <button type="button" className="channel-live-room has-auroraqua-highlight" onClick={() => { onSelectLiveChannel?.(ch.id); }} aria-current={isActive ? "true" : undefined}>
                              {isActive && <AuroraquaNavHighlight id={`${selectionId}-live`} />}
                              <span className="channel-live-cover">
                                {ch.cover ? <ResourceImage src={ch.cover} alt="" className="channel-live-cover-image" fallback={<IconVideo width={16} height={16} aria-hidden="true" />} /> : <IconVideo width={16} height={16} aria-hidden="true" />}
                                {ch.status === "live" && <span className="channel-live-dot" aria-label="直播中" />}
                              </span>
                              <span className="channel-live-room-title">{ch.title}</span>
                            </button>
                          </li>
                        );
                      })}
                    </ul>
                  </motion.div>
                )}
              </AnimatePresence>
              {showLiveMore && (
                <button type="button" className="channel-live-more" onClick={() => setLiveExpanded((v) => !v)} aria-expanded={liveExpanded}>
                  {liveExpanded ? "收起" : `展开更多（${Math.max(liveDirectory.total, liveChannels.length) - 3}）`}
                </button>
              )}
              {liveExpanded && <DirectoryLoadMore {...liveDirectory} retainCompletedSpace={false} />}
              </motion.div>
            )}
          </AnimatePresence>
        </Fragment>
      );
    }
    if (scene.key === "chat") {
      const defaultSg = subgroups.find((sg) => sg.is_default) ?? subgroups[0];
      // 子群行渲染（基础 3 条与「展开更多」追加部分共用，编辑态行内编辑笔）
      const renderSubgroupLi = (sg: SubGroup) => {
        const unread = unreadByKey[subgroupKey(currentGroupId ?? "", sg.id)] ?? 0;
        const isActive = activeScene === "chat" && sg.id === activeSubgroupId;
        return (
          <li key={sg.id} className={`channel-subgroup-item${isActive ? " is-active" : ""}`}>
            <button type="button" className={`channel-subgroup has-auroraqua-highlight${isActive ? " is-active" : ""}`} onClick={() => { onSelectSubgroup(sg.id); onSelectScene("chat"); }} aria-current={isActive ? "true" : undefined}>
              {isActive && <AuroraquaNavHighlight id={`${selectionId}-subgroup`} />}
              <span className="channel-subgroup-name">{sg.name}</span>
              {sg.muted === true && <span className="channel-subgroup-muted" title="已禁言（仅群主/管理员可发言）">禁言</span>}
              {unread > 0 && <span className="channel-subgroup-badge" aria-label={`${unread} 条未读`} title="有未读消息">{unread > 99 ? "99+" : unread}</span>}
            </button>
            {editing && (
              <button type="button" className="channel-subgroup-edit-btn" onClick={() => { setDialogError(null); setDialog({ kind: "edit", sg }); }} aria-label={`编辑子群 ${sg.name}`} title="编辑子群">
                <PencilIcon />
              </button>
            )}
          </li>
        );
      };
      return (
        <Fragment key={scene.key}>
          <div className={`channel-scene-row channel-scene-row--${scene.key}`}>
            <button type="button" className={`channel-scene has-auroraqua-highlight ${active ? "is-active" : ""}`} onClick={() => { onSelectScene("chat"); scrollSceneRowToPin("chat"); if (defaultSg) onSelectSubgroup(defaultSg.id); }} aria-current={active ? "true" : undefined}>
              {active && <AuroraquaNavHighlight id={`${selectionId}-scene`} />}
              <Icon width={20} height={20} />
              <span>{scene.label}</span>
            </button>
            {subgroupsOpen && canManage && (
              <button type="button" className={`channel-scene-subgroup-edit${editing ? " is-active" : ""}`} onClick={() => setEditing((v) => !v)} aria-label={editing ? "退出编辑" : "编辑"} title={editing ? "退出编辑" : "编辑"} aria-pressed={editing}>
                <PencilIcon />
              </button>
            )}
            <button type="button" className={`channel-scene-subgroup-toggle${subgroupsOpen ? " is-open" : ""}`} onClick={() => setSubgroupsOpen((o) => !o)} aria-label={subgroupsOpen ? "收起子群" : "展开子群"} aria-expanded={subgroupsOpen}>
              <IconChevronDown width={14} height={14} />
            </button>
          </div>
          <AnimatePresence initial={false}>
            {subgroupsOpen && (
              <motion.div
                key="subgroups"
                className="channel-subgroups"
                variants={collapseVariants}
                initial="closed"
                animate="open"
                exit="closed"
              >
              <ul className="channel-subgroup-list">
                {subgroups.slice(0, 3).map((sg) => renderSubgroupLi(sg))}
              </ul>
              {/* 「展开更多」追加的子群（编辑态直接全显）：复用选项卡展开收起动画（collapseVariants） */}
              <AnimatePresence initial={false}>
                {(editing || subgroupsExpanded) && (
                  <motion.div
                    key="subgroups-more"
                    variants={collapseVariants}
                    initial="closed"
                    animate="open"
                    exit="closed"
                  >
                    <ul className="channel-subgroup-list">
                      {subgroups.slice(3).map((sg) => renderSubgroupLi(sg))}
                    </ul>
                    <DirectoryLoadMore {...subgroupPage} retainCompletedSpace={false} />
                  </motion.div>
                )}
              </AnimatePresence>
              {showMore && (
                <button type="button" className="channel-subgroup-more" onClick={() => setSubgroupsExpanded((v) => !v)} aria-expanded={subgroupsExpanded}>
                  {subgroupsExpanded ? "收起" : `展开更多（${Math.max(subgroups.length, subgroupPage.total) - 3}）`}
                </button>
              )}
              {canManage && editing && (
                <button type="button" className="channel-subgroup-add" onClick={() => { setDialogError(null); setDialog({ kind: "add" }); }} aria-label="添加子群" title="添加子群">
                  <IconPlus width={16} height={16} />
                </button>
              )}
              </motion.div>
            )}
          </AnimatePresence>
        </Fragment>
      );
    }
    return (
      <li key={scene.key} className="channel-scene-item">
        <button type="button" className={`channel-scene has-auroraqua-highlight ${active ? "is-active" : ""}`} onClick={() => onSelectScene(scene.key)} aria-current={active ? "true" : undefined}>
          {active && <AuroraquaNavHighlight id={`${selectionId}-scene`} />}
          <Icon width={20} height={20} />
          <span>{scene.label}</span>
          {scene.key === "posts" && postUnread > 0 && (
            <span className="channel-scene-status channel-scene-posts-badge" aria-label={`${postUnread} 条未读帖子`} title="有未读帖子">{postUnread > 99 ? "99+" : postUnread}</span>
          )}
        </button>
      </li>
    );
  };

  return (
    <>
      <button type="button" className="channel-sidebar-head" onClick={onOpenInfo}>
        <span className="channel-sidebar-title">{groupName}</span>
        <Chevron />
      </button>
      <motion.div layoutScroll className="channel-sidebar-list" style={{ overflowAnchor: "none" }} ref={sceneListRef} onScroll={(event) => {
        if (voiceOpen && voiceExpanded) voiceDirectory.onScroll(event.currentTarget);
        if (liveOpen && liveExpanded) liveDirectory.onScroll(event.currentTarget);
      }}>
        {SCENE_META.filter((scene) => scene.key !== "posts" && scene.key !== "games").map(renderSceneItem)}
      </motion.div>
      <ul className="channel-sidebar-list channel-sidebar-list-bottom">
        {SCENE_META.filter((scene) => scene.key === "posts" || scene.key === "games").map(renderSceneItem)}
      </ul>

      {present && showVoiceCreate && (
        <CreateSheet title="创建语音房" onClose={() => setShowVoiceCreate(false)}>
          <VoiceChannelCreate group={currentGroupId} onCreated={() => setShowVoiceCreate(false)} />
        </CreateSheet>
      )}

      {present && showLiveCreate && (
        <CreateSheet title="群内开播" onClose={() => setShowLiveCreate(false)}>
          <LiveStartSheet
            onStart={handleLiveStarted}
            onCreateNew={() => void handleCreateNewLive()}
            creatingNew={creatingLive}
            createError={liveCreateError}
          />
        </CreateSheet>
      )}

      {present && dialog && (
        <SubGroupDialog
          state={dialog}
          busy={busy}
          error={dialogError}
          onClose={() => {
            if (busy) return;
            setDialog(null);
            setDialogError(null);
          }}
          onConfirm={async (name, muted) => {
            if (!currentGroupId) return;
            if (dialog.kind === "add") {
              await runDialogAction(async () => {
                const sg = await chatApi.createSubgroup(currentGroupId, name);
                handleCreated(sg);
              });
            } else {
              await runDialogAction(async () => {
                const sg = await chatApi.updateSubgroup(currentGroupId, dialog.sg.id, { name, muted });
                handleCreated(sg);
              });
            }
          }}
          onDelete={() => {
            if (dialog.kind === "edit") setConfirmDelete(dialog.sg);
          }}
        />
      )}

      {present && confirmDelete && (
        <ConfirmDialog
          title="删除子群"
          message={`确定删除子群「${confirmDelete.name}」？该子群的所有聊天记录将永久删除，无法恢复。`}
          confirmLabel="删除"
          onConfirm={() => void confirmDeleteSubgroup()}
          onClose={() => {
            if (busy) return;
            setConfirmDelete(null);
            setDialogError(null);
          }}
        />
      )}
    </>
  );
}

function Chevron() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="m9 6 6 6-6 6" />
    </svg>
  );
}

function IconChevronDown({ width = 14, height = 14 }: { width?: number; height?: number }) {
  return (
    <svg width={width} height={height} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="m6 9 6 6 6-6" />
    </svg>
  );
}

function PencilIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M17 3a2.85 2.83 0 1 1 4 4L7.5 20.5 2 22l1.5-5.5Z" />
    </svg>
  );
}
