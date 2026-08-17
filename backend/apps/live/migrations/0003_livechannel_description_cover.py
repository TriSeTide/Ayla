from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [
        ("live", "0002_livechannel_group_livechannel_visibility"),
    ]

    operations = [
        migrations.AddField(
            model_name="livechannel",
            name="description",
            field=models.TextField(blank=True, default="", verbose_name="直播间介绍"),
        ),
        migrations.AddField(
            model_name="livechannel",
            name="cover",
            field=models.CharField(blank=True, default="", max_length=512, verbose_name="直播间封面"),
        ),
    ]
