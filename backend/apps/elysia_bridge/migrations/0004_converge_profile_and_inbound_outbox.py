"""D-2：ElysiaProfile 字段收敛 + 入站 outbox + 通道序号表。

背景
====

旧爱莉桥接用 `ElysiaProfile.stream_id / platform / chat_type` 给 Elysium 侧挑
聊天流与补充 inject 帧字段（REQUIREMENTS.zh.md §13.4）。新通道（WS + JWT 认定
身份 + 帧内直接带 conversation_id）不再存在「Elysium stream」这层投影，三个字段
与 `models.generate_elysia_stream_id()` 一并删除（DEVELOPMENT.zh.md §3）。
本迁移同时建立 §9 要求的入站 outbox 与其序号分配器。

数据前提与可逆性
================

生产库 `elysia_profiles` 迁移到 0003 时为 0 行；本地开发库有 1 行。
三个字段都可**确定性重建**，这是本迁移敢直接删列的依据：

- `stream_id = sha256("ayla_{user_id}_private")`（旧 `generate_elysia_stream_id`
  的算法；已用本地开发库那一行实测比对，哈希完全一致）；
- `platform` 与 `chat_type` 在 0002 之后是常量默认（`ayla` / `private`），
  0003 已把全部历史行从 `elysia-app` 迁到 `ayla`。

因此：

- **前进**：先由 `RunPython` 逐行校验「现存的 stream_id 确实等于该算法结果」。
  校验不通过（例如有人手工改过 stream_id）会**显式失败并中止**，而不是让
  `RemoveField` 把不可重建的值悄悄丢掉（AGENTS.md §12「不得在迁移完成证据
  不足时删除旧权威数据」）。回退前另已执行 `mysqldump` 到 `backend/runtime/`
  （gitignore，不进仓库）。
- **回退**：不能直接依赖 `RemoveField` 的自动反向——`stream_id` 是
  `NOT NULL` + `unique` + 无 default，MySQL 反向 ADD COLUMN 会把每一行填成
  `''`，行数 ≥2 时唯一索引直接冲突（实测 1062）。故本迁移先把该列
  `AlterField` 成 `null=True`（MySQL/SQLite 的唯一索引都不限制多个 NULL），
  再在 `AddField` 与 `AlterField` 反向之间插入 `RunPython` 逐行回填
  `sha256`，最后才由 `AlterField` 反向收回到 `NOT NULL`。

引擎/字面集（本机 MySQL 默认引擎是 MyISAM，Django 的 CREATE TABLE 不带
ENGINE 子句）：新建的两张表必须在建表后显式转 InnoDB，并按目标表的实际
collation 对齐，才能补 `message_id` 外键——与 `chat.0011` 同一手法。
"""
import hashlib

import django.db.models.deletion
from django.db import migrations, models

PLATFORM_DEFAULT = "ayla"
CHAT_TYPE_PRIVATE = "private"


def _derive_stream_id(user_id: object) -> str:
    """旧 `generate_elysia_stream_id` 的同算法重建（迁移内联，不 import 已删函数）。"""
    key = f"ayla_{user_id}_private"
    return hashlib.sha256(key.encode("utf-8")).hexdigest()


def _verify_profile_rows_reconstructable(apps, schema_editor):
    """删列前确认每一行的 stream_id 都能由 user_id 确定性重建。

    不满足就中止：宁可让迁移失败，也不把无法重建的流标识静默删掉。
    """
    ElysiaProfile = apps.get_model("elysia_bridge", "ElysiaProfile")
    bad = []
    for profile in ElysiaProfile.objects.all().iterator():
        expected = _derive_stream_id(profile.user_id)
        if profile.stream_id != expected:
            bad.append(profile.pk)
        if profile.platform != PLATFORM_DEFAULT:
            bad.append(profile.pk)
        if profile.chat_type != CHAT_TYPE_PRIVATE:
            bad.append(profile.pk)
    if bad:
        raise RuntimeError(
            "elysia_bridge.0004 中止：这些 profile 行的 stream_id/platform/chat_type "
            f"无法确定性重建（pk={sorted(set(bad))}）。请先 mysqldump 该表并人工确认"
            "如何迁移这些值，再重跑本迁移；不要直接删列丢数据。"
        )


def _backfill_stream_ids(apps, schema_editor):
    """反向：为刚被 ADD COLUMN 填成 NULL 的列逐行回填确定性 stream_id。"""
    table = schema_editor.quote_name("elysia_profiles")
    column = schema_editor.quote_name("stream_id")
    with schema_editor.connection.cursor() as cursor:
        cursor.execute(f"SELECT id, user_id FROM {table}")
        rows = cursor.fetchall()
        for pk, user_id in rows:
            cursor.execute(
                f"UPDATE {table} SET {column} = %s WHERE id = %s",
                [_derive_stream_id(user_id), pk],
            )


def _align_engine_and_fk(apps, schema_editor):
    """新表转 InnoDB、对齐 collation，并补 outbox → messages 的外键。

    本机 MySQL 服务器默认引擎是 MyISAM（Django 的 CREATE TABLE 不写 ENGINE
    子句），MyISAM 既不执行也不校验外键，且 collation 与 `messages` 不一致时
    建约束会 1215 失败。因此按目标表的**实际** collation 动态对齐，不写死。
    非 MySQL（SQLite 测试库）由 Django 直接建表，无需此步。
    """
    if schema_editor.connection.vendor != "mysql":
        return
    with schema_editor.connection.cursor() as cursor:
        cursor.execute(
            "SELECT TABLE_NAME, ENGINE, TABLE_COLLATION FROM information_schema.TABLES "
            "WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME IN "
            "('ayla_channel_sequences','ayla_inbound_outbox','messages')"
        )
        info = {row[0]: {"engine": row[1], "collation": row[2]} for row in cursor.fetchall()}

        # 新建表的 collation 取服务器默认（本机是 utf8_unicode_ci），与既有 InnoDB
        # 表族（utf8mb4_0900_ai_ci）不一致。两张表都对齐到 messages 的 collation：
        # outbox 是因为有外键（collation 不一致会 1215 拒绝建约束），
        # sequences 是为了不在同一 schema 里再引入一种 collation。
        target_collation = info.get("messages", {}).get("collation")
        charset = target_collation.split("_")[0] if target_collation else None
        for table in ("ayla_channel_sequences", "ayla_inbound_outbox"):
            if info.get(table, {}).get("engine") != "InnoDB":
                cursor.execute(f"ALTER TABLE {table} ENGINE=InnoDB")
            if target_collation and info.get(table, {}).get("collation") != target_collation:
                cursor.execute(
                    f"ALTER TABLE {table} CONVERT TO CHARACTER SET {charset} "
                    f"COLLATE {target_collation}"
                )

        cursor.execute(
            "SELECT COUNT(*) FROM information_schema.TABLE_CONSTRAINTS "
            "WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ayla_inbound_outbox' "
            "AND CONSTRAINT_TYPE='FOREIGN KEY'"
        )
        if cursor.fetchone()[0] == 0:
            cursor.execute(
                "ALTER TABLE ayla_inbound_outbox ADD CONSTRAINT "
                "ayla_inbound_outbox_message_id_fk_messages_id "
                "FOREIGN KEY (message_id) REFERENCES messages (id)"
            )


class Migration(migrations.Migration):

    dependencies = [
        ("chat", "0013_message_share_payload_alter_message_type"),
        ("elysia_bridge", "0003_migrate_legacy_ayla_profiles"),
    ]

    operations = [
        migrations.CreateModel(
            name="AylaChannelSequence",
            fields=[
                ("id", models.AutoField(primary_key=True, serialize=False)),
                ("name", models.CharField(max_length=32, unique=True, verbose_name="通道")),
                ("last_seq", models.BigIntegerField(default=0, verbose_name="已分配序号")),
                ("updated_at", models.DateTimeField(auto_now=True, verbose_name="更新时间")),
            ],
            options={
                "verbose_name": "通道序号",
                "verbose_name_plural": "通道序号",
                "db_table": "ayla_channel_sequences",
            },
        ),
        # 顺序是本迁移最关键的部分，三段必须严格相邻且按此排列：
        #
        #   1. AlterField：stream_id 先放宽为 NULL（MySQL/SQLite 的唯一索引都
        #      允许多个 NULL）。这是可逆性的前提——否则反向 AddField 会把每一行
        #      填成 ''，行数 ≥2 时唯一索引直接 1062（实测）。
        #   2. RunPython：前进时逐行校验三个字段都能确定性重建（此时历史状态里
        #      它们都还在）；反向时由 `_backfill_stream_ids` 逐行回填 sha256。
        #      位置必须在 RemoveField 之前：删列之后历史模型就没有这些字段了。
        #   3. RemoveField：真正删列。
        #
        # 反向按倒序执行，于是实际顺序变成「加回 stream_id 列 → 加回
        # platform/chat_type（用 0002 的默认值填充）→ 回填 sha256 →
        # 恢复 NOT NULL」，回填恰好在收紧约束之前完成。
        migrations.AlterField(
            model_name="elysiaprofile",
            name="stream_id",
            field=models.CharField(
                "Elysium stream_id", max_length=240, unique=True, null=True
            ),
        ),
        migrations.RunPython(
            _verify_profile_rows_reconstructable, _backfill_stream_ids
        ),
        migrations.RemoveField(
            model_name="elysiaprofile",
            name="chat_type",
        ),
        migrations.RemoveField(
            model_name="elysiaprofile",
            name="platform",
        ),
        migrations.RemoveField(
            model_name="elysiaprofile",
            name="stream_id",
        ),
        migrations.CreateModel(
            name="AylaInboundOutbox",
            fields=[
                ("id", models.AutoField(primary_key=True, serialize=False)),
                ("seq", models.BigIntegerField(unique=True, verbose_name="通道序号")),
                (
                    "status",
                    models.CharField(
                        choices=[
                            ("pending", "待投递"),
                            ("delivered", "已确认"),
                            ("failed", "不可投递"),
                            ("dead", "重投耗尽"),
                        ],
                        default="pending",
                        max_length=16,
                        verbose_name="状态",
                    ),
                ),
                ("attempts", models.IntegerField(default=0, verbose_name="已尝试次数")),
                (
                    "next_attempt_at",
                    models.DateTimeField(blank=True, null=True, verbose_name="下次重试时间"),
                ),
                ("last_error", models.TextField(blank=True, default="", verbose_name="最近错误")),
                ("created_at", models.DateTimeField(auto_now_add=True, verbose_name="创建时间")),
                ("updated_at", models.DateTimeField(auto_now=True, verbose_name="更新时间")),
                (
                    "message",
                    models.OneToOneField(
                        db_constraint=False,
                        on_delete=django.db.models.deletion.CASCADE,
                        related_name="ayla_outbox",
                        to="chat.message",
                        verbose_name="消息",
                    ),
                ),
            ],
            options={
                "verbose_name": "入站 outbox",
                "verbose_name_plural": "入站 outbox",
                "db_table": "ayla_inbound_outbox",
                "indexes": [
                    models.Index(fields=["status", "seq"], name="ayla_outbox_status_seq")
                ],
            },
        ),
        migrations.RunPython(_align_engine_and_fk, migrations.RunPython.noop),
    ]
