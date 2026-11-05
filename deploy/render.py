#!/usr/bin/env python3
"""Render non-secret deployment settings. Runtime secrets stay in Key Vault."""

import os
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent
UUID = r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}"
PATTERNS = {
    "GATEWAY_IMAGE": r"ghcr\.io/ben-z/teslamate-gateway@sha256:[0-9a-f]{64}",
    "BACKUP_IMAGE": r"ghcr\.io/ben-z/teslamate-backup@sha256:[0-9a-f]{64}",
    "SOURCE_SHA": r"[0-9a-f]{40}",
    "AZURE_TENANT_ID": UUID,
    "TESLAMATE_SECRET_IDENTITY_CLIENT_ID": UUID,
    "TESLAMATE_KEY_VAULT_NAME": r"[a-zA-Z][a-zA-Z0-9-]{1,22}[a-zA-Z0-9]",
    "TESLAMATE_BACKUP_ACCOUNT": r"[a-z0-9]{3,24}",
    "TESLAMATE_MODE": r"prepare|active",
}


def render(settings):
    for name, pattern in PATTERNS.items():
        if not re.fullmatch(pattern, settings.get(name, "")):
            raise ValueError(f"Missing or invalid {name}")
    replacements = {f"__{name}__": settings[name] for name in PATTERNS}
    active = settings["TESLAMATE_MODE"] == "active"
    replacements["__LOGGER_REPLICAS__"] = "1" if active else "0"
    replacements["__BACKUP_SUSPEND__"] = "false" if active else "true"
    manifest = (ROOT / "kubernetes/application.yaml").read_text()
    for placeholder, value in replacements.items():
        manifest = manifest.replace(placeholder, value)
    if re.search(r"__[A-Z_]+__", manifest):
        raise ValueError("Unresolved manifest placeholder")
    return manifest


if __name__ == "__main__":
    try:
        print(render(os.environ), end="")
    except ValueError as error:
        sys.exit(str(error))
