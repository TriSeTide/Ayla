/// 点播视频播放（web 内联 `<video>` / 查看器 `<video controls autoPlay>` 的 Flutter 等价）。
///
/// ## 事实源
///
/// | 场景 | web | 本文件 |
/// |---|---|---|
/// | 气泡内联首帧（`MediaContent.tsx` `VideoFrame`） | `<video preload="metadata" muted playsInline tabIndex={-1}>` + `pointer-events: none`（禁交互，点击进查看器） | [AylaVodVideo] `controls: false, muted: true`（`IgnorePointer` 包住画面） |
/// | 查看器播放（`ImageViewer.tsx` `VideoPlayer`） | `<video controls autoPlay preload="auto">` | [AylaVodVideo] `controls: true, autoPlay: true, muted: false` |
/// | `object-fit: cover` | `.media-video`（app.css 1415–1421） | [fit] |
///
/// ⚠️ **有意偏离（登记）**：web 的播放控制条是**浏览器原生 UA 控件**
/// （形态随浏览器而定，CSS 不可改）⇒ Flutter 侧没有等价物，改为**库内自绘控制条**
/// （播放/暂停键沿用 `.voice-play` 的 40 圆 + `--indigo-700` 底 + hover `--glow-shadow`；
/// 进度条沿用 `.voice-seek` 的 4px 轨道 + 12px 拇指；时间沿用 `--font-utility` 12px）。
/// 视觉不是发明：三者的度量全部取自 app.css 1535–1639（语音卡同族控件）。
///
/// ## 平台分派（同 [player/hls_player.dart] 的既有约定）
/// Windows = media_kit(mpv)；Android/iOS = video_player（见 `platforms/vod_platform.dart`）。
library;

import 'package:flutter/material.dart';

import 'platforms/vod_platform.dart';
import '../theme/tokens.dart';

/// 播放器可观测状态（两端统一投影）。
class VodPlaybackState {
  const VodPlaybackState({
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.playing = false,
    this.buffering = false,
    this.error,
  });

  final Duration position;
  final Duration duration;
  final bool playing;
  final bool buffering;

  /// 出错文案（null = 正常）。
  final String? error;

  VodPlaybackState copyWith({
    Duration? position,
    Duration? duration,
    bool? playing,
    bool? buffering,
    String? error,
  }) =>
      VodPlaybackState(
        position: position ?? this.position,
        duration: duration ?? this.duration,
        playing: playing ?? this.playing,
        buffering: buffering ?? this.buffering,
        error: error ?? this.error,
      );

  /// 进度 0..1（duration 未知时为 0）。
  double get progress {
    final int total = duration.inMilliseconds;
    if (total <= 0) return 0;
    return (position.inMilliseconds / total).clamp(0.0, 1.0);
  }
}

/// 平台播放器接口（两端各一份实现，见 `platforms/`）。
abstract class VodPlatformPlayer {
  /// 状态变化回调（实现方在 attach/play/pause/seek/播放推进时调用）。
  void Function(VodPlaybackState state)? onStateChange;

  /// 画面是否已可显示。
  bool get hasView;

  /// 打开媒体。[autoPlay] = 立即起播；[muted] = 静音（内联首帧用）。
  Future<void> attach(String url, {required bool autoPlay, required bool muted});

  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);

  /// 平台画面 widget（未就绪返回 null）。
  Widget? buildView();

  Future<void> dispose();
}

/// 播放器工厂（测试/预览注入替身：真实实现会创建平台播放内核）。
typedef VodPlayerFactory = VodPlatformPlayer Function();

/// 点播视频面（含可选控制条）。
class AylaVodVideo extends StatefulWidget {
  const AylaVodVideo({
    super.key,
    required this.src,
    this.controls = false,
    this.autoPlay = false,
    this.muted = true,
    this.fit = BoxFit.cover,
    this.semanticLabel,
    this.playerFactory,
    this.onReady,
    this.onError,
  });

  /// 已签名的视频地址（调用方负责签发，组件不碰媒体链路）。
  final String src;

  /// 是否显示控制条（详情/查看器 true）。
  final bool controls;

  final bool autoPlay;
  final bool muted;
  final BoxFit fit;
  final String? semanticLabel;

  /// 播放器工厂（null = 按平台创建真实播放器）。
  final VodPlayerFactory? playerFactory;

  /// 画面就绪 / 出错回调。
  final VoidCallback? onReady;
  final void Function(String detail)? onError;

  @override
  State<AylaVodVideo> createState() => _AylaVodVideoState();
}

class _AylaVodVideoState extends State<AylaVodVideo> {
  VodPlatformPlayer? _player;
  VodPlaybackState _state = const VodPlaybackState();
  bool _attached = false;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  @override
  void didUpdateWidget(covariant AylaVodVideo old) {
    super.didUpdateWidget(old);
    if (old.src != widget.src) {
      _player?.dispose();
      _player = null;
      _attached = false;
      _attach();
    }
  }

  void _attach() {
    final VodPlatformPlayer player =
        (widget.playerFactory ?? createVodPlatformPlayer)();
    player.onStateChange = (VodPlaybackState s) {
      if (!mounted) return;
      setState(() => _state = s);
      if (s.error != null) widget.onError?.call(s.error!);
    };
    _player = player;
    player
        .attach(widget.src, autoPlay: widget.autoPlay, muted: widget.muted)
        .then((_) {
      if (!mounted || _player != player) return;
      setState(() => _attached = true);
      widget.onReady?.call();
    }).catchError((Object e) {
      if (!mounted) return;
      setState(() => _state = _state.copyWith(error: e.toString()));
      widget.onError?.call(e.toString());
    });
  }

  @override
  void dispose() {
    _player?.dispose();
    _player = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Widget? view = _attached ? _player?.buildView() : null;
    if (view == null) return const SizedBox.shrink();

    final Widget fitted = widget.fit == BoxFit.fill
        ? view
        : FittedBox(fit: widget.fit, clipBehavior: Clip.hardEdge, child: view);

    if (!widget.controls) {
      // 气泡内禁交互（web `.media-video { pointer-events: none }`）：点击事件留给外层按钮。
      return IgnorePointer(
        child: Semantics(label: widget.semanticLabel, child: fitted),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        fitted,
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: _VodControls(
            state: _state,
            onToggle: _toggle,
            onSeek: _seek,
          ),
        ),
      ],
    );
  }

  void _toggle() {
    final VodPlatformPlayer? player = _player;
    if (player == null) return;
    if (_state.playing) {
      player.pause();
    } else {
      // 播完后再点播放：从头开始（web `<video>` 到结尾后 play 会自动重头，两端一致）
      if (_state.duration > Duration.zero && _state.position >= _state.duration) {
        player.seek(Duration.zero);
      }
      player.play();
    }
  }

  void _seek(double progress) {
    final VodPlatformPlayer? player = _player;
    final int total = _state.duration.inMilliseconds;
    if (player == null || total <= 0) return;
    player.seek(Duration(milliseconds: (total * progress).round()));
  }
}

/// 自绘控制条（见文件头「有意偏离」：视觉沿用 `.voice-play` / `.voice-seek` 同族控件）。
class _VodControls extends StatelessWidget {
  const _VodControls({
    required this.state,
    required this.onToggle,
    required this.onSeek,
  });

  final VodPlaybackState state;
  final VoidCallback onToggle;
  final ValueChanged<double> onSeek;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AylaSpacing.sp3,
        vertical: AylaSpacing.sp2,
      ),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[Color(0x00000000), Color(0x66000000)],
        ),
      ),
      child: Row(
        children: <Widget>[
          _PlayPauseButton(playing: state.playing, onTap: onToggle),
          const SizedBox(width: AylaSpacing.sp3),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4,
                activeTrackColor: AylaColors.indigo700,
                inactiveTrackColor: const Color(0x739DBFE6),
                thumbColor: AylaColors.indigo700,
                overlayColor: const Color(0x339DBFE6),
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
              ),
              child: Slider(
                value: state.progress,
                onChanged: onSeek,
                // ⚠️ 不传 divisions（Flutter 的 isDiscrete 会让拇指动画化、追不上指针，
                //    见 13 号 §五「Slider 传 divisions 会让拇指不跟手」）。
                semanticFormatterCallback: (double v) =>
                    '播放进度 ${(v * 100).round()}%',
              ),
            ),
          ),
          const SizedBox(width: AylaSpacing.sp2),
          Text(
            '${_fmt(state.position)} / ${_fmt(state.duration)}',
            style: const TextStyle(
              fontFamily: AylaFonts.utility,
              fontFamilyFallback: AylaFonts.cjkFallback,
              fontSize: 11,
              letterSpacing: 0.3,
              color: Color(0xFFFFFAFB),
            ),
          ),
        ],
      ),
    );
  }

  static String _fmt(Duration d) {
    final int total = d.inSeconds < 0 ? 0 : d.inSeconds;
    return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
  }
}

/// 播放/暂停圆键（`.voice-play`：40 圆 + `--indigo-700` 底 + `#fffafb` 字 + hover `--glow-shadow`）。
class _PlayPauseButton extends StatefulWidget {
  const _PlayPauseButton({required this.playing, required this.onTap});

  final bool playing;
  final VoidCallback onTap;

  @override
  State<_PlayPauseButton> createState() => _PlayPauseButtonState();
}

class _PlayPauseButtonState extends State<_PlayPauseButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Semantics(
          button: true,
          label: widget.playing ? '暂停' : '播放',
          child: AnimatedContainer(
            duration: AylaDurations.button,
            curve: AylaCurves.easeOut,
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AylaColors.indigo700,
              shape: BoxShape.circle,
              boxShadow: _hovered ? AylaShadows.glow : null,
            ),
            child: Center(
              child: Icon(
                widget.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                size: 20,
                color: const Color(0xFFFFFAFB),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
