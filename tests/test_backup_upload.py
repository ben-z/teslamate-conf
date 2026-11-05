import base64
import hashlib
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlparse
import xml.etree.ElementTree as ET

from test_deployment import module

backup = module("backup", "deploy/backup/backup.py")


class UploadTests(unittest.TestCase):
    def test_multiblock_archive_is_committed_and_integrity_checked(self):
        payload = b"archive" * (2 * 1024 * 1024)
        blocks = {}
        stored = {}

        def request(method, url, data=None, headers=None):
            query = parse_qs(urlparse(url).query)
            if method == "HEAD":
                return b"", {"Content-Length": str(len(stored["bytes"])),
                             "x-ms-meta-sha256": stored["sha256"]}
            if query["comp"] == ["block"]:
                self.assertEqual(base64.b64decode(headers["Content-MD5"]),
                                 hashlib.md5(data, usedforsecurity=False).digest())
                blocks[query["blockid"][0]] = data
            else:
                stored["bytes"] = b"".join(blocks[node.text] for node in ET.fromstring(data))
                stored["sha256"] = headers["x-ms-meta-sha256"]
                self.assertEqual(headers["If-None-Match"], "*")
            return b"", {}

        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "test.dump"
            archive.write_bytes(payload)
            with patch.object(backup, "request", side_effect=request):
                digest, size = backup.upload(archive, "https://test.blob.core.windows.net/teslamate/test.dump", "token")
        self.assertGreater(len(blocks), 1)
        self.assertEqual(stored["bytes"], payload)
        self.assertEqual(digest, hashlib.sha256(payload).hexdigest())
        self.assertEqual(size, len(payload))

    def test_failed_block_is_never_committed(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "test.dump"
            archive.write_bytes(b"archive")
            with patch.object(backup, "request", side_effect=OSError("upload failed")) as request:
                with self.assertRaises(OSError):
                    backup.upload(archive, "https://example.com/backup", "token")
            self.assertEqual(request.call_count, 1)
            self.assertIn("comp=block&", request.call_args.args[1])

    def test_remote_checksum_mismatch_fails_backup(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "test.dump"
            archive.write_bytes(b"archive")
            with patch.object(backup, "request", side_effect=[(b"", {}), (b"", {}),
                              (b"", {"Content-Length": "7", "x-ms-meta-sha256": "wrong"})]):
                with self.assertRaisesRegex(RuntimeError, "does not match"):
                    backup.upload(archive, "https://example.com/backup", "token")


if __name__ == "__main__":
    unittest.main()
