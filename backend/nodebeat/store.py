"""Coleção mks no MongoDB. Ids são str(ObjectId); id inválido -> None/False."""
from __future__ import annotations

import ipaddress
from datetime import UTC, datetime

from bson import ObjectId
from bson.errors import InvalidId


def _oid(id: str) -> ObjectId | None:
    try:
        return ObjectId(id)
    except (InvalidId, TypeError):
        return None


def _out(d: dict) -> dict:
    d = dict(d)
    d["id"] = str(d.pop("_id"))
    return d


async def list_mks(db) -> list[dict]:
    return [_out(d) async for d in db.mks.find()]


async def get_mk(db, id: str) -> dict | None:
    oid = _oid(id)
    d = await db.mks.find_one({"_id": oid}) if oid else None
    return _out(d) if d else None


async def insert_mk(db, doc: dict) -> str:
    doc = {"criado_em": datetime.now(UTC), **doc}
    return str((await db.mks.insert_one(doc)).inserted_id)


async def update_mk(db, id: str, fields: dict) -> bool:
    oid = _oid(id)
    return bool(oid) and (await db.mks.update_one({"_id": oid}, {"$set": fields})).matched_count > 0


async def delete_mk(db, id: str) -> bool:
    oid = _oid(id)
    return bool(oid) and (await db.mks.delete_one({"_id": oid})).deleted_count > 0


async def set_cert(db, id: str, sha: str | None) -> None:
    await update_mk(db, id, {"cert_sha256": sha})


async def get_user(db, usuario: str) -> dict | None:
    return await db.users.find_one({"usuario": usuario})


async def insert_user(db, usuario: str, senha_hash: str) -> str:
    """Usuário duplicado -> DuplicateKeyError (índice único)."""
    await db.users.create_index("usuario", unique=True)
    doc = {"usuario": usuario, "senha_hash": senha_hash, "criado_em": datetime.now(UTC)}
    return str((await db.users.insert_one(doc)).inserted_id)


def _utc(d: dict) -> dict:
    """Sem _id; datetimes do Mongo (naive, em UTC) viram aware."""
    d = {k: v for k, v in d.items() if k != "_id"}
    return {k: v.replace(tzinfo=UTC) if isinstance(v, datetime) and v.tzinfo is None else v
            for k, v in d.items()}


async def salvar_inventario(db, mk_id: str, doc: dict, lido_em: datetime) -> None:
    await db.inventario.replace_one(
        {"mk_id": mk_id}, {"mk_id": mk_id, **doc, "lido_em": lido_em, "erro": None}, upsert=True)


async def inventario_erro(db, mk_id: str, detalhe: str) -> None:
    await db.inventario.update_one({"mk_id": mk_id}, {"$set": {"erro": detalhe}}, upsert=True)


async def get_inventario(db, mk_id: str) -> dict | None:
    d = await db.inventario.find_one({"mk_id": mk_id})
    return _utc(d) if d else None


async def listar_inventarios(db) -> list[dict]:
    return [_utc(d) async for d in db.inventario.find()]


async def registrar_ips(db, mk_id: str, ips: list[dict], quando: datetime) -> None:
    await db.inventario_ips.create_index([("mk_id", 1), ("ip", 1)], unique=True)
    for i in ips:
        await db.inventario_ips.update_one(
            {"mk_id": mk_id, "ip": i["ip"]},
            {"$set": {"mac": i.get("mac"), "host_name": i.get("host_name"),
                      "fixo": i.get("fixo", False), "ultimo_visto": quando},
             "$setOnInsert": {"primeiro_visto": quando}}, upsert=True)


async def listar_ips(db, mk_id: str) -> list[dict]:
    ips = [_utc(d) async for d in db.inventario_ips.find({"mk_id": mk_id})]
    return sorted(ips, key=lambda d: ipaddress.ip_address(d["ip"]))


async def esquecer_ip(db, mk_id: str, ip: str) -> bool:
    return (await db.inventario_ips.delete_one({"mk_id": mk_id, "ip": ip})).deleted_count > 0


async def apagar_inventario(db, mk_id: str) -> None:
    await db.inventario.delete_many({"mk_id": mk_id})
    await db.inventario_ips.delete_many({"mk_id": mk_id})
