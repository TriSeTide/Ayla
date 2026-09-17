/// PoC-B HLS 测试页：URL 输入 → 播放 → 跳边 → 黑屏自愈状态显示。
///
/// 封装层 `lib/player/hls_player.dart`（状态机 + 自愈 + 跳边 + 平台分发）。
/// 本页只做验证 UI（PoC 不展开业务组件）。
library;

import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../player/hls_player.dart';
import '../player/platforms/hls_platform.dart';

class HlsPage extends StatefulWidget {
  const HlsPage({super.key});

  @override
  State<HlsPage> createState() => _HlsPageState();
}

class _HlsPageState extends State<HlsPage> {
  /// 平台区分：Android 模拟器访问宿主机用 10.0.2.2；桌面端 127.0.0.1。
  static const String _streamKey =
      '7d42d1ffdc41aa6e88340457bc75784d06dd24739e160be9';
  late final String _defaultHost =
      Platform.isAndroid ? '10.0.2.2:8080' : '127.0.0.1:8080';
  late final TextEditingController _urlCtrl = TextEditingController(
    text: 'http://$_defaultHost/live/$_streamKey.m3u8',
  );

  HlsPlaybackController? _hls;
  HlsState _state = HlsState.idle;
  String _lastError = '—';
  final ScrollController _scroll = ScrollController();
  final List<String> _logs = [];

  bool get _active => _hls != null;

  void _log(String line) {
    _logs.add('${DateTime.now().toString().substring(11, 23)} $line');
    if (_logs.length > 200) _logs.removeAt(0);
    if (_scroll.hasClients) {
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _attach() async {
    if (_active) return;
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) {
      _log('URL 为空');
      return;
    }
    _log('attach $url');
    final callbacks = HlsPlayerCallbacks();
    callbacks.onStateChange = (HlsState s) {
      setState(() => _state = s);
    };
    callbacks.onError = (String d) {
      setState(() {
        _lastError = d;
        _log('error: $d');
      });
    };
    callbacks.onLog = _log;
    final hls = HlsPlaybackController(createHlsPlatformPlayer, callbacks);
    setState(() => _hls = hls);
    await hls.attach(url);
  }

  Future<void> _destroy() async {
    final hls = _hls;
    setState(() => _hls = null);
    if (hls != null) await hls.destroy();
    _state = HlsState.idle;
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('PoC-B HLS 播放')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _urlCtrl,
            decoration: const InputDecoration(labelText: 'HLS URL'),
            enabled: !_active,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              FilledButton(
                onPressed: _active ? null : _attach,
                child: const Text('播放'),
              ),
              OutlinedButton(
                onPressed: _active ? _destroy : null,
                child: const Text('停止'),
              ),
              FilledButton.tonal(
                onPressed: _active ? () => _hls?.refreshToLiveEdge() : null,
                child: const Text('跳边(Live Edge)'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_active && _hls?.videoView != null) ...[
            AspectRatio(
              aspectRatio: 16 / 9,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: _hls!.videoView!,
              ),
            ),
            const SizedBox(height: 12),
          ],
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('状态: $_stateName'),
                  Text('自愈参数: stall ${kStallTimeoutMs}ms / 冷却 ${kRebuildCooldownMs}ms'),
                  Text('最近错误: $_lastError'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Container(
            height: 220,
            decoration: BoxDecoration(
              color: const Color(0xFF0D1117),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ListView.builder(
              controller: _scroll,
              itemCount: _logs.length,
              itemBuilder: (_, i) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
                child: Text(
                  _logs[i],
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String get _stateName => switch (_state) {
        HlsState.idle => 'idle',
        HlsState.loading => 'loading',
        HlsState.playing => 'playing',
        HlsState.buffering => 'buffering',
        HlsState.error => 'error',
      };
}
