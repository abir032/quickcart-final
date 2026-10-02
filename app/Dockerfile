FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py repository.py ./
RUN useradd -m -u 1001 appuser
USER appuser
ARG APP_VERSION=v1
ENV APP_VERSION=$APP_VERSION
EXPOSE 8080
CMD ["gunicorn", "-b", "0.0.0.0:8080", "-w", "2", "--graceful-timeout", "20", "--access-logfile", "-", "app:app"]
