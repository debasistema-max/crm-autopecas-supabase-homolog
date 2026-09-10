#!/usr/bin/env python3
"""Minimal authenticated HTTP adapter for a locally synchronized master XLSX."""

from __future__ import annotations

import importlib.util
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("build_excel_sync_payload.py")
SPEC = importlib.util.spec_from_file_location("excel_payload", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("Não foi possível carregar o normalizador do Excel.")
excel_payload = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(excel_payload)


class Handler(BaseHTTPRequestHandler):
    server_version = "IPSExcelAdapter/1.0"

    def log_message(self, pattern, *args):
        print(f"{self.address_string()} - {pattern % args}")

    def send_json(self, status: int, body: dict):
        encoded = json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(encoded)

    def authorized(self) -> bool:
        expected = os.environ.get("DATA_SYNC_ADAPTER_TOKEN", "")
        supplied = self.headers.get("Authorization", "")
        return bool(expected and supplied == f"Bearer {expected}")

    def do_GET(self):
        if self.path != "/health":
            return self.send_json(404, {"error": "NAO_ENCONTRADO"})
        source = Path(os.environ.get("EXCEL_MASTER_PATH", ""))
        self.send_json(200 if source.is_file() else 503, {
            "status": "ok" if source.is_file() else "source_unavailable",
            "source_available": source.is_file()
        })

    def do_POST(self):
        if self.path not in ("/", "/sync"):
            return self.send_json(404, {"error": "NAO_ENCONTRADO"})
        if not self.authorized():
            return self.send_json(401, {"error": "NAO_AUTORIZADO"})
        source = Path(os.environ.get("EXCEL_MASTER_PATH", ""))
        if not source.is_file():
            return self.send_json(503, {"error": "EXCEL_INDISPONIVEL"})
        try:
            self.send_json(200, excel_payload.build(source.resolve()))
        except Exception as error:
            print(f"Falha ao normalizar a origem: {type(error).__name__}: {error}")
            self.send_json(422, {"error": "FONTE_INVALIDA"})


def main():
    host = os.environ.get("DATA_SYNC_ADAPTER_HOST", "127.0.0.1")
    port = int(os.environ.get("DATA_SYNC_ADAPTER_PORT", "8788"))
    if not os.environ.get("DATA_SYNC_ADAPTER_TOKEN"):
        raise SystemExit("DATA_SYNC_ADAPTER_TOKEN é obrigatório.")
    if not os.environ.get("EXCEL_MASTER_PATH"):
        raise SystemExit("EXCEL_MASTER_PATH é obrigatório.")
    print(f"Excel adapter ativo em http://{host}:{port}; origem configurada e token oculto.")
    ThreadingHTTPServer((host, port), Handler).serve_forever()


if __name__ == "__main__":
    main()
