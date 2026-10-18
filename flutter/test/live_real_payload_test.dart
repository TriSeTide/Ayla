/// 生产 payload → Ayla 解析/归一 → 真实地址契约。
///
/// payload 取自线上后端（2026-10-18 频道 2，`GET /live/channels/2/` 实测）：
/// ```json
/// {"hls_url": "https://live.trise.top:7882/live/<key>.m3u8", ...}
/// ```
/// 该地址在原生播放器上 TLS 握手被重置（见 `core/net/live_play_url.dart` 文件头），
/// 因此必须被归一到 API 同源。本测试锁住「真实 payload 真的被改写」。
library;

import 'package:flutter_test/flutter_test.dart';

import '../lib/core/net/live_play_url.dart';
import '../lib/widgets/live/live_channel_snapshot.dart';

const String kKey = 'be86d4a1deb369a224b9cd4805d1a984b9e6413ba9fe056e';
const String kApi = 'https://s.ayla.trise.top:26211';

void main() {
  test('线上频道 payload：hls_url/flv_url 归一到 API 同源', () {
    final AylaLiveChannelSnapshot snap = AylaLiveChannelSnapshot.fromJson(
      <String, Object?>{
        'id': 2,
        'title': 'test',
        'status': 'live',
        'hls_url': 'https://live.trise.top:7882/live/$kKey.m3u8',
        'flv_url': 'https://live.trise.top:7882/live/$kKey.flv',
      },
    )!;
    // 测试进程没有 --dart-define，归一函数默认按「未配置远端」原样返回；
    // 这里显式传生产 apiBase 复现 release 构建的行为。
    expect(
      aylaNormalizeLivePlayUrl(snap.hlsUrl!, apiBase: kApi, configured: true),
      '$kApi/live/$kKey.m3u8',
    );
    expect(
      aylaNormalizeLivePlayUrl(snap.flvUrl!, apiBase: kApi, configured: true),
      '$kApi/live/$kKey.flv',
    );
  });
}
