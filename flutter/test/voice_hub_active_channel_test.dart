/// 语音大厅「当前所在频道」接线回归锁（web `VoiceHubPage.tsx:303`）。
///
/// ## 事实源
/// | 环节 | web | 行 |
/// |---|---|---|
/// | 大厅列表把当前频道传下去 | `VoiceHubPage.tsx:303` | `currentChannelId={currentChannelId}` |
/// | 卡片的 active 描边 | `.active` → `--indigo-700` | `voice.css:557–559` |
/// | 当前频道的事实源 | `stores/voice.ts:48` `currentChannelId` | join 成功 / leave 清空 |
///
/// ## 为什么需要这条锁
/// `AylaVoiceChannelList` **支持** `currentChannelId`（组件级已锁），但 `VoiceHubPage`
/// 的大厅分支**从未传它** ⇒ 真实运行时那张「我在其中」的卡只剩 `mine` 档，缺 `.active`
/// 的 indigo 描边，与 web 不一致。这是**调用点**缺陷，纯组件测试量不到。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/api/directory_page.dart' show AylaDirectoryPage;
import '../lib/core/api/voice_api.dart' show AylaDirectoryVoiceEntry;
import '../lib/pages/voice_hub_page.dart';
import '../lib/state/directory_store.dart' show aylaDirectoryStore;
import '../lib/state/room_providers.dart' show voiceStateProvider;
import '../lib/state/voice_state.dart'
    show AylaVoiceState, AylaVoiceMemberState;
import '../lib/theme/preview_theme.dart' show previewScope;
import '../lib/widgets/voice/voice_channels.dart'
    show AylaVoiceCardData, AylaVoiceChannelCard, AylaVoiceChannelList;

Widget _host(Widget child) => MaterialApp(
      home: Builder(
        builder: (BuildContext context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(size: const Size(1440, 900)),
          child: previewScope(child),
        ),
      ),
    );

void main() {
  setUp(() {
    aylaDirectoryStore.reset();
    aylaDirectoryStore.userId = 'u1';
  });
  tearDown(() => aylaDirectoryStore.reset());

  testWidgets('大厅列表拿到当前频道 ⇒ 那张卡是 active（web tsx 303）',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    aylaDirectoryStore.requestOverride = (kind, options, cursor) async =>
        AylaDirectoryPage<Object>(
          results: <Object>[
            AylaDirectoryVoiceEntry(
              card: const AylaVoiceCardData(
                id: 'v2',
                name: '深夜电台',
                memberCount: 1,
                mine: true,
              ),
            ),
          ],
          total: 1,
          totalMemberCount: 1,
        );

    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);
    // 域 store 里「我在频道 v2」= join 成功后的真实状态（web stores/voice.ts:48）。
    container
        .read(voiceStateProvider)
        .enterChannel('v2', const <AylaVoiceMemberState>[]);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: _host(const VoiceHubPage()),
      ),
    );
    for (int i = 0; i < 6; i += 1) {
      await tester.pump(const Duration(milliseconds: 80));
    }

    // ① 接线本身：页面必须把当前频道传进列表。
    final AylaVoiceChannelList list =
        tester.widget<AylaVoiceChannelList>(find.byType(AylaVoiceChannelList));
    expect(
      list.currentChannelId,
      'v2',
      reason: '★ VoiceHubPage 必须把 voiceState.currentChannelId 传给列表；'
          '漏传 ⇒ 卡片缺 .active 的 indigo 描边（web tsx 303 有传）',
    );
    // ② 净效果：那张卡渲染为 active。
    expect(
      find.byWidgetPredicate(
        (Widget w) => w is AylaVoiceChannelCard && w.active,
      ),
      findsOneWidget,
      reason: '当前频道那张卡必须是 active（描边 indigo-700）',
    );
  });
}
