/// P1-4 定向测试：群内收藏消息深链 `?msg=&seq=&subgroup=`
/// —— web `pages/group/GroupChat.tsx:72–101` + `components/chat/MessageList.tsx:184 / :785–818`。
///
/// web 两条判据（本组逐条锁）：
/// 1. **子群切换**（`GroupChat.tsx:87–101`）：
///    - 带 `subgroup` 且该子群**存在**且不是当前 ⇒ 切过去；
///    - 不带 `subgroup` ⇒ 切到**默认组**；
///    - 子群已删 ⇒ **保持当前视图**（web 原话「跳转自然失败」）。
/// 2. **定位门控**（`MessageList.tsx:791–796` 的 `subgroupMatches`）：
///    目标子群与当前视图不匹配时 **不跳**，等父级切换后由新实例处理。
///
/// 纯函数覆盖两条判据的全部分支（不依赖 widget / 网络）；
/// 路由层「三个 query 参数确实被解析成构造参数」由 `test/group_deeplink_route_test.dart` 覆盖。
library;

import 'package:flutter_test/flutter_test.dart';

import '../lib/pages/group_chat_page.dart'
    show aylaGroupJumpSubgroupMatches, aylaGroupJumpTargetSubgroupId;

/// 子群条目（与页面里 `({String id, bool isDefault})` 的 record 形状一致）。
({String id, bool isDefault}) sg(String id, {bool isDefault = false}) =>
    (id: id, isDefault: isDefault);

void main() {
  group('aylaGroupJumpTargetSubgroupId（web GroupChat.tsx:87–101）', () {
    final List<({String id, bool isDefault})> list = <({String id, bool isDefault})>[
      sg('sg-default', isDefault: true),
      sg('sg-a'),
      sg('sg-b'),
    ];

    test('带 subgroup 且存在、且不是当前 ⇒ 切到该子群', () {
      expect(
        aylaGroupJumpTargetSubgroupId(
          jumpSubgroupId: 'sg-a',
          activeSubgroupId: 'sg-default',
          subgroups: list,
        ),
        'sg-a',
      );
    });

    test('带 subgroup 但**已经是当前** ⇒ 返回 null（不重复切、不重拉历史）', () {
      expect(
        aylaGroupJumpTargetSubgroupId(
          jumpSubgroupId: 'sg-a',
          activeSubgroupId: 'sg-a',
          subgroups: list,
        ),
        isNull,
      );
    });

    test('带 subgroup 但该子群**已删除** ⇒ 返回 null，保持当前视图（web 原话）', () {
      expect(
        aylaGroupJumpTargetSubgroupId(
          jumpSubgroupId: 'sg-gone',
          activeSubgroupId: 'sg-default',
          subgroups: list,
        ),
        isNull,
      );
    });

    test('不带 subgroup ⇒ 切到**默认组**', () {
      expect(
        aylaGroupJumpTargetSubgroupId(
          jumpSubgroupId: null,
          activeSubgroupId: 'sg-a',
          subgroups: list,
        ),
        'sg-default',
      );
    });

    test('不带 subgroup 且已在默认组 ⇒ 返回 null', () {
      expect(
        aylaGroupJumpTargetSubgroupId(
          jumpSubgroupId: null,
          activeSubgroupId: 'sg-default',
          subgroups: list,
        ),
        isNull,
      );
    });

    test('不带 subgroup 且列表里**没有默认组** ⇒ 返回 null（不猜）', () {
      expect(
        aylaGroupJumpTargetSubgroupId(
          jumpSubgroupId: null,
          activeSubgroupId: 'sg-a',
          subgroups: <({String id, bool isDefault})>[sg('sg-a'), sg('sg-b')],
        ),
        isNull,
      );
    });

    test('空串 subgroup 等同「不带」（路由里 `?subgroup=` 的退化形态）', () {
      expect(
        aylaGroupJumpTargetSubgroupId(
          jumpSubgroupId: '',
          activeSubgroupId: 'sg-a',
          subgroups: list,
        ),
        'sg-default',
      );
    });

    test('子群列表为空（尚未加载）⇒ 一律返回 null（不越权切）', () {
      expect(
        aylaGroupJumpTargetSubgroupId(
          jumpSubgroupId: 'sg-a',
          activeSubgroupId: null,
          subgroups: const <({String id, bool isDefault})>[],
        ),
        isNull,
      );
      expect(
        aylaGroupJumpTargetSubgroupId(
          jumpSubgroupId: null,
          activeSubgroupId: null,
          subgroups: const <({String id, bool isDefault})>[],
        ),
        isNull,
      );
    });
  });

  group('aylaGroupJumpSubgroupMatches（web MessageList.tsx:791–796）', () {
    test('目标是子群 A、当前也是 A ⇒ 匹配', () {
      expect(
        aylaGroupJumpSubgroupMatches(
          activeSubgroupId: 'sg-a',
          activeIsDefault: false,
          jumpSubgroupId: 'sg-a',
        ),
        isTrue,
      );
    });

    test('目标是子群 A、当前是 B ⇒ **不匹配**（等父级切过去）', () {
      expect(
        aylaGroupJumpSubgroupMatches(
          activeSubgroupId: 'sg-b',
          activeIsDefault: false,
          jumpSubgroupId: 'sg-a',
        ),
        isFalse,
      );
    });

    test('目标无子群（默认组）、当前是默认组 ⇒ 匹配', () {
      expect(
        aylaGroupJumpSubgroupMatches(
          activeSubgroupId: 'sg-default',
          activeIsDefault: true,
          jumpSubgroupId: null,
        ),
        isTrue,
      );
    });

    test('目标无子群（默认组）、当前是非默认子群 ⇒ 不匹配', () {
      expect(
        aylaGroupJumpSubgroupMatches(
          activeSubgroupId: 'sg-a',
          activeIsDefault: false,
          jumpSubgroupId: null,
        ),
        isFalse,
      );
    });

    test('目标有子群、当前是默认组 ⇒ 不匹配', () {
      expect(
        aylaGroupJumpSubgroupMatches(
          activeSubgroupId: 'sg-default',
          activeIsDefault: true,
          jumpSubgroupId: 'sg-a',
        ),
        isFalse,
      );
    });

    test('空串 jumpSubgroupId 等同「目标在默认组」', () {
      expect(
        aylaGroupJumpSubgroupMatches(
          activeSubgroupId: 'sg-default',
          activeIsDefault: true,
          jumpSubgroupId: '',
        ),
        isTrue,
      );
    });

    test('尚未选中子群（active == null）⇒ 看 activeIsDefault（默认组视图视为匹配）', () {
      expect(
        aylaGroupJumpSubgroupMatches(
          activeSubgroupId: null,
          activeIsDefault: true,
          jumpSubgroupId: null,
        ),
        isTrue,
      );
      expect(
        aylaGroupJumpSubgroupMatches(
          activeSubgroupId: null,
          activeIsDefault: false,
          jumpSubgroupId: null,
        ),
        isFalse,
      );
    });
  });
}
