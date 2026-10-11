#!/usr/bin/env python3
"""Export a reviewable public source tree without local history or paid fonts."""

import argparse
from pathlib import Path
import re
import shutil
import tempfile


ROOT = Path(__file__).resolve().parents[1]
FONT_EXTENSIONS = {".otf", ".ttf", ".woff", ".woff2"}
REQUIRED_FILES = [
    ".gitignore", "Package.swift", "VERSION", "README.md", "LICENSE",
    "THIRD_PARTY_NOTICES.md", "CHANGELOG.md",
    "AppResources/Authors.txt", "AppResources/Font-Copyright.txt",
    "AppResources/QuotaBar.icns", "AppResources/QuotaBar.png",
    "docs/development.md", "docs/release.md",
    "script/build_and_run.sh", "script/generate_app_icon.sh",
    "script/prepare_source.py",
]
CHECKS = {
    "possible credential": re.compile(
        rb"(?:sk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{24,}"
        rb"|gh[pousr]_[A-Za-z0-9]{24,}"
        rb"|github_pat_[A-Za-z0-9_]{30,}"
        rb"|xox[baprs]-[A-Za-z0-9-]{20,}"
        rb"|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----)"
    ),
    "personal home path": re.compile(rb"/Users/[A-Za-z0-9_.-]+/"),
}


def main():
    version = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise SystemExit("Invalid VERSION")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path,
                        default=ROOT / "dist" / f"QuotaBar-{version}-source")
    output = parser.parse_args().output.resolve()
    if output.exists():
        raise SystemExit("Output already exists; choose a new directory with --output.")

    sources = [ROOT / name for name in REQUIRED_FILES]
    sources += sorted((ROOT / "Sources").rglob("*.swift"))
    sources += sorted((ROOT / "Tests").rglob("*.swift"))
    sources += sorted((ROOT / "Sources/QuotaBar/Resources/Icons").glob("*.svg"))
    if not any(path.suffix == ".swift" for path in sources):
        raise SystemExit("No Swift source found")
    for path in sources:
        if not path.is_file() or path.is_symlink():
            raise SystemExit(f"Missing file or unsupported symlink: {path.relative_to(ROOT)}")
        if not path.resolve().is_relative_to(ROOT) or path.suffix.lower() in FONT_EXTENSIONS:
            raise SystemExit("Unexpected source outside the export policy")
        if path.suffix.lower() not in {".png", ".icns"}:
            data = path.read_bytes()
            for label, pattern in CHECKS.items():
                if pattern.search(data):
                    raise SystemExit(f"Review {path.relative_to(ROOT)}: {label}")

    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".quotabar-source-", dir=output.parent) as temp:
        staging = Path(temp) / output.name
        staging.mkdir()
        for source in sources:
            target = staging / source.relative_to(ROOT)
            target.parent.mkdir(parents=True, exist_ok=True)
            # Do not copy Finder metadata or local extended attributes.
            shutil.copyfile(source, target)
            target.chmod(0o755 if source.suffix in {".sh", ".py"} else 0o644)
        staging.rename(output)
    print(f"Public source: {output}")
    print(f"Files: {len(sources)}; no Git history, local settings or font binaries.")


if __name__ == "__main__":
    main()
