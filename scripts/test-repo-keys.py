#!/usr/bin/python3
"""Offline regression tests for the image's local-key build gate."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    "repo_keys", Path(__file__).resolve().parents[1] / "build_files/validate-repo-keys.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class RepoKeyTests(unittest.TestCase):
    def test_repo_keys(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            key = root / "key-44"
            key.write_text("test public key")
            repo = root / "test.repo"
            cases = [
                (f"gpgkey=file://{root}/key-$releasever", True),
                (f"gpgkey=https://example.test/key\n file://{root}/key-${{releasever}}", True),
                (f"gpgkey=file://{root}/missing", False),
                (f"enabled=0\ngpgkey=file://{root}/missing", True),
                (f"gpgkey=file://{root}/key-$unknown", False),
                (f"gpgkey=file://{root}/key-44,file://{root}/missing", False),
            ]
            for config, valid in cases:
                with self.subTest(config=config):
                    repo.write_text(f"[test]\n{config}\n")
                    if valid:
                        module.validate(root, {"releasever": "44"})
                    else:
                        with self.assertRaises(ValueError):
                            module.validate(root, {"releasever": "44"})
            key.write_text("")
            repo.write_text(f"[test]\ngpgkey=file://{key}\n")
            with self.assertRaises(ValueError):
                module.validate(root, {})


if __name__ == "__main__":
    unittest.main()
