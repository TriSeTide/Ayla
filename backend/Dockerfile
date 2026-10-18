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
RUN pip install --index-url https://pypi.tuna.tsinghua.edu.cn/simple .

# 源码层
COPY apps ./apps
COPY config ./config
COPY manage.py ./

# 运行数据目录（凭据落盘 / 媒体临时中转，挂载 volume）
RUN mkdir -p /app/runtime

EXPOSE 8100

# 启动前自动应用迁移（迁移失败拒绝启动）；collectstatic 供 Django admin 静态；
# daphne 承载 ASGI（含 lifespan 内嵌 SSE bridge），绑 127.0.0.1（host 网络，仅本机可达）。
CMD ["sh", "-c", "python manage.py migrate --no-input && python manage.py collectstatic --noinput && daphne -b 127.0.0.1 -p 8100 config.asgi:application"]
