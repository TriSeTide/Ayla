/// 在线光环（Presence Halo）—— Ayla 的签名元素（app.css 281–380 行 / d:§6）。
///
/// 事实源：
/// - `.avatar-halo`：padding 2.5px + `--ring-online` 背景
///   = `conic-gradient(from 210deg, #9DBFE6, #F9B0FF, #F796FF, #9DBFE6)`
///   （t:--ring-online；Flutter 无 conic-gradient → SweepGradient，
///   换算：CSS 角 = Flutter 角 + 90°，起点 210° → Flutter 120°）
/// - `.avatar-halo.is-offline`：光环褪为 `--ice-100` 灰环
/// - `.avatar-halo.is-elysia`：`halo-breathe` 3.2s ease-in-out 无限
///   （base.css：0/100% = 0 0 8px rgba(247,150,255,.5)；
///   50% = 0 0 8px .9 + 0 0 16px .45）
/// - `.avatar-core-user`：135deg ice-500→ice-300 渐变 + indigo-700 字
/// - `.avatar-core-elysia`：135deg sakura-100→sakura-300 + grape-700 字
///   （爱莉专属，不可复用于普通用户；d:§2/§6）
/// - reduced-motion：静态 `0 0 8px rgba(247,150,255,.5)`（base.css 375–380 行）
///
/// 在线状态 = 光环 + 文字标签双通道（d:§10），光环只表达运行事实。
///
/// ## 公开面
/// `AylaAvatarCore` · `AylaAvatarHalo`

library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/user_public.dart' show AylaUserPublic;
import '../../state/display_status.dart' show presenceOnline, withLiveStatus;
import '../../state/presence_providers.dart' show presenceStateProvider;
import '../../state/presence_state.dart'
    show AylaPresenceState, AylaUserProfilePatch;
import '../../theme/css_gradient.dart';
import '../../theme/tokens.dart';
import 'resource_image.dart';
import 'tooltip.dart';

/// 头像形状。
enum AylaAvatarCore {
  /// 普通用户：ice 渐变底 + indigo 字
  user,

  /// 爱莉：sakura 渐变底 + grape 字 + 呼吸辉光（全应用唯一）
  elysia,
}

/// 在线光环头像。
///
/// [size] 为**头像本体直径**（光环外径 = size + 2.5×2，即环宽 2.5px 在
/// 头像外圈）；[online] 为运行事实（false = 离线灰环）；[core] 决定底色字色。
class AylaAvatarHalo extends StatefulWidget {
  const AylaAvatarHalo({
    super.key,
    required this.label,
    this.size = 40,
    this.online = false,
    this.user,
    this.userId,
    this.core = AylaAvatarCore.user,
    this.resourceUrl,
    this.onTap,
    this.semanticLabel,
    this.previewImage,
  });

  /// **【推荐】给了 `user` 就自订阅 presence 实时在线态 + 实时资料覆盖**。
  ///
  /// ⚠️ **2026-10-20 修复（用户实报「所有页面头像在线状态不热更新」）**：
  /// 本组件的 `online` 是**不可变构造参数**，37 个使用点里绝大多数传的是
  /// REST 快照字段或硬编码 `true` ⇒ presence 帧到达后头像光环**永不变化**。
  /// web 的等价物是 `usePresenceOnline(user)`（`utils/displayStatus.ts:75–81`）：
  /// 订阅 `usePresenceStore` 后实时求值。
  ///
  /// ⚠️ **2026-10-26 扩展（用户实报「换头像不热更新」）**：给了身份（[user] 或
  /// [userId]）之后，**头像图片 URL / 昵称文字**也一并取实时值 ——
  /// 优先 `AylaPresenceState.profileOf(id)`（`user.updated` 帧写入的资料覆盖），
  /// 无覆盖字段时回退本组件的 [resourceUrl] / [label]。
  /// web 侧该帧不存在（web `Avatar` 完全靠调用点重渲染），所以这是 Flutter
  /// 补齐后端已广播能力的一处**主动扩展**。
  final AylaUserPublic? user;

  /// **【最轻量】只给 userId 也能订阅**（无需完整 [AylaUserPublic]）。
  ///
  /// 适用场景：列表条目只有 id/名字（群成员、弹幕发送者、会话 peer）。
  /// store 有该 id 记录 ⇒ 按记录（WS 权威）；无记录 ⇒ 回退 [online]。
  /// 与 [user] 的关系：给了 [user] 优先它（能正确处理 `invisible` 隐身）。
  ///
  /// **同时启用资料覆盖**：`user.updated` 帧带来的新头像 URL / 新昵称会覆盖
  /// [resourceUrl] / [label]（见 [user] 的说明）。
  final String? userId;

  /// 头像内容文字（无图时的首字/名字；有图时作语义标签）。
  final String label;

  /// 头像本体直径（web CSS px；Windows 125% 下 1:1 逻辑 px）。
  final double size;

  /// 在线状态（false = --ice-100 灰环）。
  final bool online;

  /// 底色/字色形态（爱莉专属 [AylaAvatarCore.elysia]）。
  final AylaAvatarCore core;

  /// 头像图片 URL（带签名媒体需走 AylaResourceImage）。
  ///
  /// **null 与空串等价** —— 都表示「没有头像图」⇒ 走文字首字档。
  /// 见 [_AvatarHaloState._avatarSrc]：组件内统一归一，调用点无需各自 `_nonEmpty`。
  final String? resourceUrl;

  /// 点击回调（.avatar-halo-btn：可点击头像，hover brightness 1.06）。
  final VoidCallback? onTap;

  /// 可访问性标签（默认 [label] 后附在线状态，双通道语义）。
  final String? semanticLabel;

  /// 头像**覆盖图**（透传给内部 `AylaResourceImage.previewImage`）。
  ///
  /// 两类生产/非生产用途（2026-09-28 订正——原注释写作「只用于预览与画布样张」，
  /// 那是**过时结论**）：
  /// ① 画布样张 / 预览注入的静态图；
  /// ② **本地待上传头像的即时预览** —— `ProfilePage` 选中新头像后用
  ///    `MemoryImage(bytes)` 覆盖真实头像（web 侧是 `URL.createObjectURL(file)`，见
  ///    `ProfilePage.tsx:168`；对象 URL 先于上传存在，保存成功后才换成真实 URL）。
  /// null（默认）⇒ 走 [resourceUrl]。
  final ImageProvider? previewImage;

  static const double haloWidth = 2.5;

  @override
  State<AylaAvatarHalo> createState() => _AvatarHaloState();
}

class _AvatarHaloState extends State<AylaAvatarHalo>
    with SingleTickerProviderStateMixin {
  /// 生效的在线态（给定 store 的**纯求值**）。
  ///
  /// web \`usePresenceOnline(user)\` 的等价物（\`utils/displayStatus.ts:75–81\`）：
  /// store 已知状态优先（WS 增量权威），无记录回退 REST 快照。
  ///
  /// 没给 [AylaAvatarHalo.user] / [AylaAvatarHalo.userId] 时用调用方给的静态 \`online\`
  /// （纯展示/画布样张语义不变）。
  bool _computeOnline(AylaPresenceState? presence) {
    final AylaUserPublic? user = widget.user;
    final String? userId = widget.userId;
    if (user == null && userId == null) return widget.online;
    if (presence == null) return widget.online;
    if (user != null) {
      return presenceOnline(
        presence.users,
        withLiveStatus(presence.statuses, user),
      );
    }
    final String? known = presence.users[userId];
    if (known != null) return known == 'online';
    return widget.online;
  }

  /// 本头像的**身份 id**（用于取资料覆盖）：优先 [AylaAvatarHalo.user] 的 id。
  String? get _identityId => widget.user?.id ?? widget.userId;

  /// `user.updated` 帧带来的资料覆盖（无身份 / 无覆盖 / 无 scope ⇒ null）。
  ///
  /// 这是「换头像不热更新」的修复点：帧把新头像写进 `AylaPresenceState._profiles`，
  /// 但**此前全仓零处读它** ⇒ 头像永远是构造时的 REST 快照。
  AylaUserProfilePatch? _profilePatch(AylaPresenceState? presence) {
    final String? id = _identityId;
    if (id == null || presence == null) return null;
    return presence.profileOf(id);
  }

  /// 生效的**昵称/标签**：覆盖层有非空 nickname 就用它，否则回退构造参数 [AylaAvatarHalo.label]。
  ///
  /// 与 web 的差异：web 的 `Avatar` 只收调用方算好的 label；后端 `user.updated`
  /// 在 web 侧没有消费者（该帧是 Flutter 轮次才补的后端能力）⇒ 这里由组件兜住，
  /// 免去逐调用点改 `label`。
  String _effectiveLabel(AylaUserProfilePatch? patch) {
    final String? nick = patch?.nickname;
    if (nick != null && nick.trim().isNotEmpty) return nick;
    return widget.label;
  }

  /// 生效的**头像图 URL**：覆盖层有非空 avatar 就用它，否则回退 [AylaAvatarHalo.resourceUrl]。
  String? _effectiveResourceUrl(AylaUserProfilePatch? patch) {
    final String? live = patch?.avatar;
    if (live != null) {
      // 后端「清空头像」会广播空串 ⇒ **以空串为权威**（真的没头像了），
      // 不能回退旧 URL，否则用户删掉头像后别人仍看到旧图。
      return live;
    }
    return widget.resourceUrl;
  }

  /// **仅测试用**：暴露「当前生效的头像 URL」供回归锁断言。
  ///
  /// 为什么需要：`resourceUrl` 是调用方的**静态参数**（构造后不变），真正决定画面
  /// 的是 `_effectiveResourceUrl(patch)` —— 它叠加了 `user.updated` 的资料覆盖。
  /// 回归锁必须断言**生效值**，否则测不出「store 存了但没人读」那个历史缺陷。
  @visibleForTesting
  String? get debugEffectiveResourceUrl {
    final AylaPresenceState? presence = _presenceOrNull();
    return _effectiveResourceUrl(_profilePatch(presence));
  }

  /// **仅测试用**：暴露「当前生效的展示名」（昵称随 `user.updated` 覆盖）。
  @visibleForTesting
  String get debugEffectiveLabel {
    final AylaPresenceState? presence = _presenceOrNull();
    return _effectiveLabel(_profilePatch(presence));
  }

  /// 当前 presence store（**无 ProviderScope ⇒ null**）。
  ///
  /// ⚠️ 刻意用 \`listen: false\` 只「取一次引用」——**真正的订阅交给 ListenableBuilder**。
  /// 普查 D §8.2 实测：\`containerOf(listen: true)\` 只依赖 \`UncontrolledProviderScope\`
  /// 这个 InheritedWidget，其 \`updateShouldNotify\` 是 \`container != oldWidget.container\`
  /// （riverpod \`framework.dart:287–289\`），而 container 是长生命周期单例、
  /// **永不更换 ⇒ 永不重建**；\`container.read()\` 也不建立 provider 监听
  /// （\`container.dart:238–242\`）⇒ 那样写「参数传了但光环照旧冻」，是最容易
  /// 误判成已修的陷阱。这里改为直接监听 ChangeNotifier 本体。
  AylaPresenceState? _presenceOrNull() {
    try {
      return ProviderScope.containerOf(context, listen: false)
          .read(presenceStateProvider);
    } on StateError {
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 爱莉呼吸（3.2s ease-in-out 循环）：0 ↔ π 正弦驱动两层辉光。
  late final AnimationController _breathe = AnimationController(
    vsync: this,
    duration: AylaDurations.breathe,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // MediaQuery 依赖只能在 didChangeDependencies 之后读取（initState 里
    // 读取会触发 framework 断言）。
    _syncBreathe(_computeOnline(_presenceOrNull()));
  }

  /// 按**当前**在线态启停爱莉呼吸动画（离线/静态语义下不呼吸）。
  void _syncBreathe(bool online) {
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    final bool shouldBreathe = online &&
        widget.core == AylaAvatarCore.elysia &&
        !reduceMotion;
    if (shouldBreathe && !_breathe.isAnimating) {
      _breathe.repeat();
    } else if (!shouldBreathe && _breathe.isAnimating) {
      _breathe.stop();
      _breathe.value = 0;
    }
  }

  @override
  void didUpdateWidget(covariant AylaAvatarHalo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.online != oldWidget.online ||
        widget.core != oldWidget.core) {
      didChangeDependencies();
    }
  }

  @override
  void dispose() {
    _breathe.dispose();
    super.dispose();
  }

  /// 头像本体内的内容（名字首字 / 人形图标）。
  ///
  /// 统一口径（2026-10-26 用户裁决）：
  /// - 有名字 ⇒ 取首字（web 同）；
  /// - **没名字 ⇒ 人形图标 `Icons.person`**（正常默认头像观感），**不再显示「?」**。
  ///
  /// 光环/在线态由 `_computeOnline` 独立决定，**与本方法无关** —— 无名不影响光环。
  Widget _coreChild({
    required String effectiveLabel,
    required Color coreColor,
    required double size,
  }) {
    if (effectiveLabel.isNotEmpty) {
      return Text(
        effectiveLabel.characters.first,
        style: TextStyle(
          fontFamily: AylaFonts.display,
          fontFamilyFallback: AylaFonts.cjkFallback,
          fontWeight: FontWeight.w500,
          // web `Avatar.tsx:38`：`Math.round(size * 0.42)`（JS 已取整 px）。
          fontSize: (size * 0.42).roundToDouble(),
          color: coreColor,
        ),
      );
    }
    // 无名 ⇒ 人形图标。尺寸与字身同量级（0.42 字 → 0.52 图标），视觉重心居中。
    return Icon(
      Icons.person,
      size: (size * 0.52).roundToDouble(),
      color: coreColor,
    );
  }
  @override
  Widget build(BuildContext context) {
    // presence 实时订阅：**只对给了 user/userId 的头像生效**（纯展示/画布走原路径）。
    // 用 ListenableBuilder 监听 ChangeNotifier 本体 —— 这是唯一真正会触发重建的写法。
    if (widget.user != null || widget.userId != null) {
      final AylaPresenceState? presence = _presenceOrNull();
      if (presence != null) {
        // ⚠️ **必须用 ListenableBuilder 监听 ChangeNotifier 本体**。
        // 用 `container.read(...)` 直接求值**不会**建立监听（见 _presenceOrNull 注释），
        // 那样写「参数传了但光环照旧冻」——回归锁 test/avatar_presence_test.dart 正是锁这个。
        //
        // 同一个 listener 同时驱动三件事，都随帧重建：
        // ① 光环颜色（presence.update / presence.status）；
        // ② 头像图 URL（user.updated → profileOf）；
        // ③ 昵称/语义标签（user.updated → profileOf）。
        return ListenableBuilder(
          listenable: presence,
          builder: (BuildContext _, Widget? __) => _buildBody(
            context,
            _computeOnline(presence),
            patch: _profilePatch(presence),
          ),
        );
      }
      // 无 ProviderScope（画布/纯 widget 测试）⇒ 回落静态值。
    }
    return _buildBody(context, widget.online);
  }

  /// 生效的头像图 URL：**空串按 null 处理**（没有头像图）。
  ///
  /// ## 2026-10-25 修复（用户实报「私信界面头像不显示」的第一根因）
  ///
  /// 此前本组件用 `widget.resourceUrl == null` 判「有没有图」（`:281` / `:299`），
  /// 但**后端对没有头像的用户返回的是空串，不是 null**：
  /// `apps/accounts/models.py:33` 是 `avatar = CharField(blank=True, default="")`，
  /// 序列化走 `UserPublicSerializer`（`apps/accounts/serializers.py:12–38`）原样透出；
  /// Flutter 侧 `AylaUserPublic.avatar` 也保持 `String?`（`user_public.dart:79`
  /// `raw['avatar'] as String?`）⇒ 空串一路传到本组件。
  ///
  /// 空串命中「有图」分支 ⇒ `AylaResourceImage(src: '')` ⇒
  /// `resource_image.dart:307` 的 `if (src.trim().isEmpty)` 直接判 failed ⇒
  /// **装饰图（alt: ''）只渲染 fallback**（`:445`）⇒ 视觉上就是文字首字。
  /// 也就是说：**「没头像」这种正常情况走的是「图片加载失败」的路径**，
  /// 在多徽标光环里还会白白走一遍 loading → failed 的状态机。
  ///
  /// web 事实源 `components/Avatar.tsx:46`：`imageUrl ? <ResourceImage …/> : safeLabel.slice(0,1)`
  /// —— JS 的假值判断把 `''` 与 `null` 一视同仁，走**文字分支**。
  ///
  /// 修在**组件内**而不是各调用点：全库 31 个光环使用点都可能从后端拿到空串
  /// （气泡发送者头像、会话列表、成员表、弹幕、评论…），逐点补 `_nonEmpty` 必漏。
  String? _avatarSrcOf(AylaUserProfilePatch? patch) {
    final String? raw = _effectiveResourceUrl(patch);
    if (raw == null) return null;
    return raw.trim().isEmpty ? null : raw;
  }

  /// 真正的 build 体（[online] 是**已求值**的在线态）。
  ///
  /// [patch] 是 `user.updated` 带来的资料覆盖（null = 无覆盖，全走构造参数）。
  Widget _buildBody(
    BuildContext context,
    bool online, {
    AylaUserProfilePatch? patch,
  }) {
    // 在线态可能在 presence 帧到达后变化（ListenableBuilder 重建）⇒ 同步呼吸动画。
    _syncBreathe(online);
    final double size = widget.size;
    // 光环底色：CSS `conic-gradient(from 210deg, #9DBFE6, #F9B0FF,
    // #F796FF, #9DBFE6)`（t:--ring-online）的 Flutter 等价。
    //
    // 关键：SweepGradient 的采样角被归一化到 [0, 2π)，若渐变区间不从 0
    // 开始（如 startAngle=120°），落在区间外的角度会 clamp 成纯色，与
    // 渐变区末端在物理某处硬切（实测：3 点方向 glow↔ice 突变）。
    // 正确做法：区间 = [0, 2π) 全覆盖 + **首尾同色** 闭合，并把相位换算
    // 对齐 CSS（Flutter 角 = CSS 角 − 90°，0° 在 3 点方向）：
    //   CSS:  ice@210°(7点)  sakura@330°(11点)  glow@90°(3点)  ice@210°
    //   Fla:  glow@0°(3点)   ice@120°(7点)      sakura@240°(11点)
    // → colors = [glow, ice, sakura, glow]（首尾同色，环闭合无缝）。
    final Gradient ringGradient = online
        ? const SweepGradient(
            startAngle: 0,
            endAngle: math.pi * 2,
            colors: <Color>[
              AylaColors.glow500,
              AylaColors.ice500,
              AylaColors.sakura300,
              AylaColors.glow500,
            ],
          )
        : const LinearGradient(colors: <Color>[
            AylaColors.ice100,
            AylaColors.ice100,
          ]);

    // 头像本体：core 渐变底 + Fredoka 500 字（app.css .avatar-core-*）
    final List<Color> coreColors;
    final Color coreColor;
    switch (widget.core) {
      case AylaAvatarCore.user:
        coreColors = AylaGradients.avatarCoreUser;
        coreColor = AylaColors.indigo700;
      case AylaAvatarCore.elysia:
        coreColors = AylaGradients.avatarCoreElysia;
        coreColor = AylaColors.grape700;
    }

    final String? avatarSrc = _avatarSrcOf(patch);
    // 昵称也可能被 user.updated 覆盖（换昵称同样要热更新）。
    final String effectiveLabel = _effectiveLabel(patch);

    final Widget core = ClipOval(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: cssLinearGradient(angleDeg: 135, colors: coreColors),
        ),
        child: Center(
          // ⚠️ **2026-10-26 用户裁决**：名字取不到时**不显示「?」**，而是用**人形图标**
          // 兜底 —— 视觉上就是一个正常的默认头像。
          //
          // 有意偏离 web（`Avatar.tsx:37` 是 `label?.trim() || "?"`）：问号在界面上像
          // 「出错了」，而默认人形头像是通行形态。光环（在线/离线）逻辑**完全不受影响**
          // —— 它由 `_computeOnline` 独立决定，与有没有名字无关。
          child: _coreChild(effectiveLabel: effectiveLabel, coreColor: coreColor, size: size),
        ),
      ),
    );

    // 无图时 core 撑满本体；有图时图在上、字在下（语义层）
    final Widget coreLayer = avatarSrc == null
        ? core
        : Stack(
            fit: StackFit.expand,
            children: <Widget>[
              // 图片走组件库 AylaResourceImage（**2026-09-20 B5 前置修复**）：
              // web `Avatar.tsx:46–48` 用的是 AylaResourceImage → 媒体头像
              // （/api/v1/media/<id>/content）需要签名，裸 `Image.network`
              // 会 401 破图。AylaResourceImage 对非媒体 URL 直接加载、对媒体路径
              // 走 MediaSigner 签名 + 过期重签，语义与 web 一致。
              // 失败/加载中回退文字首字（`alt: ''` = 装饰图，只渲染 fallback）。
              ClipOval(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient:
                        cssLinearGradient(angleDeg: 135, colors: coreColors),
                  ),
                  child: AylaResourceImage(
                    src: avatarSrc,
                    alt: '',
                    fit: BoxFit.cover,
                    previewImage: widget.previewImage,
                    // 头像 = **永久资产 A5（用户）/ A6（群）**（用户裁决 2026-10-23）
                    // ⇒ 不落本地缓存。事实源：retention-boundaries §3 A5/A6。
                    cacheable: false,
                    // 图片加载失败时的兜底：与无图分支**同一口径**（有名字取首字、
                    // 无名用人形图标），见 [_coreChild]。
                    fallback: Center(
                      child: _coreChild(
                        effectiveLabel: effectiveLabel,
                        coreColor: coreColor,
                        size: size,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );

    // 外层：2.5px 光环 +（爱莉在线时）呼吸辉光
    Widget halo = Padding(
      padding: const EdgeInsets.all(AylaAvatarHalo.haloWidth),
      child: SizedBox(
        width: size,
        height: size,
        child: coreLayer,
      ),
    );

    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    final bool breathe = online &&
        widget.core == AylaAvatarCore.elysia &&
        !reduceMotion;

    if (breathe) {
      halo = AnimatedBuilder(
        animation: _breathe,
        builder: (BuildContext context, Widget? child) {
          // sin(π·t)：0→0.5 上升、0.5→1 回落，与 CSS 0/100↔50 同构
          final double wave =
              math.sin(math.pi * _breathe.value).clamp(0.0, 1.0).toDouble();
          return DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: AylaColors.haloBreathSoft
                      .withValues(alpha: 0.5 + 0.4 * wave),
                  blurRadius: 8,
                ),
                BoxShadow(
                  color: AylaColors.haloBreathOuter
                      .withValues(alpha: 0.45 * wave),
                  blurRadius: 16,
                ),
              ],
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: ringGradient,
              ),
              child: child,
            ),
          );
        },
        child: halo,
      );
    } else {
      halo = DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: ringGradient,
          // reduced-motion：静态 0 0 8px rgba(247,150,255,.5)
          boxShadow: online &&
                  widget.core == AylaAvatarCore.elysia
              ? const <BoxShadow>[
                  BoxShadow(
                    color: AylaColors.haloBreathSoft,
                    blurRadius: 8,
                  ),
                ]
              : null,
        ),
        child: halo,
      );
    }

    final String stateLabel = online ? '在线' : '离线';
    // 语义标签也要跟着覆盖后的昵称走（否则读屏仍是旧名字）。
    final Widget result = Semantics(
      image: true,
      label:
          '${widget.semanticLabel ?? effectiveLabel}，$stateLabel', // 光环+文字双通道
      child: halo,
    );

    // 呼吸辉光（3.2s 循环）与 hover 着色都在这个组件内部变化：包一层重绘边界，
    // 让每帧的 markNeedsPaint 止步于此 —— 否则在顶栏/直播间这类**静态布局**里
    // 会一路上传到最近的边界（即整页重绘）。2026-09-25 全库审计：动画组件此前
    // **没有一个** RepaintBoundary。
    final Widget bounded = RepaintBoundary(child: result);

    if (widget.onTap == null) return bounded;

    // .avatar-halo-btn：可点击头像，hover brightness(1.06)、focus-visible 辉光环
    // web «Avatar.tsx:70»：可点击头像的 button 上带 «title={ariaLabel ?? safeLabel}»
    // ⇒ AylaTooltip（全库统一项）。不可点击分支（onTap == null）在上一行已提前返回 ——
    // web 那条走 «aria-hidden» span，不带 title，两侧一致。
    return AylaTooltip(
      message: widget.semanticLabel ?? effectiveLabel,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: _hovered
              ? ColorFiltered(
                  colorFilter: const ColorFilter.matrix(<double>[
                    1.06, 0, 0, 0, 0, //
                    0, 1.06, 0, 0, 0, //
                    0, 0, 1.06, 0, 0, //
                    0, 0, 0, 1, 0,
                  ]),
                  child: result,
                )
              : result,
        ),
      ),
    );
  }

  bool _hovered = false;
}

// ======================= 样张 =======================
