/// 桌游室卡片。
///
/// ## 事实源
/// ```
/// GameRoomCard.tsx 15–53   结构：wrap（relative）> button.game-room-card + FavoriteButton(compact)
/// boardgame.css 9–13       .game-room-card-wrap：position relative · width 100% · min-width 0
/// boardgame.css 15–19      .game-room-card-wrap > .favorite-toggle：绝对定位 top/right = sp2 = 8
/// …（逐条 CSS 对照 / 层叠推导**原文**见 `docs/flutter/17-组件文件头归档（整理前原文）.md` 的 `widgets/game/game_room_card.dart` 一节）
/// ```
///
/// ## 来源标签（裁决）
/// web 的 .game-room-source（boardgame.css 107–119）是 display 11 / ls .8 / padding 0×8 的
/// 独立规格；用户裁决**桌游并入统一档** ⇒ 复用 [AylaSourceTag]（live 徽章档 =
/// utility 12 / padding 2×8 / sakura-300 底 / grape-700 字 / 12ch），与语音/直播/帖子一致。
/// 容器仍照 web：flex 1 1 auto + min-width 0 的横向滚动条（[AylaScrollingTags]）。
///
/// ## 公开面
/// `AylaGameRoomCard` · 样张 `aylaGameRoomCardSamples()`

library;

import 'package:flutter/material.dart';

import '../../core/models/game_room.dart';
import '../../core/models/user_public.dart';
import '../../core/models/visibility.dart';
import '../../theme/app_icons.dart';
import '../../theme/app_theme.dart';
import '../../theme/glass.dart';
import '../../theme/tokens.dart';
import '../base/directory_controls.dart' show AylaFavoriteButton, AylaFavoriteState;
import '../base/primitives.dart';
import '../base/reveal.dart';

/// .game-room-card —— 桌游室卡片（GameRoomCard.tsx:15–53）。
class AylaGameRoomCard extends StatelessWidget {
  const AylaGameRoomCard({
    super.key,
    required this.room,
    required this.onEnter,
    this.revealDelay,
    this.action,
    this.showFavorite = true,
    this.favoriteState = AylaFavoriteState.unknown,
    this.favoriteBusy = false,
    this.favoriteError,
    this.onToggleFavorite,
    this.onRetryFavoriteStatus,
    this.reserveSpace = false,
  });

  /// 卡片数据（web GameCardData，字段可缺）。
  final AylaGameCardData room;

  /// 进入房间（web onEnter）。
  final VoidCallback onEnter;

  /// 入场延迟（非 null → 挂 .reveal-item + --reveal-delay，tsx 31–32）。
  final Duration? revealDelay;

  /// 收藏位替换件（web action）：
  /// - null（默认）+ [showFavorite] → 渲染默认收藏键（FavoriteButton compact，tsx 50）；
  /// - null + showFavorite: false → **不渲染**（SearchPage.tsx 440 的 action={null}）；
  /// - 非 null → 用它替换默认收藏键（DirectoryResultCards.tsx 60 的删除键）。
  final Widget? action;

  /// 是否渲染默认收藏键（仅在 [action] 为 null 时生效）。
  final bool showFavorite;

  /// 收藏状态（AylaFavoriteButton 契约）。
  final AylaFavoriteState favoriteState;

  /// 收藏请求进行中。
  final bool favoriteBusy;

  /// 收藏失败文案。
  final String? favoriteError;

  /// 切换收藏（传入目标状态：true = 收藏）。
  final ValueChanged<bool>? onToggleFavorite;

  /// 收藏状态未知/出错时点击 → 重新拉取。
  final VoidCallback? onRetryFavoriteStatus;

  /// **网格等高**（web 靠 CSS grid 的 align-items: stretch 拉平同行卡片）。
  ///
  /// Flutter 没有 stretch，且卡片内含 LayoutBuilder（[AylaScrollingTags] 需要行宽）
  /// ⇒ 不能走 IntrinsicHeight（LayoutBuilder 不支持 intrinsics）。沿用 live 卡
  /// / 语音卡的先例：**把可变行恒占位**（状态 tag 行 · 房主行 · meta 行），
  /// 让高度由构造决定。网格上下文传 true；单独使用（搜索结果）保持 false，
  /// 避免卡底多出空白（web 同样没有）。
  final bool reserveSpace;

  @override
  Widget build(BuildContext context) {
    final Widget card = _wrap(context);
    final Duration? delay = revealDelay;
    if (delay == null) return card;
    return AylaRevealItem(delay: delay, child: card);
  }

  /// .game-room-card-wrap：卡片 + 右上角收藏键（relative 容器）。
  Widget _wrap(BuildContext context) {
    final Widget face = _face(context);
    final Widget? slot = action ??
        (showFavorite
            ? AylaFavoriteButton(
                state: favoriteState,
                compact: true, // .favorite-toggle.is-compact：32×32、图标 16
                busy: favoriteBusy,
                actionError: favoriteError,
                onToggle: onToggleFavorite,
                onRetryStatus: onRetryFavoriteStatus,
                // 卡片内使用：拦截卡片点击（web toggle() 的 stopPropagation）
                onPressedInsideCard: () {},
              )
            : null);
    if (slot == null) return face;
    return Stack(
      children: <Widget>[
        face,
        Positioned(
          top: AylaSpacing.sp2, // boardgame.css 15–19：top/right = var(--sp-2)
          right: AylaSpacing.sp2,
          child: slot,
        ),
      ],
    );
  }

  /// 卡片面：玻璃材质 + hover 阴影升级 + 卡片族交互。
  Widget _face(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);

    return AylaCardInteraction(
      onTap: onEnter,
      // base.css 366–370 的**全局** focus 环（token --focus-ring = #f796ff = glow-500）。
      // 桌游卡在 web 里没有域内覆写（对照：voice.css 547 / typed-result-cards.css 68
      // 用的是 --ice-500），故环色取 glow-500；offset 2 + width 2 由组件表达。
      focusRingColor: AylaColors.glow500,
      builder: (BuildContext context, bool hovered) => AylaGlassSurface(
        radiusOverride: const BorderRadius.all(Radius.circular(AylaRadii.rCard)),
        blur: AylaGlass.blurCard, // --glass-filter：blur(24) saturate(1.4)
        shadow: hovered ? AylaShadows.glassHover : AylaShadows.glass,
        // boardgame.css 36 / auroraqua.css 29–33：卡片族 box-shadow 过渡 300ms
        shadowTransition: AylaDurations.auroraqua,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch, // 卡片是 flex column
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _cover(),
            Padding(
              // .game-room-info { padding: var(--sp-2) var(--sp-3) var(--sp-3) }
              padding: const EdgeInsets.only(
                left: AylaSpacing.sp3,
                right: AylaSpacing.sp3,
                top: AylaSpacing.sp2,
                bottom: AylaSpacing.sp3,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                spacing: 2, // gap: 2px
                children: _info(t),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// .game-room-cover：16:9 占位封面（ice-100 底 + ice-500 游戏图标）。
  Widget _cover() {
    return Padding(
      // margin: 8px 8px 0
      padding: const EdgeInsets.only(left: 8, right: 8, top: 8),
      child: AspectRatio(
        aspectRatio: 16 / 9, // aspect-ratio: 16 / 9
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: AylaColors.ice100, // background: var(--ice-100)
            borderRadius: BorderRadius.circular(AylaRadii.rInput), // radius 12
          ),
          child: Center(
            // tsx 36：<IconGame width={48} height={48} />（色继承 .game-room-cover 的 --ice-500）
            child: AylaIcon(
              aylaIconByName('iconGame')!,
              size: 48,
              color: AylaColors.ice500,
            ),
          ),
        ),
      ),
    );
  }

  /// info 区四行的条件渲染（[reserveSpace] 时改为恒占位）。
  List<Widget> _info(AylaTextStyles t) {
    final AylaGameRoomStatus? status = room.status;
    final String? owner = room.ownerDisplayName;

    final Widget? statusRow = status == null ? null : _statusTag(status); // tsx 40
    final Widget? ownerRow = (owner ?? '').isEmpty
        ? null
        : Text(
            owner!, // tsx 43：nickname || username
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            // .game-room-owner（typed-result-cards.css 44）：12px · text-secondary；
            // 未声明 line-height ⇒ 继承 body
            style: TextStyle(
              fontFamily: AylaFonts.body,
              fontFamilyFallback: AylaFonts.cjkFallback,
              fontSize: 12,
              height: t.body.height,
              color: AylaColors.textSecondary,
            ),
          );

    if (reserveSpace) {
      return <Widget>[
        _name(), // tsx 39：房间名恒在
        SizedBox(height: _statusRowHeight, child: statusRow),
        SizedBox(height: _ownerRowHeight(t), child: ownerRow),
        SizedBox(height: _metaRowHeight(t), child: _meta()),
      ];
    }
    return <Widget>[
      _name(), // tsx 39：房间名恒在
      if (statusRow != null) statusRow,
      if (ownerRow != null) ownerRow,
      _meta(), // tsx 44：meta 行无条件渲染
    ];
  }

  /// .game-room-name：单行滚动房间名（15 / w700 / text-primary / lh 1.35）。
  ///
  /// 字体族未在 CSS 里声明 ⇒ 继承 body（Nunito）。行高 1.35 是 CSS 里写死的
  /// 「消除中英文字体行高差异」。
  Widget _name() {
    return AylaScrollingText(
      text: room.name,
      style: const TextStyle(
        fontFamily: AylaFonts.body,
        fontFamilyFallback: AylaFonts.cjkFallback,
        fontSize: 15,
        fontWeight: FontWeight.w700,
        height: 1.35,
        color: AylaColors.textPrimary,
      ),
    );
  }

  /// .game-room-status：状态 tag（pill）。
  ///
  /// ⚠️ 颜色档**只看 playing**（tsx 40：playing ? "is-playing" : "is-waiting"）
  /// —— ended 与 waiting 同档。
  Widget _statusTag(AylaGameRoomStatus status) {
    final bool playing = status == AylaGameRoomStatus.playing;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: playing ? AylaColors.sakura300 : AylaColors.ice300,
        borderRadius: AylaRadii.pill,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AylaSpacing.sp2,
          vertical: 1, // padding: 1px 8px
        ),
        child: Text(
          status.label,
          style: TextStyle(
            fontFamily: AylaFonts.display, // --font-display
            fontFamilyFallback: AylaFonts.cjkFallback,
            fontSize: 11,
            letterSpacing: 0.8,
            height: 1.4,
            color: playing ? AylaColors.grape700 : AylaColors.indigo700,
          ),
        ),
      ),
    );
  }

  /// .game-room-meta：人数 + 来源标签同行（标签横向滚动、不挤压人数）。
  Widget _meta() {
    final List<String> labels = room.visibilityLabels;
    final int? count = room.memberCount;

    return Row(
      spacing: AylaSpacing.sp2,
      children: <Widget>[
        if (count != null)
          // .game-room-count { flex: 0 0 auto; white-space: nowrap }
          Text(
            '$count 人',
            maxLines: 1,
            style: const TextStyle(
              fontFamily: AylaFonts.utility, // --font-utility
              fontFamilyFallback: AylaFonts.cjkFallback,
              fontSize: 12,
              height: 1.4,
              color: AylaColors.textSecondary,
            ),
          ),
        if (labels.isNotEmpty)
          // .game-room-source-tags { flex: 1 1 auto; min-width: 0 }
          Expanded(
            child: AylaScrollingTags(
              children: <Widget>[
                for (final String label in labels) AylaSourceTag(label),
              ],
            ),
          ),
      ],
    );
  }

  // ---- 预留行高（网格等高；算法同 live 卡「卡片等高的正确做法」）----

  /// 状态 tag 行：11 × 1.4 + 上下各 1px padding = 17.4 → 向上取整（否则预留比
  /// 真实布局少 0.4px，会出现亚像素裁切）。
  static double get _statusRowHeight => (11 * 1.4 + 1 + 1).ceilToDouble();

  /// 房主行：12 × body 行高（.game-room-owner 未声明 line-height ⇒ 继承 body）。
  static double _ownerRowHeight(AylaTextStyles t) =>
      (12 * (t.body.height ?? 1.55)).ceilToDouble();

  /// meta 行：max(人数文本 12 × 1.4, 来源标签胶囊 12 × body 行高 + 2×2)。
  static double _metaRowHeight(AylaTextStyles t) {
    final double countLine = 12 * 1.4;
    final double tagLine = 12 * (t.body.height ?? 1.55) + 2 + 2;
    return (countLine > tagLine ? countLine : tagLine).ceilToDouble();
  }
}

// ======================= 样张 =======================

/// 桌游室卡片样张。
///
/// 覆盖：playing（对局中）/ waiting（等待中）/ 极简（无状态·无房主·无人数·无标签）/
/// 长名字（滚动）/ **网格等高**（reserveSpace 恒占位）。
Widget aylaGameRoomCardSamples() => const _GameRoomCardDemo();

class _GameRoomCardDemo extends StatefulWidget {
  const _GameRoomCardDemo();

  @override
  State<_GameRoomCardDemo> createState() => _GameRoomCardDemoState();
}

class _GameRoomCardDemoState extends State<_GameRoomCardDemo> {
  int _entered = 0;
  String _last = '—';

  static const AylaUserPublic _alice =
      AylaUserPublic(id: 'u1', nickname: '爱莉', username: 'elysia');
  static const AylaUserPublic _bob =
      AylaUserPublic(id: 'u2', username: 'bob_the_builder');

  void _enter(String name) => setState(() {
        _entered++;
        _last = name;
      });

  Widget _stage(String title, Widget child) {
    return SizedBox(
      width: 240, // 网格里的列宽（GamesHub / GroupGames 由页面层决定）
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        spacing: AylaSpacing.sp2,
        children: <Widget>[
          Text(title, style: const TextStyle(fontSize: 11)),
          child,
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      spacing: AylaSpacing.sp4,
      children: <Widget>[
        Text(
          '已进入 $_entered 次，最后一次「$_last」',
          style: const TextStyle(fontSize: 12),
        ),
        Wrap(
          spacing: AylaSpacing.sp4,
          runSpacing: AylaSpacing.sp4,
          crossAxisAlignment: WrapCrossAlignment.start,
          children: <Widget>[
            _stage(
              '对局中 + 房主 + 3 人 + 公开',
              AylaGameRoomCard(
                room: const AylaGameCardData(
                  id: '1',
                  name: '爱莉的桌游室',
                  status: AylaGameRoomStatus.playing,
                  owner: _alice,
                  memberCount: 3,
                  visibility: AylaPostVisibility.public,
                ),
                onEnter: () => _enter('爱莉的桌游室'),
              ),
            ),
            _stage(
              '等待中 + 用户名兜底 + 长名字滚动 + 群标签',
              AylaGameRoomCard(
                room: const AylaGameCardData(
                  id: '2',
                  name: '深夜局的超长房间名字用于验证单行滚动与省略',
                  status: AylaGameRoomStatus.waiting,
                  owner: _bob,
                  memberCount: 2,
                  visibility: AylaPostVisibility.group,
                  allowedGroupNames: <String>['冰樱研究社'],
                ),
                onEnter: () => _enter('深夜局'),
              ),
            ),
            _stage(
              '极简（无状态 · 无房主 · 无人数 · 无标签）',
              AylaGameRoomCard(
                room: const AylaGameCardData(id: '3', name: '空房间'),
                onEnter: () => _enter('空房间'),
                showFavorite: false, // 搜索页用法（web action={null}）
              ),
            ),
            _stage(
              'action 槽位替换（搜索结果里的删除键位）',
              AylaGameRoomCard(
                room: const AylaGameCardData(
                  id: '4',
                  name: '被搜索到的房间',
                  status: AylaGameRoomStatus.ended,
                  memberCount: 0,
                ),
                onEnter: () => _enter('被搜索到的房间'),
                action: const SizedBox(width: 32, height: 32),
              ),
            ),
          ],
        ),
        const SizedBox(height: AylaSpacing.sp2),
        const Text(
          '网格等高（reserveSpace: true —— 三行恒占位，同行高度一致）',
          style: TextStyle(fontSize: 11),
        ),
        SizedBox(
          width: 2 * 240 + AylaSpacing.sp3, // 2 列网格（boardgame.css 232–237：gap sp3）
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: AylaSpacing.sp3,
            children: <Widget>[
              Expanded(
                child: AylaGameRoomCard(
                  room: const AylaGameCardData(
                    id: '5',
                    name: '满行卡片',
                    status: AylaGameRoomStatus.playing,
                    owner: _alice,
                    memberCount: 4,
                    visibility: AylaPostVisibility.public,
                  ),
                  onEnter: () => _enter('满行卡片'),
                  reserveSpace: true,
                ),
              ),
              Expanded(
                child: AylaGameRoomCard(
                  room: const AylaGameCardData(id: '6', name: '缺行卡片'),
                  onEnter: () => _enter('缺行卡片'),
                  reserveSpace: true,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
