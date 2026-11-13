from fastapi import FastAPI

from nodebeat.api import app_from_env


def test_app_from_env(monkeypatch):
    for k, v in {"NODEBEAT_MONGO_URL": "mongodb://localhost:27017/nodebeat", "NODEBEAT_REDIS_URL": "redis://localhost:6379",
                 "NODEBEAT_SECRET_KEY": "k", "NODEBEAT_WEBHOOK_URL": "https://hook.example",
                 "NODEBEAT_REFERENCE_HOST": "ref.example"}.items():
        monkeypatch.setenv(k, v)
    assert isinstance(app_from_env(), FastAPI)
