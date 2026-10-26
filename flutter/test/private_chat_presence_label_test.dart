/// 私信「在线/离线」标签实时性回归锁（2026-10-25）。
///
/// ## 为什么必须有这条锁
/// 用户实报：「私信界面在线离线标签没有热更新」。
///
/// 根因不是「光环没修好」（`avatar_halo` 那条已修并有锁），而是**另一条独立的
/// 渲染路径**：顶栏状态文案走的是
/// `aylaDisplayStatusOf(peer?.status, online)`，其中
/// - `online` 来自 `peer.online` —— **REST 快照**（`final bool`，登录/进房那刻定死）；
/// - `peer.status` 同样是快照，**状态模式（勿扰/离开/隐身）也不会更新**。
///
/// web 的等价物是 `useDisplayStatus(peer)`（`utils/displayStatus.ts:92–101`）：
/// 订阅 `usePresenceStore` 后实时求值。
///
/// 这条锁断言「presence 帧到达后，标签文案**真的**变」—— 用纯函数层锁，
/// 因为页面级注入的正确性最终由这两条纯规则决定。
library;

import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/user_public.dart' show AylaUserPublic;
import '../lib/state/display_status.dart'
    show presenceOnline, presenceStatus, withLiveStatus;
import '../lib/widgets/chat/conversation_list.dart' show aylaDisplayStatusOf;

void main() {
  const AylaUserPublic peer = AylaUserPublic(
    id: 'u2',
    username: 'xixi',
    nickname: '汐汐',
    online: false, // REST 快照：离线
    status: 'auto',
  );

  /// 复刻页面注入的那条链路：presence → (online, status) → 文案。
  String labelOf({Map<String, String> users = const {}, Map<String, String> statuses = const {}}) {
    final AylaUserPublic? live = withLiveStatus(statuses, peer);
    final bool online = presenceOnline(users, live);
    return aylaDisplayStatusOf(presenceStatus(statuses, peer), online);
  }

  test('presence 前：REST 快照离线 ⇒ 文案「离线」', () {
    expect(labelOf(), '离线');
  });

  test('★ presence.update(online) 帧 ⇒ 文案变「在线」（过去这里恒为「离线」）', () {
    expect(labelOf(users: <String, String>{'u2': 'online'}), '在线');
  });

  test('★ presence.update(offline) 帧 ⇒ 文案变回「离线」', () {
    expect(labelOf(users: <String, String>{'u2': 'offline'}), '离线');
  });

  test('★ presence.status(dnd) 帧 ⇒ 「勿扰」（状态模式同样要实时）', () {
    expect(
      labelOf(users: <String, String>{'u2': 'online'}, statuses: <String, String>{'u2': 'dnd'}),
      '勿扰',
    );
  });

  test('★ presence.status(away) 帧 ⇒ 「离开」', () {
    expect(
      labelOf(users: <String, String>{'u2': 'online'}, statuses: <String, String>{'u2': 'away'}),
      '离开',
    );
  });

  test('★ presence.status(invisible) 帧 ⇒ 「离线」（隐身强制离线）', () {
    expect(
      labelOf(users: <String, String>{'u2': 'online'}, statuses: <String, String>{'u2': 'invisible'}),
      '离线',
    );
  });

  test('反向锁：store 无记录时回退 REST 快照（不能凭空造在线）', () {
    expect(labelOf(), '离线');
    expect(presenceOnline(const <String, String>{}, peer), isFalse);
  });
}
