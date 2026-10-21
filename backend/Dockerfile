# Ayla 后端生产镜像（frp 服务器）
# 构建（context 必须是 Ayla backend 源码目录）：
#   docker build -f backend/Dockerfile -t ayla-backend:latest <repo>/Ayla/backend
# Python 基础镜像默认用国内加速源；离线/代理不可用时可用 --build-arg BASE_IMAGE=
# 指向本机已有的镜像（如上一次的 ayla-backend:latest），依赖层通常命中缓存。
ARG BASE_IMAGE=docker.m.daocloud.io/library/python:3.11-slim
FROM ${BASE_IMAGE}

ENV PYTHONUNBUFFERED=1     PIP_NO_CACHE_DIR=1     PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

# 依赖层（pyproject 变更才重建）
COPY pyproject.toml ./
# ⚠️ 关键：装完依赖后必须删掉 site-packages 里的 apps/ 与 config/ 源码副本。
#
# pyproject 的 [tool.setuptools.packages.find] include = ["apps*", "config*"]，
# 所以 `pip install .` 会把本工程源码以**构建当时的快照**实体复制到
#   /usr/local/lib/python3.11/site-packages/apps/
# 而 site-packages 在 sys.path 中排在 /app 之前 ⇒ 它会**遮蔽**下面 COPY 进 /app 的
# 当前源码。后果：源码层更新后运行的实际仍是旧代码，且本层命中 Docker 缓存时
# 长期不重建。
#
# 2026-10-21 排查实证：media 过期修复部署并重建镜像后，运行时仍加载
#   /usr/local/lib/python3.11/site-packages/apps/media/...（10-18 旧快照），
# /app/apps/ 下的新代码从未被执行。
#
# 删除范围只含本工程包（不碰第三方 dist-info/egg-info，避免破坏依赖元数据）。
RUN pip install --index-url https://pypi.tuna.tsinghua.edu.cn/simple . \
 && rm -rf /usr/local/lib/python3.11/site-packages/apps \
           /usr/local/lib/python3.11/site-packages/config

# 源码层（**必须**晚于依赖层，保证 /app 下是当前代码）
COPY apps ./apps
COPY config ./config
COPY manage.py ./

# 运行数据目录（凭据落盘 / 媒体临时中转，挂载 volume）
RUN mkdir -p /app/runtime

EXPOSE 8100

# 启动前自动应用迁移（迁移失败拒绝启动）；collectstatic 供 Django admin 静态；
# daphne 承载 ASGI（含 lifespan 内嵌 SSE bridge），绑 127.0.0.1（host 网络，仅本机可达）。
CMD ["sh", "-c", "python manage.py migrate --no-input && python manage.py collectstatic --noinput && daphne -b 127.0.0.1 -p 8100 config.asgi:application"]
