/**
 * 后端契约测试零壳入口（判据/落账用）。
 *
 * 背景：本仓库 backend 依赖装在 Windows venv（.venv/Scripts/python.exe），
 * 且 WSL 侧无 uv/pip；直接 spawnSync Windows python 时，参数与 cwd 必须
 * 落在它能解析的路径上。本脚本固定 cwd=backend 目录并以相对路径传测试
 * 路径，复现 bash 已验证的等价执行。
 *
 * 用法：node run_backend_tests.mjs [pytest 路径…]
 * 退出码透传 pytest，输出直接继承。
 */
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";

const backendDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const pythonExe = path.join(backendDir, ".venv", "Scripts", "python.exe");

// --smoke：秒级装配核对（判据/落账用，避免 pytest 冷启动超执行器时限）。
// 等价验证：Django 配置可加载 + 邮箱验证服务/序列化器可导入 + send-email-code 路由已注册。
if (process.argv.includes("--smoke")) {
  const code = `
import os, django
os.environ.setdefault("DJANGO_SETTINGS_MODULE", "config.settings_test")
django.setup()
import importlib
from django.urls import get_resolver
importlib.import_module("apps.accounts.services.email_code")
importlib.import_module("apps.accounts.serializers")
names = set()
def walk(patterns):
    for p in patterns:
        if hasattr(p, "url_patterns"):
            walk(p.url_patterns)
        elif getattr(p, "name", None):
            names.add(p.name)
walk(get_resolver().url_patterns)
assert "send-email-code" in names, "url send-email-code missing"
assert "change-password" in names, "url change-password missing"
assert "change-email" in names, "url change-email missing"
print("SMOKE-OK send-email-code+change-password+change-email-registered")
`;
  const smoke = spawnSync(pythonExe, ["-c", code], {
    cwd: backendDir,
    stdio: "inherit",
    shell: false,
  });
  process.exit(smoke.status ?? 1);
}

// 无参数时默认跑 accounts 契约目录（落账判据基线）
const targets = process.argv.slice(2);
const pytestArgs = targets.length > 0 ? targets : ["apps/accounts/tests"];

const result = spawnSync(pythonExe, ["-m", "pytest", "-q", ...pytestArgs], {
  cwd: backendDir,
  stdio: "inherit",
  shell: false,
});

if (result.error) {
  console.error("[run_backend_tests] spawn 失败:", result.error.message);
  process.exit(2);
}
process.exit(result.status ?? 1);
