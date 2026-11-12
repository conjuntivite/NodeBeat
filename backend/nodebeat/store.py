"""Coleção mks no MongoDB. Ids são str(ObjectId); id inválido -> None/False."""
from __future__ import annotations

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
