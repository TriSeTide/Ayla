from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [
        ("favorites", "0001_initial"),
    ]

    operations = [
        migrations.AlterField(
            model_name="favorite",
            name="target_type",
            field=models.CharField(
                choices=[
                    ("post", "帖子"),
                    ("message", "消息"),
                    ("live", "直播间"),
                    ("voice", "语音房"),
                    ("game", "桌游室"),
                    ("group", "群"),
                ],
                max_length=16,
                verbose_name="目标类型",
            ),
        ),
    ]

    # Existing rows are unchanged; the new target type is additive.
    atomic = True
