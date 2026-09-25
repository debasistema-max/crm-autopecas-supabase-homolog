#!/usr/bin/env python3
"""Download the master XLSX from an exact personal OneDrive path and sync it.

Only delegated read access is requested. Runtime code is constrained to one
configured folder and filename. Tokens, pre-authenticated download URLs and
workbook contents are never printed or persisted outside a temporary directory.
"""

from __future__ import annotations

import importlib.util
import json
import os
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any


MODULE_PATH = Path(__file__).with_name("build_excel_sync_payload.py")
SPEC = importlib.util.spec_from_file_location("excel_payload", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("Não foi possível carregar o normalizador do Excel.")
excel_payload = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(excel_payload)

AUDIT_MODULE_PATH = Path(__file__).with_name("audit_excel_formula_contract.py")
AUDIT_SPEC = importlib.util.spec_from_file_location("excel_formula_audit", AUDIT_MODULE_PATH)
if AUDIT_SPEC is None or AUDIT_SPEC.loader is None:
    raise RuntimeError("Não foi possível carregar a validação de fórmulas do Excel.")
excel_formula_audit = importlib.util.module_from_spec(AUDIT_SPEC)
AUDIT_SPEC.loader.exec_module(excel_formula_audit)

GRAPH_ROOT = "https://graph.microsoft.com/v1.0"
TOKEN_URL = "https://login.microsoftonline.com/consumers/oauth2/v2.0/token"
MAX_WORKBOOK_BYTES = 300 * 1024 * 1024
CHUNK_ROWS = 500


class SyncError(RuntimeError):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def required_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise SyncError(f"CONFIGURACAO_AUSENTE:{name}")
    return value


def request_json(url: str, *, method: str = "GET", headers: dict[str, str] | None = None,
                 payload: dict[str, Any] | None = None, retries: int = 4,
                 timeout: int = 150) -> dict[str, Any]:
    encoded = None if payload is None else json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    request_headers = {"Accept": "application/json", **(headers or {})}
    if encoded is not None:
        request_headers["Content-Type"] = "application/json"
    for attempt in range(retries):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, data=encoded, headers=request_headers, method=method), timeout=timeout) as response:
                body = response.read()
                return json.loads(body) if body else {}
        except urllib.error.HTTPError as error:
            retryable = error.code in {429, 500, 502, 503, 504}
            if retryable and attempt + 1 < retries:
                delay = error.headers.get("Retry-After")
                time.sleep(min(int(delay) if delay and delay.isdigit() else 2 ** attempt, 30))
                continue
            graph_code = ""
            try:
                error_body = json.loads(error.read())
                raw_error = error_body.get("error", {})
                graph_code = str(raw_error.get("code") or "") if isinstance(raw_error, dict) else str(raw_error or "")
            except (json.JSONDecodeError, UnicodeDecodeError, AttributeError):
                pass
            suffix = f"_{graph_code}" if graph_code else ""
            raise SyncError(f"HTTP_{error.code}{suffix}:{urllib.parse.urlparse(url).netloc}") from error
        except (urllib.error.URLError, TimeoutError) as error:
            if attempt + 1 < retries:
                time.sleep(2 ** attempt)
                continue
            raise SyncError(f"REDE_INDISPONIVEL:{urllib.parse.urlparse(url).netloc}") from error
    raise SyncError("FALHA_HTTP")


def access_token(client_id: str, refresh_token: str) -> str:
    form = urllib.parse.urlencode({
        "client_id": client_id,
        "grant_type": "refresh_token",
        "refresh_token": refresh_token,
        "scope": "offline_access Files.Read",
    }).encode("ascii")
    try:
        with urllib.request.urlopen(urllib.request.Request(
            TOKEN_URL, data=form, headers={"Content-Type": "application/x-www-form-urlencoded"}, method="POST"
        ), timeout=60) as response:
            result = json.loads(response.read())
    except urllib.error.HTTPError as error:
        raise SyncError("AUTORIZACAO_MICROSOFT_INVALIDA") from error
    token = str(result.get("access_token") or "")
    if not token:
        raise SyncError("ACCESS_TOKEN_AUSENTE")
    return token


def graph_json(path: str, token: str) -> dict[str, Any]:
    return request_json(f"{GRAPH_ROOT}{path}", headers={"Authorization": f"Bearer {token}"})


def _validate_workbook_match(items: list[dict[str, Any]], filename: str) -> dict[str, Any]:
    matches = [item for item in items if item.get("name") == filename and item.get("file")]
    if len(matches) != 1:
        raise SyncError("PLANILHA_NAO_ENCONTRADA_NA_PASTA_CONFIGURADA")
    item = matches[0]
    size = int(item.get("size") or 0)
    if not filename.lower().endswith(".xlsx") or size <= 0 or size > MAX_WORKBOOK_BYTES:
        raise SyncError("PLANILHA_FORA_DOS_LIMITES")
    return item


def locate_workbook(token: str, filename: str, folder_path: str) -> dict[str, Any]:
    normalized_path = folder_path.strip().strip("/")
    if not normalized_path or "/" in normalized_path or normalized_path in {".", ".."}:
        raise SyncError("CAMINHO_ONEDRIVE_INVALIDO")
    root_fields = urllib.parse.quote("id,name,folder", safe=",")
    root_items = graph_json(f"/me/drive/root/children?$select={root_fields}", token).get("value", [])
    folders = [item for item in root_items if item.get("name") == normalized_path and item.get("folder") is not None]
    if len(folders) != 1:
        raise SyncError("PASTA_EXCLUSIVA_NAO_ENCONTRADA")
    folder_id = urllib.parse.quote(str(folders[0].get("id") or ""), safe="")
    if not folder_id:
        raise SyncError("PASTA_EXCLUSIVA_NAO_ENCONTRADA")
    fields = urllib.parse.quote("id,name,size,eTag,lastModifiedDateTime,file", safe=",")
    children = graph_json(f"/me/drive/items/{folder_id}/children?$select={fields}", token).get("value", [])
    return _validate_workbook_match(children, filename)


def download_workbook(token: str, item: dict[str, Any], destination: Path) -> None:
    item_id = urllib.parse.quote(str(item["id"]), safe="")
    opener = urllib.request.build_opener(NoRedirect)
    request = urllib.request.Request(
        f"{GRAPH_ROOT}/me/drive/items/{item_id}/content",
        headers={"Authorization": f"Bearer {token}"},
    )
    try:
        opener.open(request, timeout=60)
        raise SyncError("REDIRECIONAMENTO_GRAPH_AUSENTE")
    except urllib.error.HTTPError as response:
        if response.code not in {301, 302, 303, 307, 308}:
            raise SyncError(f"GRAPH_DOWNLOAD_HTTP_{response.code}") from response
        location = response.headers.get("Location", "")
    if not location.startswith("https://"):
        raise SyncError("URL_DOWNLOAD_GRAPH_INVALIDA")

    total = 0
    with urllib.request.urlopen(urllib.request.Request(location), timeout=150) as source, destination.open("wb") as target:
        while True:
            chunk = source.read(1024 * 1024)
            if not chunk:
                break
            total += len(chunk)
            if total > MAX_WORKBOOK_BYTES:
                raise SyncError("PLANILHA_FORA_DOS_LIMITES")
            target.write(chunk)
    if total != int(item["size"]):
        raise SyncError("DOWNLOAD_INCOMPLETO")
    with destination.open("rb") as stream:
        if stream.read(4) != b"PK\x03\x04":
            raise SyncError("ARQUIVO_XLSX_INVALIDO")


def edge_call(edge_url: str, secret: str, body: dict[str, Any], *, timeout: int = 130) -> dict[str, Any]:
    return request_json(
        edge_url, method="POST", headers={"x-sync-secret": secret}, payload=body, timeout=timeout
    )


def process_batch(edge_url: str, secret: str, batch_id: str,
                  records: list[dict[str, Any]]) -> dict[str, Any]:
    prepared = edge_call(edge_url, secret, {
        "source": "EXCEL_API", "operation": "prepare", "batch_id": batch_id,
    })
    batch = prepared.get("batch") or {}
    state = str(batch.get("state") or "").upper()
    if state == "COMMITTED":
        return batch
    if state == "DRAFT":
        staged_rows = 0
        for index in range(0, len(records), CHUNK_ROWS):
            staged = edge_call(edge_url, secret, {
                "source": "EXCEL_API", "operation": "stage", "batch_id": batch_id,
                "records": records[index:index + CHUNK_ROWS],
            })
            staged_rows = int(staged.get("staged_rows") or 0)
        if staged_rows != len(records):
            raise SyncError(f"STAGING_INCOMPLETO:{staged_rows}:{len(records)}")

    max_calls = max(10, (len(records) + CHUNK_ROWS - 1) // CHUNK_ROWS + 10)
    for _ in range(max_calls):
        status = edge_call(edge_url, secret, {
            "source": "EXCEL_API", "operation": "status", "batch_id": batch_id,
        }).get("batch") or {}
        state = str(status.get("state") or "").upper()
        if state in {"PREVIEWED", "COMMITTING", "COMMITTED"}:
            break
        if state != "DRAFT":
            raise SyncError(f"ESTADO_VALIDACAO_INESPERADO:{state or 'AUSENTE'}")
        validated = edge_call(edge_url, secret, {
            "source": "EXCEL_API", "operation": "validate", "batch_id": batch_id,
        })
        if validated.get("done"):
            state = str((validated.get("batch") or {}).get("state") or "").upper()
            break
    else:
        raise SyncError("VALIDACAO_NAO_CONCLUIDA")

    if state == "COMMITTED":
        return status
    if state not in {"PREVIEWED", "COMMITTING"}:
        raise SyncError(f"LOTE_SEM_LINHAS_VALIDAS:{state or 'AUSENTE'}")

    for _ in range(max_calls):
        committed = edge_call(edge_url, secret, {
            "source": "EXCEL_API", "operation": "commit", "batch_id": batch_id,
        })
        if committed.get("done"):
            result = committed.get("batch") or {}
            if str(result.get("state") or "").upper() != "COMMITTED":
                raise SyncError("COMMIT_RETORNOU_ESTADO_INVALIDO")
            return result
    raise SyncError("COMMIT_NAO_CONCLUIDO")


def synchronize() -> dict[str, Any]:
    client_id = required_env("MS_GRAPH_CLIENT_ID")
    refresh_token = required_env("MS_GRAPH_REFRESH_TOKEN")
    workbook_name = required_env("ONEDRIVE_WORKBOOK_NAME")
    folder_path = (os.environ.get("ONEDRIVE_FOLDER_PATH") or "IPS CRM Excel Sync").strip()
    edge_url = required_env("DATA_SYNC_EDGE_URL")
    sync_secret = required_env("DATA_SYNC_SCHEDULER_SECRET")
    token = access_token(client_id, refresh_token)
    before = locate_workbook(token, workbook_name, folder_path)

    with tempfile.TemporaryDirectory(prefix="ips-excel-sync-") as temp_dir:
        source = Path(temp_dir, "master.xlsx")
        download_workbook(token, before, source)
        after = graph_json(
            f"/me/drive/items/{urllib.parse.quote(str(before['id']), safe='')}?$select=id,size,eTag,lastModifiedDateTime",
            token,
        )
        for field in ("size", "eTag", "lastModifiedDateTime"):
            if after.get(field) != before.get(field):
                raise SyncError("EXCEL_ALTERADO_DURANTE_DOWNLOAD")
        try:
            formula_audit = excel_formula_audit.audit(source)
        except Exception as error:
            raise SyncError(f"FORMULAS_INVALIDAS:{error}") from error
        print(json.dumps({"formula_audit": formula_audit}, ensure_ascii=False, separators=(",", ":")), file=sys.stderr)
        payload = excel_payload.build(source, str(before.get("lastModifiedDateTime") or ""))
        metadata = {key: payload[key] for key in (
            "source_name", "source_version", "source_updated_at", "file_hash", "original_filename", "file_size"
        )}
        metadata["original_filename"] = workbook_name
        created = edge_call(edge_url, sync_secret, {"source": "EXCEL_API", "operation": "create", "metadata": metadata})
        batch_id = str(created.get("batch_id") or "")
        if not batch_id:
            raise SyncError("LOTE_NAO_CRIADO")
        completed = process_batch(edge_url, sync_secret, batch_id, payload["records"])
        fiscal_bases = payload.get("fiscal_bases") or {"ncm_rules": [], "group_rules": []}
        fiscal_result = edge_call(edge_url, sync_secret, {
            "source": "EXCEL_API",
            "operation": "fiscal-bases",
            "source_version": payload["source_version"],
            "source_updated_at": payload["source_updated_at"],
            "ncm_rules": fiscal_bases.get("ncm_rules") or [],
            "group_rules": fiscal_bases.get("group_rules") or [],
        })
        return {
            "duplicate": bool(created.get("duplicate")), "batch_id": batch_id,
            "summary": payload["summary"], "result": completed, "fiscal_bases": fiscal_result,
        }


def main() -> None:
    try:
        result = synchronize()
        print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))
    except Exception as error:
        message = str(error) if isinstance(error, SyncError) else f"FALHA_SINCRONIZACAO:{type(error).__name__}"
        print(json.dumps({"ok": False, "error": message}, ensure_ascii=False, separators=(",", ":")))
        raise SystemExit(1) from error


if __name__ == "__main__":
    main()
