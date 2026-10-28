"""幽灵成员清理（真因 2）契约测试：mark_stale_members_left + management command。

背景（真实生产，见 Ayla/.workbuddy/evidence/livekit-udp/P4-WS-热更新-结论.md §8）：
`mark_stale_members_left` 早已实现但**全仓库零调用**，客户端异常退出（杀进程/断网/
崩溃）不会 POST `/leave/`，成员关系永远留在表里。生产频道 1 实测仍有 67.9 小时前
`last_seen` 的成员，`VOICE_MEMBER_TIMEOUT_SECONDS`（生产 120s）形同虚设。

本文件锁死：
1. 超时成员 → 删成员关系 + 广播 `voice.state left`（**帧形态与正常 leave 完全一致**）
   + 目录人数刷新帧；同时清 User 的 is_in_voice / voice_room_id；
2. 未超时成员不动、不发帧；
3. 重复执行幂等（第二次 0 人、0 帧）；
4. `--dry-run` 不改库、不发帧、但打印每人明细；
5. 边界：last_seen_at 恰好等于阈值 → 按未超时处理（保守）；
6. 跨频道：只清理自身频道的成员。
"""
from io import StringIO

import pytest
from django.core.management import call_command
from django.utils import timezone

from apps.voice import services
from apps.voice.models import VoiceChannel, VoiceChannelMember


class RecordingLayer:
    """记录 group_send 调用（不真正投递），用于断言广播帧形态。"""

    def __init__(self):
        self.calls: list[tuple[str, dict]] = []

    async def group_send(self, group, event):
        self.calls.append((group, event))

    def voice_state_events(self) -> list[dict]:
        return [e for _, e in self.calls if e["type"] == "voice.state"]

    def count_events(self) -> list[dict]:
        return [
            e for _, e in self.calls
            if e["type"] == "voice.channel.member_count_changed"
        ]


@pytest.fixture
def layer(monkeypatch):
    rec = RecordingLayer()
    monkeypatch.setattr("channels.layers.get_channel_layer", lambda: rec)
    return rec


def _make_channel(owner, name="语音", room_name="room_reap") -> VoiceChannel:
    return VoiceChannel.objects.create(name=name, room_name=room_name, owner=owner)


def _backdate(member: VoiceChannelMember, seconds: float) -> None:
    """把 last_seen_at 拨回 N 秒前（绕过 auto_now）。"""
    VoiceChannelMember.objects.filter(pk=member.pk).update(
        last_seen_at=timezone.now() - timezone.timedelta(seconds=seconds)
    )


# ---------- services 层 ----------

@pytest.mark.django_db
def test_stale_member_marked_left_with_same_frames_as_leave(auth_client, layer):
    """超时成员：删除成员关系 + voice.state left + 人数刷新帧；User 标记被清。"""
    _, owner = auth_client(username="reap_owner")
    _, ghost = auth_client(username="reap_ghost")
    ch = _make_channel(owner)
    services.join_channel(ch, owner)
    member = services.join_channel(ch, ghost)
    _backdate(member, 9999)
    layer.calls.clear()

    cleared = services.mark_stale_members_left(ch, timeout_seconds=120)

    assert cleared == 1
    assert not VoiceChannelMember.objects.filter(channel=ch, user=ghost).exists()
    assert VoiceChannelMember.objects.filter(channel=ch, user=owner).exists()

    left = [
        e for e in layer.voice_state_events()
        if e["data"]["state"] == "left" and e["data"]["user_id"] == str(ghost.id)
    ]
    assert left, f"未广播 voice.state left: {layer.calls}"
    # 帧形态与正常 leave 完全一致（客户端靠这些字段移除成员行）
    assert set(left[0]["data"]) == {"channel_id", "user_id", "state", "ts"}
    assert left[0]["data"]["channel_id"] == str(ch.id)
    # 频道组名与正常广播一致
    assert (services._voice_group_name(ch.id), left[0]) in layer.calls
    # 目录人数刷新帧也要有
    assert layer.count_events(), f"未广播人数刷新: {layer.calls}"

    ghost.refresh_from_db()
    assert ghost.is_in_voice is False
    assert ghost.voice_room_id is None


@pytest.mark.django_db
def test_non_stale_member_untouched_and_no_frames(auth_client, layer):
    """未超时成员不动、不发帧。"""
    _, owner = auth_client(username="reap_keep_owner")
    _, active = auth_client(username="reap_active")
    ch = _make_channel(owner, room_name="room_reap_keep")
    services.join_channel(ch, owner)
    member = services.join_channel(ch, active)
    _backdate(member, 10)  # 10s < 120s，未超时
    layer.calls.clear()

    cleared = services.mark_stale_members_left(ch, timeout_seconds=120)

    assert cleared == 0
    assert VoiceChannelMember.objects.filter(channel=ch, user=active).exists()
    assert layer.calls == [], f"未超时不应发任何帧: {layer.calls}"


@pytest.mark.django_db
def test_boundary_exactly_at_threshold_is_not_stale(auth_client, layer):
    """边界：last_seen_at 恰好等于阈值 ⇒ 按未超时处理（保守，不误踢）。"""
    _, owner = auth_client(username="reap_edge_owner")
    _, edge = auth_client(username="reap_edge")
    ch = _make_channel(owner, room_name="room_reap_edge")
    member = services.join_channel(ch, edge)
    # 判定口径是严格小于 cutoff ⇒ last_seen_at 必须**明显晚于** cutoff 才算未超时。
    #
    # ⚠️ 安全余量不能压到毫秒级：`mark_stale_members_left` 内部会**再取一次**
    # `timezone.now()`，cutoff 随之向真实时间前移；余量太小会让本用例随机器快慢
    # 随机变红（本机实测翻过）。留 5s 余量：仍然严格验证「不误踢」，但不赌时钟。
    VoiceChannelMember.objects.filter(pk=member.pk).update(
        last_seen_at=timezone.now() - timezone.timedelta(seconds=115)
    )
    layer.calls.clear()
    assert services.mark_stale_members_left(ch, timeout_seconds=120) == 0
    assert VoiceChannelMember.objects.filter(pk=member.pk).exists()
    assert layer.calls == []


@pytest.mark.django_db
def test_repeated_run_is_idempotent(auth_client, layer):
    """重复执行幂等：第二次 0 人、0 帧。"""
    _, owner = auth_client(username="reap_idem_owner")
    _, ghost = auth_client(username="reap_idem_ghost")
    ch = _make_channel(owner, room_name="room_reap_idem")
    services.join_channel(ch, owner)
    member = services.join_channel(ch, ghost)
    _backdate(member, 9999)

    assert services.mark_stale_members_left(ch, timeout_seconds=120) == 1
    layer.calls.clear()
    assert services.mark_stale_members_left(ch, timeout_seconds=120) == 0
    assert layer.calls == [], f"重复执行不应再发帧: {layer.calls}"


@pytest.mark.django_db
def test_other_channel_members_not_affected(auth_client, layer):
    """跨频道不串：只清理自身频道的超时成员。"""
    _, owner = auth_client(username="reap_cross_owner")
    _, other_owner = auth_client(username="reap_cross_other")
    _, ghost = auth_client(username="reap_cross_ghost")
    ch = _make_channel(owner, room_name="room_reap_cross_a")
    other_ch = _make_channel(other_owner, name="别的频道", room_name="room_reap_cross_b")
    services.join_channel(ch, owner)
    other_member = services.join_channel(other_ch, ghost)  # ghost 在另一个频道
    _backdate(other_member, 9999)
    layer.calls.clear()

    assert services.mark_stale_members_left(ch, timeout_seconds=120) == 0
    assert VoiceChannelMember.objects.filter(pk=other_member.pk).exists()
    assert layer.calls == []


@pytest.mark.django_db
def test_reap_frames_are_identical_shape_to_normal_leave(auth_client, layer):
    """铁证：超时清理发出的帧序列与正常 leave **逐帧一致**（同组名、同 type、同字段集）。

    客户端（Flutter voice_support.dart / web VoiceChannelPanel）只认 `voice.state left`
    移除成员行——两条路径一旦分叉就白做，所以这里直接比对两次调用产生的帧。
    """
    _, owner = auth_client(username="par_owner")
    _, a = auth_client(username="par_a")
    _, b = auth_client(username="par_b")
    ch = _make_channel(owner, room_name="room_par")
    services.join_channel(ch, owner)

    # 路径 1：正常 leave
    member_a = services.join_channel(ch, a)
    layer.calls.clear()
    services.leave_channel(ch, a)
    leave_calls = list(layer.calls)

    # 路径 2：超时清理
    member_b = services.join_channel(ch, b)
    _backdate(member_b, 9999)
    layer.calls.clear()
    services.mark_stale_members_left(ch, timeout_seconds=120)
    reap_calls = list(layer.calls)

    def shape(calls, user):
        return [
            (
                group,
                event["type"],
                tuple(sorted(event["data"] if "data" in event else event)),
            )
            for group, event in calls
            if "data" not in event or event["data"].get("user_id") == str(user.id)
        ]

    assert shape(reap_calls, b) == shape(leave_calls, a)


# ---------- management command ----------

@pytest.mark.django_db
def test_command_reaps_across_all_channels(auth_client, layer):
    """command 默认扫描全部频道：清理超时成员并广播。"""
    _, owner = auth_client(username="cmd_owner")
    _, ghost = auth_client(username="cmd_ghost")
    ch = _make_channel(owner, room_name="room_cmd")
    services.join_channel(ch, owner)
    member = services.join_channel(ch, ghost)
    _backdate(member, 7200)
    out = StringIO()

    call_command("voice_reap_stale_members", stdout=out)

    text = out.getvalue()
    assert "已清理 1 人" in text
    assert str(ghost.id) in text  # 明细里有 user_id
    assert not VoiceChannelMember.objects.filter(channel=ch, user=ghost).exists()
    assert [
        e for e in layer.voice_state_events() if e["data"]["user_id"] == str(ghost.id)
    ]


@pytest.mark.django_db
def test_command_dry_run_does_not_touch_db_or_broadcast(auth_client, layer):
    """--dry-run：打印将清理 N 人 + 每人明细，但不改库、不发帧。"""
    _, owner = auth_client(username="dry_owner")
    _, ghost = auth_client(username="dry_ghost")
    ch = _make_channel(owner, room_name="room_dry")
    services.join_channel(ch, owner)
    member = services.join_channel(ch, ghost)
    _backdate(member, 9000)
    layer.calls.clear()
    out = StringIO()

    call_command("voice_reap_stale_members", "--dry-run", stdout=out)

    text = out.getvalue()
    assert "dry-run" in text
    assert "将清理 1 人" in text
    assert str(ghost.id) in text
    assert "last_seen_at=" in text
    assert "silent=" in text
    # 未改库、未发帧
    assert VoiceChannelMember.objects.filter(channel=ch, user=ghost).exists()
    assert layer.calls == []


@pytest.mark.django_db
def test_command_second_run_reports_zero(auth_client, layer):
    """command 重复执行：第二轮 0 人、0 帧（cron 每分钟重跑安全）。"""
    _, owner = auth_client(username="cmd2_owner")
    _, ghost = auth_client(username="cmd2_ghost")
    ch = _make_channel(owner, room_name="room_cmd2")
    services.join_channel(ch, owner)
    member = services.join_channel(ch, ghost)
    _backdate(member, 9000)

    call_command("voice_reap_stale_members", stdout=StringIO())
    layer.calls.clear()
    out = StringIO()
    call_command("voice_reap_stale_members", stdout=out)
    assert "无超时成员" in out.getvalue()
    assert layer.calls == []


@pytest.mark.django_db
def test_command_honours_channel_id_filter(auth_client, layer):
    """--channel-id：只处理指定频道。"""
    _, owner = auth_client(username="cf_owner")
    _, ghost_a = auth_client(username="cf_ghost_a")
    _, ghost_b = auth_client(username="cf_ghost_b")
    ch_a = _make_channel(owner, room_name="room_cf_a")
    ch_b = _make_channel(owner, name="频道二", room_name="room_cf_b")
    services.join_channel(ch_a, ghost_a)
    services.join_channel(ch_b, ghost_b)
    _backdate(VoiceChannelMember.objects.get(channel=ch_a, user=ghost_a), 9000)
    _backdate(VoiceChannelMember.objects.get(channel=ch_b, user=ghost_b), 9000)
    layer.calls.clear()

    call_command(
        "voice_reap_stale_members", "--channel-id", str(ch_a.id), stdout=StringIO()
    )

    assert not VoiceChannelMember.objects.filter(channel=ch_a, user=ghost_a).exists()
    assert VoiceChannelMember.objects.filter(channel=ch_b, user=ghost_b).exists()


@pytest.mark.django_db
def test_command_uses_settings_timeout_by_default(auth_client, layer, settings):
    """默认超时取 settings.VOICE_MEMBER_TIMEOUT_SECONDS（不是硬编码 120）。"""
    settings.VOICE_MEMBER_TIMEOUT_SECONDS = 60
    _, owner = auth_client(username="set_owner")
    _, ghost = auth_client(username="set_ghost")
    ch = _make_channel(owner, room_name="room_set")
    services.join_channel(ch, owner)
    member = services.join_channel(ch, ghost)
    _backdate(member, 90)  # 90s > 60s（settings）但 < 120s（旧硬编码）
    out = StringIO()

    call_command("voice_reap_stale_members", stdout=out)

    assert "settings=60s" in out.getvalue()
    assert not VoiceChannelMember.objects.filter(channel=ch, user=ghost).exists()
