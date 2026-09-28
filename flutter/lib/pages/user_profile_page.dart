/// 他人个人主页（路由 `/user/:userId`）—— `web/src/pages/UserProfilePage.tsx` 211 行的等价物。
///
/// ## 事实源（逐条）
/// - tsx 38–68：加载（带 revision 守卫，卸载后丢弃在途结果）· 错误态 · `relation === "self"`
///   时重定向 `/profile`（避免出现「加自己好友」）；
/// - tsx 100–210：loading 骨架（高 96 + 12/60%）· 错误卡（「用户不存在或暂时无法访问」+ 重试 + 返回）·
///   身份行（返回 40 · **分享紧随返回** · 头像 64 · 昵称 / @用户名 · 在线胶囊）·
///   签名行（有才渲染）· `relation` 四档操作（none / pending_sent / pending_received / friend）·
///   `show_content` 才渲染他的内容分区；
/// - `profile.css:558–570` `.profile-presence`（`align-self: flex-start` · `padding: 2px sp3` ·
///   pill · 12/600 · `--ice-100` 底 + `--text-secondary` 字；`.is-online` ⇒ `--sakura-300` 底 +
///   `--grape-700` 字）· `573–578` `.profile-signature-row`（14 / lh 1.55 / secondary）。
///
/// ## 与 ProfilePage 的差异（**不能直接复用 [AylaProfileIdentity]**）
/// 身份行槽位顺序不同：本人页是「返回 → 头像 → 昵称 → 分享（`margin-left: auto` 靠右）」，
/// 他人页是「返回 → **分享紧跟** → 头像 → 昵称 → 在线胶囊」⇒ 本页自己装配该行，
/// 以免把两个页面的 DOM 顺序混成一个（CSS 的靠右槽位与紧跟槽位不是同一件事）。
///
/// ## 未接线 / 待提升（第 1 批登记）
/// · 在线胶囊按 `profile.css:558–570` 在**本页私有实现**（`_PresenceChip`）——
///   组件库无 `AylaProfilePresence`（19 号 §7.5 第三批已登记为缺口）⇒ **待提升为公共件**；
/// · 分享面板接线属分享域批次（本页只装配分享键）；
/// · 内容分区数据源同 [ProfilePage]：传 `postsError` 显式失败态；
/// · `usePresenceOnline` / `useDisplayStatus` 属 presence 接线 ⇒ 本页用后端 `display_status` 兜底。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api/users_api.dart';
import '../core/models/user_public.dart';
import '../core/net/dio_client.dart';
import '../theme/app_icons.dart';
import '../theme/buttons.dart';
import '../theme/glass.dart';
import '../theme/tokens.dart';
import '../widgets/base/avatar_halo.dart';
import '../widgets/base/loading.dart' show AylaSkeleton;
import '../widgets/base/profile_content_sections.dart';
import '../widgets/base/share.dart';
import '../widgets/profile/profile_card.dart';

class UserProfilePage extends ConsumerStatefulWidget {
  const UserProfilePage({super.key, required this.userId});

  /// 路由参数 `/user/:userId`。
  final String userId;

  @override
  ConsumerState<UserProfilePage> createState() => _UserProfilePageState();
}

class _UserProfilePageState extends ConsumerState<UserProfilePage> {
  bool _loading = true;
  String? _error;
  AylaUserDetail? _detail;

  /// `busy`（tsx 31）：'friend' / 'chat' / null。
  String? _busy;

  /// 装载版本（tsx 36 `loadRevision`）：卸载或重新加载后丢弃在途结果。
  int _revision = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _revision++; // 让在途请求的结果失效（tsx 60 的 cleanup）
    super.dispose();
  }

  Future<void> _load() async {
    final int revision = ++_revision;
    setState(() {
      _loading = true;
      _detail = null;
      _error = null;
      _busy = null;
    });
    try {
      final AylaUserDetail detail =
          await AylaUsersApi.getUserDetail(widget.userId);
      if (!mounted || revision != _revision) return;
      setState(() {
        _detail = detail;
        _loading = false;
      });
      // 路由层保护（tsx 64–68）：自己 → /profile
      if (detail.relation == AylaFriendRelation.self) {
        context.go('/profile');
      }
    } catch (err) {
      if (!mounted || revision != _revision) return;
      setState(() {
        _error = err is ApiException ? err.message : '加载用户资料失败';
        _loading = false;
      });
    }
  }

  /// `addFriend`（tsx 70–83）：失败**静默**（web 如此）。
  Future<void> _addFriend() async {
    final AylaUserDetail? detail = _detail;
    if (detail == null || _busy != null) return;
    final int revision = _revision;
    setState(() => _busy = 'friend');
    try {
      await AylaUsersApi.createFriendRequest(toUserId: detail.user.id);
      if (!mounted || revision != _revision) return;
      setState(() {
        _detail = AylaUserDetail(
          user: detail.user,
          relation: AylaFriendRelation.pendingSent,
          showContent: detail.showContent,
        );
      });
    } catch (_) {
      // 失败静默（web 同）
    } finally {
      if (mounted && revision == _revision) setState(() => _busy = null);
    }
  }

  /// `sendMessage`（tsx 85–98）：失败**静默**。
  Future<void> _sendMessage() async {
    final AylaUserDetail? detail = _detail;
    if (detail == null || _busy != null) return;
    final int revision = _revision;
    setState(() => _busy = 'chat');
    try {
      final String conversationId =
          await AylaUsersApi.openPrivateConversation(detail.user.id);
      if (!mounted || revision != _revision) return;
      if (conversationId.isNotEmpty) context.go('/chat/$conversationId');
    } catch (_) {
      // 失败静默（web 同）
    } finally {
      if (mounted && revision == _revision) setState(() => _busy = null);
    }
  }

  void _back() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/group');
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool isNarrow =
        AylaBreakpoints.isNarrow(MediaQuery.sizeOf(context).width);
    final AylaUserDetail? detail = _detail;

    Widget body;
    if (_loading) {
      // tsx 104–107：高 96 骨架 + 高 12 / 宽 60% 骨架
      body = AylaProfileCard(
        compact: !isNarrow,
        children: const <Widget>[
          AylaSkeleton(height: 96, radius: AylaRadii.rInput),
          // 第二根骨架：高 12、宽 60%（tsx 106）
          FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: 0.6,
            child: AylaSkeleton(height: 12),
          ),
        ],
      );
    } else if (_error != null || detail == null) {
      // tsx 108–115
      body = AylaProfileCard(
        compact: !isNarrow,
        children: <Widget>[
          const Text(
            '用户不存在或暂时无法访问',
            style: TextStyle(fontSize: 14, color: AylaColors.textSecondary),
          ),
          Row(
            spacing: AylaSpacing.sp2,
            children: <Widget>[
              AylaGlassButton(
                label: '重试',
                variant: AylaGlassButtonVariant.ghost,
                minHeight: 40,
                onPressed: () => _load(),
              ),
              AylaGlassButton(
                label: '返回',
                variant: AylaGlassButtonVariant.ghost,
                minHeight: 40,
                onPressed: _back,
              ),
            ],
          ),
        ],
      );
    } else {
      body = AylaProfileCard(
        compact: !isNarrow,
        children: <Widget>[
          _identity(detail),
          if (detail.signature != null && detail.signature!.isNotEmpty)
            Text(
              detail.signature!, // tsx 147–149
              style: const TextStyle(
                fontSize: 14,
                height: 1.55,
                color: AylaColors.textSecondary,
              ),
            ),
          _relationActions(detail),
        ],
      );
    }

    final Widget sections = AylaProfileContentSections(
      displayName: detail?.user.displayName ?? '',
      postsError: '内容分区（他的发帖 / 直播间 / 桌游）的数据源属后续批次',
    );
    final bool split = !isNarrow && (detail?.showContent ?? false);

    return Padding(
      // ≥769：`padding: sp3 sp3 0`（profile.css `.profile-page-split:has(.profile-main)`）
      padding: EdgeInsets.fromLTRB(
        AylaSpacing.sp3,
        AylaSpacing.sp3,
        AylaSpacing.sp3,
        0,
      ),
      child: SingleChildScrollView(
        child: split
            ? LayoutBuilder(
                builder: (BuildContext context, BoxConstraints c) {
                  final double sideWidth =
                      (c.maxWidth * 0.32).clamp(280.0, 340.0);
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: AylaSpacing.sp3,
                    children: <Widget>[
                      SizedBox(width: sideWidth, child: body),
                      Expanded(child: sections),
                    ],
                  );
                },
              )
            : body,
      ),
    );
  }

  /// 身份行（tsx 120–145）：返回 · **分享紧跟** · 头像 64 · 昵称/@用户名 · 在线胶囊。
  Widget _identity(AylaUserDetail detail) {
    final AylaUserPublic user = detail.user;
    final String displayName = user.displayName ?? user.username ?? '';
    return Wrap(
      spacing: AylaSpacing.sp2,
      runSpacing: AylaSpacing.sp2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        AylaIconButton(
          icon: AylaIcon(aylaIconByName('iconBack')!, size: 20), // tsx 127
          semanticLabel: '返回',
          onPressed: _back,
        ),
        AylaShareButton(
          label: '分享用户', // tsx 129
          size: 40,
          onPressed: () {}, // 分享面板接线属分享域批次
        ),
        AylaAvatarHalo(
          label: displayName, // tsx 132 `user.nickname || user.username`
          size: 64,
          online: user.online,
          resourceUrl: (user.avatar ?? '').isEmpty ? null : user.avatar,
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(displayName, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
            Text(
              '@${user.username ?? ''}', // tsx 140
              style: const TextStyle(fontSize: 13, color: AylaColors.textSecondary),
            ),
          ],
        ),
        _PresenceChip(
          label: user.displayStatus ?? (user.online ? '在线' : '离线'),
          online: user.online,
        ),
      ],
    );
  }

  /// `relation` 四档操作（tsx 151–196）。
  Widget _relationActions(AylaUserDetail detail) {
    switch (detail.relation) {
      case AylaFriendRelation.friend:
        return Row(
          children: <Widget>[
            AylaGlassButton(
              label: _busy == 'chat' ? '进入中…' : '发消息', // tsx 159
              minHeight: 40,
              onPressed: _busy == 'chat' ? null : () => _sendMessage(),
            ),
          ],
        );
      case AylaFriendRelation.pendingSent:
        return Row(
          children: <Widget>[
            AylaGlassButton(
              label: '申请已发送', // tsx 165（恒禁用）
              variant: AylaGlassButtonVariant.ghost,
              minHeight: 40,
              onPressed: null,
            ),
          ],
        );
      case AylaFriendRelation.pendingReceived:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: AylaSpacing.sp2,
          children: <Widget>[
            const Text(
              '对方已向你发送好友申请，可在消息中心处理', // tsx 171
              style: TextStyle(
                fontSize: 14,
                height: 1.55,
                color: AylaColors.textSecondary,
              ),
            ),
            Row(
              children: <Widget>[
                AylaGlassButton(
                  label: '去处理', // tsx 174
                  variant: AylaGlassButtonVariant.ghost,
                  minHeight: 40,
                  onPressed: () => context.go('/messages'),
                ),
              ],
            ),
          ],
        );
      case AylaFriendRelation.self:
      case AylaFriendRelation.none:
        return Row(
          spacing: AylaSpacing.sp2,
          children: <Widget>[
            AylaGlassButton(
              label: _busy == 'friend' ? '发送中…' : '添加好友', // tsx 185
              minHeight: 40,
              onPressed: _busy == 'friend' ? null : () => _addFriend(),
            ),
            AylaGlassButton(
              label: _busy == 'chat' ? '进入中…' : '发消息', // tsx 193
              variant: AylaGlassButtonVariant.ghost,
              minHeight: 40,
              onPressed: _busy == 'chat' ? null : () => _sendMessage(),
            ),
          ],
        );
    }
  }
}

/// `.profile-presence`（`profile.css:558–570`）—— **本页私有**，待提升为公共
/// `AylaProfilePresence`（19 号 §7.5 第三批已登记为缺口）。
class _PresenceChip extends StatelessWidget {
  const _PresenceChip({required this.label, required this.online});

  final String label;
  final bool online;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AylaSpacing.sp3,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        // 在线 ⇒ --sakura-300 + --grape-700；否则 --ice-100 + --text-secondary
        color: online ? AylaColors.sakura300 : AylaColors.ice100,
        borderRadius: AylaRadii.pill,
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: online ? AylaColors.grape700 : AylaColors.textSecondary,
        ),
      ),
    );
  }
}