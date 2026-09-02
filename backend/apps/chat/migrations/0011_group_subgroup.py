"""群聊子群：GroupSubGroup 模型 + Message.subgroup 归属。

数据迁移（RunPython）：
- 为每个现有群聊 Conversation 创建「默认组」（is_default=True）；
- 把该群所有 subgroup 为 null 的旧消息归入默认组（子群功能上线前的群聊本体）。

反向迁移：把默认组消息的 subgroup 置回 null，再删除默认组（不删其他子群）。
"""
from django.db import migrations, models


def _ensure_default_subgroups(apps, schema_editor):
    Conversation = apps.get_model("chat", "Conversation")
    GroupSubGroup = apps.get_model("chat", "GroupSubGroup")
    Message = apps.get_model("chat", "Message")

    # 历史模型没有 TYPE_GROUP 类常量，用字符串字面量
    for conv in Conversation.objects.filter(type="group"):
        default, _ = GroupSubGroup.objects.get_or_create(
            conversation=conv, is_default=True, defaults={"name": "默认组"}
        )
        Message.objects.filter(conversation=conv, subgroup__isnull=True).update(
            subgroup=default
        )


def _reverse_default_subgroups(apps, schema_editor):
    GroupSubGroup = apps.get_model("chat", "GroupSubGroup")
    Message = apps.get_model("chat", "Message")

    for default in GroupSubGroup.objects.filter(is_default=True):
        Message.objects.filter(subgroup=default).update(subgroup=None)
        default.delete()


def _align_engine_and_fk(apps, schema_editor):
    """把 group_subgroups 对齐 conversations 的引擎/字符集后补 conversation 外键。

    服务器默认引擎/字符集可能是 MyISAM/utf8（本机实测），与既有表
    InnoDB/utf8mb4_0900_ai_ci 不一致会导致外键 1215 失败
    （MyISAM 不执行 FK；collation 不匹配拒绝建约束）。
    测试库由 Django 迁移创建（utf8_unicode_ci），生产库可能是 utf8mb4_0900_ai_ci，
    因此按 conversations 实际 collation 动态对齐，不写死。
    """
    with schema_editor.connection.cursor() as cur:
        cur.execute("ALTER TABLE group_subgroups ENGINE=InnoDB")
        cur.execute(
            "SELECT TABLE_COLLATION FROM information_schema.TABLES "
            "WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='conversations'"
        )
        row = cur.fetchone()
        if row:
            collation = row[0]
            charset = collation.split("_")[0]
            cur.execute(
                f"ALTER TABLE group_subgroups CONVERT TO CHARACTER SET {charset} "
                f"COLLATE {collation}"
            )
        cur.execute(
            "ALTER TABLE group_subgroups ADD CONSTRAINT "
            "group_subgroups_conversation_id_fk_conversations_id "
            "FOREIGN KEY (conversation_id) REFERENCES conversations (id)"
        )


class Migration(migrations.Migration):

    dependencies = [
        ("chat", "0010_message_alter_type_poke"),
    ]

    operations = [
        migrations.CreateModel(
            name="GroupSubGroup",
            fields=[
                ("id", models.AutoField(primary_key=True, serialize=False)),
                (
                    "name",
                    models.CharField(max_length=64, verbose_name="子群名"),
                ),
                (
                    "is_default",
                    models.BooleanField(default=False, verbose_name="默认组"),
                ),
                (
                    "created_at",
                    models.DateTimeField(auto_now_add=True, verbose_name="创建时间"),
                ),
                (
                    "conversation",
                    models.ForeignKey(
                        on_delete=models.CASCADE,
                        related_name="subgroups",
                        to="chat.conversation",
                        # 服务器默认引擎可能是 MyISAM（不支持 FK 约束），建表时声明
                        # FK 会 1215 失败；约束在表转为 InnoDB 后由下方 RunSQL 手动添加。
                        db_constraint=False,
                    ),
                ),
            ],
            options={
                "verbose_name": "群聊子群",
                "verbose_name_plural": "群聊子群",
                "db_table": "group_subgroups",
                "ordering": ["id"],
            },
        ),
        migrations.AddConstraint(
            model_name="groupsubgroup",
            constraint=models.UniqueConstraint(
                fields=("conversation", "name"), name="uniq_conv_subgroup_name"
            ),
        ),
        # 服务器默认引擎/字符集可能是 MyISAM/utf8（本机实测），与既有表
        # InnoDB/utf8mb4_0900_ai_ci 不一致会导致外键 1215 失败
        # （MyISAM 不执行 FK；collation 不匹配拒绝建约束）。
        # 动态对齐 conversations 的引擎/字符集后补 conversation 外键。
        migrations.RunPython(
            _align_engine_and_fk, migrations.RunPython.noop
        ),
        migrations.AddField(
            model_name="message",
            name="subgroup",
            field=models.ForeignKey(
                blank=True,
                null=True,
                on_delete=models.SET_NULL,
                related_name="messages",
                to="chat.groupsubgroup",
                db_index=True,
            ),
        ),
        migrations.RunPython(
            _ensure_default_subgroups, _reverse_default_subgroups
        ),
    ]
