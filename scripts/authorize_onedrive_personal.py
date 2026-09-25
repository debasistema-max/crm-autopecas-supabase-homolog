#!/usr/bin/env python3
"""Authorize the dedicated OneDrive workbook and its automatic backup folder.

The refresh token is kept in memory and sent to `gh secret set` through stdin.
It is never printed or written to disk.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request


AUTHORITY = "https://login.microsoftonline.com/consumers/oauth2/v2.0"
GRAPH_ROOT = "https://graph.microsoft.com/v1.0"
SCOPES = "offline_access Files.ReadWrite"


def post_form(url: str, data: dict[str, str]) -> dict:
    encoded = urllib.parse.urlencode(data).encode("ascii")
    request = urllib.request.Request(
        url, data=encoded, headers={"Content-Type": "application/x-www-form-urlencoded"}, method="POST"
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return json.loads(response.read())
    except urllib.error.HTTPError as error:
        body = json.loads(error.read() or b"{}")
        body["_status"] = error.code
        return body


def authorize(client_id: str) -> tuple[str, str]:
    device = post_form(f"{AUTHORITY}/devicecode", {"client_id": client_id, "scope": SCOPES})
    if not device.get("device_code"):
        raise RuntimeError(f"DISPOSITIVO_NAO_AUTORIZADO:{device.get('error', 'UNKNOWN')}")
    print("Abra:", device.get("verification_uri", "https://microsoft.com/devicelogin"), flush=True)
    print("Código:", device.get("user_code", ""), flush=True)
    print(
        "Entre somente com a conta exclusiva da integração e confirme leitura e gravação para os backups.",
        flush=True,
    )

    deadline = time.monotonic() + int(device.get("expires_in", 900))
    interval = max(int(device.get("interval", 5)), 5)
    while time.monotonic() < deadline:
        time.sleep(interval)
        token = post_form(f"{AUTHORITY}/token", {
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            "client_id": client_id,
            "device_code": str(device["device_code"]),
        })
        if token.get("access_token") and token.get("refresh_token"):
            return str(token["access_token"]), str(token["refresh_token"])
        error = token.get("error")
        if error == "authorization_pending":
            continue
        if error == "slow_down":
            interval += 5
            continue
        raise RuntimeError(f"AUTORIZACAO_RECUSADA:{error or 'UNKNOWN'}")
    raise RuntimeError("AUTORIZACAO_EXPIRADA")


def verify_workbook(access_token: str, folder_path: str, workbook_name: str) -> None:
    normalized_path = folder_path.strip().strip("/")
    if not normalized_path or "/" in normalized_path or not workbook_name.lower().endswith(".xlsx"):
        raise RuntimeError("CAMINHO_OU_PLANILHA_INVALIDO")
    headers = {"Authorization": f"Bearer {access_token}"}
    root_fields = urllib.parse.quote("id,name,folder", safe=",")
    try:
        with urllib.request.urlopen(urllib.request.Request(
            f"{GRAPH_ROOT}/me/drive/root/children?$select={root_fields}", headers=headers
        ), timeout=60) as response:
            root_items = json.loads(response.read()).get("value", [])
    except urllib.error.HTTPError as error:
        raise RuntimeError(f"RAIZ_ONEDRIVE_INACESSIVEL:HTTP_{error.code}") from error
    folders = [item for item in root_items if item.get("name") == normalized_path and item.get("folder") is not None]
    if len(folders) != 1:
        raise RuntimeError("PASTA_EXCLUSIVA_NAO_ENCONTRADA")
    folder_id = urllib.parse.quote(str(folders[0].get("id") or ""), safe="")
    fields = urllib.parse.quote("id,name,size,file", safe=",")
    try:
        with urllib.request.urlopen(urllib.request.Request(
            f"{GRAPH_ROOT}/me/drive/items/{folder_id}/children?$select={fields}", headers=headers
        ), timeout=60) as response:
            items = json.loads(response.read()).get("value", [])
    except urllib.error.HTTPError as error:
        raise RuntimeError(f"PASTA_EXCLUSIVA_INACESSIVEL:HTTP_{error.code}") from error
    matches = [item for item in items if item.get("name") == workbook_name and item.get("file")]
    if len(matches) != 1 or int(matches[0].get("size") or 0) <= 0:
        raise RuntimeError("PLANILHA_EXCLUSIVA_NAO_ENCONTRADA")


def store_github_secret(repo: str, refresh_token: str) -> None:
    subprocess.run(
        ["gh", "secret", "set", "MS_GRAPH_REFRESH_TOKEN", "--repo", repo],
        input=refresh_token, text=True, check=True,
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--client-id", required=True)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--folder-path", required=True)
    parser.add_argument("--workbook-name", required=True)
    args = parser.parse_args()
    access_token, refresh_token = authorize(args.client_id)
    verify_workbook(access_token, args.folder_path, args.workbook_name)
    store_github_secret(args.repo, refresh_token)
    print("Autorização de backup validada; token salvo no GitHub Secrets sem ser exibido.")


if __name__ == "__main__":
    main()
