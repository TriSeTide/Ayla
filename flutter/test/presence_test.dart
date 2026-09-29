/// presence 数据层定向测试 —— 对照 web 三个事实源：
///
/// - `stores/presence.ts`（49 行）：`users` / `statuses` / `connection` + 六个 setter；
/// - `utils/displayStatus.ts`（101 行）：四条纯规则（**隐身强制离线** / 无记录回退 REST /
///   `presence.status` 覆盖 `user.status` / 未知值兜底）；
/// - `ws/presence.ts:111–125`：两类帧 → store（`presence.update` 归一化 / `presence.status` 原样）。
///
/// 用例逐条对照 web 的 `vitest/presence.test.ts` / `vitest/display-status.test.ts` /
/// `vitest/presence-ws.test.ts`；帧注入走 `debugHandleFrame`、状态回放走
/// `debugHandleStatus`（均 `@visibleForTesting`）—— 被测对象是真实分发逻辑，
/// 只绕开 socket 传输层（`WsChannel` 属 M0 已交付件）。
library;

import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/user_public.dart';
import '../lib/core/ws/presence_ws.dart';
import '../lib/core/ws/ws_manager.dart' show WsChannelStatus;
import '../lib/state/display_status.dart';
import '../lib/state/presence_state.dart';
import '../lib/state/realtime_state.dart';

/// 用户投影（web 测试里的 `user(overrides)`；默认与 `display-status.test.ts:14–26` 同）。
AylaUserPublic _u({
  String id = 'u1',
  String? status = 'auto',
  bool online = false,
  String? displayStatus,
}) =>
    AylaUserPublic(
      id: id,
      username: id,
      status: status,
      online: online,
      displayStatus: displayStatus,
    );

void main() {
  group('displayStatusOf（纯规则，displayStatus.ts:17–32）', () {
    test('auto 跟随实时在线', () {
      expect(displayStatusOf(_u(), true), '在线');
      expect(displayStatusOf(_u(), false), '离线');
    });

    test('dnd → 勿扰（不依赖实时）', () {
      expect(displayStatusOf(_u(status: 'dnd'), true), '勿扰');
      expect(displayStatusOf(_u(status: 'dnd'), false), '勿扰');
    });

    test('away → 离开', () {
      expect(displayStatusOf(_u(status: 'away'), true), '离开');
      expect(displayStatusOf(_u(status: 'away'), false), '离开');
    });

    test('invisible → 离线（不暴露在线痕迹）', () {
      expect(displayStatusOf(_u(status: 'invisible'), true), '离线');
    });

    test('未知 / 缺失状态按 auto 兜底', () {
      expect(displayStatusOf(_u(status: 'online'), true), '在线');
      expect(displayStatusOf(null, false), '离线');
    });
  });

  group('presenceOnline（纯规则，displayStatus.ts:40–48）', () {
    test('store 已知 online → 在线（优先于 REST 快照 online=false）', () {
      final AylaPresenceState s = AylaPresenceState()..setUser('u1', 'online');
      expect(presenceOnline(s.users, _u(online: false)), isTrue);
    });

    test('store 已知 offline → 离线（优先于 REST 快照 online=true）', () {
      final AylaPresenceState s = AylaPresenceState()..setUser('u1', 'offline');
      expect(presenceOnline(s.users, _u(online: true)), isFalse);
    });

    test('隐身：store 有 online 记录也强制离线（不泄漏光环）', () {
      final AylaPresenceState s = AylaPresenceState()..setUser('u1', 'online');
      expect(
        presenceOnline(s.users, _u(status: 'invisible', online: true)),
        isFalse,
      );
    });

    test('无记录 → 回退 REST 快照 user.online', () {
      final AylaPresenceState s = AylaPresenceState();
      expect(presenceOnline(s.users, _u(online: true)), isTrue);
      expect(presenceOnline(s.users, _u(online: false)), isFalse);
    });

    test('user 为 null → false', () {
      expect(presenceOnline(const <String, String>{}, null), isFalse);
    });

    test('运行中切隐身（presence.status 实时）→ 立即离线', () {
      // REST 快照 status=auto + 在线记录，但实时 statuses 已是 invisible
      final AylaPresenceState s = AylaPresenceState()
        ..setUser('u1', 'online')
        ..setUserStatus('u1', 'invisible');
      final AylaUserPublic? live = withLiveStatus(s.statuses, _u(online: true));
      expect(presenceOnline(s.users, live), isFalse);
      expect(displayStatusOf(live, true), '离线');
    });
  });

  group('presenceStatus / withLiveStatus（displayStatus.ts:54–69）', () {
    test('presence.status 增量优先于 REST 快照', () {
      final AylaPresenceState s = AylaPresenceState()..setUserStatus('u1', 'dnd');
      expect(presenceStatus(s.statuses, _u(status: 'auto')), 'dnd');
    });

    test('无记录 → 回退 REST 快照 user.status', () {
      final AylaPresenceState s = AylaPresenceState();
      expect(presenceStatus(s.statuses, _u(status: 'away')), 'away');
    });

    test('user 为 null → auto（不造用户）', () {
      expect(presenceStatus(const <String, String>{}, null), 'auto');
    });

    test('未知模式原样返回（不归一化；显示层按 auto 兜底）', () {
      final AylaPresenceState s = AylaPresenceState()..setUserStatus('u1', 'busy');
      expect(presenceStatus(s.statuses, _u()), 'busy');
      expect(displayStatusOf(withLiveStatus(s.statuses, _u()), true), '在线');
    });

    test('withLiveStatus：覆盖 status，其余字段逐一保留', () {
      final AylaPresenceState s = AylaPresenceState()
        ..setUserStatus('u1', 'invisible');
      final AylaUserPublic? live = withLiveStatus(
        s.statuses,
        _u(online: true, displayStatus: '在线'),
      );
      expect(live!.id, 'u1');
      expect(live.status, 'invisible');
      expect(live.online, isTrue);
      expect(live.displayStatus, '在线', reason: 'display_status 是后端快照口径，原样保留');
    });

    test('withLiveStatus：user 为 null → null（web `if (!user) return user`）', () {
      expect(withLiveStatus(const <String, String>{}, null), isNull);
    });
  });

  group('AylaPresenceState（stores/presence.ts）', () {
    test('presence.update 增量 → 合并到集合', () {
      final AylaPresenceState s = AylaPresenceState()
        ..setUser('u1', 'online')
        ..setUser('u2', 'away');
      expect(s.users, <String, String>{'u1': 'online', 'u2': 'away'});
    });

    test('offline 已知状态保留记录（显示层区分「未收到」与「已离线」）', () {
      final AylaPresenceState s = AylaPresenceState()
        ..setUser('u1', 'online')
        ..setUser('u1', 'offline');
      expect(s.users, <String, String>{'u1': 'offline'});
      expect(s.users.containsKey('u1'), isTrue);
    });

    test('removeUser → 删 key（不存在时也不报错）', () {
      final AylaPresenceState s = AylaPresenceState()
        ..setUser('u1', 'online')
        ..removeUser('u1');
      expect(s.users, isEmpty);
      s.removeUser('u1');
      expect(s.users, isEmpty);
    });

    test('replaceAll → 全量替换', () {
      final AylaPresenceState s = AylaPresenceState()
        ..setUser('u1', 'online')
        ..replaceAll(<String, String>{'u3': 'dnd'});
      expect(s.users, <String, String>{'u3': 'dnd'});
    });

    test('presence.status 增量 → 状态模式映射（勿扰/离开/隐身/自动）', () {
      final AylaPresenceState s = AylaPresenceState()
        ..setUserStatus('u1', 'dnd')
        ..setUserStatus('u2', 'invisible');
      expect(s.statuses, <String, String>{'u1': 'dnd', 'u2': 'invisible'});
    });

    test('连接状态流转 + reset 清空三档（含 statuses）', () {
      final AylaPresenceState s = AylaPresenceState()
        ..setConnection(AylaPresenceConnection.connecting)
        ..setConnection(AylaPresenceConnection.online)
        ..setUser('u1', 'online')
        ..setUserStatus('u1', 'away');
      expect(s.connection, AylaPresenceConnection.online);
      s.reset();
      expect(s.connection, AylaPresenceConnection.offline);
      expect(s.users, isEmpty);
      expect(s.statuses, isEmpty);
    });

    test('通知：同值 setConnection 不重复通知，setUser 变更必通知', () {
      final AylaPresenceState s = AylaPresenceState();
      int notifications = 0;
      s.addListener(() => notifications++);
      s.setConnection(AylaPresenceConnection.offline);
      expect(notifications, 0, reason: '同值不通知（可观察状态未变）');
      s.setConnection(AylaPresenceConnection.connecting);
      expect(notifications, 1);
      s.setUser('u1', 'online');
      expect(notifications, 2);
    });
  });

  group('AylaPresenceWsClient（ws/presence.ts:111–125）', () {
    test('presence.update online / offline 增量 → users', () {
      final AylaPresenceState s = AylaPresenceState();
      final AylaPresenceWsClient client = AylaPresenceWsClient(
        presence: s,
        realtime: AylaRealtimeState(),
      );
      client.debugHandleFrame(<String, dynamic>{
        'type': 'presence.update',
        'data': <String, dynamic>{'user_id': 'u1', 'status': 'online'},
      });
      client.debugHandleFrame(<String, dynamic>{
        'type': 'presence.update',
        'data': <String, dynamic>{'user_id': 'u2', 'status': 'online'},
      });
      expect(s.users, <String, String>{'u1': 'online', 'u2': 'online'});

      client.debugHandleFrame(<String, dynamic>{
        'type': 'presence.update',
        'data': <String, dynamic>{'user_id': 'u1', 'status': 'offline'},
      });
      expect(s.users, <String, String>{'u1': 'offline', 'u2': 'online'});
    });

    test('presence.update 非 offline 值一律记 online（缺 status 同）', () {
      final AylaPresenceState s = AylaPresenceState();
      final AylaPresenceWsClient client = AylaPresenceWsClient(
        presence: s,
        realtime: AylaRealtimeState(),
      );
      client.debugHandleFrame(<String, dynamic>{
        'type': 'presence.update',
        'data': <String, dynamic>{'user_id': 'u1', 'status': 'away'},
      });
      client.debugHandleFrame(<String, dynamic>{
        'type': 'presence.update',
        'data': <String, dynamic>{'user_id': 'u2'},
      });
      expect(s.users, <String, String>{'u1': 'online', 'u2': 'online'});
    });

    test('presence.status 原样存（勿扰/离开/隐身/自动 + 未知值）', () {
      final AylaPresenceState s = AylaPresenceState();
      final AylaPresenceWsClient client = AylaPresenceWsClient(
        presence: s,
        realtime: AylaRealtimeState(),
      );
      client.debugHandleFrame(<String, dynamic>{
        'type': 'presence.status',
        'data': <String, dynamic>{'user_id': 'u1', 'status': 'dnd'},
      });
      client.debugHandleFrame(<String, dynamic>{
        'type': 'presence.status',
        'data': <String, dynamic>{'user_id': 'u2', 'status': 'busy'},
      });
      expect(s.statuses, <String, String>{'u1': 'dnd', 'u2': 'busy'});
    });

    test('坏帧不写状态（非 String type / data 非 map / 缺 user_id / 空 user_id / status 非字符串）', () {
      final AylaPresenceState s = AylaPresenceState();
      final AylaPresenceWsClient client = AylaPresenceWsClient(
        presence: s,
        realtime: AylaRealtimeState(),
      );
      client.debugHandleFrame(<String, dynamic>{'data': <String, dynamic>{}});
      client.debugHandleFrame(<String, dynamic>{
        'type': 'presence.update',
        'data': 'not-a-map',
      });
      client.debugHandleFrame(<String, dynamic>{
        'type': 'presence.update',
        'data': <String, dynamic>{'user_id': ''},
      });
      client.debugHandleFrame(<String, dynamic>{
        'type': 'presence.update',
        'data': <String, dynamic>{'status': 'online'},
      });
      client.debugHandleFrame(<String, dynamic>{
        'type': 'presence.status',
        'data': <String, dynamic>{'user_id': 'u1'},
      });
      expect(s.users, isEmpty);
      expect(s.statuses, isEmpty);
    });

    test('连接态映射：connection 三档 + realtime presence 档（web ws:35/53/70/86）', () {
      final AylaPresenceState s = AylaPresenceState();
      final AylaRealtimeState realtime = AylaRealtimeState();
      final AylaPresenceWsClient client =
          AylaPresenceWsClient(presence: s, realtime: realtime);

      client.debugHandleStatus(WsChannelStatus.connecting);
      expect(s.connection, AylaPresenceConnection.connecting);
      expect(
        realtime.statusOf(AylaRealtimeChannel.presence).connection,
        AylaRealtimeConnection.connecting,
      );

      client.debugHandleStatus(WsChannelStatus.online);
      expect(s.connection, AylaPresenceConnection.online);
      expect(
        realtime.statusOf(AylaRealtimeChannel.presence).connection,
        AylaRealtimeConnection.online,
      );

      client.debugHandleStatus(WsChannelStatus.offline);
      expect(s.connection, AylaPresenceConnection.offline);
      expect(
        realtime.statusOf(AylaRealtimeChannel.presence).connection,
        AylaRealtimeConnection.offline,
      );
    });

    test('disconnect → 清空在线集合 + 连接态 offline（web ws:133–147 的 reset）', () {
      final AylaPresenceState s = AylaPresenceState()
        ..setUser('u1', 'online')
        ..setUserStatus('u1', 'dnd')
        ..setConnection(AylaPresenceConnection.online);
      final AylaRealtimeState realtime = AylaRealtimeState();
      final AylaPresenceWsClient client =
          AylaPresenceWsClient(presence: s, realtime: realtime);

      client.disconnect();

      expect(s.users, isEmpty);
      expect(s.statuses, isEmpty);
      expect(s.connection, AylaPresenceConnection.offline);
      expect(
        realtime.statusOf(AylaRealtimeChannel.presence).connection,
        AylaRealtimeConnection.offline,
      );
    });
  });
}
