/// 用**真实后端响应体的脱敏快照**（test/fixtures/favorites_response_string_ids.json；
/// 2026-10-15 取自真实 /api/v1/favorites/，仅把 id/文案替换为占位符，**保留触发缺陷的结构**）。
///
/// 跑完整解析链：收藏页四条必须全部「可用」（不得退化为「内容不可用」）。
///
/// 这是缺陷 1 的**最强证据**：真实数据里四条的 target.id **全是字符串**
/// （post '106' / live '128' / voice '12' / voice '3'），
/// 其中 post 是唯一因「只接受 num」而解析失败的 ⇒ 用户截图里四条全不可用。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/api/directory_page.dart' show AylaDirectoryPage;
import '../lib/core/api/favorites_api.dart';

void main() {
  test('真实响应（4 条）逐条解析：全部可用', () {
    // 路径相对测试进程 cwd（= Ayla/flutter）；fixture 随仓库提交 ⇒ 恒存在，不再静默跳过。
    final File f = File('test/fixtures/favorites_response_string_ids.json');
    expect(f.existsSync(), isTrue,
        reason: 'fixture 必须随仓库存在（缺失即说明被误删）：' + f.path);
    final Map<String, dynamic> raw =
        jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    final AylaDirectoryPage<AylaFavoriteEntry> page =
        AylaDirectoryPage.fromJson<AylaFavoriteEntry>(
      raw,
      AylaFavoriteEntry.fromJson,
    );
    expect(page.results.length, 4, reason: '真实响应有 4 条');
    final List<String> unavailable = <String>[];
    final List<String> summary = <String>[];
    for (final AylaFavoriteEntry e in page.results) {
      summary.add(e.card.targetType.name + '=' + (e.card.isAvailable ? 'ok' : 'UNAVAILABLE'));
      if (!e.card.isAvailable) {
        unavailable.add(e.card.targetType.name + '(id=' + e.targetId + ')');
      }
    }
    debugPrint('解析结果: ' + summary.join(' / '));
    expect(unavailable, isEmpty,
        reason: '真实数据的四条都必须可用；不可用的：' + unavailable.join(','));
  });
}