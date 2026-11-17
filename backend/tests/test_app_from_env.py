from fastapi import FastAPI

from nodebeat.api import app_from_env


def test_app_from_env(monkeypatch):
    for k, v in {"NODEBEAT_MONGO_URL": "mongodb://localhost:27017/nodebeat", "NODEBEAT_REDIS_URL": "redis://localhost:6379",
                 "NODEBEAT_SECRET_KEY": "k", "NODEBEAT_WEBHOOK_URL": "https://hook.example",
                 "NODEBEAT_REFERENCE_HOST": "ref.example"}.items():
        monkeypatch.setenv(k, v)
    assert isinstance(app_from_env(), FastAPI)


def _env_base(monkeypatch):
    for k, v in {"NODEBEAT_MONGO_URL": "m", "NODEBEAT_REDIS_URL": "r", "NODEBEAT_SECRET_KEY": "k",
                 "NODEBEAT_WEBHOOK_URL": "https://hook.example", "NODEBEAT_REFERENCE_HOST": "ref.example"}.items():
        monkeypatch.setenv(k, v)


def test_ips_do_servidor_opcionais(monkeypatch):
    import pytest

    from nodebeat.config import load_settings
    _env_base(monkeypatch)
    s = load_settings()
    assert s.ip_origem is None and s.ips_publicos_sede == []
    monkeypatch.setenv("NODEBEAT_IP_ORIGEM", "10.9.9.9")
    monkeypatch.setenv("NODEBEAT_IPS_PUBLICOS_SEDE", "203.0.113.5, 198.51.100.7")
    s = load_settings()
    assert (s.ip_origem, s.ips_publicos_sede) == ("10.9.9.9", ["203.0.113.5", "198.51.100.7"])
    monkeypatch.setenv("NODEBEAT_IPS_PUBLICOS_SEDE", "203.0.113.5,x")
    with pytest.raises(RuntimeError, match="NODEBEAT_IPS_PUBLICOS_SEDE inválida"):
        load_settings()


def test_ip_origem_invalido_falha(monkeypatch):
    import pytest

    from nodebeat.config import load_settings
    _env_base(monkeypatch)
    monkeypatch.setenv("NODEBEAT_IP_ORIGEM", "abc")
    with pytest.raises(RuntimeError, match="NODEBEAT_IP_ORIGEM inválida"):
        load_settings()
