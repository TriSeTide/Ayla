/// 直播弹幕热更新 + presence 自身登记 回归锁（2026-10-26）。
///
/// 用户实报：
/// ① 自己发弹幕后头像不在线  ② 别人弹幕头像不在线  ③ 新弹幕不热更新
///
/// ①② 根因（已修）：`presence.self` / 建连 `presence.update` 在 `attach` 之前
/// 被丢弃 ⇒ `presence.users` 永远没有「自己」⇒ 回退 REST 快照 = 恒离线。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/api/live_api.dart' show AylaLiveDanmaku;
import '../lib/state/live_state.dart' show AylaLiveState, kAylaDanmakuMaxItems;
import '../lib/state/presence_providers.dart' show presenceStateProvider;

AylaLiveDanmaku _dm(String id, int second) => AylaLiveDanmaku(
      id: id,
      // ⚠️ createdAt 必须**单调递增**：normalizeDanmaku 按其排序，
      // 全部相同会让顺序不确定（第一版测试就栽在这）。
      createdAt: '2026-10-26T10:00:' + second.toString().padLeft(2, '0') + 'Z',
      senderUserId: 'u2',
      senderNickname: '小樱',
      content: 'c' + id,
    );

void main() {
  test('★ presence.update(自己) 后 store 里有自己', () {
    final ProviderContainer c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(presenceStateProvider).setUser('me', 'online');
    expect(c.read(presenceStateProvider).users['me'], 'online',
        reason: '自己不在 store ⇒ presenceOnline 回退 REST 快照 ⇒ 永远离线');
  });

  test('★ presence.self（只带 id）也把自己标记在线', () {
    final ProviderContainer c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(presenceStateProvider).setUser('me2', 'online');
    expect(c.read(presenceStateProvider).users['me2'], 'online');
  });

  test('★ appendDanmaku 后能看到新弹幕', () {
    final AylaLiveState live = AylaLiveState();
    addTearDown(live.dispose);
    expect(live.danmaku, isEmpty);
    live.appendDanmaku(_dm('d1', 0));
    expect(live.danmaku.length, 1);
    live.appendDanmaku(_dm('d2', 1));
    expect(live.danmaku.length, 2);
    expect(live.danmaku.last.content, 'cd2');
  });

  test('★ 重复 id 不重复追加', () {
    final AylaLiveState live = AylaLiveState();
    addTearDown(live.dispose);
    final AylaLiveDanmaku one = _dm('dup', 0);
    live.appendDanmaku(one);
    live.appendDanmaku(one);
    expect(live.danmaku.length, 1);
  });

  test('★ 超过上限时保留最新一条（裁头不裁尾）', () {
    final AylaLiveState live = AylaLiveState();
    addTearDown(live.dispose);
    for (int i = 0; i < kAylaDanmakuMaxItems + 5; i += 1) {
      final String mm = (i ~/ 60).toString().padLeft(2, '0');
      final String ss = (i % 60).toString().padLeft(2, '0');
      live.appendDanmaku(AylaLiveDanmaku(
        id: 'm' + i.toString(),
        createdAt: '2026-10-26T10:' + mm + ':' + ss + 'Z',
        content: 'c' + i.toString(),
      ));
    }
    expect(live.danmaku.length, kAylaDanmakuMaxItems);
    final String lastId = 'm' + (kAylaDanmakuMaxItems + 4).toString();
    expect(live.danmaku.last.id, lastId,
        reason: '最新一条必须保留 —— 裁掉尾部会让用户刚发的弹幕立刻消失');
  });
}
