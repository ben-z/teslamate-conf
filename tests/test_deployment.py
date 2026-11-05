import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


render = module("render", "deploy/render.py")
verify = module("verify", "deploy/verify-images.py")
SETTINGS = {
    "GATEWAY_IMAGE": "ghcr.io/ben-z/teslamate-gateway@sha256:" + "a" * 64,
    "BACKUP_IMAGE": "ghcr.io/ben-z/teslamate-backup@sha256:" + "b" * 64,
    "SOURCE_SHA": "c" * 40,
    "AZURE_TENANT_ID": "11111111-1111-1111-1111-111111111111",
    "TESLAMATE_SECRET_IDENTITY_CLIENT_ID": "22222222-2222-2222-2222-222222222222",
    "TESLAMATE_KEY_VAULT_NAME": "teslamate-test-vault",
    "TESLAMATE_BACKUP_ACCOUNT": "tmbackuptest",
    "TESLAMATE_MODE": "prepare",
}


def resources(mode="prepare"):
    return list(yaml.safe_load_all(render.render({**SETTINGS, "TESLAMATE_MODE": mode})))


class DeploymentTests(unittest.TestCase):
    def test_preparation_cannot_start_loggers_or_back_up_empty_database(self):
        objects = {(r["kind"], r["metadata"]["name"]): r for r in resources()}
        for name in ("teslamate", "grafana"):
            self.assertEqual(objects["Deployment", name]["spec"]["replicas"], 0)
            self.assertEqual(objects["Deployment", name]["spec"]["strategy"]["type"], "Recreate")
        self.assertTrue(objects["CronJob", "database-backup"]["spec"]["suspend"])
        self.assertEqual(objects["StatefulSet", "database"]["spec"]["replicas"], 1)

    def test_activation_enables_one_logger_and_scheduled_backups(self):
        objects = {(r["kind"], r["metadata"]["name"]): r for r in resources("active")}
        self.assertEqual(objects["Deployment", "teslamate"]["spec"]["replicas"], 1)
        self.assertEqual(objects["Deployment", "grafana"]["spec"]["replicas"], 1)
        self.assertFalse(objects["CronJob", "database-backup"]["spec"]["suspend"])

    def test_missing_settings_and_manifest_injection_are_rejected(self):
        for key in SETTINGS:
            with self.subTest(key=key):
                incomplete = dict(SETTINGS)
                del incomplete[key]
                with self.assertRaises(ValueError):
                    render.render(incomplete)
                with self.assertRaises(ValueError):
                    render.render({**SETTINGS, key: SETTINGS[key] + "\nkind: Secret"})
        with self.assertRaises(ValueError):
            render.render({**SETTINGS, "TESLAMATE_MODE": "true"})

    def test_platform_isolation_and_restricted_pods(self):
        for resource in resources():
            self.assertEqual(resource["metadata"]["namespace"], "teslamate")
            self.assertNotIn(resource["kind"], ("Namespace", "Secret", "ClusterRole", "ClusterRoleBinding"))
            if resource["kind"] == "Service":
                self.assertEqual(resource["spec"].get("type", "ClusterIP"), "ClusterIP")
                self.assertNotIn("externalIPs", resource["spec"])
            if resource["kind"] == "Ingress":
                self.assertEqual(resource["spec"]["ingressClassName"], "tailnet")
                self.assertEqual([r["host"] for r in resource["spec"]["rules"]], ["teslamate.benzhang.dev"])
                self.assertNotIn("annotations", resource["metadata"])
            if resource["kind"] in ("Deployment", "StatefulSet", "CronJob"):
                pod = verify.pod_spec(resource)
                self.assertEqual(pod["nodeSelector"], {"unicorns.dev/workload": "applications"})
                self.assertTrue(pod["securityContext"]["runAsNonRoot"])
                self.assertEqual(pod["securityContext"]["seccompProfile"]["type"], "RuntimeDefault")
                for container in pod["containers"]:
                    self.assertIn("@sha256:", container["image"])
                    self.assertFalse(container["securityContext"]["allowPrivilegeEscalation"])
                    self.assertEqual(container["securityContext"]["capabilities"]["drop"], ["ALL"])

    def test_upstream_images_match_running_compose_versions(self):
        compose = yaml.safe_load((ROOT / "docker-compose.yml").read_text())["services"]
        for resource in resources():
            if resource["kind"] in ("Deployment", "StatefulSet"):
                name = resource["metadata"]["name"]
                if name in compose:
                    self.assertEqual(verify.pod_spec(resource)["containers"][0]["image"], compose[name]["image"])

    def test_deployer_has_no_secret_or_exec_or_cluster_admin_permission(self):
        rbac = list(yaml.safe_load_all((ROOT / "deploy/bootstrap/namespace-rbac.yaml").read_text()))
        self.assertEqual(rbac[0]["metadata"]["labels"]["unicorns.dev/satellite"], "true")
        role = next(item for item in rbac if item["kind"] == "Role")
        for rule in role["rules"]:
            self.assertNotIn("*", rule["resources"])
            self.assertNotIn("secrets", rule["resources"])
            self.assertNotIn("pods/exec", rule["resources"])
            self.assertNotIn("namespaces", rule["resources"])

    def test_image_and_activation_verification_detect_drift(self):
        expected = resources()
        live = [copy.deepcopy(r) for r in expected if r["kind"] in ("Deployment", "StatefulSet", "CronJob")]
        verify.verify(expected, live)
        for resource in live:
            original = verify.pod_spec(resource)["containers"][0]["image"]
            verify.pod_spec(resource)["containers"][0]["image"] = "unexpected:latest"
            with self.assertRaises(ValueError):
                verify.verify(expected, live)
            verify.pod_spec(resource)["containers"][0]["image"] = original
        logger = next(item for item in live if item["metadata"]["name"] == "teslamate")
        logger["spec"]["replicas"] = 1
        with self.assertRaises(ValueError):
            verify.verify(expected, live)

    def test_workflow_builds_both_native_architectures_and_keeps_runtime_secrets_out(self):
        workflow = yaml.safe_load((ROOT / ".github/workflows/deploy.yml").read_text())
        jobs = workflow["jobs"]
        matrix = jobs["build"]["strategy"]["matrix"]
        self.assertEqual(matrix["image"], ["gateway", "backup"])
        self.assertEqual(matrix["architecture"], ["amd64", "arm64"])
        self.assertEqual(jobs["deploy"]["environment"], "production")
        self.assertEqual(jobs["deploy"]["permissions"], {"contents": "read", "id-token": "write"})
        self.assertNotIn("secrets.", json.dumps(workflow))


class BackupScriptTests(unittest.TestCase):
    def test_existing_archive_is_never_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "database.dump"
            path.write_bytes(b"existing backup")
            result = subprocess.run([str(ROOT / "scripts/backup.sh"), "compose", str(path)], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(path.read_bytes(), b"existing backup")


if __name__ == "__main__":
    unittest.main()
