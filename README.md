# Transfer Gate v2

Portable online/offline file-sorting tool for moving unsorted staging files into a structured archive (“Cabinet”).

Built for Blue Islands **tosort** workflows: same UI on a networked Mac/NAS path and on an air-gapped Windows workstation.

## What’s in the box

| File | Zone | Purpose |
|------|------|---------|
| `transfer-gate.html` | Both | Single-file UI |
| `transfer-gate-server.py` | Online | Python HTTP bridge (stdlib; PyYAML optional) |
| `transfer-gate.ps1` | Offline | PowerShell server / batch helpers |
| `transfer-gate.json` | Both | Config (`cabinetRoot`, paths, oMLX optional) |
| `structure-rules.yaml` | Both | Folder metadata / rules (optional) |
| `start-transfer-gate.command` | Online Mac | Double-click launcher (system Python 3.8+) |
| `Start-TransferGate-Online.bat` | Online Win | Launcher: system Python → `python-portable\` → download embed 3.12.7 |
| `Start-TransferGate.bat` | Offline Win | PowerShell offline launcher (no Python) |
| `docs/` | — | PRD, HLD, user guide, app layout |
| `tests/` | — | `test_server.py` (pytest), PowerShell tests |

**Not shipped in git:** `python-portable/` (Windows embeddable runtime, ~22 MB).  
`Start-TransferGate-Online.bat` creates it automatically on first run if Python is missing.

## Quick start

### macOS (online)

```bash
# From this directory:
open start-transfer-gate.command
# or:
python3 transfer-gate-server.py --port 8080
```

Open http://127.0.0.1:8080

### Windows (online / AI sorting path)

1. Copy this folder to the machine.
2. Double-click `Start-TransferGate-Online.bat`.
3. If no system Python: one-time portable download from python.org into `python-portable\`.

### Windows (offline / air-gapped)

Double-click `Start-TransferGate.bat` (PowerShell 5.1+, no Python).

## Configuration

Edit `transfer-gate.json` per machine:

- `cabinetRoot` — archive root
- sorted/outbox paths as needed
- optional oMLX endpoint for classification (online only)

## Tests

```bash
python3 -m pytest tests/test_server.py -q
```

## Design docs

Open locally:

- `docs/user-guide.html`
- `docs/prd.html`
- `docs/hld.html`
- `docs/app-layout.html`

## NAS staging note

Source of work-in-progress on the Mini/NAS may still live under  
`/Volumes/Public/projects/tosort/TransferTool/`.  
**This repository is the clean product tree** — do not push the entire `tosort` dump (personal files, media, unrelated piles).

## License

Proprietary — Blue Islands Enterprises / board use unless otherwise stated.
