#!/usr/bin/env python3
"""Transfer Gate v2 — Online Python Backend.

HTTP server bridging the portable HTML UI to the filesystem and oMLX.
Serves transfer-gate.html and provides REST-like API endpoints for
file listing, Cabinet tree loading, AI classification, batch staging,
and configuration management.

Python 3 standard library only (exception: pyyaml for structure-rules).

Usage:
    python3 transfer-gate-server.py [--root <tosort-dir>] [--port 8080]
        [--cabinet <cabinet-root>] [--config <path-to-transfer-gate.json>]
"""

import argparse
import hashlib
import json
import os
import pathlib
import shutil
import socket
import sys
import urllib.request
import urllib.error
from datetime import datetime, timezone
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

try:
    import yaml
    HAS_YAML = True
except ImportError:
    HAS_YAML = False

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_CONFIG = os.path.join(SCRIPT_DIR, "transfer-gate.json")
SKIP_NAMES = {".DS_Store", "@eaDir", ".Trashes", ".TemporaryItems",
              "#recycle", ".streams", "$RECYCLE.BIN", "System Volume Information"}
TRANSFER_MANIFEST = "transfer-manifest.json"
PLACEMENT_MANIFEST = "placement-manifest.json"
PAYLOAD_DIR = "payload"


def utc_now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def sha256_file(path, chunk_size=1024 * 1024):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(chunk_size), b""):
            h.update(chunk)
    return h.hexdigest()


def is_excluded(name):
    return name in SKIP_NAMES or name.startswith("._")


class AppConfig:
    """Manages Transfer Gate configuration with v1 auto-migration."""

    def __init__(self, config_path=None, root_override=None, cabinet_override=None,
                 port_override=None):
        self.config_path = config_path or DEFAULT_CONFIG
        self.data = {}
        self._load()
        if root_override:
            self.root = root_override
        if cabinet_override:
            self.data["cabinetRoot"] = cabinet_override
        if port_override:
            self.data["serverPort"] = port_override

    def _load(self):
        if os.path.exists(self.config_path):
            with open(self.config_path, "r", encoding="utf-8") as f:
                self.data = json.load(f)
        self._migrate_v1()

    def _migrate_v1(self):
        if "archiveRoot" in self.data and not self.data.get("cabinetRoot"):
            self.data["cabinetRoot"] = self.data["archiveRoot"]
            if "inbox" in self.data and os.path.isabs(self.data["inbox"]):
                cabinet = self.data["cabinetRoot"]
                inbox = self.data["inbox"]
                if inbox.startswith(cabinet):
                    self.data["inbox"] = os.path.relpath(inbox, cabinet)
            if "manifestOutput" in self.data and os.path.isabs(self.data["manifestOutput"]):
                cabinet = self.data["cabinetRoot"]
                mo = self.data["manifestOutput"]
                if mo.startswith(cabinet):
                    self.data["manifestOutput"] = os.path.relpath(mo, cabinet)

    @property
    def source_path(self):
        return self.data.get("sourcePath", "")

    @source_path.setter
    def source_path(self, val):
        self.data["sourcePath"] = val

    @property
    def sorted_path(self):
        return self.data.get("sortedPath", "")

    @sorted_path.setter
    def sorted_path(self, val):
        self.data["sortedPath"] = val

    @property
    def cabinet_root(self):
        return self.data.get("cabinetRoot", "")

    @cabinet_root.setter
    def cabinet_root(self, val):
        self.data["cabinetRoot"] = val

    @property
    def inbox(self):
        return self.data.get("inbox", "00 Inbox")

    @property
    def manifest_output(self):
        return self.data.get("manifestOutput", "gate-out")

    @property
    def exclude(self):
        return set(self.data.get("exclude", SKIP_NAMES))

    @property
    def omlx_endpoint(self):
        return self.data.get("omlxEndpoint", "http://localhost:8000/v1")

    @property
    def port(self):
        return int(self.data.get("serverPort", 8080))

    @property
    def media_naming_rule(self):
        return self.data.get("mediaFileNamingRule", "{date} {title}")

    def to_dict(self):
        return dict(self.data)


def scan_files(root):
    """List unsorted files in the tosort directory with metadata."""
    files = []
    root = os.path.abspath(root)
    if not os.path.isdir(root):
        return files
    for entry in sorted(os.scandir(root), key=lambda e: e.name):
        if entry.is_file() and not is_excluded(entry.name):
            stat = entry.stat()
            ext = os.path.splitext(entry.name)[1].lstrip(".")
            files.append({
                "name": entry.name,
                "path": entry.name,
                "size": stat.st_size,
                "ext": ext.lower(),
                "mtime": datetime.fromtimestamp(
                    stat.st_mtime, tz=timezone.utc
                ).strftime("%Y-%m-%dT%H:%M:%SZ"),
            })
    return files


def load_cabinet_tree(manifest_path):
    """Load Cabinet folder tree from an offline-structure-manifest.json."""
    if not manifest_path or not os.path.exists(manifest_path):
        return []
    with open(manifest_path, "r", encoding="utf-8") as f:
        data = json.load(f)
    tree = []
    for entry in data.get("tree", []):
        path = entry.get("path", ".")
        if path == ".":
            continue
        depth = path.count("/")
        tree.append({
            "path": path,
            "depth": depth,
            "file_count": entry.get("file_count", 0),
            "bytes": entry.get("bytes", 0),
        })
    return tree


def load_structure_rules(rules_path):
    """Load structure-rules.yaml if available."""
    if not rules_path or not os.path.exists(rules_path):
        return {}
    if HAS_YAML:
        with open(rules_path, "r", encoding="utf-8") as f:
            return yaml.safe_load(f) or {}
    with open(rules_path, "r", encoding="utf-8") as f:
        return json.load(f)


def classify_with_omlx(files, folder_tree, rules, endpoint):
    """Send file metadata + folder tree to oMLX for AI classification."""
    prompt_parts = [
        "You are a file classification assistant. Given a list of files and a folder taxonomy, "
        "suggest the best destination folder for each file. The folder names are semantically "
        "meaningful — use them to understand categories.\n\n"
        "FOLDER TAXONOMY:\n"
    ]
    for f in folder_tree:
        indent = "  " * f.get("depth", 0)
        prompt_parts.append(f"{indent}{f['path']}")
        if rules:
            folder_rule = _get_folder_rule(rules, f["path"])
            if folder_rule and folder_rule.get("description"):
                prompt_parts.append(f" — {folder_rule['description']}")
        prompt_parts.append("\n")

    prompt_parts.append("\nFILES TO CLASSIFY:\n")
    for fi in files:
        prompt_parts.append(f"- {fi['name']} ({fi['ext']}, {fi['size']} bytes)\n")

    prompt_parts.append(
        "\nRespond ONLY with a JSON array. Each element must have: "
        '"filename", "suggested_folder" (exact path from taxonomy), '
        '"confidence" (0.0-1.0), "reasoning" (one sentence). '
        "Do not include any other text."
    )

    prompt = "".join(prompt_parts)

    payload = json.dumps({
        "model": "Qwen3.5-9B-mlx-lm-mxfp4",
        "messages": [{"role": "user", "content": prompt}],
        "temperature": 0.1,
        "max_tokens": 4096,
    }).encode("utf-8")

    req = urllib.request.Request(
        f"{endpoint}/chat/completions",
        data=payload,
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            result = json.loads(resp.read())
        content = result["choices"][0]["message"]["content"]
        start = content.find("[")
        end = content.rfind("]") + 1
        if start >= 0 and end > start:
            return json.loads(content[start:end])
        return []
    except Exception:
        return []


def _get_folder_rule(rules, path):
    """Navigate structure-rules to find a folder's rule."""
    folders = rules.get("folders", {})
    parts = path.replace("\\", "/").split("/")
    current = folders
    for part in parts:
        if part in current:
            current = current[part]
        elif "children" in current and part in current["children"]:
            current = current["children"][part]
        else:
            return None
    return current if isinstance(current, dict) else None


def preview_rename(filename, date_str=None):
    """Generate a rename preview for YYYY-MM-DD Title (version) format."""
    base, ext = os.path.splitext(filename)
    if not date_str:
        date_str = datetime.now().strftime("%Y-%m-%d")
    title = base
    for prefix in [date_str, date_str.replace("-", "")]:
        if title.startswith(prefix):
            title = title[len(prefix):].lstrip(" -_")
    version = "v1"
    return f"{date_str} {title} ({version}){ext}"


def create_transfer_batch(root, decisions, outbox, batch_id=None):
    """Create a transfer batch from sort decisions.

    Returns (batch_info, error_message). batch_info is None on error.
    """
    if not batch_id:
        batch_id = datetime.now(timezone.utc).strftime("batch-%Y%m%dT%H%M%SZ")

    batch_dir = os.path.join(os.path.abspath(outbox), batch_id)
    payload_root = os.path.join(batch_dir, PAYLOAD_DIR)

    if os.path.exists(batch_dir):
        return None, f"Batch directory already exists: {batch_dir}"

    os.makedirs(payload_root, exist_ok=True)

    transfer_entries = []
    placement_decisions = []
    total_bytes = 0

    for dec in decisions:
        src_name = dec.get("source", "")
        renamed = dec.get("renamed", src_name)
        destination = dec.get("destination", "")
        conflict_policy = dec.get("conflict_policy", "skip")

        src_path = os.path.join(root, src_name)
        if not os.path.isfile(src_path):
            continue
        if not renamed:
            continue

        dest_rel = os.path.join(destination, renamed) if destination else renamed
        dest_path = os.path.join(payload_root, dest_rel)
        os.makedirs(os.path.dirname(dest_path), exist_ok=True)

        shutil.copy2(src_path, dest_path)
        size = os.path.getsize(dest_path)
        digest = sha256_file(dest_path)
        total_bytes += size

        transfer_entries.append({
            "path": dest_rel.replace(os.sep, "/"),
            "size": size,
            "sha256": digest,
            "source": src_name,
        })

        placement_decisions.append({
            "source_path": dest_rel.replace(os.sep, "/"),
            "original_name": src_name,
            "destination": destination.replace(os.sep, "/"),
            "conflict_policy": conflict_policy,
            "classification": dec.get("classification", {}),
        })

    transfer_manifest = {
        "manifest_version": 1,
        "kind": "transfer-manifest",
        "batch_id": batch_id,
        "created_utc": utc_now(),
        "source_host": socket.gethostname(),
        "totals": {"files": len(transfer_entries), "bytes": total_bytes},
        "files": transfer_entries,
    }

    placement_manifest = {
        "manifest_version": 2,
        "kind": "placement-manifest",
        "batch_id": batch_id,
        "created_utc": utc_now(),
        "cabinet_root_hint": "",
        "decisions": placement_decisions,
    }

    with open(os.path.join(batch_dir, TRANSFER_MANIFEST), "w",
              encoding="utf-8") as f:
        f.write(json.dumps(transfer_manifest, indent=2, ensure_ascii=False) + "\n")

    with open(os.path.join(batch_dir, PLACEMENT_MANIFEST), "w",
              encoding="utf-8") as f:
        f.write(json.dumps(placement_manifest, indent=2, ensure_ascii=False) + "\n")

    html_src = os.path.join(SCRIPT_DIR, "transfer-gate.html")
    if os.path.exists(html_src):
        shutil.copy2(html_src, os.path.join(batch_dir, "transfer-gate.html"))

    return {
        "batch_id": batch_id,
        "batch_dir": batch_dir,
        "files": len(transfer_entries),
        "bytes": total_bytes,
    }, None


class TransferGateHandler(BaseHTTPRequestHandler):
    """HTTP request handler for the Transfer Gate online backend."""

    server_version = "TransferGate/2.0"

    def log_message(self, format, *args):
        sys.stderr.write("[%s] %s\n" % (self.log_date_time_string(), format % args))

    def _send_json(self, data, status=200):
        body = json.dumps(data, indent=2, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", len(body))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def _send_html(self, path):
        if not os.path.exists(path):
            self.send_error(404, "File not found")
            return
        with open(path, "rb") as f:
            body = f.read()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", len(body))
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self):
        length = int(self.headers.get("Content-Length", 0))
        if length == 0:
            return {}
        return json.loads(self.rfile.read(length))

    def _get_config(self):
        return self.server.app_config

    def _get_root(self):
        config = self._get_config()
        if config.source_path:
            return os.path.abspath(config.source_path)
        return self.server.tosort_root

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, PUT, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/")
        params = parse_qs(parsed.query)

        if path == "" or path == "/":
            self._send_html(os.path.join(SCRIPT_DIR, "transfer-gate.html"))
        elif path == "/api/files":
            files = scan_files(self._get_root())
            self._send_json({"files": files, "root": self._get_root()})
        elif path == "/api/cabinet":
            manifest_path = params.get("manifest", [None])[0]
            if not manifest_path:
                config = self._get_config()
                out_dir = os.path.join(self._get_root(), "_transfer-gate")
                manifest_path = os.path.join(
                    out_dir, "offline-structure-manifest.json")
            tree = load_cabinet_tree(manifest_path)
            self._send_json({"tree": tree})
        elif path == "/api/cabinet/rules":
            config = self._get_config()
            rules_path = os.path.join(SCRIPT_DIR, "structure-rules.yaml")
            rules = load_structure_rules(rules_path)
            self._send_json(rules)
        elif path == "/api/batches":
            config = self._get_config()
            if config.sorted_path:
                outbox = os.path.abspath(config.sorted_path)
            else:
                outbox = os.path.join(self._get_root(), "_transfer-gate", "outbox")
            batches = self._list_batches(outbox)
            self._send_json({"batches": batches})
        elif path == "/api/config":
            config = self._get_config()
            self._send_json(config.to_dict())
        elif path == "/api/health":
            self._send_json({"status": "ok", "version": "2.0.0"})
        else:
            self.send_error(404, "Not found")

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/")

        if path == "/api/classify":
            self._handle_classify()
        elif path == "/api/rename-preview":
            self._handle_rename_preview()
        elif path == "/api/stage":
            self._handle_stage()
        elif path == "/api/conflicts":
            self._handle_conflicts()
        else:
            self.send_error(404, "Not found")

    def do_PUT(self):
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/")

        if path == "/api/config":
            self._handle_config_update()
        else:
            self.send_error(404, "Not found")

    def _handle_classify(self):
        body = self._read_body()
        files = body.get("files", [])
        config = self._get_config()

        manifest_path = os.path.join(
            self._get_root(), "_transfer-gate",
            "offline-structure-manifest.json")
        tree = load_cabinet_tree(manifest_path)
        rules_path = os.path.join(SCRIPT_DIR, "structure-rules.yaml")
        rules = load_structure_rules(rules_path)

        if not tree:
            self._send_json({"classifications": [], "method": "none",
                             "error": "No Cabinet tree loaded"})
            return

        results = classify_with_omlx(files, tree, rules, config.omlx_endpoint)
        if results:
            self._send_json({"classifications": results, "method": "omlx"})
        else:
            heuristics = self._heuristic_classify(files, tree)
            self._send_json({"classifications": heuristics,
                             "method": "heuristic"})

    def _heuristic_classify(self, files, tree):
        """Extension-based fallback when oMLX is unavailable."""
        ext_hints = {
            "pdf": ["Finance", "Legal", "Personal"],
            "xlsx": ["Finance"],
            "csv": ["Finance"],
            "docx": ["Legal", "Business"],
            "jpg": ["Personal", "Media"],
            "png": ["Personal", "Media"],
            "mp4": ["Media"],
            "mp3": ["Media"],
        }
        results = []
        for fi in files:
            ext = fi.get("ext", "").lower()
            hints = ext_hints.get(ext, [])
            suggested = ""
            confidence = 0.0
            for folder in tree:
                path = folder["path"]
                for hint in hints:
                    if hint.lower() in path.lower():
                        suggested = path
                        confidence = 0.3
                        break
                if suggested:
                    break
            results.append({
                "filename": fi["name"],
                "suggested_folder": suggested,
                "confidence": confidence,
                "reasoning": f"Extension-based heuristic ({ext})" if suggested
                else "No heuristic match",
            })
        return results

    def _handle_rename_preview(self):
        body = self._read_body()
        filename = body.get("filename", "")
        date_str = body.get("date", None)
        renamed = preview_rename(filename, date_str)
        self._send_json({"original": filename, "renamed": renamed})

    def _handle_stage(self):
        body = self._read_body()
        decisions = body.get("decisions", [])
        batch_id = body.get("batch_id", None)

        if not decisions:
            self._send_json({"error": "No decisions provided"}, 400)
            return

        for dec in decisions:
            if not dec.get("renamed"):
                self._send_json(
                    {"error": f"File '{dec.get('source', '?')}' missing rename"},
                    400)
                return

        config = self._get_config()
        if config.sorted_path:
            outbox = os.path.abspath(config.sorted_path)
        else:
            outbox = os.path.join(self._get_root(), "_transfer-gate", "outbox")
        os.makedirs(outbox, exist_ok=True)

        result, err = create_transfer_batch(
            self._get_root(), decisions, outbox, batch_id)
        if err:
            self._send_json({"error": err}, 400)
        else:
            self._send_json(result)

    def _handle_conflicts(self):
        body = self._read_body()
        decisions = body.get("decisions", [])
        manifest_path = os.path.join(
            self._get_root(), "_transfer-gate",
            "offline-structure-manifest.json")
        tree = load_cabinet_tree(manifest_path)
        tree_paths = {f["path"] for f in tree}
        conflicts = []
        for dec in decisions:
            dest = dec.get("destination", "")
            if dest in tree_paths:
                folder = next((f for f in tree if f["path"] == dest), None)
                if folder and folder.get("file_count", 0) > 0:
                    conflicts.append({
                        "file": dec.get("source", ""),
                        "destination": dest,
                        "level": "folder",
                        "existing_files": folder["file_count"],
                    })
        self._send_json({"conflicts": conflicts})

    def _handle_config_update(self):
        body = self._read_body()
        config = self._get_config()
        for key in ["sourcePath", "sortedPath", "cabinetRoot",
                     "omlxEndpoint", "serverPort", "mediaFileNamingRule"]:
            if key in body:
                config.data[key] = body[key]
        try:
            with open(config.config_path, "w", encoding="utf-8") as f:
                json.dump(config.data, f, indent=4, ensure_ascii=False)
        except OSError:
            pass
        self._send_json(config.to_dict())

    def _list_batches(self, outbox):
        batches = []
        if not os.path.isdir(outbox):
            return batches
        for entry in sorted(os.scandir(outbox), key=lambda e: e.name,
                            reverse=True):
            if not entry.is_dir():
                continue
            manifest_path = os.path.join(entry.path, TRANSFER_MANIFEST)
            if os.path.exists(manifest_path):
                with open(manifest_path, "r", encoding="utf-8") as f:
                    m = json.load(f)
                batches.append({
                    "batch_id": m.get("batch_id", entry.name),
                    "created_utc": m.get("created_utc", ""),
                    "files": m.get("totals", {}).get("files", 0),
                    "bytes": m.get("totals", {}).get("bytes", 0),
                })
        return batches


def main(argv=None):
    p = argparse.ArgumentParser(description="Transfer Gate v2 Online Backend")
    p.add_argument("--root", default=os.path.dirname(SCRIPT_DIR),
                   help="Path to tosort/ directory (default: parent of script dir)")
    p.add_argument("--port", type=int, default=None,
                   help="Server port (default: from config or 8080)")
    p.add_argument("--cabinet", default=None,
                   help="Override Cabinet root path")
    p.add_argument("--config", default=DEFAULT_CONFIG,
                   help="Path to transfer-gate.json")
    args = p.parse_args(argv)

    config = AppConfig(
        config_path=args.config,
        root_override=args.root,
        cabinet_override=args.cabinet,
        port_override=args.port,
    )

    if not config.cabinet_root:
        print("ERROR: config must specify cabinetRoot (or archiveRoot for v1 compat)")
        print(f"  Edit {config.config_path} and set cabinetRoot to your archive path,")
        print("  or pass --cabinet <path> on the command line.")
        return 2

    port = args.port or config.port

    server = HTTPServer(("127.0.0.1", port), TransferGateHandler)
    server.app_config = config
    server.tosort_root = os.path.abspath(args.root)

    print(f"Transfer Gate v2 server starting on http://127.0.0.1:{port}")
    print(f"  tosort root: {server.tosort_root}")
    print(f"  Source path: {config.source_path or '(using tosort root)'}")
    print(f"  Sorted path: {config.sorted_path or '(default: _transfer-gate/outbox)'}")
    print(f"  Cabinet root: {config.cabinet_root}")
    print(f"  oMLX endpoint: {config.omlx_endpoint}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
