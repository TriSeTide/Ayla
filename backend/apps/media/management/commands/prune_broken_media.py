"""清理「媒体原件已不存在」的聊天消息与 MediaObject 记录。

## 用途

2026-10-29 对象误删事故后，有一批消息的媒体原件永久丢失（客户端也没缓存）。
它们在前端表现为点不开的灰气泡 / 已过期占位，既无内容也无恢复可能。
本命令按用户 2026-10-29 的裁决把它们清掉：

- 纯媒体消息（type=voice 等，整条只有媒体）→ 整条删除；
- 图文混排（type=mixed，segments 里部分媒体坏掉）→ **只摘掉坏段**，
  保留还能显示的内容；全坏才整条删（Q1=B）；
- 弹幕图片 / 语音房图片 → 整条删除；
- MediaObject 记录 → 一并删除，不留死记录（Q2=B）。

## 安全纪律（事故教训）

1. **先备份**：受影响记录全量导出到 <backup-dir>/media-cleanup-backup-*.json，
   备份写入成功才继续；
2. **默认 dry-run**：必须显式 --apply 才改库；
3. **单事务**：任一步失败整体回滚。

## 用法

    manage.py prune_broken_media            # 盘点 + 备份（不动数据）
    manage.py prune_broken_media --apply    # 真正执行

完成后派生对象（thumbnail/waveform）可能成孤儿，接着跑
`manage.py media_audit --prune-orphans --no-dry-run` 清理。
"""
import json
import os
from datetime import datetime

from django.core.management.base import BaseCommand
from django.db import transaction

from apps.chat.models import Message
from apps.live.models import Danmaku
from apps.media import storage
from apps.media.models import MediaObject
from apps.voice.models import VoiceChatMessage


class Command(BaseCommand):
    help = "清理「媒体原件已不存在」的消息与 MediaObject 记录（默认 dry-run）"

    def add_arguments(self, parser):
        parser.add_argument(
            "--apply", action="store_true", help="真正执行删除（默认只盘点并备份）"
        )
        parser.add_argument(
            "--backup-dir", default="/app/runtime", help="备份 JSON 落盘目录"
        )

    def handle(self, *args, **options):
        store = storage.get_storage()

        broken = {
            m.media_id: m
            for m in MediaObject.objects.all()
            if not (m.storage_path and store.exists(m.storage_path))
        }
        if not broken:
            self.stdout.write(self.style.SUCCESS("[prune] 没有无原件的媒体，无事可做"))
            return
        self.stdout.write(f"[prune] 无可用原件的媒体: {len(broken)}")

        plain_msgs = list(
            Message.objects.filter(media_id__in=broken.keys()).order_by("id")
        )
        seg_actions = []
        for msg in Message.objects.exclude(segments=None).order_by("id"):
            segs = msg.segments
            if not isinstance(segs, list):
                continue
            keep = [
                s for s in segs
                if not (isinstance(s, dict) and s.get("media_id") in broken)
            ]
            if len(keep) != len(segs):
                seg_actions.append((msg, keep, len(segs) - len(keep)))

        danmaku = list(Danmaku.objects.filter(media_id__in=broken.keys()).order_by("id"))
        voice_room = list(
            VoiceChatMessage.objects.filter(media_id__in=broken.keys()).order_by("id")
        )

        self.stdout.write(f"[prune] 纯媒体消息（整条删）: {len(plain_msgs)}")
        self.stdout.write(f"[prune] 混排消息（摘坏段）: {len(seg_actions)}")
        self.stdout.write(f"[prune] 弹幕（整条删）: {len(danmaku)}")
        self.stdout.write(f"[prune] 语音房消息（整条删）: {len(voice_room)}")

        backup = {
            "generated_at": datetime.now().isoformat(),
            "broken_media": [
                {
                    "media_id": m.media_id,
                    "kind": m.kind,
                    "owner_id": m.owner_id,
                    "storage_path": m.storage_path,
                    "thumbnail_path": m.thumbnail_path,
                    "waveform_path": m.waveform_path,
                    "created_at": m.created_at.isoformat(),
                }
                for m in broken.values()
            ],
            "messages_deleted": [
                {
                    "id": m.id,
                    "conversation_id": m.conversation_id,
                    "sender_id": m.sender_id,
                    "type": m.type,
                    "content": m.content,
                    "media_id": m.media_id,
                    "segments": m.segments,
                    "created_at": m.created_at.isoformat(),
                }
                for m in plain_msgs
            ],
            "messages_segments_trimmed": [
                {
                    "id": msg.id,
                    "old_segments": msg.segments,
                    "new_segments": keep,
                    "dropped": dropped,
                }
                for msg, keep, dropped in seg_actions
            ],
            "danmaku_deleted": [
                {
                    "id": d.id,
                    "channel_id": d.channel_id,
                    "content": d.content,
                    "media_id": d.media_id,
                }
                for d in danmaku
            ],
            "voice_room_deleted": [
                {
                    "id": v.id,
                    "channel_id": v.channel_id,
                    "content": v.content,
                    "media_id": v.media_id,
                }
                for v in voice_room
            ],
        }
        backup_dir = options["backup_dir"]
        os.makedirs(backup_dir, exist_ok=True)
        path = os.path.join(
            backup_dir, f"media-cleanup-backup-{datetime.now():%Y%m%d-%H%M%S}.json"
        )
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(backup, fh, ensure_ascii=False, indent=2)
        self.stdout.write(self.style.WARNING(f"[prune] 备份: {path}"))

        if not options["apply"]:
            self.stdout.write(
                self.style.WARNING("[prune] dry-run：备份已生成，加 --apply 才真删")
            )
            return

        with transaction.atomic():
            for msg, keep, dropped in seg_actions:
                if keep:
                    msg.segments = keep
                    msg.save(update_fields=["segments"])
                    self.stdout.write(
                        f"[trim] message {msg.id}: 摘掉 {dropped} 段，保留 {len(keep)} 段"
                    )
                else:
                    msg.delete()
                    self.stdout.write(f"[delete] message {msg.id}: 段全坏，整条删除")
            for m in plain_msgs:
                m.delete()
            for d in danmaku:
                d.delete()
            for v in voice_room:
                v.delete()
            removed, _ = MediaObject.objects.filter(
                media_id__in=list(broken.keys())
            ).delete()

        self.stdout.write(
            self.style.SUCCESS(
                f"[prune] 完成：消息 {len(plain_msgs)} / 弹幕 {len(danmaku)} / "
                f"语音房 {len(voice_room)} 条删除，{len(seg_actions)} 条摘段，"
                f"MediaObject {len(broken)} 条（级联 {removed} 行）"
            )
        )
        self.stdout.write(
            "[prune] 提示：删记录后其派生对象会成为孤儿，接着跑 "
            "`manage.py media_audit --prune-orphans --no-dry-run` 清理"
        )
