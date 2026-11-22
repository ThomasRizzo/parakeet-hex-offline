#!/usr/bin/env python3
"""Write release notes (Markdown) for a staged release folder."""
import json
import pathlib
import sys

out = pathlib.Path(sys.argv[1])
m = json.loads((out / "manifest.json").read_text())
repo, tag = m["repo"], m["tag"]
pin = m["hex_pins"]["parakeet_unified_en"]
vad = m["hex_pins"]["speech_detector"]
base = f"https://github.com/{repo}/releases/download/{tag}"


def mb(n):
    return f"{n / 1_000_000:,.1f} MB"


lines = [
    f"Offline mirror of **Hex {m['hex']['version']}** for Windows plus the "
    f"**[{pin['repository']}](https://huggingface.co/{pin['repository']}/tree/{pin['revision']})** "
    f"GGUFs at `{pin['revision']}`, for machines that can reach only github.com.",
    "",
    "Install (current user, no admin, Windows PowerShell 5.1+):",
    "",
    "```powershell",
    f"irm {base}/install-windows.ps1 | iex",
    "```",
    "",
    "Air-gapped: on a connected PC run `install-windows.ps1 -DownloadOnly .\\kit`, copy `kit`, "
    "then `powershell -ExecutionPolicy Bypass -File .\\kit\\install-windows.ps1 -Offline`.",
    "",
    "| File | Size | SHA-256 | Source |",
    "|---|---:|---|---|",
]
for f in m["hex"]["files"]:
    lines.append(f"| `{f['name']}` | {mb(f['size'])} | `{f['sha256'][:16]}…` | [anomalyco/hex]({f['source_url']}) |")
for e in m["models"]:
    src = f"[{e['repo']}@{e['revision'][:7]}]({e['source_url']})"
    if e.get("parts"):
        names = ", ".join(f"`{p['name']}`" for p in e["parts"])
        lines.append(f"| `{e['name']}` (split: {names}) | {mb(e['size'])} | `{e['sha256'][:16]}…` | {src} |")
    else:
        lines.append(f"| `{e['name']}` | {mb(e['size'])} | `{e['sha256'][:16]}…` | {src} |")
lines += [
    "",
    f"Hex {m['hex']['version']} downloads `{pin['filename']}` (Parakeet Unified English, its default model) "
    f"and `{vad['filename']}` (Silero VAD, `{vad['repository']}@{vad['revision'][:7]}`) on first run; the installer "
    "puts both in `%LOCALAPPDATA%\\hex\\models` so Hex never contacts Hugging Face. "
    "The other quantizations are mirrored for completeness (`-ExtraModels`).",
    "",
    f"anoma.ly manifest cross-check: {'matched' if m['hex']['anomaly_manifest']['cross_checked'] else 'not performed (stable channel serves ' + str(m['hex']['anomaly_manifest']['version']) + ')'}.",
    "Full metadata: `manifest.json`; checksums: `SHA256SUMS`.",
]
(out.parent / "release-notes.md").write_text("\n".join(lines) + "\n")
