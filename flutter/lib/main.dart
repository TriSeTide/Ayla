import 'package:flutter/material.dart';

import 'poc/echo_page.dart';
import 'poc/hls_page.dart';

void main() {
  runApp(const PocApp());
}

/// PoC 最小壳：双 PoC 入口（PoC-A 语音中继 / PoC-B HLS 播放）。
/// 本阶段只做两个 PoC，不展开任何业务页面/组件/主题。
class PocApp extends StatelessWidget {
  const PocApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ayla Flutter PoC',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFF9DBFE6),
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ayla Flutter PoC')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            FilledButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const EchoPage()),
              ),
              child: const Text('PoC-A 音频 Echo（语音中继）'),
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const HlsPage()),
              ),
              child: const Text('PoC-B HLS 播放（直播）'),
            ),
          ],
        ),
      ),
    );
  }
}
