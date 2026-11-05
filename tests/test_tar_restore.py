import io
import tarfile
import unittest

from test_deployment import module

restore = module("tar_restore", "deploy/strip-tar-root.py")


class TarRestoreTests(unittest.TestCase):
    def test_only_mount_root_header_is_removed_and_file_bytes_are_preserved(self):
        source = io.BytesIO()
        payload = b"grafana-database-bytes" * 10000
        with tarfile.open(fileobj=source, mode="w") as archive:
            for name in (".", "./plugins"):
                directory = tarfile.TarInfo(name)
                directory.type = tarfile.DIRTYPE
                directory.mode = 0o755
                archive.addfile(directory)
            file = tarfile.TarInfo("./grafana.db")
            file.size = len(payload)
            file.mode = 0o600
            archive.addfile(file, io.BytesIO(payload))
            link = tarfile.TarInfo("./database-link")
            link.type = tarfile.SYMTYPE
            link.linkname = "grafana.db"
            archive.addfile(link)
        source.seek(0)
        destination = io.BytesIO()
        restore.strip_root(source, destination)
        destination.seek(0)
        with tarfile.open(fileobj=destination) as archive:
            self.assertEqual(archive.getnames(), ["./plugins", "./grafana.db", "./database-link"])
            self.assertEqual(archive.extractfile("./grafana.db").read(), payload)
            self.assertEqual(archive.getmember("./grafana.db").mode, 0o600)
            self.assertEqual(archive.getmember("./database-link").linkname, "grafana.db")


if __name__ == "__main__":
    unittest.main()
