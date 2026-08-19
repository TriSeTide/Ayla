# 修复：群外发帖选择指定群可见功能

## 问题描述

当用户在群外发帖弹窗中选择"指定群可见"时，无法正常发帖。

## 根因分析

在 `apps/posts/services.py` 的 `_resolve_visibility` 函数中，存在过于严格的校验：

```python
# 修复前（第 29-30 行）
if visibility == Visibility.GROUP and group is None:
    raise ValueError("群成员可见必须指定群")
```

这个逻辑存在问题：
- 当用户在群外发帖（`group` 为 `None`）
- 选择了"指定群可见"（`visibility` 为 `GROUP`）
- 并提供了 `allowed_group_ids`（选择了具体的群）

代码在第 29 行就直接抛出异常，根本没有机会执行到后面的 `set_allowed_groups` 逻辑（第 48-50 行）。

## 修复方案

修改 `_resolve_visibility` 函数的校验逻辑，允许在提供 `allowed_group_ids` 的情况下，即使 `group` 为 `None` 也能正常创建帖子：

```python
# 修复后
def _resolve_visibility(group, visibility, allowed_group_ids) -> str:
    """S1 可见性默认：group 非空且未显式指定 → group 可见；否则 public。"""
    if visibility in (None, ""):
        return Visibility.GROUP if group is not None else Visibility.PUBLIC
    if visibility == Visibility.GROUP and group is None and not allowed_group_ids:
        raise ValueError("群成员可见必须指定群或 allowed_group_ids")
    return visibility
```

修改要点：
1. 增加 `allowed_group_ids` 参数
2. 将条件从 `group is None` 改为 `group is None and not allowed_group_ids`
3. 错误消息更新为 "群成员可见必须指定群或 allowed_group_ids"

## 修改文件

- `Ayla/backend/apps/posts/services.py`
  - 第 25 行：`_resolve_visibility` 函数签名增加 `allowed_group_ids` 参数
  - 第 29 行：校验条件修改
  - 第 43 行：调用时传入 `allowed_group_ids` 参数

## 验证

### 场景 1：群外发帖 + allowed_group_ids（应该成功）
```python
post = create_post(
    author=author,
    title="",
    body="这是一条只给指定群看的帖子",
    group=None,  # 群外发帖
    visibility=Visibility.GROUP,  # 群成员可见
    allowed_group_ids=["group1_id", "group2_id"],  # 指定群白名单
)
```

预期：
- 帖子创建成功
- `post.group` 为 `None`
- `post.visibility` 为 `GROUP`
- `post.allowed_groups` 包含指定的群

### 场景 2：visibility=GROUP 但既无 group 也无 allowed_group_ids（应该失败）
```python
post = create_post(
    author=author,
    title="",
    body="这应该失败",
    group=None,
    visibility=Visibility.GROUP,
    allowed_group_ids=None,
)
```

预期：抛出 `ValueError: 群成员可见必须指定群或 allowed_group_ids`

## 数据流验证

1. **前端** (`PostEditor.tsx:86`)：发送 `allowed_group_ids: selectedGroupIds`
2. **序列化器** (`serializers.py:152-154`)：定义 `allowed_group_ids` 字段
3. **视图层** (`views.py:142`)：传递 `allowed_group_ids=data.get("allowed_group_ids")`
4. **服务层** (`services.py:48-50`)：调用 `set_allowed_groups(post, allowed_group_ids)`
5. **可见性层** (`visibility.py:87-102`)：验证并设置群白名单

整个数据流已打通，修复后应该能正常工作。

## 日期

2025-01-XX
