"""在线状态改造：User.status 选项 online → auto（自动）。

- schema：choices 移除 online、加入 auto，default 改为 auto；
- 数据：存量 online 值迁移为 auto（auto 语义 = 对外显示跟随实时在线，
  与旧 online 的对外表现一致，见任务 06 需求分析）。
- presence 不迁移：Redis 实时值（online/invisible）语义不变。
"""
from django.db import migrations, models


def forward(apps, schema_editor):
    User = apps.get_model("accounts", "User")
    User.objects.filter(status="online").update(status="auto")


def backward(apps, schema_editor):
    User = apps.get_model("accounts", "User")
    User.objects.filter(status="auto").update(status="online")


class Migration(migrations.Migration):

    dependencies = [
        ("accounts", "0003_user_show_content"),
    ]

    operations = [
        migrations.AlterField(
            model_name="user",
            name="status",
            field=models.CharField(
                choices=[
                    ("auto", "自动"),
                    ("away", "离开"),
                    ("dnd", "勿扰"),
                    ("invisible", "隐身"),
                ],
                default="auto",
                max_length=16,
                verbose_name="状态",
            ),
        ),
        migrations.RunPython(forward, backward),
    ]
