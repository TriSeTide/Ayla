"""群聊子群禁言开关：GroupSubGroup.muted。

开启后仅群主/管理员可在该子群发言（普通成员发消息 403）。
"""
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("chat", "0011_group_subgroup"),
    ]

    operations = [
        migrations.AddField(
            model_name="groupsubgroup",
            name="muted",
            field=models.BooleanField(default=False, verbose_name="禁言"),
        ),
    ]
