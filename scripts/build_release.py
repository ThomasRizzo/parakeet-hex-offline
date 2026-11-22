#!/usr/bin/env python3
"""Stage every release asset for parakeet-hex-offline into an output folder.

Fetches, verifies, and lays out:
  * the Hugging Face repo HF_REPO at HF_REVISION (every file; LFS files are
    checked against their LFS sha256, small files against their git blob sha1),
  * the other GGUF the given Hex version downloads at runtime (the Silero VAD
    speech detector), read from Hex's own source at tag v<HEX_VERSION>,
  * the Hex Windows binaries for that version from github.com/anomalyco/hex
    releases (checked against the release's asset digests and, when it serves
    the same version, against anoma.ly's release manifest, which is what the
    upstream install-windows.ps1 reads),
then splits anything over GitHub's 2 GiB asset limit, and writes manifest.json
and SHA256SUMS. install-windows.ps1 is stamped with the repo and tag.
"""
import argparse
import datetime
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import urllib.request

PART_BYTES = 1_900_000_000          # GitHub release assets must be < 2 GiB
SPLIT_OVER = 2_000_000_000
UA = "parakeet-hex-offline-builder"


def log(*a):
    print(*a, file=sys.stderr, flush=True)


def get_json(url, token=None):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "application/json"})
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


def curl(url, dest):
    subprocess.run(
        ["curl", "-fSL", "--retry", "5", "--retry-delay", "5", "--retry-all-errors",
         "-A", UA, "-o", str(dest), url],
        check=True,
    )


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(8 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def git_blob_sha1(path):
    data = pathlib.Path(path).read_bytes()
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


def hex_pins(hex_version, workdir):
    src = workdir / f"hex-src-{hex_version}"
    if not src.exists():
        subprocess.run(["git", "clone", "-q", "--depth", "1", "--branch", f"v{hex_version}",
                        "https://github.com/anomalyco/hex.git", str(src)], check=True)
    out = subprocess.run([sys.executable, str(pathlib.Path(__file__).with_name("hex_pins.py")), str(src)],
                         check=True, capture_output=True, text=True).stdout
    return json.loads(out), src


def fetch_hf(repo, revision, out, role_for, prefix_docs):
    """Download every file of an HF repo at revision; return manifest entries."""
    tree = get_json(f"https://huggingface.co/api/models/{repo}/tree/{revision}?recursive=true")
    entries = []
    for item in tree:
        if item.get("type") != "file":
            continue
        path = item["path"]
        if "/" in path:
            sys.exit(f"{repo}: nested path {path} is not supported")
        is_model = "lfs" in item
        name = path if is_model else f"{prefix_docs}.{path.lstrip('.')}"
        if not is_model and path.startswith("."):
            name = f"{prefix_docs}.dot-{path.lstrip('.')}"
        dest = out / name
        url = f"https://huggingface.co/{repo}/resolve/{revision}/{path}"
        log(f"fetch {url}")
        curl(url, dest)
        size = dest.stat().st_size
        if size != item["size"]:
            sys.exit(f"{path}: size {size} != {item['size']}")
        digest = sha256(dest)
        if is_model:
            if digest != item["lfs"]["oid"]:
                sys.exit(f"{path}: sha256 {digest} != LFS oid {item['lfs']['oid']}")
            verified = "hf-lfs-sha256"
        else:
            if git_blob_sha1(dest) != item["oid"]:
                sys.exit(f"{path}: git blob sha1 mismatch")
            verified = "hf-git-blob-sha1"
        entries.append({
            "name": name, "repo": repo, "revision": revision, "path": path,
            "size": size, "sha256": digest, "source_url": url, "verified": verified,
            "role": role_for(path, is_model),
        })
    return entries


def fetch_hex(version, out, token):
    rel = get_json(f"https://api.github.com/repos/anomalyco/hex/releases/tags/v{version}", token)
    try:
        anomaly = get_json("https://anoma.ly/release/hex/desktop/stable.json")
    except Exception as e:  # informational cross-check only
        log(f"warning: anoma.ly manifest unavailable: {e}")
        anomaly = None
    anomaly_targets = {}
    if anomaly and anomaly.get("release", {}).get("version") == version:
        anomaly_targets = anomaly["release"]["targets"]
    files = []
    pat = re.compile(rf"^hex(-setup)?-{re.escape(version)}-windows-(x64|arm64)\.(exe|com)$")
    for asset in rel["assets"]:
        m = pat.match(asset["name"])
        if not m:
            continue
        setup, arch, ext = m.groups()
        role = "setup" if setup else ("cli" if ext == "com" else "app")
        target = f"windows-{arch}" + {"setup": "-setup", "cli": "-cli", "app": ""}[role]
        dest = out / asset["name"]
        log(f"fetch {asset['browser_download_url']}")
        curl(asset["browser_download_url"], dest)
        digest = sha256(dest)
        size = dest.stat().st_size
        want = (asset.get("digest") or "").removeprefix("sha256:")
        if size != asset["size"] or (want and digest != want):
            sys.exit(f"{asset['name']}: does not match GitHub release metadata")
        entry = {"name": asset["name"], "arch": arch, "role": role, "target": target,
                 "size": size, "sha256": digest, "source_url": asset["browser_download_url"]}
        a = anomaly_targets.get(target)
        if a:
            if a["sha256"] != digest or a["size"] != size:
                sys.exit(f"{asset['name']}: differs from anoma.ly manifest {target}")
            entry["anomaly_url"] = "https://anoma.ly" + a["url"]
        files.append(entry)
    roles = {(f["arch"], f["role"]) for f in files}
    for need in [("x64", "app"), ("x64", "cli")]:
        if need not in roles:
            sys.exit(f"Hex v{version} release lacks windows {need}")
    return {
        "version": version,
        "release_url": rel["html_url"],
        "anomaly_manifest": {
            "url": "https://anoma.ly/release/hex/desktop/stable.json",
            "version": anomaly.get("release", {}).get("version") if anomaly else None,
            "cross_checked": bool(anomaly_targets),
        },
        "files": files,
    }


def split_large(out, entry):
    path = out / entry["name"]
    if entry["size"] <= SPLIT_OVER:
        return
    parts = []
    with open(path, "rb") as f:
        i = 0
        while True:
            chunk_path = out / f"{entry['name']}.part{i:02d}"
            h = hashlib.sha256()
            written = 0
            with open(chunk_path, "wb") as w:
                while written < PART_BYTES:
                    buf = f.read(min(8 << 20, PART_BYTES - written))
                    if not buf:
                        break
                    w.write(buf)
                    h.update(buf)
                    written += len(buf)
            if written == 0:
                chunk_path.unlink()
                break
            parts.append({"name": chunk_path.name, "size": written, "sha256": h.hexdigest()})
            i += 1
    path.unlink()
    entry["parts"] = parts
    log(f"split {entry['name']} into {len(parts)} parts")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hf-repo", required=True)
    ap.add_argument("--hf-revision", required=True)
    ap.add_argument("--hex-version", required=True)
    ap.add_argument("--repo", required=True, help="owner/name of this mirror repo")
    ap.add_argument("--tag", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--allow-pin-mismatch", action="store_true")
    a = ap.parse_args()
    out = pathlib.Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    work = out.parent / "work"
    work.mkdir(exist_ok=True)
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")

    pins, hex_src = hex_pins(a.hex_version, work)
    default = pins["PARAKEET_UNIFIED_ENGLISH_ARTIFACT"]
    vad = pins["SPEECH_DETECTOR_ARTIFACT"]
    if (default["repository"], default["revision"]) != (a.hf_repo, a.hf_revision):
        msg = (f"Hex v{a.hex_version} pins {default['repository']}@{default['revision']}, "
               f"not {a.hf_repo}@{a.hf_revision}")
        if not a.allow_pin_mismatch:
            sys.exit(msg + " (set allow_pin_mismatch to publish anyway)")
        log("warning: " + msg)

    def parakeet_role(path, is_model):
        if not is_model:
            return "doc"
        return "hex-default-model" if path == default["filename"] else "extra-model"

    models = fetch_hf(a.hf_repo, a.hf_revision, out, parakeet_role,
                      a.hf_repo.split("/")[1])
    vad_files = fetch_hf(vad["repository"], vad["revision"], out,
                         lambda p, m: "hex-speech-detector" if p == vad["filename"] else "doc",
                         vad["repository"].split("/")[1])
    names = [e["name"] for e in models + vad_files]
    if len(names) != len(set(names)):
        sys.exit(f"duplicate asset names: {sorted(n for n in set(names) if names.count(n) > 1)}")
    for e in models + vad_files:
        if e["role"] == "hex-default-model":
            pin = default
        elif e["role"] == "hex-speech-detector":
            pin = vad
        else:
            continue
        if e["sha256"] != pin["sha256"] or e["size"] != pin["bytes"]:
            sys.exit(f"{e['name']}: differs from Hex's pin in {pin['source']}")
        e["hex_pin_source"] = pin["source"]
    hex_info = fetch_hex(a.hex_version, out, token)
    lic = out / f"hex-{a.hex_version}.LICENSE"
    lic.write_bytes((hex_src / "LICENSE").read_bytes())

    for e in models + vad_files:
        split_large(out, e)

    # Stamp the installer with this repo and tag.
    script = pathlib.Path(__file__).resolve().parent.parent / "install-windows.ps1"
    text = script.read_text(encoding="utf-8")
    text, n1 = re.subn(r"(?m)^\$DefaultRepo = '.*'$", f"$DefaultRepo = '{a.repo}'", text)
    text, n2 = re.subn(r"(?m)^\$DefaultTag = '.*'$", f"$DefaultTag = '{a.tag}'", text)
    if n1 != 1 or n2 != 1:
        sys.exit("install-windows.ps1: could not stamp $DefaultRepo/$DefaultTag")
    # ASCII with CRLF and no BOM: Windows PowerShell 5.1 reads it the same
    # from a file, and `irm | iex` would choke on a BOM before param().
    (out / "install-windows.ps1").write_bytes(
        text.replace("\r\n", "\n").replace("\n", "\r\n").encode("ascii"))

    manifest = {
        "schema": 1,
        "repo": a.repo,
        "tag": a.tag,
        "created": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "hex": hex_info,
        "hex_pins": {"parakeet_unified_en": default, "speech_detector": vad},
        "models": models + vad_files,
        "extras": [{"name": lic.name, "size": lic.stat().st_size, "sha256": sha256(lic),
                    "source_url": f"https://github.com/anomalyco/hex/blob/v{a.hex_version}/LICENSE"}],
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    sums = []
    for p in sorted(out.iterdir()):
        if p.is_file() and p.name != "SHA256SUMS":
            sums.append(f"{sha256(p)}  {p.name}")
    (out / "SHA256SUMS").write_text("\n".join(sums) + "\n", encoding="utf-8")
    for p in sorted(out.iterdir()):
        if p.stat().st_size >= 2 * 1024 ** 3:
            sys.exit(f"{p.name} is still >= 2 GiB")
    log("\n".join(sums))


if __name__ == "__main__":
    main()
