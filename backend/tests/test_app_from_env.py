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


def test_redes_tunel_extra(monkeypatch):
    import pytest

    from nodebeat.config import load_settings
    _env_base(monkeypatch)
    assert load_settings().redes_tunel_extra == []
    monkeypatch.setenv("NODEBEAT_REDES_TUNEL_EXTRA", "172.32.0.1/22, 100.64.0.0/10")
    assert load_settings().redes_tunel_extra == ["172.32.0.0/22", "100.64.0.0/10"]
    monkeypatch.setenv("NODEBEAT_REDES_TUNEL_EXTRA", "x")
    with pytest.raises(RuntimeError, match="NODEBEAT_REDES_TUNEL_EXTRA inválida"):
        load_settings()


def test_syslog_dias_minimo_1(monkeypatch):
    import pytest

    from nodebeat.config import load_settings
    _env_base(monkeypatch)
    assert load_settings().syslog_dias == 30
    monkeypatch.setenv("NODEBEAT_SYSLOG_DIAS", "7")
    assert load_settings().syslog_dias == 7
    for ruim in ("0", "-5", "x"):
        monkeypatch.setenv("NODEBEAT_SYSLOG_DIAS", ruim)
        with pytest.raises(RuntimeError, match="NODEBEAT_SYSLOG_DIAS inválida"):
            load_settings()
