#!/usr/bin/env python3
"""Authorize a personal OneDrive and store its refresh token in GitHub Secrets.

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
GRAPH_APP_ROOT = "https://graph.microsoft.com/v1.0/me/drive/special/approot?$select=id,name"
SCOPES = "offline_access Files.ReadWrite.AppFolder"


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
    print("Entre com a conta que possui o OneDrive e confirme apenas a pasta do aplicativo.", flush=True)

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


def create_app_folder(access_token: str) -> str:
    request = urllib.request.Request(GRAPH_APP_ROOT, headers={"Authorization": f"Bearer {access_token}"})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            result = json.loads(response.read())
    except urllib.error.HTTPError as error:
        raise RuntimeError(f"PASTA_DO_APLICATIVO_HTTP_{error.code}") from error
    if not result.get("id"):
        raise RuntimeError("PASTA_DO_APLICATIVO_NAO_CRIADA")
    return str(result.get("name") or "IPS CRM Excel Sync")


def store_github_secret(repo: str, refresh_token: str) -> None:
    subprocess.run(
        ["gh", "secret", "set", "MS_GRAPH_REFRESH_TOKEN", "--repo", repo],
        input=refresh_token, text=True, check=True,
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--client-id", required=True)
    parser.add_argument("--repo", required=True)
    args = parser.parse_args()
    access_token, refresh_token = authorize(args.client_id)
    folder_name = create_app_folder(access_token)
    store_github_secret(args.repo, refresh_token)
    print(f"Autorização concluída. Pasta privada do aplicativo: Aplicativos/{folder_name}")
    print("O refresh token foi salvo diretamente no GitHub Secrets e não foi exibido.")


if __name__ == "__main__":
    main()
