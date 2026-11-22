# parakeet-hex-offline

Offline Windows installer for **[Hex](https://github.com/anomalyco/hex)** (Anomaly's local voice
dictation app) together with the **[handy-computer/parakeet-unified-en-0.6b-gguf](https://huggingface.co/handy-computer/parakeet-unified-en-0.6b-gguf/tree/7e948f21b7bdbac698d3318db9d350f1096f3b6c)**
speech model, for Windows machines that can reach **only github.com** (or nothing at all).

Everything the target needs is in this repo's [GitHub Releases](../../releases):
the Hex Windows binaries, the Parakeet GGUFs, the Silero VAD GGUF Hex also downloads on first run,
`manifest.json`, `SHA256SUMS`, and `install-windows.ps1`. Nothing is fetched from anoma.ly,
huggingface.co, or any other host.

## Pins

| Component | Pin | Source |
|---|---|---|
| Hex | `3.4.0` (`hex-3.4.0-windows-{x64,arm64}.exe` + `.com`, `hex-setup-3.4.0-*.exe`) | [anomalyco/hex v3.4.0](https://github.com/anomalyco/hex/releases/tag/v3.4.0), cross-checked against `https://anoma.ly/release/hex/desktop/stable.json` |
| Parakeet Unified English GGUF | `handy-computer/parakeet-unified-en-0.6b-gguf` @ `7e948f21b7bdbac698d3318db9d350f1096f3b6c` (all six quantizations + model card) | Hugging Face |
| Silero VAD GGUF | `handy-computer/silero-vad-v6.2-gguf` @ `a9b2d61c20ae4ddf3644edb34969e8185a485448` | Hugging Face; read from Hex's own source (`SPEECH_DETECTOR_ARTIFACT`) |

Release tag: `parakeet-7e948f2-hex-3.4.0`.

Hex 3.4.0 itself pins exactly this Parakeet revision (`src/transcription/artifacts.rs`:
`parakeet-unified-en-0.6b-Q8_0.gguf`, 731,357,568 bytes, sha256 `4b50b6dd…f38795`), and the
release workflow fails if a Hex version you bump to pins something else.

## Install

Requirements: 64-bit Windows 10/11 (x64 with AVX2, or ARM64), Windows PowerShell 5.1 or
PowerShell 7. **No administrator rights.** ~1 GB disk (default model), more with `-ExtraModels`.

### One-liner (machine can reach github.com)

```powershell
irm https://github.com/ThomasRizzo/parakeet-hex-offline/releases/latest/download/install-windows.ps1 | iex
```

With options:

```powershell
& ([scriptblock]::Create((irm https://github.com/ThomasRizzo/parakeet-hex-offline/releases/latest/download/install-windows.ps1))) -ExtraModels F16 -DisableUpdates
```

### Download and run

```powershell
iwr https://github.com/ThomasRizzo/parakeet-hex-offline/releases/latest/download/install-windows.ps1 -OutFile install-windows.ps1 -UseBasicParsing
powershell -ExecutionPolicy Bypass -File .\install-windows.ps1
```

### Fully air-gapped

On any Windows PC with github.com access:

```powershell
powershell -ExecutionPolicy Bypass -File .\install-windows.ps1 -DownloadOnly .\kit   # add -Arch arm64 / -ExtraModels as needed
```

Copy `kit\` to the target, then:

```powershell
powershell -ExecutionPolicy Bypass -File .\kit\install-windows.ps1 -Offline
```

(Or download the release assets by hand into one folder: `SHA256SUMS`, `manifest.json`,
`install-windows.ps1`, `hex-3.4.0-windows-x64.exe`, `hex-3.4.0-windows-x64.com`,
`parakeet-unified-en-0.6b-Q8_0.gguf`, `silero-vad-v6.2-F32.gguf`, and run with `-Offline`.)

### Options

| Option | Effect |
|---|---|
| `-Offline` / `-Source <dir>` | Use assets already in `<dir>` (default: the script's folder); no network at all |
| `-DownloadOnly <dir>` | Fetch exactly what an install needs (plus the script) into `<dir>` |
| `-ExtraModels F16,F32,Q6_K,Q5_K_M,Q4_K_M` or `All` | Also install those quantizations into `%LOCALAPPDATA%\hex\gguf` (F32 is reassembled from its two parts). Hex 3.4 accepts F32/F16/Q8_0 tensors: `hex model import <file>` |
| `-Arch x64\|arm64` | Override detection |
| `-Tag <tag>` / `-Repo <owner/name>` | Install another release of this mirror |
| `-DisableUpdates` | Try to set `HKCU\Software\Policies\Anomaly\Hex\DisableUpdates=1` (Hex's own switch) so Hex stops polling anoma.ly. Windows usually lets only admins write under `HKCU\Software\Policies`, so this may just warn |
| `-NoShortcut`, `-NoPath`, `-SkipSmokeTest`, `-KeepDownloads` | As named |
| `-Uninstall [-RemoveModels]` | Remove Hex (shortcut, PATH entry, Run key, versions); models stay unless `-RemoveModels` |

## What the installer does

It follows Anomaly's [`install-windows.ps1`](https://anoma.ly/hex/files/install-windows.ps1), which
reads `https://anoma.ly/release/hex/desktop/stable.json` and downloads only two files,
`hex.exe` (the GUI app) and `hex.com` (its console entry point). This version reads the
same information from the release's `manifest.json` (itself checked against `SHA256SUMS`)
and checks every file's size and SHA-256:

1. `%APPDATA%\hex\versions\3.4.0\hex.exe` + `hex.com`, `%APPDATA%\hex\current-version`, and the
   `install.json` receipt (`method: direct`), the same managed layout as upstream and HexSetup.exe,
   so either can later replace it.
2. `%APPDATA%\hex\bin\hex.com` on the **user** PATH; Start Menu shortcut `Hex` (per-user).
3. **Models:** `%LOCALAPPDATA%\hex\models\parakeet-unified-en-0.6b-Q8_0.gguf` and
   `silero-vad-v6.2-F32.gguf`. That is the folder Hex uses on Windows (`src/app_paths.rs`
   `models_dir()`; `HEX_APPLICATION_SUPPORT_DIR\models` if that variable is set), and Hex treats a
   file already there with its pinned size and SHA-256 as installed: it verifies it and writes
   `<file>.verified.json` instead of downloading from huggingface.co. Parakeet Unified English is
   Hex's default model, so nothing needs configuring.
4. Smoke test: `hex --version` must match, then `hex model install parakeet_unified_en`
   (with the file present this only verifies it and selects it) and `hex model status`.

## Release workflow

`.github/workflows/release.yml` (manual, **Actions → Build release → Run workflow**; inputs default to the pins):

1. Clones `anomalyco/hex` at `v<hex_version>` and parses its `GgufArtifact` pins
   (`scripts/hex_pins.py`); fails if the Parakeet repo/revision differ from the inputs unless
   `allow_pin_mismatch`.
2. Downloads every file of the Parakeet repo at the pinned commit
   (`/resolve/<sha>/<file>`), checking LFS files against their LFS sha256 and small files against
   their git blob sha1; the same for the Silero VAD repo Hex pins; checks Hex's two model files
   against Hex's own pinned size/sha256.
3. Downloads the Hex Windows assets from the `anomalyco/hex` GitHub release, checking them against
   the release's asset digests and, when anoma.ly's stable channel serves the same version, against
   its manifest.
4. Splits anything over 2 GB (`parakeet-unified-en-0.6b-F32.gguf`, 2.47 GB) into
   `.part00`/`.part01` (the whole-file sha256 and each part's are in `manifest.json`), stamps
   `install-windows.ps1` with this repo and tag, and writes `manifest.json` and `SHA256SUMS`.
5. Publishes the release as a draft, uploads, re-checks every published asset's size and digest,
   then publishes it as latest.
6. Runs `.github/workflows/test-installer.yml` against the new release.

`test-installer.yml` (also on pushes that touch the installer, or manually for any tag) lints the
script with PSScriptAnalyzer (5.1 + 7 syntax), then on `windows-latest` with Hugging Face and
anoma.ly blackholed in `hosts`: installs via `irm | iex` in Windows PowerShell 5.1, checks files,
PATH and checksums, transcribes a synthesized WAV with `hex model transcribe`, uninstalls, builds a
`-DownloadOnly` kit, and installs it `-Offline` as a newly created **standard (non-admin) user**.

## Bumping pins

Run **Build release** with new inputs:

- **New Hex version:** set `hex_version` (e.g. `3.5.0`). If that Hex pins a different Parakeet
  revision, the run fails and prints the revision it wants; use that as `hf_revision`.
- **New Parakeet revision:** set `hf_revision` to the full commit sha. If the Hex version does not
  pin it, Hex would not recognize the file as its catalog model; `allow_pin_mismatch` publishes
  anyway (then import it in Hex with `hex model import`).

The tag is `parakeet-<sha7>-hex-<version>`; an existing tag needs `replace_existing`. Then update the
defaults in `release.yml`, `$DefaultTag` in `install-windows.ps1` (the release copy is stamped
automatically), and the tables above.

## Notes and caveats

- **Updates:** Hex checks `anoma.ly` for updates and notes; on a GitHub-only network those checks
  simply fail. Use `-DisableUpdates` (or an admin can set
  `HKLM\SOFTWARE\Policies\Anomaly\Hex\DisableUpdates=1`) to turn them off. Install a newer Hex by
  running a newer release of this mirror.
- **Other Hex models** (Parakeet v2/v3, Whisper, Qwen3-ASR, …) still download from huggingface.co
  when picked in Hex; only Parakeet Unified English and the VAD are mirrored here.
- **GPU:** x64 Hex uses Vulkan from the graphics driver (`vulkan-1.dll`) and falls back to CPU;
  no Visual C++ runtime or other dependency is needed (Hex links them statically).
- **Unsigned / SmartScreen:** the binaries are byte-identical to Anomaly's (same sha256), so their
  Authenticode signature, if any, is intact.
- `hex-setup-3.4.0-windows-*.exe` (Anomaly's per-user Inno Setup installer) is mirrored too; it
  installs Hex the same way but leaves the model download to Hex, so prefer `install-windows.ps1`.

## Licenses

Hex: MIT (`hex-3.4.0.LICENSE` in the release). Parakeet GGUFs: see the model card
(`parakeet-unified-en-0.6b-gguf.README.md`; CC-BY-4.0 conversion of NVIDIA's
`nvidia/parakeet-unified-en-0.6b`, governed by the NVIDIA Open Model License). Silero VAD GGUF: MIT
(`silero-vad-v6.2-gguf.LICENSE`). This repo's scripts: MIT.
