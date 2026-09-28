/// 收藏状态机（AylaFavoriteStatusController）定向测试。
///
/// 事实源：web stores/favoriteStatus.ts（未知态 ≠ 未收藏 · 批量查询 · 60s 新鲜期 ·
/// 响应必须覆盖全部 id）+ components/FavoriteButton.tsx（未知/错误态点击 = 重新拉取）。
library;

import 'package:flutter_test/flutter_test.dart';

import '../lib/core/api/favorites_api.dart';
import '../lib/state/favorite_status.dart';
import '../lib/widgets/base/favorite_button.dart' show AylaFavoriteState;

void main() {
  test('未查询 → unknown（不是未收藏）', () {
    final AylaFavoriteStatusController controller =
        AylaFavoriteStatusController(
      fetcher: (String type, List<String> ids) async =>
          const AylaFavoriteStatuses(targetType: 'live', statuses: <String, int?>{}),
    );
    expect(controller.stateOf('live', '1'), AylaFavoriteState.unknown);
    expect(controller.favoriteIdOf('live', '1'), isNull);
    controller.dispose();
  });

  test('批量查询成功 → favorited / notFavorited 两态', () async {
    final List<List<String>> requested = <List<String>>[];
    final AylaFavoriteStatusController controller =
        AylaFavoriteStatusController(
      fetcher: (String type, List<String> ids) async {
        requested.add(ids);
        return AylaFavoriteStatuses(
          targetType: type,
          statuses: <String, int?>{'a': 12, 'b': null},
        );
      },
    );
    await controller.load('live', <String>['a', 'b']);
    expect(requested.single, <String>['a', 'b']);
    expect(controller.stateOf('live', 'a'), AylaFavoriteState.favorited);
    expect(controller.stateOf('live', 'b'), AylaFavoriteState.notFavorited);
    expect(controller.favoriteIdOf('live', 'a'), 12);
    expect(controller.favoriteIdOf('live', 'b'), isNull);
    controller.dispose();
  });

  test('响应缺某个 id ⇒ 不完整 ⇒ error 态（不把没给当成未收藏）', () async {
    final AylaFavoriteStatusController controller =
        AylaFavoriteStatusController(
      fetcher: (String type, List<String> ids) async =>
          const AylaFavoriteStatuses(targetType: 'live', statuses: <String, int?>{}),
    );
    await controller.load('live', <String>['a']);
    expect(controller.stateOf('live', 'a'), AylaFavoriteState.error);
    controller.dispose();
  });

  test('60s 新鲜期内不重复查询；force 无视新鲜期', () async {
    int calls = 0;
    final AylaFavoriteStatusController controller =
        AylaFavoriteStatusController(
      fetcher: (String type, List<String> ids) async {
        calls += 1;
        return AylaFavoriteStatuses(
          targetType: type,
          statuses: <String, int?>{'a': null},
        );
      },
    );
    await controller.load('live', <String>['a']);
    await controller.load('live', <String>['a']);
    expect(calls, 1);
    await controller.load('live', <String>['a'], force: true);
    expect(calls, 2);
    controller.dispose();
  });

  test('未知态点击 = 重新拉取状态，不发收藏请求', () async {
    int adds = 0;
    int removes = 0;
    int fetches = 0;
    final AylaFavoriteStatusController controller =
        AylaFavoriteStatusController(
      fetcher: (String type, List<String> ids) async {
        fetches += 1;
        return AylaFavoriteStatuses(
          targetType: type,
          statuses: <String, int?>{'a': null},
        );
      },
      add: (String type, String id) async {
        adds += 1;
        return 99;
      },
      remove: (int favoriteId) async {
        removes += 1;
      },
    );
    await controller.toggle('live', 'a'); // 未知态 ⇒ 只拉状态
    expect(fetches, 1);
    expect(adds, 0);
    expect(removes, 0);
    expect(controller.stateOf('live', 'a'), AylaFavoriteState.notFavorited);

    await controller.toggle('live', 'a'); // 已查到未收藏 ⇒ 收藏
    expect(adds, 1);
    expect(controller.stateOf('live', 'a'), AylaFavoriteState.favorited);
    expect(controller.favoriteIdOf('live', 'a'), 99);

    await controller.toggle('live', 'a'); // 已收藏 ⇒ 取消
    expect(removes, 1);
    expect(controller.stateOf('live', 'a'), AylaFavoriteState.notFavorited);
    controller.dispose();
  });

  test('收藏动作失败 → actionError（状态不变）', () async {
    final AylaFavoriteStatusController controller =
        AylaFavoriteStatusController(
      fetcher: (String type, List<String> ids) async =>
          AylaFavoriteStatuses(
        targetType: type,
        statuses: <String, int?>{'a': null},
      ),
      add: (String type, String id) async => throw StateError('boom'),
    );
    await controller.load('live', <String>['a']);
    await controller.toggle('live', 'a');
    expect(controller.stateOf('live', 'a'), AylaFavoriteState.notFavorited);
    expect(controller.actionErrorOf('live', 'a'), isNotNull);
    expect(controller.busyOf('live', 'a'), isFalse);
    controller.dispose();
  });

  test('apply 直接写入（收藏页取消收藏后对账）', () async {
    final AylaFavoriteStatusController controller =
        AylaFavoriteStatusController(
      fetcher: (String type, List<String> ids) async =>
          AylaFavoriteStatuses(
        targetType: type,
        statuses: <String, int?>{'a': 3},
      ),
    );
    await controller.load('live', <String>['a']);
    expect(controller.stateOf('live', 'a'), AylaFavoriteState.favorited);
    controller.apply('live', 'a', null);
    expect(controller.stateOf('live', 'a'), AylaFavoriteState.notFavorited);
    controller.dispose();
  });
}
