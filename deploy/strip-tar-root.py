#!/usr/bin/env python3
"""Stream a tar archive without its root directory's metadata header."""

import argparse
import posixpath
import sys
import tarfile


def strip_root(source, destination):
    with tarfile.open(fileobj=source, mode="r|*") as original:
        with tarfile.open(fileobj=destination, mode="w|") as output:
            for member in original:
                if member.isdir() and posixpath.normpath(member.name) == ".":
                    continue
                payload = original.extractfile(member) if member.isfile() else None
                output.addfile(member, payload)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive")
    args = parser.parse_args()
    with open(args.archive, "rb") as source:
        strip_root(source, sys.stdout.buffer)
