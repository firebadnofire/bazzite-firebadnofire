#!/usr/bin/env python3
"""Exercise verifier failure policy without requiring Hyprland or root."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


HELPER = Path(__file__).resolve().parents[1] / (
    "system_files/usr/libexec/bazzite-firebadnofire-verify-hyprland"
)


class VerificationPolicy(unittest.TestCase):
    def run_helper(self, mode="valid", missing=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            # Fake only the privilege boundary and verifier. The helper's actual
            # status handling, log checks, control ordering and cleanup execute.
            programs = {
                "Hyprland": "#!/bin/sh\nexit 99\n",
                "id": "#!/bin/sh\necho 0\n",
                "rpm": "#!/bin/sh\necho hyprland-0.57.0-2.fc44.x86_64\n",
                "chown": "#!/bin/sh\nexit 0\n",
                "setpriv": '''#!/usr/bin/env python3
import os, sys
from pathlib import Path
path = sys.argv[-1]
control = Path(path).name
mode = os.environ['TEST_MODE']
if mode == 'crash': sys.exit(139)
if mode == 'timeout': sys.exit(124)
if mode == 'dependency': sys.exit(127)
if mode == 'false-success': sys.exit(0)
if mode == 'accept-invalid':
    print('config ok')
    sys.exit(0)
if control in ('syntax.lua', 'semantic.lua'):
    print(path + ':1: configuration error')
    sys.exit(1)
if mode == 'syntax' and control == 'shipped.lua':
    print(path + ':1: syntax error near bad')
    sys.exit(1)
if mode == 'semantic' and control == 'shipped.lua':
    print(path + ':1: error setting general.border_size')
    sys.exit(1)
print('config ok')
''',
            }
            for name, source in programs.items():
                path = root / name
                path.write_text(source)
                path.chmod(0o755)
            config = root / "shipped.lua"
            if not missing:
                config.write_text("-- test config\n")
            return subprocess.run(
                ["bash", str(HELPER), str(config)],
                env={**os.environ, "PATH": f"{root}:{os.environ['PATH']}", "TEST_MODE": mode},
                text=True, capture_output=True, check=False,
            )

    def test_valid(self):
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_reject_failures(self):
        for mode, diagnostic in (
            ("crash", "crashed/terminated"),
            ("timeout", "timed out"),
            ("dependency", "environment/dependency failure"),
            ("false-success", "without confirming config ok"),
            ("accept-invalid", "negative control"),
            ("syntax", "invalid Lua syntax"),
            ("semantic", "configuration validation or environment failed"),
        ):
            with self.subTest(mode=mode):
                result = self.run_helper(mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(diagnostic, result.stderr)

    def test_missing(self):
        result = self.run_helper(missing=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing or empty configuration", result.stderr)


if __name__ == "__main__":
    unittest.main()
