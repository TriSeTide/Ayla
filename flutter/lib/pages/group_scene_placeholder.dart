/// 群内子场景占位 —— web `pages/group/GroupScenePlaceholder.tsx`（25 行）的等价物。
///
/// ## 何时会被渲染
/// web 的 `GroupPage.renderScene()` 在 `contentScene` 落到 `default` 时渲染本页；
/// 而 `contentScene` 由 `VALID_SCENES` 过滤（`GroupPage.tsx:61/216–224`）⇒
/// **未知场景已被回退成 `chat`**，该 `default` 分支实际不可达。
/// Flutter 侧同理：[AylaGroupScene] 是 6 值枚举、`switch` 已穷尽 ⇒ 本页**无生产调用点**。
///
/// 仍按 web 原文实现（文案表逐字、落步骤 chip 保留）：它是**该路由语义的文档化载体**，
/// 也是画布样张的展示件；若将来场景枚举扩展（新增子场景而未交付页面），
/// 由它与 [AylaGroupScenePlaceholder] 承接，而不是静默显示空白。
library;

import 'package:flutter/material.dart';

import '../widgets/group/group_scene.dart' show AylaGroupScenePlaceholder;
import '../widgets/shell/channel_sidebar.dart' show AylaGroupScene;

/// 场景元数据 —— web `GroupScenePlaceholder.tsx:9–14` 的 `SCENE_META` 逐字。
const Map<AylaGroupScene, ({String title, String step, String desc})>
    kAylaGroupSceneMeta = <AylaGroupScene, ({String title, String step, String desc})>{
  AylaGroupScene.live: (
    title: '群内直播',
    step: 'F4',
    desc: '直接进入该群直播间，上下滑切换（范围仅该群）',
  ),
  AylaGroupScene.voice: (
    title: '群内语音',
    step: 'F5',
    desc: '该群语音房卡片列表，点卡片进房间',
  ),
  AylaGroupScene.posts: (
    title: '群内帖子',
    step: 'F6',
    desc: '该群帖子流 + 输入框发帖（区别于一级 tab 的 FAB 发帖）',
  ),
  AylaGroupScene.games: (
    title: '群内桌游',
    step: 'F7',
    desc: '该群桌游室卡片列表，点卡片进房间',
  ),
};

/// 兜底元数据（web tsx 17：`SCENE_META[scene] ?? { title: "子场景", step: "F3", desc: "" }`）。
const ({String title, String step, String desc}) kAylaGroupSceneFallbackMeta = (
  title: '子场景',
  step: 'F3',
  desc: '',
);

/// 群内子场景占位页。
class GroupScenePlaceholderPage extends StatelessWidget {
  const GroupScenePlaceholderPage({super.key, required this.scene});

  final AylaGroupScene scene;

  @override
  Widget build(BuildContext context) {
    final ({String title, String step, String desc}) meta =
        kAylaGroupSceneMeta[scene] ?? kAylaGroupSceneFallbackMeta;
    return AylaGroupScenePlaceholder(
      title: meta.title,
      description: meta.desc,
      children: <Widget>[AylaGroupScenePlaceholder.stepChip(meta.step)],
    );
  }
}
