#!/usr/bin/env python3
"""Upload a verified PostgreSQL archive to Azure Blob using workload identity."""

import base64
from datetime import datetime, timezone
from email.utils import formatdate
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen
from uuid import uuid4


def request(method, url, data=None, headers=None):
    for attempt in range(4):
        try:
            with urlopen(Request(url, data=data, headers=headers or {}, method=method), timeout=60) as response:
                return response.read(), response.headers
        except HTTPError as error:
            if error.code not in (408, 429, 500, 502, 503, 504) or attempt == 3:
                raise
        except (URLError, TimeoutError):
            if attempt == 3:
                raise
        time.sleep(2 ** attempt)
    raise RuntimeError("Request retry limit reached")


def access_token():
    tenant = os.environ["AZURE_TENANT_ID"]
    client = os.environ["AZURE_CLIENT_ID"]
    assertion = Path(os.environ["AZURE_FEDERATED_TOKEN_FILE"]).read_text().strip()
    body = urlencode({
        "client_id": client,
        "scope": "https://storage.azure.com/.default",
        "grant_type": "client_credentials",
        "client_assertion_type": "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
        "client_assertion": assertion,
    }).encode()
    response, _ = request("POST", f"https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token",
                          body, {"Content-Type": "application/x-www-form-urlencoded"})
    return json.loads(response)["access_token"]


def upload(path, url, token):
    headers = {
        "Authorization": f"Bearer {token}",
        "x-ms-version": "2023-11-03",
        "x-ms-date": formatdate(usegmt=True),
    }
    blocks = []
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as archive:
        while chunk := archive.read(8 * 1024 * 1024):
            identifier = base64.b64encode(f"{len(blocks):08d}".encode()).decode()
            checksum = base64.b64encode(hashlib.md5(chunk, usedforsecurity=False).digest()).decode()
            request("PUT", url + "?" + urlencode({"comp": "block", "blockid": identifier}),
                    chunk, {**headers, "Content-MD5": checksum})
            blocks.append(identifier)
            digest.update(chunk)
            size += len(chunk)
    if not blocks:
        raise ValueError("Refusing to upload an empty archive")
    sha256 = digest.hexdigest()
    block_list = ("<?xml version='1.0' encoding='utf-8'?><BlockList>" +
                  "".join(f"<Latest>{identifier}</Latest>" for identifier in blocks) +
                  "</BlockList>").encode()
    request("PUT", url + "?comp=blocklist", block_list, {
        **headers,
        "Content-Type": "application/xml",
        "If-None-Match": "*",
        "x-ms-meta-sha256": sha256,
        "x-ms-blob-content-type": "application/octet-stream",
    })
    _, stored = request("HEAD", url, headers=headers)
    if int(stored["Content-Length"]) != size or stored["x-ms-meta-sha256"] != sha256:
        raise RuntimeError("Stored backup size or SHA-256 metadata does not match")
    return sha256, size


def main():
    os.umask(0o077)
    account = os.environ["BACKUP_ACCOUNT"]
    if not re.fullmatch(r"[a-z0-9]{3,24}", account):
        raise ValueError("Invalid BACKUP_ACCOUNT")
    secrets = Path("/mnt/secrets-store")
    environment = {**os.environ, "PGUSER": (secrets / "database-user").read_text(),
                   "PGPASSWORD": (secrets / "database-password").read_text()}
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    name = f"teslamate-{timestamp}-{uuid4().hex}.dump"
    with tempfile.TemporaryDirectory(prefix="teslamate-backup-") as directory:
        archive = Path(directory) / name
        subprocess.run(["pg_dump", "--format=custom", "--file", str(archive)], env=environment, check=True)
        subprocess.run(["pg_restore", "--list", str(archive)], check=True, stdout=subprocess.DEVNULL)
        url = f"https://{account}.blob.core.windows.net/teslamate/{name}"
        sha256, size = upload(archive, url, access_token())
        print(f"Verified backup: {name} bytes={size} sha256={sha256}")


if __name__ == "__main__":
    main()
