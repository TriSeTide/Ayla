/// B6-2：目录结果卡族（DirectoryResultCards.tsx 119 行 + typed-result-cards.css）。
///
/// ## 事实源（逐条对应 web，禁自由发挥）
/// ── GroupResultCard（tsx 18–37 + css .typed-group-card）：玻璃卡（--glass-bg + 1px 边 +
/// radius-card 16 + --glass-shadow-compact + blur24 sat1.4）· padding sp4（窄屏 sp3）·
/// flex 居中 · gap sp3；主按钮 .typed-group-main（flex 居中 gap sp3 + width 100%）=
/// Avatar 44 + copy（strong 标题 + .typed-card-meta「N 人」/「公开群聊」/「申请制群聊」，
/// 12px secondary gap sp2）+ 可选 entryLabel（.search-row-action）；末尾 action 槽位
/// ── FavoriteResultCard（tsx 40–119）：按 target_type 分派到既有卡（post / live / voice / game）
/// 并传 action；target 缺失 → .typed-unavailable-card「内容不可用」（按钮 disabled）
/// ── message 情形自绘 .typed-message-card：卡片同玻璃规格但 align-items flex-start +
/// flex-wrap wrap；主按钮 .typed-message-main（flex 1 · 左对齐 · canOpen=false 时 disabled）=
/// heading（IconMessage 18 + 昵称/「消息」，13px secondary gap sp2）+ 正文三态：已撤回
/// 「该消息已撤回」/ 戳一戳「戳一戳消息」（两者 = .typed-message-recalled：ice-100 底 +
/// padding sp3 + radius-input + 13px secondary）/ 非媒体 = blockquote（ice-100 + sp3 +
/// radius-input + 原文）；媒体区 .typed-message-media（flex-basis 100% + margin-top sp3）
/// 独立于跳转（点媒体不跳转）→ 复用 AylaMediaContent；整卡 is-openable 时可点跳转
/// ── .typed-result-card 只是宽度归一（子卡 100% / min-width 0）⇒ Flutter 侧由各卡自身表达，
/// 不新造空壳容器；.typed-result-card .voice-channel-card 的竖排覆写与本库 B1-1 语音卡同形 ✓
///
/// ## 附带补档
/// .live-card 在 web 的收藏卡里接受 action（tsx 56）⇒ 给 AylaLiveChannelCard 补上 action 槽位
/// （此前只有 showActions，与 post/voice/game 三卡不一致）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../core/models/chat_message.dart';
import '../core/models/game_room.dart';
import '../core/models/post.dart';
import '../core/models/subgroup.dart' show AylaGroupJoinPolicy;
import '../theme/app_icons.dart';
import '../theme/app_theme.dart';
import '../theme/glass.dart';
import '../theme/preview_theme.dart';
import '../theme/tokens.dart';
import 'avatar_halo.dart';
import 'game_room_card.dart';
import 'live_hall.dart';
import 'media_content.dart';
import 'post_card.dart';
import 'voice_channels.dart';

/// 群结果投影（web GroupCardData = Partial of SearchGroupItem，另加 id 与 title 必填）。
class AylaGroupResultData {
  const AylaGroupResultData({
    required this.id,
    required this.title,
    this.memberCount,
    this.joinPolicy,
    this.avatar,
  });

  final String id;
  final String title;

  /// 人数（null → 不渲染「N 人」，tsx 29 的 typeof === number 守卫）。
  final int? memberCount;

  /// 入群策略（public → 「公开群聊」/ application → 「申请制群聊」；null → 不渲染）。
  final AylaGroupJoinPolicy? joinPolicy;

  final String? avatar;

  /// tsx 30：策略文案两档。
  String? get joinPolicyLabel => switch (joinPolicy) {
        AylaGroupJoinPolicy.public => '公开群聊',
        AylaGroupJoinPolicy.application => '申请制群聊',
        null => null,
      };
}

/// .typed-group-card —— 群结果卡（GroupResultCard.tsx 18–37）。
class AylaGroupResultCard extends StatelessWidget {
  const AylaGroupResultCard({
    super.key,
    required this.group,
    required this.onOpen,
    this.entryLabel,
    this.action,
  });

  final AylaGroupResultData group;

  /// 打开（web onOpen）。
  final VoidCallback onOpen;

  /// 入口文案（.search-row-action；null 不渲染）。
  final String? entryLabel;

  /// 末尾槽位（如取消收藏键）。
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final bool narrow = MediaQuery.sizeOf(context).width <= 768;

    return GlassSurface(
      radius: AylaRadii.rCard,
      blur: AylaGlass.blurCard, // --glass-filter
      shadow: AylaShadows.compact, // --glass-shadow-compact
      padding: EdgeInsets.all(narrow ? AylaSpacing.sp3 : AylaSpacing.sp4),
      child: Row(
        spacing: AylaSpacing.sp3, // gap: var(--sp-3)
        children: <Widget>[
          Expanded(
            child: GestureDetector(
              onTap: onOpen,
              behavior: HitTestBehavior.opaque,
              child: Row(
                spacing: AylaSpacing.sp3,
                children: <Widget>[
                  // Avatar size 44（tsx 26）
                  AvatarHalo(
                    label: group.title,
                    size: 44,
                    resourceUrl: group.avatar,
                    semanticLabel: group.title,
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      spacing: AylaSpacing.sp2, // gap: var(--sp-2)
                      children: <Widget>[
                        Text(
                          group.title,
                          style: t.bodyStrong.copyWith(
                            color: AylaColors.textPrimary,
                          ),
                        ),
                        if (group.memberCount != null ||
                            group.joinPolicyLabel != null)
                          Wrap(
                            spacing: AylaSpacing.sp2, // gap: var(--sp-2)
                            children: <Widget>[
                              if (group.memberCount != null)
                                Text(
                                  '${group.memberCount} 人', // tsx 29
                                  style: t.body.copyWith(
                                    fontSize: 12,
                                    color: AylaColors.textSecondary,
                                  ),
                                ),
                              if (group.joinPolicyLabel != null)
                                Text(
                                  group.joinPolicyLabel!,
                                  style: t.body.copyWith(
                                    fontSize: 12,
                                    color: AylaColors.textSecondary,
                                  ),
                                ),
                            ],
                          ),
                      ],
                    ),
                  ),
                  if ((entryLabel ?? '').isNotEmpty)
                    Text(
                      entryLabel!,
                      // .search-row-action：12px secondary
                      style: t.body.copyWith(
                        fontSize: 12,
                        color: AylaColors.textSecondary,
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (action != null) action!,
        ],
      ),
    );
  }
}

/// 收藏目标类型（web FavoriteTargetType）。
enum AylaFavoriteTargetType { post, live, voice, game, message }

/// 收藏条目投影（web Favorite：target_type + target_id + target 投影）。
///
/// 各目标的投影都可缺省：缺投影即「内容不可用」（等价 web 的 target 缺失分支），不造默认内容。
class AylaFavoriteResultData {
  const AylaFavoriteResultData({
    required this.id,
    required this.targetType,
    this.post,
    this.live,
    this.voice,
    this.game,
    this.message,
  });

  final int id;
  final AylaFavoriteTargetType targetType;

  /// post 卡投影。
  final AylaPost? post;

  /// live 卡投影。
  final AylaLiveCardData? live;

  /// voice 卡投影。
  final AylaVoiceCardData? voice;

  /// game 卡投影。
  final AylaGameCardData? game;

  /// 消息投影（已是构造好的 AylaChatMessage；descriptor 缺失时由 AylaMediaContent 的
  /// descriptorFetcher 按 media_id 补拉，与 WS 帧路径同契约）。
  final AylaChatMessage? message;

  /// 该条目是否有可用投影（web 的 target 非空）。
  bool get isAvailable => switch (targetType) {
        AylaFavoriteTargetType.post => post != null,
        AylaFavoriteTargetType.live => live != null,
        AylaFavoriteTargetType.voice => voice != null,
        AylaFavoriteTargetType.game => game != null,
        AylaFavoriteTargetType.message => message != null,
      };
}

/// 收藏结果卡（FavoriteResultCard.tsx 40–119）—— 分派到既有卡或自绘消息卡。
class AylaFavoriteResultCard extends StatelessWidget {
  const AylaFavoriteResultCard({
    super.key,
    required this.favorite,
    required this.onOpen,
    this.action,
    this.descriptorFetcher,
    this.onDescriptorFetched,
    this.currentUserId,
    this.senderLabel,
  });

  final AylaFavoriteResultData favorite;

  /// 打开原内容（消息卡在 canOpen 为真时可点）。
  final VoidCallback onOpen;

  /// 取消收藏键（web action，由调用方注入）。
  final Widget? action;

  /// 消息卡媒体 descriptor 补拉（透传 AylaMediaContent）。
  final AylaMediaDescriptorFetcher? descriptorFetcher;
  final void Function(AylaMediaDescriptor media)? onDescriptorFetched;

  /// 当前用户 id（混排 @我 高亮）。
  final String? currentUserId;

  /// 消息卡 heading 的发送者昵称（web 的 target.sender_nickname；null/空 → 「消息」）。
  ///
  /// 由调用方注入：Flutter 的 [AylaChatMessage] 不承载昵称（后端在收藏投影里另给），
  /// 不在这里伪造默认昵称。
  final String? senderLabel;

  @override
  Widget build(BuildContext context) {
    if (!favorite.isAvailable) return _unavailable(context); // tsx 46–48
    return switch (favorite.targetType) {
      AylaFavoriteTargetType.post => AylaPostCard(
          post: favorite.post!,
          previewOnly: true, // tsx 53
          onOpen: onOpen,
          action: action,
        ),
      AylaFavoriteTargetType.live => AylaLiveChannelCard(
          channel: favorite.live!,
          onEnter: onOpen,
          action: action, // tsx 56（本批给 live 卡补的槽位）
        ),
      AylaFavoriteTargetType.voice => AylaVoiceChannelCard(
          channel: favorite.voice!,
          browsing: true, // tsx 58
          onEnter: onOpen,
          action: action,
        ),
      AylaFavoriteTargetType.game => AylaGameRoomCard(
          room: favorite.game!,
          onEnter: onOpen,
          action: action,
        ),
      AylaFavoriteTargetType.message => _messageCard(context),
    };
  }

  /// .typed-unavailable-card：内容不可用（按钮 disabled，tsx 46–48）。
  Widget _unavailable(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final bool narrow = MediaQuery.sizeOf(context).width <= 768;
    return GlassSurface(
      radius: AylaRadii.rCard,
      blur: AylaGlass.blurCard,
      shadow: AylaShadows.compact,
      padding: EdgeInsets.all(narrow ? AylaSpacing.sp3 : AylaSpacing.sp4),
      child: Row(
        spacing: AylaSpacing.sp3,
        children: <Widget>[
          Expanded(
            child: Text(
              '内容不可用', // tsx 47
              style: t.body.copyWith(color: AylaColors.textSecondary),
            ),
          ),
          if (action != null) action!,
        ],
      ),
    );
  }

  /// .typed-message-card：收藏消息卡（tsx 61–117）。
  Widget _messageCard(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final AylaChatMessage msg = favorite.message!;
    final bool narrow = MediaQuery.sizeOf(context).width <= 768;
    final bool recalled = msg.status == AylaMessageStatus.recalled;
    final bool isMedia = _messageMediaTypes.contains(msg.type);
    final bool canOpen = msg.conversationId.isNotEmpty; // tsx 81

    return GlassSurface(
      radius: AylaRadii.rCard,
      blur: AylaGlass.blurCard,
      shadow: AylaShadows.compact,
      padding: EdgeInsets.all(narrow ? AylaSpacing.sp3 : AylaSpacing.sp4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: AylaSpacing.sp3,
            children: <Widget>[
              Expanded(
                child: GestureDetector(
                  onTap: canOpen ? onOpen : null,
                  behavior: HitTestBehavior.opaque,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      // .typed-message-heading：IconMessage 18 + 昵称/「消息」
                      Row(
                        spacing: AylaSpacing.sp2,
                        children: <Widget>[
                          AylaIcon(
                            aylaIconByName('iconMessage')!,
                            size: 18,
                            color: AylaColors.textSecondary,
                          ),
                          Text(
                            _senderOwnLabel, // tsx 97
                            style: t.body.copyWith(
                              fontSize: 13,
                              color: AylaColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                      if (recalled)
                        _quote(t, '该消息已撤回', secondary: true) // tsx 100
                      else if (msg.type == AylaMessageType.poke)
                        _quote(t, '戳一戳消息', secondary: true) // tsx 102
                      else if (!isMedia && msg.content.isNotEmpty)
                        _quote(t, msg.content), // tsx 104
                    ],
                  ),
                ),
              ),
              if (action != null) action!,
            ],
          ),
          // .typed-message-media：独占一行 + margin-top sp3（点媒体不跳转）
          if (!recalled && isMedia)
            Padding(
              padding: const EdgeInsets.only(top: AylaSpacing.sp3),
              child: AylaMediaContent(
                msg: msg,
                descriptorFetcher: descriptorFetcher,
                onDescriptorFetched: onDescriptorFetched,
                currentUserId: currentUserId,
              ),
            ),
        ],
      ),
    );
  }

  /// blockquote / 撤回行（ice-100 底 + padding sp3 + radius-input）。
  Widget _quote(AylaTextStyles t, String text, {bool secondary = false}) {
    return Container(
      margin: const EdgeInsets.only(top: AylaSpacing.sp3),
      padding: const EdgeInsets.all(AylaSpacing.sp3),
      decoration: BoxDecoration(
        color: AylaColors.ice100,
        borderRadius: BorderRadius.circular(AylaRadii.rInput),
      ),
      child: Text(
        text,
        style: t.body.copyWith(
          fontSize: secondary ? 13 : null,
          color: secondary ? AylaColors.textSecondary : AylaColors.textPrimary,
        ),
      ),
    );
  }

  /// tsx 97：昵称优先，缺省「消息」。
  String get _senderOwnLabel {
    final String? nick = senderLabel;
    return (nick ?? '').isNotEmpty ? nick! : '消息';
  }

  /// tsx 16：走 MediaContent 真实渲染的媒体类型集合。
  static const Set<AylaMessageType> _messageMediaTypes = <AylaMessageType>{
    AylaMessageType.image,
    AylaMessageType.voice,
    AylaMessageType.file,
    AylaMessageType.emoji,
    AylaMessageType.video,
    AylaMessageType.mixed,
  };
}

// ======================= 预览 =======================

/// 目录结果卡样张（画布与 @Preview 共用）。
///
/// 群结果卡（meta 两档）· 收藏·消息卡（文本 / 已撤回）。
///
/// ⚠️ 「内容不可用」档（收藏投影缺失，web tsx 46–48）**有意不在样张里展示** —— 它是失效数据的
/// 兜底形态，摆在画布上容易被误读成坏卡；组件分支保留。
Widget aylaDirectoryResultCardSamples() => const _DirectoryResultCardsDemo();

class _DirectoryResultCardsDemo extends StatelessWidget {
  const _DirectoryResultCardsDemo();

  static const AylaGroupResultData _fullGroup = AylaGroupResultData(
    id: 'g1',
    title: '冰樱研究社',
    memberCount: 42,
    joinPolicy: AylaGroupJoinPolicy.public,
  );

  static const AylaGroupResultData _bareGroup = AylaGroupResultData(
    id: 'g2',
    title: '只有名字的群',
  );

  static const AylaChatMessage _textMessage = AylaChatMessage(
    id: 'm1',
    conversationId: 'c1',
    senderId: 'u1',
    type: AylaMessageType.text,
    content: '这是一条被收藏的文本消息，正文走 blockquote 样式。',
    status: AylaMessageStatus.sent,
    seq: 3,
    createdAt: '',
  );

  static const AylaChatMessage _recalledMessage = AylaChatMessage(
    id: 'm2',
    conversationId: 'c1',
    senderId: 'u2',
    type: AylaMessageType.text,
    content: '',
    status: AylaMessageStatus.recalled,
    seq: 4,
    createdAt: '',
  );

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AylaSpacing.sp4,
      runSpacing: AylaSpacing.sp4,
      crossAxisAlignment: WrapCrossAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 420,
          child: AylaGroupResultCard(
            group: _fullGroup,
            entryLabel: '进入',
            onOpen: _noop,
          ),
        ),
        SizedBox(
          width: 420,
          child: AylaGroupResultCard(group: _bareGroup, onOpen: _noop),
        ),
        SizedBox(
          width: 420,
          child: AylaFavoriteResultCard(
            favorite: const AylaFavoriteResultData(
              id: 1,
              targetType: AylaFavoriteTargetType.message,
              message: _textMessage,
            ),
            senderLabel: '爱莉',
            onOpen: _noop,
          ),
        ),
        SizedBox(
          width: 420,
          child: AylaFavoriteResultCard(
            favorite: const AylaFavoriteResultData(
              id: 2,
              targetType: AylaFavoriteTargetType.message,
              message: _recalledMessage,
            ),
            onOpen: _noop,
          ),
        ),
      ],
    );
  }
}

void _noop() {}

/// 目录结果卡（群 / 收藏消息 / 不可用）—— 静态样张。
@Preview(
  group: 'Widgets',
  name: '目录结果卡（群结果 / 收藏消息）',
  size: Size(1000, 900),
  wrapper: previewTheme,
)
Widget aylaDirectoryResultCardsPreview() =>
    aylaDirectoryResultCardSamples();
