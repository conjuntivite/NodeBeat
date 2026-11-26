"""Coleção mks no MongoDB. Ids são str(ObjectId); id inválido -> None/False."""
from __future__ import annotations

import ipaddress
import re
from datetime import UTC, datetime

from bson import ObjectId
from bson.errors import InvalidId
from pymongo.errors import BulkWriteError


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


async def insert_user(db, usuario: str, senha_hash: str, admin: bool = False) -> str:
    """Usuário duplicado -> DuplicateKeyError (índice único)."""
    await db.users.create_index("usuario", unique=True)
    doc = {"usuario": usuario, "senha_hash": senha_hash, "admin": admin,
           "criado_em": datetime.now(UTC)}
    return str((await db.users.insert_one(doc)).inserted_id)


async def listar_users(db) -> list[dict]:
    """Sem hash; usuário sem o campo admin conta como admin."""
    docs = await db.users.find({}).sort("usuario", 1).to_list(None)
    return [{"usuario": u["usuario"], "admin": u.get("admin", True), "criado_em": _utc(u).get("criado_em")}
            for u in docs]


async def atualizar_user(db, usuario: str, campos: dict) -> bool:
    return (await db.users.update_one({"usuario": usuario}, {"$set": campos})).matched_count == 1


async def apagar_user(db, usuario: str) -> bool:
    return (await db.users.delete_one({"usuario": usuario})).deleted_count == 1


async def contar_admins(db) -> int:
    return await db.users.count_documents({"admin": {"$ne": False}})


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


async def registrar_ips(db, mk_id: str, ips: list[dict], quando: datetime,
                        fatos: dict[str, dict] | None = None) -> None:
    await db.inventario_ips.create_index([("mk_id", 1), ("ip", 1)], unique=True)
    for i in ips:
        f = dict((fatos or {}).get(i["ip"], {}))
        if f.get("porta") is None:
            f.pop("porta", None)  # leitura sem porta não apaga a última conhecida
        await db.inventario_ips.update_one(
            {"mk_id": mk_id, "ip": i["ip"]},
            {"$set": {"mac": i.get("mac"), "host_name": i.get("host_name"),
                      "fixo": i.get("fixo", False), "ultimo_visto": quando, **f},
             "$setOnInsert": {"primeiro_visto": quando}}, upsert=True)


async def listar_ips(db, mk_id: str) -> list[dict]:
    ips = [_utc(d) async for d in db.inventario_ips.find({"mk_id": mk_id})]
    return sorted(ips, key=lambda d: ipaddress.ip_address(d["ip"]))


async def esquecer_ip(db, mk_id: str, ip: str) -> bool:
    await db.switches.delete_one({"mk_id": mk_id, "ip": ip})  # sem doc órfão de switch
    return (await db.inventario_ips.delete_one({"mk_id": mk_id, "ip": ip})).deleted_count > 0


async def editar_aparelho(db, mk_id: str, ip: str, campos: dict) -> bool:
    """Grava apelido/vigiar_manual/e_switch_manual; None limpa. False se o IP não existe."""
    permitidos = {"apelido", "vigiar_manual", "e_switch_manual"}
    sets = {k: v for k, v in campos.items() if k in permitidos and v is not None}
    unsets = {k: "" for k, v in campos.items() if k in permitidos and v is None}
    upd = ({"$set": sets} if sets else {}) | ({"$unset": unsets} if unsets else {})
    if not upd:
        return await db.inventario_ips.count_documents({"mk_id": mk_id, "ip": ip}) > 0
    return (await db.inventario_ips.update_one({"mk_id": mk_id, "ip": ip}, upd)).matched_count > 0


async def set_rotulo_porta(db, mk_id: str, porta: str, rotulo: str | None) -> None:
    # coleção própria: salvar_inventario faz replace_one e apagaria rótulos guardados no inventário
    if rotulo:
        await db.mapa_rotulos.update_one({"mk_id": mk_id, "porta": porta}, {"$set": {"rotulo": rotulo}}, upsert=True)
    else:
        await db.mapa_rotulos.delete_one({"mk_id": mk_id, "porta": porta})


async def rotulos_portas(db, mk_id: str) -> dict[str, str]:
    return {d["porta"]: d["rotulo"] async for d in db.mapa_rotulos.find({"mk_id": mk_id})}


async def marcar_gerenciavel(db, mk_id: str, ip: str, valor: bool) -> None:
    """Switch que responde SNMP passa a ser vigiado (mapa.vigiado). Só o worker grava."""
    await db.inventario_ips.update_one({"mk_id": mk_id, "ip": ip}, {"$set": {"gerenciavel": valor}})


async def registrar_ligacoes(db, mk_id: str, ligacoes: dict[str, dict]) -> None:
    """Grava (switch_ip, switch_porta) no aparelho; IP ausente mantém a última ligação conhecida
    (a tabela MAC do switch esquece aparelho desligado) e IP sem doc não é criado."""
    for ip, lig in ligacoes.items():
        await db.inventario_ips.update_one(
            {"mk_id": mk_id, "ip": ip}, {"$set": {"switch_ip": lig["switch_ip"], "switch_porta": lig["porta"]}})


async def limpar_ligacoes(db, mk_id: str, ips) -> None:
    """Tira (switch_ip, switch_porta) dos IPs da MK: switch raiz cortado no ciclo (mapa.ligacoes_e_raizes)."""
    for ip in ips:
        await db.inventario_ips.update_one({"mk_id": mk_id, "ip": ip}, {"$unset": {"switch_ip": "", "switch_porta": ""}})


async def salvar_switch(db, mk_id: str, ip: str, doc: dict) -> None:
    """Mescla os campos no doc do switch: campo ausente mantém o valor anterior."""
    await db.switches.update_one({"mk_id": mk_id, "ip": ip}, {"$set": {"mk_id": mk_id, "ip": ip, **doc}},
                                 upsert=True)


async def listar_switches(db, mk_id: str) -> list[dict]:
    return [_utc(d) async for d in db.switches.find({"mk_id": mk_id})]


async def apagar_inventario(db, mk_id: str) -> None:
    await db.inventario.delete_many({"mk_id": mk_id})
    await db.inventario_ips.delete_many({"mk_id": mk_id})
    await db.mapa_rotulos.delete_many({"mk_id": mk_id})
    await db.switches.delete_many({"mk_id": mk_id})


async def garantir_indices_eventos(db, dias: int) -> None:
    await db.eventos.create_index([("mk_id", 1), ("recebido_em", -1)])
    segundos = dias * 86400
    info = await db.eventos.index_information()
    if info.get("ttl_recebido_em", {}).get("expireAfterSeconds") not in (None, segundos):
        # ponytail: drop+create deixa a coleção alguns ms sem TTL, o que não importa
        await db.eventos.drop_index("ttl_recebido_em")
    await db.eventos.create_index("recebido_em", name="ttl_recebido_em", expireAfterSeconds=segundos)


async def garantir_indice_unifi(db) -> None:
    await db.eventos.create_index("unifi_id", unique=True, name="unifi_id_unico",
                                  partialFilterExpression={"unifi_id": {"$exists": True}})


HIST_TTL_S = 400 * 86400


async def garantir_indice_hist(db) -> None:
    await db.unifi_hist.create_index([("eq_id", 1), ("em", 1)])
    await db.unifi_hist.create_index("em", name="ttl_em", expireAfterSeconds=HIST_TTL_S)


async def inserir_retrato(db, doc: dict) -> None:
    await db.unifi_hist.insert_one(doc)


async def listar_retratos(db, eq_ids: list[str], desde: datetime) -> list[dict]:
    f = {"eq_id": {"$in": eq_ids}, "em": {"$gte": desde}}
    return [_utc(d) async for d in db.unifi_hist.find(f, {"portas": 0}).sort("em", 1)]


async def inserir_eventos_unifi(db, docs: list[dict]) -> int:
    """Insere ignorando os que já existem (o log é relido com sobreposição); devolve quantos entraram."""
    if not docs:
        return 0
    try:
        return len((await db.eventos.insert_many(docs, ordered=False)).inserted_ids)
    except BulkWriteError as e:
        erros = e.details.get("writeErrors", [])
        if any(x.get("code") != 11000 for x in erros):
            raise
        return len(docs) - len(erros)


async def inserir_eventos(db, docs: list[dict]) -> None:
    if docs:
        await db.eventos.insert_many(docs)


async def listar_eventos(db, mk_id: str, *, tipos: list[str] | None = None, desde: datetime | None = None,
                         ate: datetime | None = None, q: str | None = None, limite: int = 200) -> list[dict]:
    f: dict = {"mk_id": mk_id}
    if tipos:
        f["tipo"] = {"$in": tipos}
    if desde or ate:
        f["recebido_em"] = {**({"$gte": desde} if desde else {}), **({"$lt": ate} if ate else {})}
    if q:
        f["mensagem"] = {"$regex": re.escape(q), "$options": "i"}
    return [_utc(d) async for d in db.eventos.find(f).sort("recebido_em", -1).limit(limite)]


async def listar_eventos_periodo(db, desde: datetime, mk_id: str | None = None) -> list[dict]:
    # sem filtro: só MKs (o painel lê 30 dias; os eventos eq:<id> ficam no detalhe do equipamento)
    f: dict = {"recebido_em": {"$gte": desde}, "mk_id": mk_id or {"$not": {"$regex": "^eq:"}}}
    return [_utc(d) async for d in db.eventos.find(f).sort("recebido_em", 1)]


async def primeiros_eventos(db, desde: datetime, ate: datetime) -> list[dict]:
    """1.º instante em [desde, ate) de cada MK e de cada (MK, usuário) de config/login/logout.
    `usuario` é None na linha da MK. Agregado no Mongo: poupa trazer semanas de eventos para o Python."""
    f: dict = {"recebido_em": {"$gte": desde, "$lt": ate}, "mk_id": {"$not": {"$regex": "^eq:"}}}
    t = {"$min": "$recebido_em"}
    por_mk = [{"$match": f}, {"$group": {"_id": "$mk_id", "t": t}}]
    por_usuario = [{"$match": f | {"tipo": {"$in": ["config", "login", "logout"]}}},
                   {"$group": {"_id": {"mk": "$mk_id", "u": "$campos.usuario"}, "t": t}}]
    out = [{"mk_id": d["_id"], "usuario": None, "recebido_em": d["t"]} async for d in db.eventos.aggregate(por_mk)]
    out += [{"mk_id": d["_id"]["mk"], "usuario": d["_id"]["u"], "recebido_em": d["t"]}
            async for d in db.eventos.aggregate(por_usuario) if d["_id"].get("u")]
    return [_utc(d) for d in out]


async def listar_eventos_apos(db, cursor: ObjectId | None, limite: int) -> list[dict]:
    """Eventos de MK com _id > cursor (mantém _id), em ordem crescente; só os tipos do mapa de ataques."""
    f: dict = {"mk_id": {"$not": {"$regex": "^eq:"}}, "tipo": {"$in": ["login_falha", "erro", "login"]}}
    if cursor:
        f["_id"] = {"$gt": cursor}
    return [{**_utc(d), "_id": d["_id"]} async for d in db.eventos.find(f).sort("_id", 1).limit(limite)]


async def ultimo_evento_id(db) -> ObjectId | None:
    d = await db.eventos.find_one({}, {"_id": 1}, sort=[("_id", -1)])
    return d["_id"] if d else None


def _filtro_unifi(desde: datetime) -> dict:
    return {"mk_id": {"$regex": "^eq:"}, "origem": "unifi", "recebido_em": {"$gte": desde}}  # prefixo usa o índice (mk_id, recebido_em)


async def listar_eventos_unifi(db, desde: datetime, limite: int = 100) -> list[dict]:
    return [_utc(d) async for d in db.eventos.find(_filtro_unifi(desde)).sort("recebido_em", -1).limit(limite)]


async def listar_eventos_unifi_periodo(db, desde: datetime, ate: datetime) -> list[dict]:
    """Eventos do período [desde, ate) para agregar em Python (o mongomock não tem $dateTrunc).
    ponytail: sem limite; revisitar se passar de 50 mil eventos por período."""
    f = _filtro_unifi(desde) | {"recebido_em": {"$gte": desde, "$lt": ate}}
    proj = {"tipo": 1, "recebido_em": 1, "mk_id": 1, "campos": 1}
    return [_utc(d) async for d in db.eventos.find(f, proj)]


async def contar_eventos_unifi(db, desde: datetime) -> dict[str, int]:
    """Contagem por tipo no período."""
    pipe = [{"$match": _filtro_unifi(desde)}, {"$group": {"_id": "$tipo", "n": {"$sum": 1}}}]
    return {d["_id"]: d["n"] async for d in db.eventos.aggregate(pipe)}


async def ultimo_evento(db, mk_id: str) -> datetime | None:
    d = await db.eventos.find_one({"mk_id": mk_id}, sort=[("recebido_em", -1)])
    return _utc(d)["recebido_em"] if d else None


async def apagar_eventos(db, mk_id: str) -> None:
    await db.eventos.delete_many({"mk_id": mk_id})


async def listar_equipamentos(db, tipo: str | None = None) -> list[dict]:
    f = {"tipo": tipo} if tipo else {}
    return [_out(d) async for d in db.equipamentos.find(f)]


async def get_equipamento(db, id: str) -> dict | None:
    oid = _oid(id)
    d = await db.equipamentos.find_one({"_id": oid}) if oid else None
    return _out(d) if d else None


async def inserir_equipamento(db, doc: dict) -> str:
    doc = {"criado_em": datetime.now(UTC), **doc}
    return str((await db.equipamentos.insert_one(doc)).inserted_id)


async def atualizar_equipamento(db, id: str, campos: dict) -> bool:
    oid = _oid(id)
    return bool(oid) and (await db.equipamentos.update_one({"_id": oid}, {"$set": campos})).matched_count > 0


async def apagar_equipamento(db, id: str) -> bool:
    oid = _oid(id)
    return bool(oid) and (await db.equipamentos.delete_one({"_id": oid})).deleted_count > 0


async def upsert_descoberto(db, tipo: str, mk_id: str, ip: str, nome: str) -> str:
    """Um equipamento achado por MK tem chave (tipo, local, ip, origem). O nome só entra no insert:
    o que o operador editou não é sobrescrito a cada ciclo."""
    await db.equipamentos.create_index([("tipo", 1), ("local", 1), ("ip", 1), ("origem", 1)], unique=True)
    filtro = {"tipo": tipo, "local": mk_id, "ip": ip, "origem": "descoberto"}
    await db.equipamentos.update_one(
        filtro, {"$setOnInsert": {"nome": nome, "criado_em": datetime.now(UTC)}}, upsert=True)
    return str((await db.equipamentos.find_one(filtro))["_id"])
