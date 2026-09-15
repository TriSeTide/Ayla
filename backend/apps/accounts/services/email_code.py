"""邮箱验证码服务。

基于 django cache API（生产 default=Redis，测试 settings_test=LocMem）：
- 发码：6 位数字，TTL 5 分钟；60s 重发冷却（原子防并发）；每邮箱每日 5 次上限；
  同 IP 每小时 30 次上限（尽力而为，IP 缺失不阻断）；
- 校验：错 5 次作废；成功后一次性消费（注册建号时删除键，注册后即失效）；
- 失败语义：发信失败/校验失败显式抛 EmailCodeError，绝不静默放行或伪造成功
  （AGENTS.md 失败语义）；发信失败会回滚冷却与验证码，允许用户立即重试。
"""
import logging
import secrets

from django.conf import settings
from django.core.cache import cache
from django.core.mail import send_mail
from django.utils import timezone

logger = logging.getLogger(__name__)

CODE_TTL = 300  # 5 分钟
CODE_LEN = 6
# 默认限流值（生产用 .env 配置覆盖，见 config/settings.py EMAIL_CODE_*）；测试可用 override_settings 调整
RESEND_COOLDOWN = 60  # 秒
DAILY_LIMIT = 5  # 每邮箱每日发码上限
IP_HOURLY_LIMIT = 30  # 同 IP 每小时发码上限
MAX_ATTEMPTS = 5  # 错 5 次作废
DAILY_TTL = 86400


class EmailCodeError(Exception):
    """业务失败：冷却中/超限/校验失败。status_code 由视图翻译为 HTTP 状态。"""

    def __init__(self, detail: str, status_code: int = 400):
        super().__init__(detail)
        self.detail = detail
        self.status_code = status_code


def _key(email: str, kind: str) -> str:
    return f"email_code_{kind}:{email.strip().lower()}"


def _limit(name: str, default: int) -> int:
    """限流参数动态读 settings（支持测试 override_settings；生产走 .env 配置）。"""
    return int(getattr(settings, name, default))


def _generate() -> str:
    return f"{secrets.randbelow(10 ** CODE_LEN):0{CODE_LEN}d}"


def send_code(email: str, client_ip: str | None = None) -> None:
    """生成并发送验证码；限流或发信失败显式抛 EmailCodeError。"""
    email = (email or "").strip().lower()
    if not email:
        raise EmailCodeError("邮箱不能为空")

    daily_limit = _limit("EMAIL_CODE_DAILY_LIMIT", DAILY_LIMIT)
    cooldown = _limit("EMAIL_CODE_RESEND_COOLDOWN", RESEND_COOLDOWN)
    ip_limit = _limit("EMAIL_CODE_IP_HOURLY_LIMIT", IP_HOURLY_LIMIT)

    # 1) 每邮箱每日上限
    if cache.get(_key(email, "daily"), 0) >= daily_limit:
        raise EmailCodeError("今日发送次数已达上限，请明天再试", status_code=429)

    # 2) 重发冷却（cache.add 原子：并发重复请求只有一个能过）
    now = int(timezone.now().timestamp())
    if not cache.add(_key(email, "cd"), now, cooldown):
        raise EmailCodeError(f"发送太频繁，请 {cooldown} 秒后再试", status_code=429)

    # 3) 同 IP 每小时上限
    if client_ip and cache.get(_key(client_ip, "ip"), 0) >= ip_limit:
        raise EmailCodeError("请求过于频繁，请稍后再试", status_code=429)

    code = _generate()
    cache.set(_key(email, "code"), code, CODE_TTL)

    # 4) 每日与 IP 计数（原子初始化，已存在则 +1）
    if not cache.add(_key(email, "daily"), 1, DAILY_TTL):
        _try_incr(_key(email, "daily"), DAILY_TTL)
    if client_ip and not cache.add(_key(client_ip, "ip"), 1, 3600):
        _try_incr(_key(client_ip, "ip"), 3600)

    # 5) 发信：失败必须显式抛出，并回滚冷却与验证码（daily/ip 配额计数保留——
    #    保守扣减，防止 SMTP 故障期间持续轰炸；用户可立即重试）
    try:
        send_mail(
            subject="Ayla 注册验证码",
            message=(
                f"你的 Ayla 注册验证码是：{code}\n"
                f"{CODE_TTL // 60} 分钟内有效，请勿向他人泄露。\n"
                "如果这不是你的操作，请忽略本邮件。"
            ),
            from_email=settings.DEFAULT_FROM_EMAIL,
            recipient_list=[email],
            fail_silently=False,
        )
    except Exception:
        logger.exception("send email code failed for %s", email)
        cache.delete(_key(email, "code"))
        cache.delete(_key(email, "cd"))
        raise EmailCodeError("验证码发送失败，请稍后重试", status_code=500)


def check_code(email: str, code: str) -> bool:
    """校验验证码（不消费；注册 validate 阶段调用）。

    错码会累计尝试次数，满 MAX_ATTEMPTS 次自动作废（删除码与计数）。
    """
    email = (email or "").strip().lower()
    key = _key(email, "code")
    stored = cache.get(key)
    if stored is None:
        return False
    if not secrets.compare_digest(str(stored), str(code).strip()):
        attempts_key = _key(email, "attempts")
        attempts = cache.get(attempts_key, 0) + 1
        cache.set(attempts_key, attempts, CODE_TTL)
        if attempts >= MAX_ATTEMPTS:
            cache.delete(key)
            cache.delete(attempts_key)
        return False
    return True


def consume_code(email: str, code: str) -> None:
    """确认仍有效后一次性消费（注册 create 阶段使用，与建号同事务）。"""
    email = (email or "").strip().lower()
    key = _key(email, "code")
    stored = cache.get(key)
    if stored is None:
        raise EmailCodeError("验证码不存在或已过期，请重新获取")
    if not secrets.compare_digest(str(stored), str(code).strip()):
        raise EmailCodeError("验证码错误")
    cache.delete(key)
    cache.delete(_key(email, "attempts"))


def _try_incr(key: str, ttl: int) -> None:
    """缓存 incr 失败（键被并发清除）时重新原子初始化。"""
    try:
        cache.incr(key)
    except ValueError:
        cache.set(key, 1, ttl)
