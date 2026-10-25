/// 「群内场景不重复让出状态栏」的**接线**回归锁（2026-10-19 第三次漏修后新增）。
///
/// ## 为什么需要它（血泪教训）
/// 前两轮我都「加了开关」，但**漏了把开关传给真正渲染头部的组件**：
/// ```dart
/// // AylaGameRoomHost 加了字段…
/// final bool inGroup;
/// // …但内部调用 AylaGameRoomPlaceholder 时没传 topInset ⇒ 群内空白带一直在
/// AylaGameRoomPlaceholder(room: room, narrow: narrow, ...);   // ← 漏 topInset
/// ```
/// 而 `dart analyze` **不报**（`topInset` 有默认值 `true`，语法完全合法）、
/// 组件测试也不报（测试自己构造组件、自己喂参数，量不到宿主传了什么）。
/// ⇒ 这与 skill 里记过的 `AylaSessionActivityIndicator` 空参调用是**同一类缺陷**。
///
/// ## 本测试的做法
/// 静态扫描源码：对每个「群内会复用」的页面宿主，断言它调用渲染组件时**显式传了开关**。
/// 只锁 `lib/pages/`（宿主层），不锁组件自身与其样张。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 取 `src` 中从 `from` 起、括号配对的完整调用文本。
String _callAt(String src, int from) {
  int depth = 0;
  int i = from;
  while (i < src.length) {
    final String ch = src[i];
    if (ch == '(') depth++;
    if (ch == ')') {
      depth--;
      if (depth == 0) break;
    }
    i++;
  }
  return src.substring(from, i + 1);
}

void main() {
  /// 宿主文件 → (被调用的渲染组件, 必须出现的开关参数)
  const Map<String, List<(String, String)>> wiring = <String, List<(String, String)>>{
    // 群内直播：宿主自己就是页面参数装配处
    'lib/pages/group_live_page.dart': <(String, String)>[
      ('AylaLiveRoomBody(', 'topInset'),
    ],
    // 群内语音：页面 → Host（inGroup）→ Body（topInset）
    'lib/pages/group_voice_page.dart': <(String, String)>[
      ('AylaVoiceRoomHost(', 'inGroup'),
    ],
    'lib/pages/voice_support.dart': <(String, String)>[
      ('AylaVoiceRoomBody(', 'topInset'),
    ],
    // 群内帖子：页面 → PostDetailPage（inGroup）→ Chrome（topInset）
    'lib/pages/group_posts_page.dart': <(String, String)>[
      ('PostDetailPage(', 'inGroup'),
    ],
    'lib/pages/post_detail_page.dart': <(String, String)>[
      ('AylaPostDetailChrome(', 'topInset'),
    ],
    // 群内桌游：页面 → Host（inGroup）→ Placeholder（topInset）
    'lib/pages/group_games_page.dart': <(String, String)>[
      ('AylaGameRoomHost(', 'inGroup'),
    ],
    'lib/pages/game_support.dart': <(String, String)>[
      ('AylaGameRoomPlaceholder(', 'topInset'),
    ],
  };

  test('群内复用的房间/详情组件：宿主的每一次调用都必须显式带「让位开关」', () {
    final List<String> problems = <String>[];

    for (final MapEntry<String, List<(String, String)>> entry in wiring.entries) {
      final File file = File(entry.key);
      if (!file.existsSync()) {
        problems.add('${entry.key} 不存在（文件被移动/改名？请同步更新本测试）');
        continue;
      }
      final String src = file.readAsStringSync();

      for (final (String ctor, String key) in entry.value) {
        int start = 0;
        int found = 0;
        while (true) {
          final int i = src.indexOf(ctor, start);
          if (i < 0) break;
          start = i + 1;
          // 跳过定义/声明行（`class X` / `extends` / 注释里的提及）
          final String pre = src.substring(i > 40 ? i - 40 : 0, i);
          if (pre.contains('class ') || pre.contains('extends ')) continue;
          if (pre.trimRight().endsWith('///')) continue;
          found++;
          final String call = _callAt(src, i + ctor.length - 1);
          if (!call.contains(key + ':')) {
            final int line = src.substring(0, i).split('\n').length;
            problems.add('${entry.key}:$line  调用 $ctor 时未传 $key');
          }
        }
        if (found == 0) {
          problems.add('${entry.key} 里找不到 $ctor 调用（结构变了？请同步更新本测试）');
        }
      }
    }

    expect(
      problems,
      isEmpty,
      reason: '以下位置「加了开关却没传下去」，群内会多出空白带：\n' +
          problems.join('\n'),
    );
  });
}
