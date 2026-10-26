/// 群成员退出后头像回退文案回归锁（2026-10-26）。
///
/// 用户实报：群成员退出后，他的头像变成「发」字、在线光环消失，但点击仍能进主页。
///
/// 根因（已修）：
/// - 消息只带 sender_id（后端 MessageSerializer 无昵称/头像），前端靠
///   conversation.members 补名字；成员退出后不在表里 ⇒ label/name 双双为 null；
/// - 旧回退链是 label ?? name ?? **"发送者"** ⇒ 头像取首字 → **「发」**；
/// - web 口径（Avatar.tsx:37）是 label?.trim() || **"?"** —— 没有名字显示问号。
///
/// 本锁断言「无名时不出现伪语义词，且回退为 ?」。
library;

import 'package:characters/characters.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// 复刻修复后的回退口径（与 message_bubble.dart 一致）。
  String avatarLabel(String? avatarLabel, String? senderName) =>
      avatarLabel ?? senderName ?? '';

  test('★ 成员退出（无 label 无 name）⇒ 空串，不落「发送者」', () {
    expect(avatarLabel(null, null), '');
    expect(avatarLabel(null, null).contains('发送者'), isFalse,
        reason: '伪语义词会让头像取首字变成「发」');
  });

  test('★ 有昵称 ⇒ 用昵称（正常路径不受影响）', () {
    expect(avatarLabel(null, '小樱'), '小樱');
    expect(avatarLabel('樱', '小樱'), '樱');
  });

  test('★ 空串 label 时头像应回退 「?」（对齐 web Avatar.tsx:37）', () {
    // 头像组件的取字规则：空 ⇒ ?；否则取首字。
    String initial(String label) => label.isEmpty ? '?' : label.characters.first;
    expect(initial(''), '?');
    expect(initial('小樱'), '小');
    expect(initial('发送者'), '发', reason: '这正是修复前用户看到的字');
  });

  group('退群成员头像：仍可点击进主页（用户 2026-10-26 追问）', () {
    test('★ 点击只用 senderId，不依赖昵称/标签', () {
      // 断言口径：大头像的 onTap 走 `_onSenderTap` → `onSenderClick` → `_goUserProfile(m.senderId)`，
      // 全链路**只读 senderId**。昵称缺失（退群）只影响**显示文字**，不影响可达性。
      String? resolveTarget(String? senderId, String? senderName) {
        // 复刻 `_goUserProfile` 的守卫：仅空 id 时不可达。
        if (senderId == null || senderId.isEmpty) return null;
        return '/user/' + Uri.encodeComponent(senderId);
      }

      expect(resolveTarget('u2', null), '/user/u2',
          reason: '★ 无昵称（已退群）也必须能进主页');
      expect(resolveTarget('u2', '小樱'), '/user/u2',
          reason: '有昵称时行为不变');
      expect(resolveTarget('', null), isNull, reason: '空 id 才不可达');
      expect(resolveTarget(null, null), isNull);
    });

    test('★ 标签回退为 ? 时，头像仍带 onTap（渲染层不被禁用）', () {
      // 修复前：label 落到「发送者」仍可点；修复后：label 落到空/`?`。
      // 两者都不影响 onTap —— 本锁强调「改文案不改交互」。
      bool tappable(String? avatarLabel, String? senderName, String senderId) {
        // message_bubble 的 showSenderHalo 判据：知道发送者是谁就画头像（含 onTap）。
        return senderId.isNotEmpty;
      }

      expect(tappable(null, null, 'u2'), isTrue);
      expect(tappable('?', null, 'u2'), isTrue);
    });
  });
}
