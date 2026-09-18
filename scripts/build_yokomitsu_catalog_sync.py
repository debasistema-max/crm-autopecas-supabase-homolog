#!/usr/bin/env python3
"""Baixa o catálogo público Yokomitsu e gera SQL auditável para a homologação."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

API_URL = "https://www.yokomitsu.com.br/api/catalog/products"
OFFICIAL_ORIGIN = "https://www.yokomitsu.com.br"


def fetch_page(page: int, timeout: int) -> dict:
    query = urllib.parse.urlencode({"page": page, "limit": 48})
    request = urllib.request.Request(
        f"{API_URL}?{query}", headers={"Accept": "application/json", "User-Agent": "IPS-CRM-Catalog-Sync/1.0"}
    )
    last_error = None
    for attempt in range(4):
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                if response.status != 200:
                    raise RuntimeError(f"API retornou HTTP {response.status} na página {page}")
                payload = json.load(response)
            break
        except (urllib.error.URLError, TimeoutError, ConnectionError, RuntimeError) as error:
            last_error = error
            if attempt == 3:
                raise RuntimeError(f"Falha ao consultar a página {page} após 4 tentativas: {error}") from error
            time.sleep(1 + attempt)
    else:
        raise RuntimeError(f"Falha ao consultar a página {page}: {last_error}")
    data = payload.get("data")
    if not isinstance(data, dict) or not isinstance(data.get("products"), list):
        raise RuntimeError(f"Resposta inválida na página {page}")
    return data


def normalize_product(item: dict) -> dict | None:
    code = str(item.get("code") or "").strip()
    if not code:
        return None
    applications = item.get("applicationPreview") or []
    if not isinstance(applications, list):
        applications = [applications]
    image_url = str(item.get("primaryImageUrl") or "").strip()
    if image_url.startswith("/uploads/products/"):
        image_url = OFFICIAL_ORIGIN + image_url
    if not image_url.startswith(OFFICIAL_ORIGIN + "/uploads/products/"):
        image_url = f"{OFFICIAL_ORIGIN}/uploads/products/{code}/site/{code}.webp" if code.isdigit() else ""
    return {
        "product_code": code,
        "product_name": str(item.get("name") or "").strip() or None,
        "line_name": str(item.get("productLineName") or "").strip() or None,
        "line_slug": str(item.get("productLineSlug") or "").strip() or None,
        "applications": " • ".join(str(value).strip() for value in applications if str(value).strip()) or None,
        "official_image_url": image_url or None,
        "source_product_updated_at": str(item.get("updatedAt") or "").strip() or None,
    }


def build_records(timeout: int) -> list[dict]:
    first = fetch_page(1, timeout)
    pages = max(int(first.get("pages") or 1), 1)
    records = [value for item in first["products"] if (value := normalize_product(item))]
    for page in range(2, pages + 1):
        data = fetch_page(page, timeout)
        records.extend(value for item in data["products"] if (value := normalize_product(item)))
    unique = {record["product_code"]: record for record in records}
    return [unique[code] for code in sorted(unique)]


def build_sql(records: list[dict]) -> tuple[str, str]:
    compact = json.dumps(records, ensure_ascii=False, separators=(",", ":"))
    source_version = hashlib.sha256(compact.encode("utf-8")).hexdigest()
    if "$catalog$" in compact:
        raise RuntimeError("Payload contém delimitador SQL reservado")
    sql = (
        "begin;\n"
        "select public.sync_yokomitsu_catalog_metadata(\n"
        f"$catalog${compact}$catalog$::jsonb,\n'{source_version}'\n);\n"
        "commit;\n"
    )
    return sql, source_version


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--timeout", type=int, default=30)
    args = parser.parse_args()
    records = build_records(args.timeout)
    if not records:
        raise RuntimeError("Catálogo público não retornou produtos")
    sql, source_version = build_sql(records)
    args.output.write_text(sql, encoding="utf-8")
    print(json.dumps({"records": len(records), "source_version": source_version, "output": str(args.output)}))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"ERRO: {error}", file=sys.stderr)
        raise SystemExit(1)
