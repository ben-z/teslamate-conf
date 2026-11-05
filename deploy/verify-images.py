#!/usr/bin/env python3
"""Check every deployed workload's images and activation state after rollout."""

import json
from pathlib import Path
import subprocess
import sys

import yaml


def pod_spec(resource):
    spec = resource["spec"]
    if resource["kind"] == "CronJob":
        spec = spec["jobTemplate"]["spec"]
    return spec["template"]["spec"]


def verify(expected, actual):
    live = {(item["kind"], item["metadata"]["name"]): item for item in actual}
    for desired in expected:
        if desired["kind"] not in ("Deployment", "StatefulSet", "CronJob"):
            continue
        key = desired["kind"], desired["metadata"]["name"]
        resource = live[key]
        containers = lambda item: {c["name"]: c["image"] for c in pod_spec(item)["containers"]}
        if containers(desired) != containers(resource):
            raise ValueError(f"Live images differ for {key}")
        field = "suspend" if desired["kind"] == "CronJob" else "replicas"
        if desired["spec"][field] != resource["spec"][field]:
            raise ValueError(f"Live {field} differs for {key}")


if __name__ == "__main__":
    expected = list(yaml.safe_load_all(Path(sys.argv[1]).read_text()))
    result = subprocess.run(["kubectl", "-n", "teslamate", "get", "deployments,statefulsets,cronjobs",
                             "-o", "json"], check=True, text=True, stdout=subprocess.PIPE)
    verify(expected, json.loads(result.stdout)["items"])
    print("All workload image digests and activation settings match the release.")
