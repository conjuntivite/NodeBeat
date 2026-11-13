FROM python:3.12-slim
# ping: sondas ICMP do worker (precisa de NET_RAW, dado no compose)
RUN apt-get update && apt-get install -y --no-install-recommends iputils-ping \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --create-home nodebeat
WORKDIR /app
COPY pyproject.toml ./
COPY nodebeat ./nodebeat
RUN pip install --no-cache-dir .
USER nodebeat
# api: uvicorn --factory nodebeat.api:app_from_env ; worker: python -m nodebeat.worker (definidos no compose)
CMD ["python", "-m", "nodebeat.worker"]
