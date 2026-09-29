/// 群聊场景导航状态 —— web `stores/group.ts`（35 行）的 Dart 等价物。
///
/// ## 单一状态源（web 注释逐条保留）
/// - [activeScene]：当前群内子场景（chat/live/voice/posts/games/**info**）——
///   群头像两级点击（R-G4）与输入框显隐（R-G5）都读这一份状态，**禁止第二份导航状态**；
/// - [currentGroupId]：当前所在群（ServerRail 高亮 / 场景内容数据归属）。
///
/// ## 与 URL 的关系
/// 路由 `/group/:id[/scene]` 是场景的**可分享表现**；页面在 route param 变化时同步
/// [activeScene]（单一 effect），切换场景走 `setActiveScene + go`（store 是交互事实源、
/// URL 是回显）。
library;

import 'package:flutter/foundation.dart';

import '../widgets/shell/channel_sidebar.dart' show AylaGroupScene;

/// 窄屏五子界面横向顺序：语音 | 直播 | 聊天 | 帖子 | 桌游（聊天居中默认，R-G3）
/// —— web `stores/group.ts:17` 的 `GROUP_SCENE_ORDER`。
const List<AylaGroupScene> kAylaGroupSceneOrder = <AylaGroupScene>[
  AylaGroupScene.voice,
  AylaGroupScene.live,
  AylaGroupScene.chat,
  AylaGroupScene.posts,
  AylaGroupScene.games,
];

/// 合法的路由场景名（web `GroupPage.tsx:61` 的 `VALID_SCENES`）。
const Set<String> kAylaValidGroupScenes = <String>{
  'chat',
  'voice',
  'live',
  'posts',
  'games',
  'info',
};

/// 群内场景导航状态。
class AylaGroupState extends ChangeNotifier {
  AylaGroupScene _activeScene = AylaGroupScene.chat;
  String? _currentGroupId;

  /// 当前群内子场景。
  AylaGroupScene get activeScene => _activeScene;

  /// 当前所在群 id（null = 不在任何群）。
  String? get currentGroupId => _currentGroupId;

  void setActiveScene(AylaGroupScene scene) {
    if (_activeScene == scene) return;
    _activeScene = scene;
    notifyListeners();
  }

  void setCurrentGroup(String? groupId) {
    if (_currentGroupId == groupId) return;
    _currentGroupId = groupId;
    notifyListeners();
  }

  /// 下拉回主页时清空（web `reset()`：`{activeScene:"chat", currentGroupId:null}`）。
  void reset() {
    if (_activeScene == AylaGroupScene.chat && _currentGroupId == null) return;
    _activeScene = AylaGroupScene.chat;
    _currentGroupId = null;
    notifyListeners();
  }

  /// 路由场景名 → 枚举（未知 → null，**不 fallback**）。
  static AylaGroupScene? parseScene(String? raw) => switch (raw) {
        'chat' => AylaGroupScene.chat,
        'voice' => AylaGroupScene.voice,
        'live' => AylaGroupScene.live,
        'posts' => AylaGroupScene.posts,
        'games' => AylaGroupScene.games,
        'info' => AylaGroupScene.info,
        _ => null,
      };
}
