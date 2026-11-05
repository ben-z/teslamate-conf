#!/usr/bin/env python3
"""Copy the existing Compose credentials directly to the app's Key Vault."""

import argparse
import json
from pathlib import Path
import secrets
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def az(*arguments):
    return subprocess.run(["az", *arguments, "--only-show-errors"], check=True,
                          text=True, stdout=subprocess.PIPE).stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vault-name", required=True)
    parser.add_argument("--env-file", type=Path, default=ROOT / ".env")
    parser.add_argument("--compose-stdin", action="store_true",
                        help="Read Compose JSON streamed over SSH to the operator host")
    args = parser.parse_args()
    if args.compose_stdin:
        config = json.load(sys.stdin)
    else:
        result = subprocess.run(["docker", "compose", "--env-file", str(args.env_file.resolve()),
                                 "config", "--format", "json"], cwd=ROOT, check=True,
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        config = json.loads(result.stdout)
    environment = config["services"]["teslamate"]["environment"]
    values = {
        "teslamate-encryption-key": environment["ENCRYPTION_KEY"],
        "teslamate-database-user": environment["DATABASE_USER"],
        "teslamate-database-password": environment["DATABASE_PASS"],
    }
    if any(not value or value in ("<encryption_key>", "<username>", "<password>")
           for value in values.values()):
        raise ValueError("Replace the example credentials before populating Key Vault")
    existing = set(json.loads(az("keyvault", "secret", "list", "--vault-name", args.vault_name,
                                "--query", "[].name", "--output", "json")))
    # Check all existing values before writing anything; never rotate credentials during migration.
    for name, value in values.items():
        if name in existing:
            saved = json.loads(az("keyvault", "secret", "show", "--vault-name", args.vault_name,
                                 "--name", name, "--query", "value", "--output", "json"))
            if saved != value:
                raise ValueError(f"Existing {name} differs; refusing to replace it")
    values["teslamate-grafana-admin-password"] = secrets.token_urlsafe(48)
    values["teslamate-mqtt-password"] = secrets.token_urlsafe(48)
    with tempfile.TemporaryDirectory(prefix="teslamate-secrets-") as directory:
        for name, value in values.items():
            if name in existing:
                continue
            path = Path(directory) / name
            path.touch(mode=0o600)
            path.write_text(value)
            az("keyvault", "secret", "set", "--vault-name", args.vault_name,
               "--name", name, "--file", str(path), "--output", "none")
    print("Compose credentials preserved in Key Vault. No credential values were printed.")
    print("A restored Grafana database retains its existing administrator password.")


if __name__ == "__main__":
    main()
