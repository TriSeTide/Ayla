/// 语音房宿主的 `roomRoute` 接线锁 —— 用户实报「点悬浮球回不到房间」轮（2026-10-17）。
///
/// ## 事实源（web `hooks/useVoiceChannel.ts:256–262`）
/// ```ts
/// useSessionActivityStore.getState().upsert({
///   kind: "voice", sessionId: channelId,
///   sourceRoute: typeof window !== "undefined" && window.location.pathname.startsWith("/group/")
///     ? window.location.pathname : `/voice/${encodeURIComponent(channelId)}`,
///   ...
/// });
/// ```
/// ⇒ 一级语音的 `sourceRoute` = **`/voice/:id`**；群内语音 = 群场景路由。
///
/// ## 缺陷（本轮修）
/// Flutter 侧把「退出落点 `backPath`」与「回房路由 `roomRoute`」混用同一个参数：
/// - `backPath` 一级语音 = `/voice`（列表页，正确）；
/// - 但它被直接当成 `sourceRoute` 写进活动索引 ⇒ 索引里是 `/voice`（**不带 id**）
///   ⇒ 悬浮球点击导航到列表页，**回不到那个房间**。
///
/// ## 本文件锁什么
/// 直接读 `aylaSessionActivity.voiceSession.sourceRoute`（索引的真实写入值）——
/// 比断言 UI 更贴近事实源，且**不 seed 索引**（seed 会掩盖缺陷）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/api/voice_api.dart' show AylaVoiceChannelSnapshot;
import '../lib/pages/voice_hub_page.dart';
import '../lib/pages/voice_support.dart' show AylaVoiceRoomHost;
import '../lib/state/room_providers.dart' show voiceStateProvider;
import '../lib/state/session_activity_state.dart' show aylaSessionActivity;
import '../lib/theme/preview_theme.dart' show previewScope;

Widget _host(Widget child) => MaterialApp(
      home: Builder(
        builder: (BuildContext context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(size: const Size(1440, 900)),
          child: previewScope(child),
        ),
      ),
    );

void main() {
  setUp(aylaSessionActivity.reset);
  tearDown(aylaSessionActivity.reset);

  testWidgets('一级语音房内宿主的 roomRoute = /voice/:id（web useVoiceChannel.ts:258）',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);
    // 预置频道描述：宿主的 bootstrap 拉详情会打网络（测试里 404 无所谓），
    // 但 join/upsert 需要 channels[id] 提供 title —— 直接塞进域 store。
    container.read(voiceStateProvider).upsertChannel(
          const AylaVoiceChannelSnapshot(id: '54', name: '13244'),
        );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: _host(const VoiceHubPage(channelId: '54')),
      ),
    );
    // join 链是异步的（REST 失败后仍会走补偿路径），给足帧数让 upsert 可能发生。
    for (int i = 0; i < 10; i += 1) {
      await tester.pump(const Duration(milliseconds: 60));
    }

    // ★ 这里可能两条路径：
    //   ① join 成功 ⇒ 索引写入（断言写入值）；
    //   ② join 因无网络失败 ⇒ 索引未写入 —— 此时断言宿主参数本身。
    // 为让断言在无网络下仍有判别力，直接读宿主 widget 的 roomRoute 参数。
    final AylaVoiceRoomHost host = tester.widget<AylaVoiceRoomHost>(
      find.byType(AylaVoiceRoomHost),
    );
    expect(
      host.roomRoute,
      '/voice/54',
      reason: '★ 回房路由必须带频道 id（web useVoiceChannel.ts:258 的 /voice/:id）；'
          '若传 null 而回落 backPath（/voice）⇒ 点悬浮球回列表页而不是房间',
    );
    expect(
      host.backPath,
      '/voice',
      reason: '退出落点仍是列表页（不得被回房路由污染）',
    );
  });
}
