/// 直播播放地址归一（`core/net/live_play_url.dart`）契约。
///
/// 用户实报：`https://live.trise.top:7882` 的 HLS 在 App（mpv/ExoPlayer/AVPlayer）
/// 上 TLS 握手被重置 ⇒ 播放器一直转圈；web 走浏览器栈正常。修复 = 收敛到 API 同源。
library;

import 'package:flutter_test/flutter_test.dart';

import '../lib/core/net/live_play_url.dart';
import '../lib/widgets/live/live_channel_snapshot.dart';

const String kRemote = 'https://s.ayla.trise.top:26211';
const String kKey = 'be86d4a1deb369a224b9cd4805d1a984b9e6413ba9fe056e';

void main() {
  test('远端播放地址 → 收敛到 API 同源（保留路径与 query）', () {
    expect(
      aylaNormalizeLivePlayUrl(
        'https://live.trise.top:7882/live/$kKey.m3u8',
        apiBase: kRemote,
        configured: true,
      ),
      '$kRemote/live/$kKey.m3u8',
    );
    expect(
      aylaNormalizeLivePlayUrl(
        'https://live.trise.top:7882/live/$kKey.m3u8?hls_ctx=abc',
        apiBase: kRemote,
        configured: true,
      ),
      '$kRemote/live/$kKey.m3u8?hls_ctx=abc',
    );
    expect(
      aylaNormalizeLivePlayUrl(
        'https://live.trise.top:7882/live/$kKey-57.ts?hls_ctx=abc',
        apiBase: kRemote,
        configured: true,
      ),
      '$kRemote/live/$kKey-57.ts?hls_ctx=abc',
    );
    expect(
      aylaNormalizeLivePlayUrl(
        'https://live.trise.top:7882/live/$kKey.flv',
        apiBase: kRemote,
        configured: true,
      ),
      '$kRemote/live/$kKey.flv',
    );
  });

  test('本地开发（未配置远端 API）→ 原样返回', () {
    const String local = 'https://live.trise.top:7882/live/$kKey.m3u8';
    expect(aylaNormalizeLivePlayUrl(local, configured: false), local);
  });

  test('已经同源 → 原样返回（不做无谓改写）', () {
    const String same = '$kRemote/live/$kKey.m3u8';
    expect(
      aylaNormalizeLivePlayUrl(same, apiBase: kRemote, configured: true),
      same,
    );
  });

  test('非直播流路径 → 原样返回（不误伤其它媒体/接口地址）', () {
    for (final String url in <String>[
      'https://live.trise.top:7882/other/x.m3u8',
      'https://cdn.example.com/vod/movie.mp4',
      'https://s.ayla.trise.top:26211/api/v1/media/m1/content',
      '/live/$kKey.m3u8', // 相对路径：没有 origin 可判定
      'not a url',
      '',
    ]) {
      expect(
        aylaNormalizeLivePlayUrl(url, apiBase: kRemote, configured: true),
        url,
        reason: url,
      );
    }
  });

  test('http 播放地址 → 提升到 https 同源（避免明文被系统策略拦截）', () {
    expect(
      aylaNormalizeLivePlayUrl(
        'http://live.trise.top:7882/live/$kKey.m3u8',
        apiBase: kRemote,
        configured: true,
      ),
      '$kRemote/live/$kKey.m3u8',
    );
  });

  test('快照解析（GET /live/channels/<id>/）对 hls_url/flv_url 做同源归一', () {
    final AylaLiveChannelSnapshot? channel =
        AylaLiveChannelSnapshot.fromJson(<String, Object?>{
          'id': 2,
          'title': 'test',
          'status': 'live',
          'hls_url': 'https://live.trise.top:7882/live/$kKey.m3u8',
          'flv_url': 'https://live.trise.top:7882/live/$kKey.flv',
        });
    expect(channel, isNotNull);
    expect(channel!.hlsUrl, isNotNull);
    expect(channel.flvUrl, isNotNull);
    expect(
      AylaLiveChannelSnapshot.fromJson(<String, Object?>{
        'id': 2,
        'title': 'test',
        'hls_url': '',
        'flv_url': '',
      })!.hlsUrl,
      isNull,
      reason: '空串必须是缺席（否则播放器会拿空 URL 去 attach）',
    );
  });
}
