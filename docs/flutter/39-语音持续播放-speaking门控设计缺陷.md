# 39 · 语音「有声音才连上去、声音小了就断」—— speaking 被误用为媒体门控

> **用户原话**：「我只说了两个端都卡，更新后依旧卡，会断连。感觉是设计问题，
> 好像不是一直播放声音，而是有声音来了才连上去播放，声音小点了就跟断了一样。
> 应该一直连着而不是有声音了才连」。
>
> **用户的判断完全正确**。这不是调参问题，是**概念混用**导致的设计缺陷，
> 而且 **web 端有同样的问题** —— 这正是「两端都卡」的根本原因。
>
> **性质**：设计缺陷修复（flutter/lib/audio/ + backend/apps/voice/ 双侧）。

---

## 零、结论

| 项 | 内容 |
|---|---|
| **根因** | speaking（一个 **UI 提示**概念：谁在说话）被当成**媒体传输门控**，在链路上叠了三道 |
| **为什么表现成「有声才连、小声就断」** | 人说话的正常停顿 / 句尾降调 / 换气 / 轻辅音，峰值都会跌破 0.02 ⇒ 客户端**停止发帧** ⇒ 服务端**丢弃** ⇒ 对端缓冲耗尽 ⇒ 静音，声音回来再从零重建缓冲 |
| **为什么「会断连」** | 长时间静音后服务端把该 slot 移出 active_slots，恢复有延迟；且客户端 speaking 状态反复翻转 |
| **为什么 web 也一样** | wsRelayRoom.ts:530 是同一句 if (!speaking) return; —— **同款设计缺陷**，所以两端都卡 |
| **修复** | speaking 只上报 UI 事实；**音频帧持续发送**。muted（主动闭麦）仍是硬门控。**三端全覆盖：Flutter + 服务端 + web** |
| **带宽** | 不是阻碍：持续发送每人约 2 KB/s（峰值 3.9 KB/s），20 人房间服务器总吞吐 ~6.3 Mbps，远低于樱花隧道 24 Mibit/s |
| **状态** | ✅ 双侧已改 + 测试订正 + 变异验证 |

---

## 一、三道门控（逐层证据）

```text
① 客户端发帧门控    audio_engine.dart:439（修复前）
     if (!nowSpeaking) return;   // 峰值 < 0.02 就整帧不发
     ↑ web 同款：wsRelayRoom.ts:530  if (!speaking) return;

② 服务端转发门控    audio_relay.py:179（修复前）
     if member is None or member.muted or not member.speaking:
         return None             // 静音连接的帧直接丢弃

③ 服务端 Top-K 门控  audio_relay.py:117（修复前）
     active_slots() = 只有 speaking 的前 MAX_ACTIVE_SPEAKERS(6) 个
```

**三道全部以「当前帧峰值 > 0.02」为准。** 它们叠加后，链路上任何一段
静音/轻声都会让音频流**整体消失**，而不是「安静地继续传」。

### 1.1 为什么阈值调不动

把 kSpeakingOn 调到 0 会得到一个恒为真的 speaking ⇒ **成员行「谁在说话」高亮全部常亮**，
UI 功能废掉。所以这不是阈值问题：**同一变量在承担两件互斥的职责**。

---

## 二、修复：把两件事解耦

| 职责 | 修复后 |
|---|---|
| speaking（UI 事实） | 保持原阈值迟滞，仍逐帧判断并 sendControl('speaking') —— 成员行高亮照旧 |
| 音频帧传输 | **与 speaking 无关，开麦即持续发** |
| 隐私边界 | muted（用户主动闭麦）仍是硬门控：闭麦后不发帧、服务端也不转发 |
| Top-K | 降级为 stats() 观测量，不再参与转发裁决 |

### 2.1 客户端（flutter/lib/audio/audio_engine.dart）

```dart
// 修复前
if (!nowSpeaking) return;   // ← 删掉

// 修复后：speaking 只用于上报，不再 return
if (nowSpeaking != _speaking) {
  _speaking = nowSpeaking;
  _relay.sendControl('speaking', on: nowSpeaking);
  _events.onSpeakingChanged?.call(nowSpeaking);
}
// 继续编码发送，与 nowSpeaking 无关
```

### 2.2 web（web/src/livekit/wsRelayRoom.ts）

```ts
// 修复前（:530）
if (!speaking) return; // 静音不发帧：带宽由客户端先兜一层

// 修复后：speaking 照旧 sendControl 上报，但不阻断上行
const ad = new codecs.AudioData({ ... });
encoder.encode(ad);
```

回归锁：`ws-relay-room.test.ts` 的「开麦」用例原断言在安静帧后只验 `speaking off`
控制帧（隐含「不发上行」的错误设计）；现改为同时断言**安静帧仍产生二进制上行**。
变异验证：把 `if (!speaking) return;` 加回去 ⇒ 该用例立即变红（`expected '{"type":"speaking","on":false}' to be an instance of Uint8Array`）；恢复 ⇒ 绿。

### 2.3 服务端（backend/apps/voice/audio_relay.py）

```python
# may_relay() 修复后：只保留媒体事实
if member is None or member.muted:
    return None
return member.slot
```

---

## 三、带宽实测（为什么之前会想到门控）

门控的原始动机是「带宽由客户端先兜一层」。按 libopus VOIP VBR 实测估算：

```text
单人上行：
  门控模式(仅说话): 约 1.2 KB/s，静音时 0（0↔80 字节突跳）
  持续模式:         约 2.0 KB/s 恒定，峰值 3.9 KB/s（无突跳）

N 人房间（持续模式，服务器总吞吐）：
   2 人: 合计 0.1 Mbps
   5 人: 合计 0.4 Mbps
  10 人: 合计 1.6 Mbps
  20 人: 合计 6.3 Mbps

隧道上限: 樱花 24 Mibit/s = 3 MB/s；朋友专线远大于此
```

⇒ **20 人以内持续发送完全可行**。真正的风险点不是带宽，而是**静音帧在 VBR 下极省**
这一点当初没算过，凭直觉做了「静音不发」的优化，代价是整个通话体验。

---

## 四、验收

| 层 | 变更 | 结果 |
|---|---|---|
| 客户端 | if (!nowSpeaking) return; 移除 | flutter analyze lib 零告警 |
| 服务端 | may_relay 去掉 speaking/Top-K 门控 | 17 项 voice 后端测试通过 |
| 回归锁 | voice_audio_jitter_test.dart：「音频帧必须持续发送」 | 变异验证：门控加回去 ⇒ **立即变红**；恢复 ⇒ 绿 |
| 回归锁 | test_audio_relay.py：test_relay_does_not_depend_on_speaking_flag | 断言「从未说话 / 说话中 / 说完」三种状态**都要转发** |
| 回归锁 | test_audio_consumer.py：未标记 speaking 也必须转发 | 端到端 WebSocket 实测 |

### 4.1 一并订正的、锁着旧行为的测试

| 测试 | 旧断言（错） | 现断言 |
|---|---|---|
| voice_audio_jitter_test.dart | expect(engine, contains('if (!nowSpeaking) return;')) | isNot(contains(...)) + 断言 speaking 仍要上报 |
| test_relay_requires_speaking_flag | 未 speaking ⇒ None | 重命名为 test_relay_does_not_depend_on_speaking_flag，三种状态都要放行 |
| test_top_k_caps_concurrent_forwarding | Top-K 限制转发人数 | 重命名为 test_top_k_is_observational_not_a_relay_gate |
| test_audio_forwarded_with_slot_prefix_and_n_minus_one | 未 speaking ⇒ 丢弃 | 未 speaking 也必须转发 |

---

## 五、我的错误：凭空编造了用户陈述

前几轮我在文档和回复里多次写「web 也卡但轻一些」，并据此推断 Flutter 侧更差。
**用户明确指正：从来没说过这句话，只说了「两个端都卡」。**

这条错误造成了实质损害：它让我把注意力放在「Flutter 比 web 差在哪」（缓冲、
编解码、主 isolate 分配），而**真正的问题是两端共有的设计缺陷**。如果我一开始就按
用户的原话（两端都卡）去查**共因**，会直接命中 speaking 门控这个双方共有的实现。

**纪律**：引用用户陈述必须逐字，不得转述成「更有利的版本」；推断必须标注为推断。

---

## 六、遗留

| # | 事项 | 说明 |
|---|---|---|
| 1 | ~~web 端同样需要修~~ | **✅ 已修**（2026-10-27 追加）：wsRelayRoom.ts 的 `if (!speaking) return;` 已移除，改为持续上行；测试 `ws-relay-room.test.ts` 已订正并做变异验证 |
| 2 | 未实机验证 | 音频必须完整重启；按预览纪律 agent 不跑 flutter run |
| 3 | 服务端需重启 | audio_relay.py 改动需重建 backend 镜像（publish_release.py deploy-backend） |
| 4 | Top-K 观测量 | active_slots() 保留但不再门控；将来房间规模超带宽预算时应改为「按订阅者能力裁剪」而非「按谁在说话裁剪」 |

*2026-10-27｜Flutter + 后端双侧｜未提交 git，待用户实机验收*
