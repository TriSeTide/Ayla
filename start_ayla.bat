@echo off
rem Ayla 后端一键启动：runserver（127.0.0.1:8100）+ run_bridge（SSE 出站投影）
rem 用法：双击本文件，或在终端运行 start_ayla.bat；Ctrl+C 一并退出
title Ayla Backend
cd /d "%~dp0backend"
if not exist ".venv\Scripts\python.exe" (
    echo [start_ayla] 未找到 backend\.venv，请先创建虚拟环境并安装依赖。
    pause
    exit /b 1
)
".venv\Scripts\python.exe" launcher.py
echo.
echo [start_ayla] Ayla 后端已退出。
pause
