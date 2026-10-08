"""Native signing regression; temporary apps only, never launched or installed."""
import hashlib
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def run(arguments, *, source=None, check=True):
    result = subprocess.run([str(value) for value in arguments], input=source,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, cwd=ROOT)
    if check:
        assert result.returncode == 0, f"{Path(arguments[0]).name} failed (exit {result.returncode})"
    return result


def requirement(app):
    text = run(["/usr/bin/codesign", "-d", "-r-", app]).stdout.decode()
    match = re.search(r"^(?:# )?designated => (.+)$", text, re.MULTILINE)
    assert match, "Native codesign did not report a designated requirement"
    return match.group(1)


def cdhash(app):
    text = run(["/usr/bin/codesign", "-d", "--verbose=4", app]).stdout.decode()
    return re.search(r"^CDHash=(\w+)$", text, re.MULTILINE).group(1)


def verify(app, expected=None, *, valid=True):
    command = ["/usr/bin/codesign", "--verify", "--deep", "--strict", "--all-architectures"]
    if expected:
        command += ["-R=" + expected]
    result = run([*command, app], check=False)
    assert (result.returncode == 0) == valid, "Signature validity/identity did not match expectation"


def main():
    assert sys.platform == "darwin", "This native signing regression requires macOS"
    assert (ROOT / "scripts/sign-app.py").is_file(), "Signing helper is missing"
    fingerprint = hashlib.sha1((ROOT / "release/code-signing.cer").read_bytes()).hexdigest()
    with tempfile.TemporaryDirectory(prefix="indexa-signing-") as temporary:
        base = Path(temporary)
        apps = []
        for version in (1, 2):
            app = base / f"Version{version}.app"
            (app / "Contents/MacOS").mkdir(parents=True)
            (app / "Contents/Resources").mkdir()
            (app / "Contents/Resources/probe.txt").write_text("Synthetic sealed resource")
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "local.fine.indexa", "CFBundleExecutable": "Indexa",
                "CFBundleName": "Indexa", "CFBundlePackageType": "APPL", "CFBundleVersion": str(version),
            }))
            run(["/usr/bin/clang", "-x", "c", "-", "-o", app / "Contents/MacOS/Indexa"],
                source=f"int main(void) {{ return {version}; }}\n".encode())
            run(["/usr/bin/codesign", "--force", "--sign", "-", "--identifier", "local.fine.indexa", app])
            verify(app)
            apps.append(app)

        # Reproduce the old failure: identical bundle identifiers do not preserve ad-hoc identity.
        old = [requirement(app) for app in apps]
        assert old[0] != old[1]
        verify(apps[0], old[1], valid=False)
        verify(apps[1], old[0], valid=False)
        for app in apps:
            run([sys.executable, ROOT / "scripts/sign-app.py", app])
            verify(app)
        stable = [requirement(app) for app in apps]
        assert stable[0] == stable[1] and cdhash(apps[0]) != cdhash(apps[1])
        assert 'identifier "local.fine.indexa"' in stable[0]
        assert re.search(r'certificate leaf\s*=\s*H"' + fingerprint + r'"', stable[0], re.IGNORECASE)
        verify(apps[0], stable[1])
        verify(apps[1], stable[0])

        wrong = base / "WrongSigner.app"
        shutil.copytree(apps[0], wrong, symlinks=True)
        run(["/usr/bin/codesign", "--force", "--sign", "-", "--identifier", "local.fine.indexa", wrong])
        verify(wrong)
        verify(wrong, stable[0], valid=False)
        (apps[1] / "Contents/Resources/probe.txt").write_text("Tampered resource")
        verify(apps[1], stable[0], valid=False)
    print("PASS: ad-hoc identity regression, stable certificate-pinned identity across two builds, wrong-signer and tamper rejection")


if __name__ == "__main__":
    main()
