from django.conf import settings
from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):
    dependencies = [
        ("chat", "0005_alter_conversation_join_policy"),
    ]

    operations = [
        migrations.CreateModel(
            name="GroupMemberLeaveNotice",
            fields=[
                ("id", models.AutoField(primary_key=True, serialize=False)),
                ("member_name", models.CharField(max_length=150)),
                ("read_at", models.DateTimeField(blank=True, null=True)),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("conversation", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="member_leave_notices", to="chat.conversation")),
                ("recipient", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="group_leave_notices", to=settings.AUTH_USER_MODEL)),
            ],
            options={"db_table": "group_member_leave_notices", "ordering": ["-created_at"]},
        ),
    ]
