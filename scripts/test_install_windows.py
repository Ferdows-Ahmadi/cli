"""Offline smoke tests for the Windows installer with exact-shape release fixtures."""

import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "install.ps1"
ARCHIVE = "proofline-x86_64-pc-windows-msvc.tar.gz"
POWERSHELL = (
    os.environ.get("PROOFLINE_POWERSHELL")
    or shutil.which("powershell.exe")
    or shutil.which("pwsh")
)


@unittest.skipUnless(POWERSHELL and shutil.which("tar"), "PowerShell and tar are required")
class WindowsInstaller(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="proofline installer ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.release = self.root / "release files"
        self.release.mkdir()
        self.temp = self.root / "temporary staging"
        self.temp.mkdir()
        self.install = self.root / "installed tools"
        self.executable = self.install / "proofline.exe"

    def fixture(self, contents, *, name="proofline.exe", checksum="valid"):
        archive = self.release / ARCHIVE
        with tarfile.open(archive, "w:gz") as tar:
            entry = tarfile.TarInfo(name)
            entry.size = len(contents)
            tar.addfile(entry, io.BytesIO(contents))
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        line = f"{digest}  {ARCHIVE}\n"
        cases = {
            "valid": f"{'0' * 64}  proofline-other.tar.gz\n{line}",
            "binary": f"{digest.upper()} *{ARCHIVE}\n",
            "mismatch": f"{'0' * 64}  {ARCHIVE}\n",
            "missing": f"{digest}  {ARCHIVE}.backup\n",
            "duplicate": line * 2,
        }
        (self.release / "SHA256SUMS").write_text(cases[checksum], encoding="ascii")

    def run_installer(self, *options, local=True, extra_environment=None):
        result = subprocess.run(
            [
                POWERSHELL,
                "-NoLogo",
                "-NoProfile",
                "-NonInteractive",
                "-File",
                str(SCRIPT),
                "-InstallDir",
                str(self.install),
                *(["-ReleaseDirectory", str(self.release)] if local else []),
                *options,
            ],
            capture_output=True,
            text=True,
            timeout=30,
            env={
                **os.environ,
                "TEMP": str(self.temp),
                "TMP": str(self.temp),
                "TMPDIR": str(self.temp),
                **(extra_environment or {}),
            },
        )
        self.assertEqual(list(self.temp.iterdir()), [], result.stderr)
        if self.install.is_dir():
            self.assertEqual(set(self.install.iterdir()), {self.executable}, result.stderr)
        return result

    def test_install_and_upgrade_in_path_with_spaces(self):
        for content, checksum in [(b"fixture version 1", "valid"), (b"fixture version 2", "binary")]:
            self.fixture(content, checksum=checksum)
            result = self.run_installer()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.executable.read_bytes(), content)
            self.assertIn("PATH was not changed", result.stdout)

    def test_rejects_bad_checksums_without_replacing(self):
        self.install.mkdir()
        self.executable.write_bytes(b"old executable")
        for checksum in ("mismatch", "missing", "duplicate"):
            with self.subTest(checksum=checksum):
                self.fixture(b"bad update", checksum=checksum)
                result = self.run_installer()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("SHA256SUMS", result.stderr)
                self.assertEqual(self.executable.read_bytes(), b"old executable")

    def test_rejects_wrong_archive_without_creating_install_directory(self):
        self.fixture(b"not proofline", name="subdirectory/proofline.exe")
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must contain only the root-level", result.stderr)
        self.assertFalse(self.install.exists())

    def test_rejects_empty_executable(self):
        self.fixture(b"")
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("nonempty regular proofline.exe", result.stderr)
        self.assertFalse(self.install.exists())

    def test_local_install_and_explicit_version_are_incompatible(self):
        self.fixture(b"fixture")
        result = self.run_installer("-Version", "0.3.9")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not both", result.stderr)
        self.assertFalse(self.install.exists())

    @unittest.skipUnless(os.name == "nt", "Windows file-sharing semantics")
    def test_locked_executable_is_preserved_on_windows(self):
        self.install.mkdir()
        self.executable.write_bytes(b"old executable")
        self.fixture(b"new executable")
        # The handle denies delete sharing on Windows, like a running executable.
        with self.executable.open("rb") as locked:
            result = self.run_installer()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Close running Proofline", result.stderr)
            self.assertEqual(locked.read(), b"old executable")
        self.assertEqual(self.executable.read_bytes(), b"old executable")

    @unittest.skipIf(os.name == "nt", "POSIX shell mock; Windows uses curl.exe")
    def test_latest_and_pinned_use_one_official_release(self):
        self.fixture(b"offline HTTP fixture")
        mock_bin = self.root / "tools"
        mock_bin.mkdir()
        request_log = self.root / "requests.jsonl"
        mock = mock_bin / "curl"
        mock.write_text(
            f"""#!{sys.executable}
import json, os, pathlib, shutil, sys
arguments = sys.argv[1:]
assert arguments[0] == "--disable"
assert arguments[arguments.index("--proto") + 1] == "=https"
assert arguments[arguments.index("--proto-redir") + 1] == "=https"
output = pathlib.Path(arguments[arguments.index("--output") + 1])
url = arguments[-1]
with open(os.environ["FIXTURE_LOG"], "a") as log:
    print(json.dumps(url), file=log)
if url == "https://api.github.com/repos/prooflinedev/cli/releases/latest":
    output.write_text(json.dumps({{"tag_name": "v1.2.3"}}))
else:
    root = pathlib.Path(os.environ["FIXTURE_RELEASE"])
    shutil.copyfile(root / url.rsplit("/", 1)[1], output)
""",
            encoding="utf-8",
        )
        mock.chmod(0o755)
        environment = {
            "PATH": f"{mock_bin}{os.pathsep}{os.environ['PATH']}",
            "FIXTURE_LOG": str(request_log),
            "FIXTURE_RELEASE": str(self.release),
        }
        for arguments, tag in [((), "v1.2.3"), (("-Version", "2.3.4"), "v2.3.4")]:
            with self.subTest(tag=tag):
                request_log.write_text("", encoding="utf-8")
                result = self.run_installer(*arguments, local=False, extra_environment=environment)
                self.assertEqual(result.returncode, 0, result.stderr)
                base = f"https://github.com/prooflinedev/cli/releases/download/{tag}"
                expected = [
                    f"{base}/SHA256SUMS",
                    f"{base}/{ARCHIVE}",
                ]
                if not arguments:
                    expected.insert(0, "https://api.github.com/repos/prooflinedev/cli/releases/latest")
                self.assertEqual(
                    [json.loads(line) for line in request_log.read_text().splitlines()], expected
                )
                self.assertEqual(self.executable.read_bytes(), b"offline HTTP fixture")


if __name__ == "__main__":
    unittest.main()
