FROM python:3.11-slim

WORKDIR /app

# 安装依赖
COPY backend/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# 复制代码
COPY backend/ /app/
COPY frontend/ /app/frontend/

# 创建数据目录
RUN mkdir -p /data

# 暴露端口
EXPOSE 8080

# 启动
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
