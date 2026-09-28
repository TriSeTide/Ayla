/// 主页纯逻辑定向测试 —— 逐条对照 web `components/home/groupActivity.ts`（399 行）
/// 与官方用例 `vitest/group-activity.test.ts`。
///
/// 覆盖：时间窗口（含 1min 时钟容差）/ 白名单可见性（字符串比较）/ 消息事件
/// （poke 不加前缀、preview 优先、媒体占位、窗口外不产生）/ 群排序（置顶 > 时间新→旧 >
/// 稳定索引）/ 角标存在性（会话聚合优先、否则扫目录；语音按「有人」）/
/// 新内容聚合（四类事件取最新 + bumped 单调时间戳）/ 轮播四类卡（语音最多 3 个且人数降序、
/// 桌游开关关闭、帖子卡 hasUnread 与缩略图）/ 列表项角标（未读 + 帖未读）。
library;

import 'package:flutter_test/flutter_test.dart';

import '../lib/core/api/live_api.dart';
import '../lib/core/api/voice_api.dart';
import '../lib/core/models/chat_message.dart';
import '../lib/core/models/conversation.dart';
import '../lib/core/models/game_room.dart';
import '../lib/core/models/post.dart';
import '../lib/core/models/user_public.dart';
import '../lib/pages/home_support.dart';
import '../lib/widgets/group/group_card.dart'
    show AylaGroupCarouselSlide, AylaGroupSlideKind;
import '../lib/widgets/live/live_hall.dart';
import '../lib/widgets/voice/voice_channels.dart' show AylaVoiceCardData;

AylaConversationSummary _group(
  String id, {
  bool pinned = false,
  int unread = 0,
  int? postUnread,
  int memberCount = 3,
  String? activityAt,
  AylaGroupPresence? presence,
  AylaLastMessagePreview? lastMessage,
}) =>
    AylaConversationSummary(
      id: id,
      type: AylaConversationType.group,
      title: '群 $id',
      memberCount: memberCount,
      unreadCount: unread,
      postUnreadCount: postUnread,
      isPinned: pinned,
      directoryActivityAt: activityAt,
      groupPresence: presence,
      lastMessage: lastMessage,
    );

AylaDirectoryLiveEntry _live(
  String id, {
  AylaLiveStatus? status = AylaLiveStatus.live,
  String? startedAt,
  List<String> groups = const <String>[],
  String owner = '小樱',
  String? cover,
}) =>
    AylaDirectoryLiveEntry(
      card: AylaLiveCardData(
        id: id,
        title: '直播 $id',
        status: status,
        ownerNickname: owner,
        cover: cover,
      ),
      startedAt: startedAt,
      allowedGroupIds: groups,
    );

AylaDirectoryVoiceEntry _voice(
  String id, {
  int? memberCount = 2,
  String? createdAt,
  List<String> groups = const <String>[],
  String owner = '阿蓝',
  String name = '',
  String roomName = 'room_x',
}) =>
    AylaDirectoryVoiceEntry(
      card: AylaVoiceCardData(
        id: id,
        name: name.isEmpty ? id : name,
        ownerNickname: owner,
        memberCount: memberCount,
      ),
      createdAt: createdAt,
      roomName: roomName,
      allowedGroupIds: groups,
    );

AylaGameRoom _game(String id, {List<String> groups = const <String>[]}) =>
    AylaGameRoom(
      id: 1,
      name: '桌游 $id',
      owner: const AylaUserPublic(id: 'u1', nickname: '小樱'),
      ownerId: 'u1',
      status: AylaGameRoomStatus.playing,
      allowedGroupIds: groups,
      createdAt: '2026-09-28T10:00:00Z',
      memberCount: 2,
    );

AylaPost _post(
  int id, {
  List<String> groups = const <String>[],
  String? createdAt,
  String title = '帖子标题',
  String body = '正文',
  String? thumbnail,
  String author = '小樱',
}) =>
    AylaPost(
      id: id,
      title: title,
      body: body,
      allowedGroupIds: groups,
      createdAt: createdAt,
      author: AylaPostAuthor(id: 'u1', nickname: author),
      images: thumbnail == null
          ? const <AylaPostImage>[]
          : <AylaPostImage>[
              AylaPostImage(
                id: 1,
                media: AylaMediaDescriptor(
                  mediaId: 'm1',
                  thumbnail: thumbnail,
                ),
              ),
            ],
    );

void main() {
  // 固定「现在」（ms）—— 所有事件时间相对它构造，避免测试随真实时间漂移。
  final int now = DateTime.utc(2026, 9, 28, 12).millisecondsSinceEpoch;
  String iso(int offsetMs) =>
      DateTime.fromMillisecondsSinceEpoch(now + offsetMs, isUtc: true)
          .toIso8601String();

  group('时间窗口（tsx 58–68）', () {
    test('aylaToMs：非法/空 → 0', () {
      expect(aylaToMs(null), 0);
      expect(aylaToMs(''), 0);
      expect(aylaToMs('不是时间'), 0);
      expect(aylaToMs('2026-09-28T12:00:00Z'),
          DateTime.utc(2026, 9, 28, 12).millisecondsSinceEpoch);
    });

    test('aylaIsRecent：24h 窗口内为真，窗口外/未来超容差为假', () {
      expect(aylaIsRecent(0, now), isFalse);
      expect(aylaIsRecent(now - 1000, now), isTrue);
      expect(aylaIsRecent(now - kAylaNewContentWindowMs + 1, now), isTrue);
      expect(aylaIsRecent(now - kAylaNewContentWindowMs, now), isFalse);
      // 未来 30s 在 1min 时钟容差内
      expect(aylaIsRecent(now + 30000, now), isTrue);
      expect(aylaIsRecent(now + 61000, now), isFalse);
    });

    test('aylaVisibleInGroup：白名单字符串比较（归属群不承载可见性）', () {
      expect(aylaVisibleInGroup('g1', <String>['g1', 'g2']), isTrue);
      expect(aylaVisibleInGroup('g3', <String>['g1', 'g2']), isFalse);
      expect(aylaVisibleInGroup('g1', const <String>[]), isFalse);
    });

    test('aylaDisplayName：nickname 优先，其次 username，都空 → 空串', () {
      expect(aylaDisplayName('小樱', 'sakura'), '小樱');
      expect(aylaDisplayName('', 'sakura'), 'sakura');
      expect(aylaDisplayName(null, null), '');
    });
  });

  group('消息事件（tsx 94–111）', () {
    test('窗口内文本消息 → 「发送者：内容」', () {
      final AylaNewEvent? e = aylaMessageEvent(
        AylaLastMessagePreview(
          type: AylaMessageType.text,
          content: '今晚一起吃饭吗',
          senderName: '小樱',
          createdAt: iso(-60000),
        ),
        now,
      );
      expect(e?.kind, AylaNewEventKind.message);
      expect(e?.text, '小樱：今晚一起吃饭吗');
    });

    test('混排消息 preview 优先于 content（tsx 103–105）', () {
      final AylaNewEvent? e = aylaMessageEvent(
        AylaLastMessagePreview(
          type: AylaMessageType.mixed,
          content: '',
          preview: '文本[视频]文本[图片]',
          senderName: '小樱',
          createdAt: iso(-1000),
        ),
        now,
      );
      expect(e?.text, '小樱：文本[视频]文本[图片]');
    });

    test('媒体消息 content 空 → 类型占位（[图片]/[语音]/[文件]/[表情]/[视频]/[系统消息]）', () {
      const Map<AylaMessageType, String> expected = <AylaMessageType, String>{
        AylaMessageType.image: '[图片]',
        AylaMessageType.voice: '[语音]',
        AylaMessageType.file: '[文件]',
        AylaMessageType.emoji: '[表情]',
        AylaMessageType.video: '[视频]',
        AylaMessageType.system: '[系统消息]',
      };
      expected.forEach((AylaMessageType type, String placeholder) {
        final AylaNewEvent? e = aylaMessageEvent(
          AylaLastMessagePreview(
            type: type,
            content: '',
            senderName: '小樱',
            createdAt: iso(-1000),
          ),
          now,
        );
        expect(e?.text, '小樱：$placeholder', reason: '$type');
      });
    });

    test('poke 不加「发送者：」前缀（tsx 106–109）', () {
      final AylaNewEvent? e = aylaMessageEvent(
        AylaLastMessagePreview(
          type: AylaMessageType.poke,
          preview: '小樱戳了戳你',
          senderName: '小樱',
          createdAt: iso(-1000),
        ),
        now,
      );
      expect(e?.text, '小樱戳了戳你');
    });

    test('无 last_message / 无 created_at / 窗口外 → null（不伪造事件）', () {
      expect(aylaMessageEvent(null, now), isNull);
      expect(
        aylaMessageEvent(
          const AylaLastMessagePreview(
            content: 'x',
            senderName: 'a',
          ),
          now,
        ),
        isNull,
      );
      expect(
        aylaMessageEvent(
          AylaLastMessagePreview(
            content: 'x',
            senderName: 'a',
            createdAt: iso(-kAylaNewContentWindowMs - 1),
          ),
          now,
        ),
        isNull,
      );
    });
  });

  group('群排序（tsx 238–259）', () {
    test('置顶优先 → 组内时间新→旧 → 无新内容保持传入顺序', () {
      final List<AylaGroupActivity> acts = <AylaGroupActivity>[
        const AylaGroupActivity(lastNewAt: 100),
        const AylaGroupActivity(), // 0
        const AylaGroupActivity(lastNewAt: 300),
        const AylaGroupActivity(lastNewAt: 200),
      ];
      final List<String> ids = <String>['a', 'b', 'c', 'd'];
      final List<String> sorted = aylaSortGroupsByActivity<String>(
        ids,
        (String id) => acts[ids.indexOf(id)],
      );
      expect(sorted, <String>['c', 'd', 'a', 'b']);

      // 置顶：b 置顶 ⇒ 排最前（组内自身仍按时间）
      final List<String> pinnedFirst = aylaSortGroupsByActivity<String>(
        ids,
        (String id) => acts[ids.indexOf(id)],
        pinnedOf: (String id) => id == 'b' || id == 'a',
      );
      expect(pinnedFirst, <String>['a', 'b', 'c', 'd']);
    });
  });

  group('角标存在性（tsx 116–152）', () {
    test('会话聚合 group_presence 优先（不再扫目录）', () {
      final AylaHomeActivityMap map = AylaHomeActivityMap(
        conversations: <AylaConversationSummary>[
          _group('g1',
              presence: const AylaGroupPresence(live: true, voice: false)),
        ],
        // 目录里 g1 有语音房且有人 —— 但聚合给了 voice:false ⇒ 以聚合为准
        catalogs: AylaHomeCatalogs(
          voiceChannels: <AylaDirectoryVoiceEntry>[
            _voice('v1', groups: <String>['g1']),
          ],
        ),
      );
      final AylaGroupPresence p = map.presenceFor('g1');
      expect(p.live, isTrue);
      expect(p.voice, isFalse);
    });

    test('无聚合 → 扫目录：直播仅在播、语音要「有人」、桌游存在即真', () {
      final AylaHomeActivityMap map = AylaHomeActivityMap(
        conversations: <AylaConversationSummary>[_group('g1')],
        catalogs: AylaHomeCatalogs(
          liveChannels: <AylaDirectoryLiveEntry>[
            _live('l1', status: AylaLiveStatus.idle, groups: <String>['g1']),
          ],
          voiceChannels: <AylaDirectoryVoiceEntry>[
            _voice('v1', memberCount: 0, groups: <String>['g1']),
          ],
          gameRooms: <AylaGameRoom>[_game('r1', groups: <String>['g1'])],
        ),
      );
      final AylaGroupPresence p = map.presenceFor('g1');
      expect(p.live, isFalse, reason: '未开播不算');
      expect(p.voice, isFalse, reason: 'member_count 0 = 没人在麦');
      expect(p.game, isTrue);
    });

    test('白名单不含本群 → 三档全假', () {
      final AylaHomeActivityMap map = AylaHomeActivityMap(
        conversations: <AylaConversationSummary>[_group('g1')],
        catalogs: AylaHomeCatalogs(
          liveChannels: <AylaDirectoryLiveEntry>[
            _live('l1', groups: <String>['g2']),
          ],
          voiceChannels: <AylaDirectoryVoiceEntry>[
            _voice('v1', groups: <String>['g2']),
          ],
          gameRooms: <AylaGameRoom>[_game('r1', groups: <String>['g2'])],
        ),
      );
      final AylaGroupPresence p = map.presenceFor('g1');
      expect(p.live || p.voice || p.game, isFalse);
    });
  });

  group('新内容聚合（tsx 159–227）', () {
    test('四类事件取时间最新的一条，并带上具体描述', () {
      final AylaHomeActivityMap map = AylaHomeActivityMap(
        conversations: <AylaConversationSummary>[_group('g1')],
        catalogs: AylaHomeCatalogs(
          liveChannels: <AylaDirectoryLiveEntry>[
            _live('l1', startedAt: iso(-30000), groups: <String>['g1']),
          ],
          voiceChannels: <AylaDirectoryVoiceEntry>[
            _voice('v1',
                createdAt: iso(-60000),
                groups: <String>['g1'],
                name: '深夜电台'),
          ],
          gameRooms: <AylaGameRoom>[_game('r1', groups: <String>['g1'])],
          posts: <AylaPost>[
            _post(1, groups: <String>['g1'], createdAt: iso(-45000)),
          ],
        ),
      );
      final AylaGroupActivity act = map.activityFor('g1', null, now: now);
      expect(act.lastEvent?.kind, AylaNewEventKind.live, reason: '最新的新开播');
      expect(act.lastEvent?.text, '小樱 开播了 直播 l1');
      expect(act.lastNewAt, aylaToMs(iso(-30000)));
    });

    test('语音事件用 name 而非 room_name；帖子/桌游事件描述逐字', () {
      final AylaHomeActivityMap map = AylaHomeActivityMap(
        conversations: <AylaConversationSummary>[_group('g1')],
        catalogs: AylaHomeCatalogs(
          voiceChannels: <AylaDirectoryVoiceEntry>[
            _voice('v1',
                createdAt: iso(-1000),
                groups: <String>['g1'],
                name: '深夜电台'),
          ],
        ),
      );
      expect(
        map.activityFor('g1', null, now: now).lastEvent?.text,
        '阿蓝 创建了语音房 深夜电台',
      );

      final AylaHomeActivityMap postMap = AylaHomeActivityMap(
        conversations: <AylaConversationSummary>[_group('g1')],
        catalogs: AylaHomeCatalogs(
          posts: <AylaPost>[
            _post(7,
                groups: <String>['g1'],
                createdAt: iso(-1000),
                title: '雪山行记',
                author: '汐汐'),
          ],
        ),
      );
      expect(
        postMap.activityFor('g1', null, now: now).lastEvent?.text,
        '汐汐 发了新帖 雪山行记',
      );

      final AylaHomeActivityMap gameMap = AylaHomeActivityMap(
        conversations: <AylaConversationSummary>[_group('g1')],
        catalogs: AylaHomeCatalogs(
          gameRooms: <AylaGameRoom>[_game('r1', groups: <String>['g1'])],
        ),
      );
      // 固定 now 下 createdAt 是 2026-09-28T10:00:00Z（早于 now 2h，仍在 24h 窗口内）
      final AylaGroupActivity game = gameMap.activityFor('g1', null, now: now);
      expect(game.lastEvent?.kind, AylaNewEventKind.game);
      expect(game.lastEvent?.text, '小樱 创建了桌游房 桌游 r1');
    });

    test('消息事件可与目录事件比较取新（tsx 173 起 best 初值）', () {
      final AylaHomeActivityMap map = AylaHomeActivityMap(
        conversations: <AylaConversationSummary>[_group('g1')],
        catalogs: AylaHomeCatalogs(
          posts: <AylaPost>[
            _post(1, groups: <String>['g1'], createdAt: iso(-120000)),
          ],
        ),
      );
      final AylaGroupActivity act = map.activityFor(
        'g1',
        AylaLastMessagePreview(
          type: AylaMessageType.text,
          content: '在吗',
          senderName: '小樱',
          createdAt: iso(-1000),
        ),
        now: now,
      );
      expect(act.lastEvent?.kind, AylaNewEventKind.message);
      expect(act.lastEvent?.text, '小樱：在吗');
    });

    test('无事件但会话行带 directory_activity_at → 只保留单调时间戳（描述缺省）', () {
      final AylaHomeActivityMap map = AylaHomeActivityMap(
        conversations: <AylaConversationSummary>[
          _group('g1', activityAt: iso(-5000)),
        ],
      );
      final AylaGroupActivity act = map.activityFor('g1', null, now: now);
      expect(act.lastEvent, isNull);
      expect(act.lastNewAt, aylaToMs(iso(-5000)));
      expect(act.hasActivity, isTrue);
    });

    test('两者都无 → kAylaNoActivity（0 / null，不伪造）', () {
      final AylaHomeActivityMap map = AylaHomeActivityMap(
        conversations: <AylaConversationSummary>[_group('g1')],
      );
      expect(map.activityFor('g1', null, now: now).lastNewAt, 0);
      expect(map.activityFor('g1', null, now: now).lastEvent, isNull);
    });

    test('目录事件时间早于 bumped ⇒ lastNewAt 取 bumped（内容消失不往回排）', () {
      final AylaHomeActivityMap map = AylaHomeActivityMap(
        conversations: <AylaConversationSummary>[
          _group('g1', activityAt: iso(-1000)),
        ],
        catalogs: AylaHomeCatalogs(
          posts: <AylaPost>[
            _post(1, groups: <String>['g1'], createdAt: iso(-60000)),
          ],
        ),
      );
      final AylaGroupActivity act = map.activityFor('g1', null, now: now);
      expect(act.lastNewAt, aylaToMs(iso(-1000)));
      expect(act.lastEvent?.kind, AylaNewEventKind.post);
    });
  });

  group('状态轮播（tsx 300–398）', () {
    test('消息+语音合卡：未读 > 0 或有人语音房才生成；语音降序且最多 3 个', () {
      final AylaHomeActivityMap map = AylaHomeActivityMap(
        conversations: <AylaConversationSummary>[_group('g1')],
        catalogs: AylaHomeCatalogs(
          voiceChannels: <AylaDirectoryVoiceEntry>[
            _voice('v1', memberCount: 1, groups: <String>['g1'], name: 'A'),
            _voice('v2', memberCount: 5, groups: <String>['g1'], name: 'B'),
            _voice('v3', memberCount: 3, groups: <String>['g1'], name: 'C'),
            _voice('v4', memberCount: 9, groups: <String>['g1'], name: 'D'),
            _voice('v5', memberCount: 0, groups: <String>['g1'], name: 'E'),
          ],
        ),
      );
      final List<AylaGroupCarouselSlide> slides =
          map.carouselFor('g1', 2, now: now);
      expect(slides.length, 1);
      expect(slides.first.kind, AylaGroupSlideKind.messageVoice);
      expect(slides.first.newMessageCount, 2);
      expect(slides.first.voiceRooms.length, kAylaMaxCarouselVoiceRooms);
      expect(
        slides.first.voiceRooms.map((v) => v.name).toList(),
        <String>['D', 'B', 'C'],
        reason: '人数降序、最多 3 个；member_count 0 的房间不入卡',
      );
    });

    test('未读 0 且无语音房 → 不生成合卡（web 条件 tx 333）', () {
      final AylaHomeActivityMap map = AylaHomeActivityMap(
        conversations: <AylaConversationSummary>[_group('g1')],
      );
      expect(map.carouselFor('g1', 0, now: now), isEmpty);
    });

    test('负未读被 Math.max(0, …) 归零 ⇒ 无语音房时不生成合卡（tsx 332–339）', () {
      final AylaHomeActivityMap map = AylaHomeActivityMap(
        conversations: <AylaConversationSummary>[_group('g1')],
      );
      // tsx 332 `Math.max(0, unreadCount ?? 0)` + 333 `if (newCount > 0 || topRooms.length > 0)`
      // ⇒ 负值归零后不满足条件，**不生成**合卡（不是生成一张 newMessageCount: 0 的卡）。
      expect(map.carouselFor('g1', -3, now: now), isEmpty);
    });

    test('直播卡：每个在播且对本群可见的直播间一张（cover 空 ⇒ null）', () {
      final AylaHomeActivityMap map = AylaHomeActivityMap(
        conversations: <AylaConversationSummary>[_group('g1')],
        catalogs: AylaHomeCatalogs(
          liveChannels: <AylaDirectoryLiveEntry>[
            _live('l1', groups: <String>['g1'], cover: 'https://x/c.jpg'),
            _live('l2', status: AylaLiveStatus.idle, groups: <String>['g1']),
            _live('l3', groups: <String>['g2']),
          ],
        ),
      );
      final List<AylaGroupCarouselSlide> slides =
          map.carouselFor('g1', 0, now: now);
      expect(slides.length, 1);
      expect(slides.first.kind, AylaGroupSlideKind.live);
      expect(slides.first.title, '直播 l1');
      expect(slides.first.host, '小樱');
      expect(slides.first.cover, 'https://x/c.jpg');
    });

    test('帖子卡：窗口内最新一帖一张 + hasUnread 来自群未读帖数 + 缩略图取第一张有 thumb 的图', () {
      final AylaHomeActivityMap map = AylaHomeActivityMap(
        conversations: <AylaConversationSummary>[_group('g1')],
        catalogs: AylaHomeCatalogs(
          posts: <AylaPost>[
            _post(1, groups: <String>['g1'], createdAt: iso(-90000),
                title: '旧的'),
            _post(2, groups: <String>['g1'], createdAt: iso(-5000),
                title: '新的', body: '正文 X', thumbnail: 'https://x/t.jpg'),
          ],
        ),
      );
      final List<AylaGroupCarouselSlide> slides =
          map.carouselFor('g1', 0, postUnreadCount: 4, now: now);
      expect(slides.length, 1);
      expect(slides.first.kind, AylaGroupSlideKind.post);
      expect(slides.first.title, '新的');
      expect(slides.first.body, '正文 X');
      expect(slides.first.image, 'https://x/t.jpg');
      expect(slides.first.hasUnread, isTrue);
    });

    test('桌游档恒关闭（SHOW_GAME_STATUS = false，与 web 同值）', () {
      final AylaHomeActivityMap map = AylaHomeActivityMap(
        conversations: <AylaConversationSummary>[_group('g1')],
        catalogs: AylaHomeCatalogs(
          gameRooms: <AylaGameRoom>[_game('r1', groups: <String>['g1'])],
        ),
      );
      expect(map.carouselFor('g1', 0, now: now), isEmpty);
    });

    test('avatarStatusFor：未读 = unread_count + post_unread_count，并带三档存在性', () {
      final AylaHomeActivityMap map = AylaHomeActivityMap(
        conversations: <AylaConversationSummary>[
          _group('g1',
              unread: 3,
              postUnread: 4,
              presence: const AylaGroupPresence(live: true, game: true)),
        ],
      );
      final status = map.avatarStatusFor(
        _group('g1', unread: 3, postUnread: 4,
            presence: const AylaGroupPresence(live: true, game: true)),
      );
      expect(status.unread, 7);
      expect(status.live, isTrue);
      expect(status.voice, isFalse);
      expect(status.game, isTrue);
    });
  });
}
