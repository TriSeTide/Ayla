/// 三类卡投影 + 目录页 + 收藏条目 + 搜索分组的解析测试（第二批数据层）。
///
/// 三档口径（任务要求）：**完整响应 / 缺字段 / 空集合**。
/// 事实源：web components/cards/cardData.ts（卡投影）· api/directory.ts（游标页）·
/// api/favorites.ts + favorites/target_cards.py（收藏投影）· api/search.ts（六类分组）。
library;

import 'package:flutter_test/flutter_test.dart';

import '../lib/core/api/boardgame_api.dart';
import '../lib/core/api/directory_page.dart';
import '../lib/core/api/favorites_api.dart';
import '../lib/core/api/live_api.dart';
import '../lib/core/api/search_api.dart';
import '../lib/core/api/voice_api.dart';
import '../lib/core/models/game_room.dart';
import '../lib/core/models/subgroup.dart' show AylaGroupJoinPolicy;
import '../lib/core/models/visibility.dart';
import '../lib/widgets/base/directory_result_cards.dart';
import '../lib/widgets/live/live_hall.dart';
import '../lib/widgets/voice/voice_channels.dart';

void main() {
  group('AylaLiveCardData.fromJson（LiveCardData）', () {
    test('完整响应：逐字段对 LiveChannelDescriptor', () {
      final AylaLiveCardData? card =
          AylaLiveCardData.fromJson(<String, Object?>{
        'id': 7,
        'title': '今晚一起打游戏',
        'cover': '/api/v1/media/abc/content',
        'status': 'live',
        'owner_id': 'u1',
        'owner_nickname': '爱莉',
        'viewer_count': 128,
        'visibility': 'friends',
        'allowed_group_names': <Object?>['冰樱研究社', null, '深夜电台'],
        'group_name': '冰樱研究社',
      });
      expect(card, isNotNull);
      expect(card!.id, '7'); // int → String
      expect(card.title, '今晚一起打游戏');
      expect(card.cover, '/api/v1/media/abc/content');
      expect(card.status, AylaLiveStatus.live);
      expect(card.ownerId, 'u1');
      expect(card.ownerNickname, '爱莉');
      expect(card.viewerCount, 128);
      expect(card.visibility, AylaPostVisibility.friends);
      expect(card.allowedGroupNames, <String>['冰樱研究社', '深夜电台']);
      expect(card.groupName, '冰樱研究社');
      // 标签：好友 + 白名单群名（utils/visibility.ts 逐条）
      expect(card.visibilityLabels, <String>['好友', '冰樱研究社', '深夜电台']);
    });

    test('缺字段：只有 id/title 时其余保持缺席，不造默认值', () {
      final AylaLiveCardData? card =
          AylaLiveCardData.fromJson(<String, Object?>{'id': '9', 'title': 'x'});
      expect(card, isNotNull);
      expect(card!.cover, isNull);
      expect(card.status, isNull); // 未知/缺失 → 不渲染徽章
      expect(card.ownerId, '');
      expect(card.ownerNickname, isNull);
      expect(card.viewerCount, isNull); // 读不到 ≠ 0
      expect(card.visibility, isNull);
      expect(card.allowedGroupNames, isEmpty);
      expect(card.groupName, isNull);
      expect(card.visibilityLabels, isEmpty); // visibility 缺失 ⇒ 空标签
    });

    test('空集合 / 非法输入：null / 非 Map / 缺必填 → null', () {
      expect(AylaLiveCardData.fromJson(null), isNull);
      expect(AylaLiveCardData.fromJson(<Object?>[]), isNull);
      expect(AylaLiveCardData.fromJson(<String, Object?>{'id': '1'}), isNull);
      expect(AylaLiveCardData.fromJson(<String, Object?>{'title': 't'}), isNull);
      expect(AylaLiveCardData.fromJson(<String, Object?>{'id': ''}), isNull);
    });

    test('未知枚举值 → null（不 fallback）', () {
      final AylaLiveCardData card = AylaLiveCardData.fromJson(<String, Object?>{
        'id': '1',
        'title': 't',
        'status': 'weird',
        'visibility': 'weird',
      })!;
      expect(card.status, isNull);
      expect(card.visibility, isNull);
    });

    test('cover 空串归一为 null（web 的真值判断）', () {
      expect(
        AylaLiveCardData.fromJson(
          <String, Object?>{'id': '1', 'title': 't', 'cover': ''},
        )!.cover,
        isNull,
      );
    });
  });

  group('AylaVoiceCardData.fromJson（VoiceCardData）', () {
    test('完整响应：逐字段对 VoiceChannelDescriptor', () {
      final AylaVoiceCardData? card =
          AylaVoiceCardData.fromJson(<String, Object?>{
        'id': 'v1',
        'name': '深夜电台',
        'owner_nickname': '爱莉',
        'member_count': 5,
        'visibility': 'public',
        'allowed_group_names': <Object?>['冰樱研究社'],
        'group_name': null,
        'mine': true,
      });
      expect(card, isNotNull);
      expect(card!.id, 'v1');
      expect(card.name, '深夜电台');
      expect(card.ownerNickname, '爱莉');
      expect(card.memberCount, 5);
      expect(card.visibility, AylaPostVisibility.public);
      expect(card.allowedGroupNames, <String>['冰樱研究社']);
      expect(card.mine, isTrue);
      expect(card.visibilityLabels, <String>['公开', '冰樱研究社']);
    });

    test('缺字段：member_count 缺失 → null（与 0 语义不同）', () {
      final AylaVoiceCardData? card = AylaVoiceCardData.fromJson(
        <String, Object?>{'id': 'v2', 'name': 'x'},
      );
      expect(card, isNotNull);
      expect(card!.memberCount, isNull);
      expect(card.ownerNickname, isNull);
      expect(card.visibility, isNull);
      expect(card.mine, isFalse);
      expect(card.groupName, isNull);
    });

    test('空集合 / 非法输入', () {
      expect(AylaVoiceCardData.fromJson(null), isNull);
      expect(AylaVoiceCardData.fromJson(<String, Object?>{'id': 'v3'}), isNull);
      expect(AylaVoiceCardData.fromJson(<String, Object?>{'name': 'n'}), isNull);
    });
  });

  group('AylaGameCardData.fromJson（GameCardData）', () {
    test('完整响应：逐字段对 GameRoom', () {
      final AylaGameCardData? card =
          AylaGameCardData.fromJson(<String, Object?>{
        'id': 3,
        'name': '冰樱桌游室',
        'status': 'playing',
        'owner': <String, Object?>{
          'id': 'u1',
          'nickname': '爱莉',
          'username': 'elysia',
        },
        'member_count': 4,
        'visibility': 'group',
        'allowed_group_names': <Object?>['冰樱研究社'],
        'group_name': '冰樱研究社',
      });
      expect(card, isNotNull);
      expect(card!.id, '3');
      expect(card.name, '冰樱桌游室');
      expect(card.status, AylaGameRoomStatus.playing);
      expect(card.owner?.id, 'u1');
      expect(card.ownerDisplayName, '爱莉');
      expect(card.memberCount, 4);
      expect(card.visibility, AylaPostVisibility.group);
      expect(card.visibilityLabels, <String>['冰樱研究社']);
    });

    test('缺字段：owner / member_count / status 缺席', () {
      final AylaGameCardData? card =
          AylaGameCardData.fromJson(<String, Object?>{'id': '4', 'name': 'x'});
      expect(card, isNotNull);
      expect(card!.owner, isNull);
      expect(card.ownerDisplayName, isNull);
      expect(card.memberCount, isNull);
      expect(card.status, isNull);
      expect(card.visibilityLabels, isEmpty);
    });

    test('空集合 / 非法输入', () {
      expect(AylaGameCardData.fromJson(null), isNull);
      expect(AylaGameCardData.fromJson(<String, Object?>{'id': '5'}), isNull);
      expect(AylaGameCardData.fromJson(<String, Object?>{'name': 'n'}), isNull);
    });
  });

  group('AylaDirectoryPage.fromJson（DirectoryPage）', () {
    test('完整分页响应：results / next_cursor / has_more / total / total_member_count',
        () {
      final AylaDirectoryPage<AylaDirectoryVoiceEntry> page =
          AylaDirectoryPage.fromJson<AylaDirectoryVoiceEntry>(
        <String, Object?>{
          'results': <Object?>[
            <String, Object?>{'id': 'v1', 'name': 'a', 'owner_id': 'u1'},
            <String, Object?>{'id': 'v2', 'name': 'b', 'owner_id': 'u2'},
          ],
          'next_cursor': 'c2',
          'has_more': true,
          'total': 42,
          'total_member_count': 7,
        },
        AylaDirectoryVoiceEntry.fromJson,
      );
      expect(page.results.length, 2);
      expect(page.results.first.ownerId, 'u1');
      expect(page.nextCursor, 'c2');
      expect(page.hasMore, isTrue);
      expect(page.total, 42);
      expect(page.totalMemberCount, 7);
    });

    test('缺字段：非 Map → 空页；缺 total / total_member_count → 0 / null', () {
      final AylaDirectoryPage<AylaDirectoryLiveEntry> empty =
          AylaDirectoryPage.fromJson<AylaDirectoryLiveEntry>(
        null,
        AylaDirectoryLiveEntry.fromJson,
      );
      expect(empty.results, isEmpty);
      expect(empty.nextCursor, isNull);
      expect(empty.hasMore, isFalse);
      expect(empty.total, 0);
      expect(empty.totalMemberCount, isNull);
    });

    test('空集合：results 为空数组 → 空列表（不是「未取到」）', () {
      final AylaDirectoryPage<AylaDirectoryGameEntry> page =
          AylaDirectoryPage.fromJson<AylaDirectoryGameEntry>(
        <String, Object?>{
          'results': <Object?>[],
          'next_cursor': null,
          'has_more': false,
          'total': 0,
        },
        AylaDirectoryGameEntry.fromJson,
      );
      expect(page.results, isEmpty);
      expect(page.hasMore, isFalse);
      expect(page.total, 0);
    });

    test('非法条目逐个跳过（不整页失败）', () {
      final AylaDirectoryPage<AylaDirectoryLiveEntry> page =
          AylaDirectoryPage.fromJson<AylaDirectoryLiveEntry>(
        <String, Object?>{
          'results': <Object?>[
            <String, Object?>{'id': 1, 'title': 'ok'},
            'not-a-map',
            <String, Object?>{'id': 2},
          ],
          'has_more': false,
          'total': 3,
        },
        AylaDirectoryLiveEntry.fromJson,
      );
      expect(page.results.length, 1);
      expect(page.results.single.card.id, '1');
      expect(page.total, 3); // total 是服务端总数，不受本地跳过影响
    });
  });

  group('AylaFavoriteEntry.fromJson（收藏五类投影）', () {
    test('voice 目标：投影喂给 AylaFavoriteResultData', () {
      final AylaFavoriteEntry? entry =
          AylaFavoriteEntry.fromJson(<String, Object?>{
        'id': 3,
        'user_id': 'u1',
        'target_type': 'voice',
        'target_id': 'v1',
        'target': <String, Object?>{
          'id': 'v1',
          'name': '深夜电台',
          'member_count': 5,
          'visibility': 'public',
        },
        'created_at': '2026-09-28T00:00:00Z',
      });
      expect(entry, isNotNull);
      expect(entry!.card.id, 3);
      expect(entry.card.targetType, AylaFavoriteTargetType.voice);
      expect(entry.card.isAvailable, isTrue);
      expect(entry.card.voice?.name, '深夜电台');
      expect(entry.card.post, isNull);
      expect(entry.targetId, 'v1');
      expect(entry.createdAt, '2026-09-28T00:00:00Z');
    });

    test('message 目标：带 sender_nickname 与定位字段', () {
      final AylaFavoriteEntry? entry =
          AylaFavoriteEntry.fromJson(<String, Object?>{
        'id': 4,
        'target_type': 'message',
        'target_id': 'm1',
        'target': <String, Object?>{
          'id': 'm1',
          'conversation_id': 'c1',
          'sender_id': 'u2',
          'sender_nickname': '汐汐',
          'type': 'text',
          'content': '你好',
          'status': 'sent',
          'seq': 12,
          'subgroup_id': 'sg1',
          'created_at': '2026-09-28T00:00:00Z',
        },
      });
      expect(entry, isNotNull);
      expect(entry!.card.targetType, AylaFavoriteTargetType.message);
      expect(entry.card.message?.conversationId, 'c1');
      expect(entry.card.message?.seq, 12);
      expect(entry.card.message?.subgroupId, 'sg1');
      expect(entry.messageSenderNickname, '汐汐');
    });

    test('缺 target（内容不可用）与空集合 / 非法输入', () {
      final AylaFavoriteEntry? missing =
          AylaFavoriteEntry.fromJson(<String, Object?>{
        'id': 5,
        'target_type': 'post',
        'target_id': 'p1',
        'target': null,
      });
      expect(missing, isNotNull);
      expect(missing!.card.isAvailable, isFalse); // web 的 .typed-unavailable-card 分支
      expect(missing.card.post, isNull);

      expect(AylaFavoriteEntry.fromJson(null), isNull);
      expect(AylaFavoriteEntry.fromJson(<Object?>[]), isNull);
      // 未知 target_type → null（不 fallback 成某个类别）
      expect(
        AylaFavoriteEntry.fromJson(
          <String, Object?>{'id': 6, 'target_type': 'unknown'},
        ),
        isNull,
      );
      expect(AylaFavoriteEntry.fromJson(<String, Object?>{'id': 7}), isNull);
    });
  });

  group('AylaSearchResults.fromJson（六类分组）', () {
    test('完整响应：六类各自解析 + totalResults', () {
      final AylaSearchResults results =
          AylaSearchResults.fromJson(<String, Object?>{
        'users': <String, Object?>{
          'items': <Object?>[
            <String, Object?>{
              'id': 'u1',
              'nickname': '爱莉',
              'signature': '你好',
              'online': true,
            },
          ],
          'total': 1,
          'has_more': false,
        },
        'groups': <String, Object?>{
          'items': <Object?>[
            <String, Object?>{
              'id': 'g1',
              'title': '冰樱研究社',
              'is_member': true,
              'join_policy': 'public',
              'member_count': 42,
            },
          ],
          'total': 1,
        },
        'posts': <String, Object?>{
          'items': <Object?>[
            <String, Object?>{'id': 1, 'title': '帖子', 'body': '正文'},
          ],
          'total': 1,
        },
        'lives': <String, Object?>{
          'items': <Object?>[
            <String, Object?>{'id': 5, 'title': '播'},
          ],
          'total': 1,
          'next_cursor': 'live-c2',
          'has_more': true,
        },
        'games': <String, Object?>{
          'items': <Object?>[
            <String, Object?>{'id': 9, 'name': '房'},
          ],
          'total': 1,
        },
        'voices': <String, Object?>{
          'items': <Object?>[
            <String, Object?>{'id': 'v1', 'name': '房'},
          ],
          'total': 1,
        },
      });
      expect(results.totalResults, 6);
      expect(results.hasAnyResult, isTrue);
      expect(results.users!.items.single.signature, '你好');
      expect(results.users!.items.single.online, isTrue);
      expect(results.groups!.items.single.isMember, isTrue);
      expect(results.groups!.items.single.joinPolicy, AylaGroupJoinPolicy.public);
      expect(results.groups!.items.single.memberCount, 42);
      expect(results.posts!.items.single.id, 1);
      expect(results.lives!.items.single.title, '播');
      expect(results.lives!.hasMore, isTrue);
      expect(results.lives!.nextCursor, 'live-c2');
      expect(results.games!.items.single.name, '房');
      expect(results.voices!.items.single.name, '房');
    });

    test('缺字段：未请求的类型为 null；is_member 缺失保持三态 null', () {
      final AylaSearchResults results =
          AylaSearchResults.fromJson(<String, Object?>{
        'groups': <String, Object?>{
          'items': <Object?>[
            <String, Object?>{'id': 'g2', 'title': '无成员事实的群'},
          ],
          'total': 1,
        },
      });
      expect(results.users, isNull);
      expect(results.posts, isNull);
      expect(results.lives, isNull);
      expect(results.games, isNull);
      expect(results.voices, isNull);
      // 旧后端不给 is_member ⇒ null（不是 false）
      expect(results.groups!.items.single.isMember, isNull);
    });

    test('空集合：全空 → hasAnyResult 假；非 Map → 全 null', () {
      final AylaSearchResults empty = AylaSearchResults.fromJson(<String, Object?>{
        'users': <String, Object?>{'items': <Object?>[], 'total': 0},
        'lives': <String, Object?>{'items': <Object?>[], 'total': 0},
      });
      expect(empty.hasAnyResult, isFalse);
      expect(empty.users!.items, isEmpty);
      expect(empty.lives!.items, isEmpty);

      final AylaSearchResults notMap = AylaSearchResults.fromJson(null);
      expect(notMap.hasAnyResult, isFalse);
      expect(notMap.users, isNull);
    });
  });
}
