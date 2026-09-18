#!/usr/bin/env python3
"""Baixa o catálogo público Yokomitsu e gera SQL auditável para a homologação."""

from __future__ import annotations

import argparse
import concurrent.futures
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


def fetch_json(url: str, timeout: int) -> dict:
    request = urllib.request.Request(
        url, headers={"Accept": "application/json", "User-Agent": "IPS-CRM-Catalog-Sync/1.1"}
    )
    last_error = None
    for attempt in range(4):
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                if response.status != 200:
                    raise RuntimeError(f"API retornou HTTP {response.status}")
                return json.load(response)
        except (urllib.error.URLError, TimeoutError, ConnectionError, RuntimeError) as error:
            last_error = error
            if attempt == 3:
                break
            time.sleep(1 + attempt)
    raise RuntimeError(f"Falha ao consultar {url} após 4 tentativas: {last_error}")


def fetch_page(page: int, timeout: int) -> dict:
    query = urllib.parse.urlencode({"page": page, "limit": 48})
    payload = fetch_json(f"{API_URL}?{query}", timeout)
    data = payload.get("data")
    if not isinstance(data, dict) or not isinstance(data.get("products"), list):
        raise RuntimeError(f"Resposta inválida na página {page}")
    return data


def fetch_detail(code: str, timeout: int) -> dict:
    payload = fetch_json(f"{API_URL}/{urllib.parse.quote(code, safe='')}", timeout)
    data = payload.get("data")
    if not isinstance(data, dict) or str(data.get("code") or "").strip() != code:
        raise RuntimeError(f"Detalhe inválido para o produto {code}")
    return data


def normalized_applications(detail: dict) -> list[dict]:
    rows = detail.get("applications") or []
    if not isinstance(rows, list):
        return []
    result = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        normalized = {
            "automaker": str(row.get("automaker") or "").strip() or None,
            "vehicle": str(row.get("vehicleLabel") or "").strip() or None,
            "engine": str(row.get("engineLabel") or "").strip() or None,
            "year": str(row.get("yearLabel") or "").strip() or None,
            "notes": str(row.get("notes") or "").strip() or None,
        }
        if any(normalized.values()):
            result.append(normalized)
    return result


def application_text(applications: list[dict]) -> str | None:
    values = []
    for row in applications:
        value = " ".join(
            part for key in ("automaker", "vehicle", "engine", "year")
            if (part := str(row.get(key) or "").strip())
        )
        if row.get("notes"):
            value = f"{value} ({row['notes']})".strip()
        if value:
            values.append(value)
    return " • ".join(values) or None


def normalized_references(detail: dict, key: str) -> list[dict]:
    rows = detail.get(key) or []
    if not isinstance(rows, list):
        return []
    result = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        label = str(row.get("label") or "").strip()
        if label:
            result.append({"label": label, "support": str(row.get("support") or "").strip() or None})
    return result


def normalize_product(item: dict, detail: dict | None = None) -> dict | None:
    code = str(item.get("code") or "").strip()
    if not code:
        return None
    preview = item.get("applicationPreview") or []
    if not isinstance(preview, list):
        preview = [preview]
    image_url = str(item.get("primaryImageUrl") or "").strip()
    if image_url.startswith("/uploads/products/"):
        image_url = OFFICIAL_ORIGIN + image_url
    if not image_url.startswith(OFFICIAL_ORIGIN + "/uploads/products/"):
        image_url = f"{OFFICIAL_ORIGIN}/uploads/products/{code}/site/{code}.webp" if code.isdigit() else ""
    record = {
        "product_code": code,
        "product_name": str((detail or {}).get("name") or item.get("name") or "").strip() or None,
        "line_name": str((detail or {}).get("productLineName") or item.get("productLineName") or "").strip() or None,
        "line_slug": str((detail or {}).get("productLineSlug") or item.get("productLineSlug") or "").strip() or None,
        "applications": " • ".join(str(value).strip() for value in preview if str(value).strip()) or None,
        "applications_complete": False,
        "official_image_url": image_url or None,
        "source_product_updated_at": str(item.get("updatedAt") or "").strip() or None,
    }
    if detail is not None:
        applications = normalized_applications(detail)
        record["applications"] = application_text(applications) or record["applications"]
        record["applications_complete"] = True
        record["catalog_details"] = {
            "details": str(detail.get("detailsRaw") or "").strip() or None,
            "applications": applications,
            "oem_references": normalized_references(detail, "oemReferences"),
            "similar_references": normalized_references(detail, "similarReferences"),
            "ean_gtin": str(detail.get("eanGtin") or "").strip() or None,
            "weight_kg": detail.get("weightKg"),
            "height_cm": detail.get("heightCm"),
            "width_cm": detail.get("widthCm"),
            "length_cm": detail.get("lengthCm"),
            "volume_m3": detail.get("volumeM3"),
            "source_url": f"{OFFICIAL_ORIGIN}/produtos/{urllib.parse.quote(code, safe='')}",
        }
    return record


def build_records(timeout: int, include_details: bool = True, workers: int = 6) -> list[dict]:
    first = fetch_page(1, timeout)
    pages = max(int(first.get("pages") or 1), 1)
    items = list(first["products"])
    for page in range(2, pages + 1):
        data = fetch_page(page, timeout)
        items.extend(data["products"])
    unique_items = {str(item.get("code") or "").strip(): item for item in items if str(item.get("code") or "").strip()}
    details: dict[str, dict] = {}
    if include_details:
        with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, min(workers, 12))) as executor:
            futures = {executor.submit(fetch_detail, code, timeout): code for code in unique_items}
            for future in concurrent.futures.as_completed(futures):
                code = futures[future]
                try:
                    details[code] = future.result()
                except Exception as error:
                    print(f"AVISO: detalhe {code} não sincronizado: {error}", file=sys.stderr)
    records = [normalize_product(unique_items[code], details.get(code)) for code in sorted(unique_items)]
    return [record for record in records if record]


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
    parser.add_argument("--workers", type=int, default=6)
    parser.add_argument("--summary-only", action="store_true")
    args = parser.parse_args()
    records = build_records(args.timeout, include_details=not args.summary_only, workers=args.workers)
    if not records:
        raise RuntimeError("Catálogo público não retornou produtos")
    sql, source_version = build_sql(records)
    args.output.write_text(sql, encoding="utf-8")
    detailed = sum(1 for record in records if record.get("catalog_details"))
    print(json.dumps({"records": len(records), "detailed": detailed, "source_version": source_version, "output": str(args.output)}))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"ERRO: {error}", file=sys.stderr)
        raise SystemExit(1)
