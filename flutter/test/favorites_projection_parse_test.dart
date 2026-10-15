/// 缺陷 1 的端到端锁：用**真实收藏 API 的原始 JSON** 走 AylaFavoriteEntry.fromJson，
/// 断言帖子类型不再退化为「内容不可用」。
///
/// 形状逐字取自 2026-10-15 对 http://127.0.0.1:8100/api/v1/favorites/ 的实测响应
/// （target.id 是字符串 '106'、且**没有 title 字段**、只有 raw_title）。
library;

import 'package:flutter_test/flutter_test.dart';

import '../lib/core/api/favorites_api.dart';
import '../lib/widgets/base/directory_result_cards.dart'
    show AylaFavoriteTargetType;

void main() {
  group('收藏 API 原始响应 → 条目投影', () {
    test('post 类型：target.id 为字符串 ⇒ 卡片可用（不得退化为「内容不可用」）', () {
      final AylaFavoriteEntry? entry = AylaFavoriteEntry.fromJson(<String, dynamic>{
        'id': 44,
        'target_type': 'post',
        'target_id': '106',
        'created_at': '2026-10-01T10:00:00+08:00',
        'target': <String, dynamic>{
          'id': '106',
          'author_id': '123',
          'author_nickname': '123',
          'raw_title': '111',
          'title': '111',
          'body': '阿巴阿巴',
          'visibility': 'public',
          'group': null,
          'group_name': null,
          'allowed_group_ids': <Object?>[],
          'allowed_group_names': <Object?>[],
          'images': <Object?>[],
          'comment_count': 2,
          'is_author': true,
          'view_count': 2,
          'is_viewed': true,
          'created_at': '2026-08-29T10:00:00+08:00',
          'updated_at': null,
        },
      });
      expect(entry, isNotNull);
      expect(entry!.card.targetType, AylaFavoriteTargetType.post);
      expect(entry.card.isAvailable, isTrue,
          reason: 'id 是字符串也必须可用（否则渲染「内容不可用」）');
      expect(entry.card.post!.id, 106);
      expect(entry.card.post!.title, '111');
      expect(entry.targetId, '106');
    });

    test('live / voice / game 三类（target.id 为数字）也都要可用', () {
      final AylaFavoriteEntry? live = AylaFavoriteEntry.fromJson(<String, dynamic>{
        'id': 26,
        'target_type': 'live',
        'target_id': '128',
        'target': <String, dynamic>{'id': 128, 'title': '直播间'},
      });
      expect(live!.card.isAvailable, isTrue);

      final AylaFavoriteEntry? voice = AylaFavoriteEntry.fromJson(<String, dynamic>{
        'id': 25,
        'target_type': 'voice',
        'target_id': '12',
        'target': <String, dynamic>{'id': 12, 'name': '语音房'},
      });
      expect(voice!.card.isAvailable, isTrue);

      final AylaFavoriteEntry? game = AylaFavoriteEntry.fromJson(<String, dynamic>{
        'id': 24,
        'target_type': 'game',
        'target_id': '7',
        'target': <String, dynamic>{'id': 7, 'name': '桌游房'},
      });
      expect(game!.card.isAvailable, isTrue);
    });

    test('target 为 null（真实不可用）仍判不可用（不得伪造内容）', () {
      final AylaFavoriteEntry? entry = AylaFavoriteEntry.fromJson(<String, dynamic>{
        'id': 99,
        'target_type': 'post',
        'target_id': '999',
        'target': null,
      });
      expect(entry, isNotNull);
      expect(entry!.card.isAvailable, isFalse);
    });
  });
}