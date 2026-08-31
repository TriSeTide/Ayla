"""聊天戳一戳：Message.type 新增 poke 枚举。

poke（戳一戳）是独立消息类型，但刻意不参与未读/已读/红点：
未读排除在 services._unread_queryset（见 serializers._unread_queryset）。
"""
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("chat", "0009_message_segments_alter_message_type"),
    ]

    operations = [
        migrations.AlterField(
            model_name="message",
            name="type",
            field=models.CharField(
                choices=[
                    ("text", "文本"),
                    ("image", "图片"),
                    ("voice", "语音"),
                    ("file", "文件"),
                    ("emoji", "表情"),
                    ("video", "视频"),
                    ("mixed", "图文混排"),
                    ("system", "系统"),
                    ("poke", "戳一戳"),
                ],
                default="text",
                max_length=16,
                verbose_name="类型",
            ),
        ),
    ]
