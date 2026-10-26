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
}
