"""Restore verified original Windows binaries from temporary Release parts."""
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

EXPECTED = {
    "CAINI7_EIT_Setup_v1.1.0_Windows_x64.exe": (755955200, "9cb01ea6f8e38fc585beafbf60b88f1b41cce8be3fe33374868c0f18439a8b9c"),
    "CAINI7_EIT_v1.1.0_Windows_x64.zip": (753938431, "d29b7a8aa8520d969e48a027738167d25bdd71f7193479861aced72603bff672"),
}
MANIFEST = "upload_parts_manifest_v1.1.0.json"
REPO = os.environ["GITHUB_REPOSITORY"]
TAG = os.environ.get("RELEASE_TAG", "v1.1.0")


def gh(*args):
    result = subprocess.run(["gh", *args], check=True, capture_output=True, text=True, timeout=900)
    return result.stdout


def release_info():
    releases = json.loads(gh("api", f"repos/{REPO}/releases?per_page=100"))
    return next(r for r in releases if r["tag_name"] == TAG)


def check_asset(asset, size, digest):
    return asset and asset["state"] == "uploaded" and asset["size"] == size and asset.get("digest") == "sha256:" + digest


def main():
    release = release_info()
    if not release["draft"]:
        raise RuntimeError("Assembly requires a draft Release")
    assets = {a["name"]: a for a in release["assets"]}
    with tempfile.TemporaryDirectory(prefix="eit-release-") as folder:
        work = Path(folder)
        gh("release", "download", TAG, "--repo", REPO, "--pattern", MANIFEST, "--dir", str(work))
        manifest = json.loads((work / MANIFEST).read_text(encoding="utf-8-sig"))
        if manifest["release_tag"] != TAG or {a["name"] for a in manifest["artifacts"]} != set(EXPECTED):
            raise RuntimeError("Unexpected manifest target")
        parts = []
        seen = set()
        for artifact in manifest["artifacts"]:
            size, digest = EXPECTED[artifact["name"]]
            if (artifact["size"], artifact["sha256"]) != (size, digest):
                raise RuntimeError("Original artifact does not match the verified build")
            if sum(p["size"] for p in artifact["parts"]) != size:
                raise RuntimeError("Part sizes do not sum to the original file size")
            for part in artifact["parts"]:
                name = part["name"]
                if not re.fullmatch(r"uploadpart_v110_(setup|portable)_[0-9]{3}\.bin", name) or name in seen:
                    raise RuntimeError("Invalid or duplicate part name")
                if not 0 < part["size"] <= 104857600 or not re.fullmatch(r"[a-f0-9]{64}", part["sha256"]):
                    raise RuntimeError("Invalid part metadata")
                seen.add(name)
                if not check_asset(assets.get(name), part["size"], part["sha256"]):
                    raise RuntimeError(f"Missing or unverified part: {name}")
                parts.append(part)

        def download(part):
            gh("release", "download", TAG, "--repo", REPO, "--pattern", part["name"], "--dir", str(work))

        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            list(pool.map(download, parts))
        for artifact in manifest["artifacts"]:
            name = artifact["name"]
            size, digest = EXPECTED[name]
            existing = assets.get(name)
            if existing:
                if not check_asset(existing, size, digest):
                    raise RuntimeError(f"Refusing to replace an unexpected existing asset: {name}")
                continue
            combined = hashlib.sha256()
            destination = work / name
            with destination.open("wb") as target:
                for part in artifact["parts"]:
                    path = work / part["name"]
                    if path.stat().st_size != part["size"]:
                        raise RuntimeError("Downloaded part size mismatch")
                    part_hash = hashlib.sha256()
                    with path.open("rb") as source:
                        for block in iter(lambda: source.read(1024 * 1024), b""):
                            target.write(block)
                            part_hash.update(block)
                            combined.update(block)
                    if part_hash.hexdigest() != part["sha256"]:
                        raise RuntimeError("Downloaded part SHA-256 mismatch")
            if destination.stat().st_size != size or combined.hexdigest() != digest:
                raise RuntimeError("Reassembled artifact SHA-256 mismatch")
            gh("release", "upload", TAG, str(destination), "--repo", REPO)
            print(f"Restored original artifact: {name}", flush=True)

        final_release = release_info()
        final_assets = {a["name"]: a for a in final_release["assets"]}
        for name, (size, digest) in EXPECTED.items():
            if not check_asset(final_assets.get(name), size, digest):
                raise RuntimeError(f"GitHub final asset SHA-256 mismatch: {name}")
        checksum = final_assets.get("SHA256SUMS.txt")
        if not check_asset(checksum, 208, "a5024e1f233f08a36b028ba17a2c08d3561184f861de81dbc9a8a66f599b57e0"):
            raise RuntimeError("Published checksums file mismatch")
        # Delete only this manifest's temporary parts, after all originals verify.
        for name in sorted(seen | {MANIFEST}):
            asset = final_assets.get(name)
            if asset:
                gh("api", "--method", "DELETE", f"repos/{REPO}/releases/assets/{asset['id']}")
        summary = "Both original Windows artifacts restored and verified by SHA-256. Temporary parts removed. Release remains a draft.\n"
        print(summary, flush=True)
        if os.environ.get("GITHUB_STEP_SUMMARY"):
            Path(os.environ["GITHUB_STEP_SUMMARY"]).write_text(summary, encoding="utf-8")


if __name__ == "__main__":
    main()
