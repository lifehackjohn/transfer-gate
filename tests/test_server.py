#!/usr/bin/env python3
"""Automated tests for Transfer Gate v2 Python backend.

Tests cover: config loading/v1 migration, file scanning, manifest generation,
placement manifest creation, rename preview, batch staging, overwrite
protection, and conflict detection.

Run: python3 -m pytest tests/test_server.py -v
  or: python3 tests/test_server.py
"""

import hashlib
import json
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import importlib
server_mod = importlib.import_module("transfer-gate-server")

AppConfig = server_mod.AppConfig
scan_files = server_mod.scan_files
load_cabinet_tree = server_mod.load_cabinet_tree
load_structure_rules = server_mod.load_structure_rules
preview_rename = server_mod.preview_rename
create_transfer_batch = server_mod.create_transfer_batch
sha256_file = server_mod.sha256_file


class TestAppConfig(unittest.TestCase):
    """Config loading and v1 auto-migration."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmpdir)

    def _write_config(self, data, name="transfer-gate.json"):
        path = os.path.join(self.tmpdir, name)
        with open(path, "w") as f:
            json.dump(data, f)
        return path

    def test_v2_config_loads(self):
        path = self._write_config({
            "cabinetRoot": "D:\\Archive",
            "inbox": "00 Inbox",
            "manifestOutput": "gate-out",
        })
        cfg = AppConfig(config_path=path)
        self.assertEqual(cfg.cabinet_root, "D:\\Archive")
        self.assertEqual(cfg.inbox, "00 Inbox")
        self.assertEqual(cfg.manifest_output, "gate-out")

    def test_v1_config_auto_migration(self):
        """v1 config with archiveRoot should be transparently read as cabinetRoot."""
        path = self._write_config({
            "archiveRoot": "D:\\Archive",
            "inbox": "D:\\Archive\\00 Inbox",
            "manifestOutput": "D:\\Archive\\gate-out",
        })
        cfg = AppConfig(config_path=path)
        self.assertEqual(cfg.cabinet_root, "D:\\Archive")

    def test_v1_migration_preserves_archive_root(self):
        path = self._write_config({"archiveRoot": "/mnt/archive"})
        cfg = AppConfig(config_path=path)
        self.assertEqual(cfg.cabinet_root, "/mnt/archive")
        self.assertIn("cabinetRoot", cfg.data)

    def test_v2_config_not_overwritten_by_v1(self):
        """If both archiveRoot and cabinetRoot exist, cabinetRoot wins."""
        path = self._write_config({
            "archiveRoot": "D:\\Old",
            "cabinetRoot": "D:\\New",
        })
        cfg = AppConfig(config_path=path)
        self.assertEqual(cfg.cabinet_root, "D:\\New")

    def test_empty_cabinet_root_migrates_from_archive_root(self):
        """Empty cabinetRoot should fall back to archiveRoot if present."""
        path = self._write_config({
            "cabinetRoot": "",
            "archiveRoot": "D:\\Archive",
        })
        cfg = AppConfig(config_path=path)
        self.assertEqual(cfg.cabinet_root, "D:\\Archive")

    def test_missing_config_uses_defaults(self):
        cfg = AppConfig(config_path="/nonexistent/path.json")
        self.assertEqual(cfg.cabinet_root, "")
        self.assertEqual(cfg.inbox, "00 Inbox")
        self.assertEqual(cfg.port, 8080)

    def test_cabinet_override(self):
        path = self._write_config({"cabinetRoot": "D:\\Archive"})
        cfg = AppConfig(config_path=path, cabinet_override="Z:\\NewPath")
        self.assertEqual(cfg.cabinet_root, "Z:\\NewPath")

    def test_omlx_endpoint_default(self):
        cfg = AppConfig(config_path="/nonexistent.json")
        self.assertEqual(cfg.omlx_endpoint, "http://localhost:8000/v1")

    def test_media_naming_rule(self):
        path = self._write_config({"mediaFileNamingRule": "{date} {title} - {source}"})
        cfg = AppConfig(config_path=path)
        self.assertEqual(cfg.media_naming_rule, "{date} {title} - {source}")

    def test_to_dict_round_trip(self):
        path = self._write_config({
            "cabinetRoot": "D:\\Archive",
            "serverPort": 9090,
        })
        cfg = AppConfig(config_path=path)
        d = cfg.to_dict()
        self.assertEqual(d["cabinetRoot"], "D:\\Archive")
        self.assertEqual(d["serverPort"], 9090)


class TestScanFiles(unittest.TestCase):
    """File scanning in the tosort directory."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmpdir)

    def test_scans_files_with_metadata(self):
        with open(os.path.join(self.tmpdir, "test.pdf"), "w") as f:
            f.write("PDF content")
        with open(os.path.join(self.tmpdir, "data.csv"), "w") as f:
            f.write("a,b,c")

        files = scan_files(self.tmpdir)
        self.assertEqual(len(files), 2)
        names = {f["name"] for f in files}
        self.assertIn("test.pdf", names)
        self.assertIn("data.csv", names)

    def test_excludes_ds_store(self):
        with open(os.path.join(self.tmpdir, ".DS_Store"), "w") as f:
            f.write("x")
        with open(os.path.join(self.tmpdir, "real.txt"), "w") as f:
            f.write("y")

        files = scan_files(self.tmpdir)
        self.assertEqual(len(files), 1)
        self.assertEqual(files[0]["name"], "real.txt")

    def test_excludes_dotunderscore_files(self):
        with open(os.path.join(self.tmpdir, "._hidden"), "w") as f:
            f.write("x")
        with open(os.path.join(self.tmpdir, "visible.txt"), "w") as f:
            f.write("y")

        files = scan_files(self.tmpdir)
        self.assertEqual(len(files), 1)

    def test_empty_directory(self):
        files = scan_files(self.tmpdir)
        self.assertEqual(files, [])

    def test_nonexistent_directory(self):
        files = scan_files("/nonexistent/path")
        self.assertEqual(files, [])

    def test_file_metadata_fields(self):
        with open(os.path.join(self.tmpdir, "doc.pdf"), "wb") as f:
            f.write(b"x" * 1024)

        files = scan_files(self.tmpdir)
        self.assertEqual(len(files), 1)
        f = files[0]
        self.assertEqual(f["name"], "doc.pdf")
        self.assertEqual(f["ext"], "pdf")
        self.assertEqual(f["size"], 1024)
        self.assertIn("mtime", f)
        self.assertIn("T", f["mtime"])


class TestCabinetTree(unittest.TestCase):
    """Loading Cabinet tree from offline-structure-manifest.json."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmpdir)

    def _write_manifest(self, tree_entries):
        manifest = {
            "manifest_version": 1,
            "kind": "offline-structure-manifest",
            "tree": tree_entries,
        }
        path = os.path.join(self.tmpdir, "offline-structure-manifest.json")
        with open(path, "w") as f:
            json.dump(manifest, f)
        return path

    def test_loads_tree_with_depth(self):
        path = self._write_manifest([
            {"path": ".", "dirs": ["10 Finance"], "file_count": 0, "bytes": 0},
            {"path": "10 Finance", "dirs": ["Tax"], "file_count": 2, "bytes": 1000},
            {"path": "10 Finance/Tax", "dirs": ["2026"], "file_count": 0, "bytes": 0},
            {"path": "10 Finance/Tax/2026", "dirs": [], "file_count": 3, "bytes": 5000},
        ])
        tree = load_cabinet_tree(path)
        self.assertEqual(len(tree), 3)  # root "." excluded
        self.assertEqual(tree[0]["path"], "10 Finance")
        self.assertEqual(tree[0]["depth"], 0)
        self.assertEqual(tree[1]["path"], "10 Finance/Tax")
        self.assertEqual(tree[1]["depth"], 1)
        self.assertEqual(tree[2]["path"], "10 Finance/Tax/2026")
        self.assertEqual(tree[2]["depth"], 2)

    def test_missing_manifest_returns_empty(self):
        tree = load_cabinet_tree("/nonexistent/manifest.json")
        self.assertEqual(tree, [])

    def test_none_path_returns_empty(self):
        tree = load_cabinet_tree(None)
        self.assertEqual(tree, [])


class TestStructureRules(unittest.TestCase):
    """Loading structure-rules.yaml."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmpdir)

    def test_loads_json_fallback(self):
        rules = {"folders": {"10 Finance": {"description": "Financial docs"}}}
        path = os.path.join(self.tmpdir, "rules.yaml")
        with open(path, "w") as f:
            json.dump(rules, f)
        result = load_structure_rules(path)
        self.assertIn("folders", result)

    def test_missing_rules_returns_empty(self):
        result = load_structure_rules("/nonexistent/rules.yaml")
        self.assertEqual(result, {})


class TestPreviewRename(unittest.TestCase):
    """Mandatory rename to YYYY-MM-DD Title (version) format."""

    def test_basic_rename(self):
        result = preview_rename("Annual Tax Return.pdf", "2026-11-07")
        self.assertEqual(result, "2026-11-07 Annual Tax Return (v1).pdf")

    def test_strips_existing_date_prefix(self):
        result = preview_rename("2026-11-07 Tax Return.pdf", "2026-11-07")
        self.assertEqual(result, "2026-11-07 Tax Return (v1).pdf")

    def test_preserves_extension(self):
        result = preview_rename("document.docx", "2026-01-15")
        self.assertEqual(result, "2026-01-15 document (v1).docx")

    def test_no_extension(self):
        result = preview_rename("README", "2026-03-01")
        self.assertEqual(result, "2026-03-01 README (v1)")

    def test_defaults_to_today(self):
        result = preview_rename("file.txt")
        self.assertRegex(result, r"\d{4}-\d{2}-\d{2} file \(v1\)\.txt")


class TestTransferBatch(unittest.TestCase):
    """Batch staging with manifest generation."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.root = os.path.join(self.tmpdir, "tosort")
        self.outbox = os.path.join(self.tmpdir, "outbox")
        os.makedirs(self.root)
        os.makedirs(self.outbox)

    def tearDown(self):
        shutil.rmtree(self.tmpdir)

    def _create_source(self, name, content="test content"):
        path = os.path.join(self.root, name)
        with open(path, "w") as f:
            f.write(content)
        return path

    def test_creates_batch_with_manifests(self):
        self._create_source("tax.pdf", "tax document")
        decisions = [{
            "source": "tax.pdf",
            "renamed": "2026-11-07 Tax Return (v1).pdf",
            "destination": "10 Finance/Tax/2026",
            "conflict_policy": "skip",
        }]
        result, err = create_transfer_batch(
            self.root, decisions, self.outbox, "test-batch-001")
        self.assertIsNone(err)
        self.assertEqual(result["batch_id"], "test-batch-001")
        self.assertEqual(result["files"], 1)

        batch_dir = os.path.join(self.outbox, "test-batch-001")
        self.assertTrue(os.path.isdir(batch_dir))
        self.assertTrue(os.path.exists(
            os.path.join(batch_dir, "transfer-manifest.json")))
        self.assertTrue(os.path.exists(
            os.path.join(batch_dir, "placement-manifest.json")))

    def test_transfer_manifest_v1_format(self):
        self._create_source("doc.pdf", "document")
        decisions = [{
            "source": "doc.pdf",
            "renamed": "2026-01-01 Doc (v1).pdf",
            "destination": "20 Legal",
        }]
        result, _ = create_transfer_batch(
            self.root, decisions, self.outbox, "batch-v1test")

        with open(os.path.join(self.outbox, "batch-v1test",
                               "transfer-manifest.json")) as f:
            m = json.load(f)
        self.assertEqual(m["manifest_version"], 1)
        self.assertEqual(m["kind"], "transfer-manifest")
        self.assertEqual(m["batch_id"], "batch-v1test")
        self.assertEqual(len(m["files"]), 1)
        self.assertIn("sha256", m["files"][0])
        self.assertIn("size", m["files"][0])

    def test_placement_manifest_v2_format(self):
        self._create_source("doc.pdf", "document")
        decisions = [{
            "source": "doc.pdf",
            "renamed": "2026-01-01 Doc (v1).pdf",
            "destination": "20 Legal",
            "conflict_policy": "skip",
            "classification": {"method": "omlx", "confidence": 0.95},
        }]
        create_transfer_batch(
            self.root, decisions, self.outbox, "batch-v2test")

        with open(os.path.join(self.outbox, "batch-v2test",
                               "placement-manifest.json")) as f:
            m = json.load(f)
        self.assertEqual(m["manifest_version"], 2)
        self.assertEqual(m["kind"], "placement-manifest")
        self.assertEqual(len(m["decisions"]), 1)
        self.assertEqual(m["decisions"][0]["original_name"], "doc.pdf")
        self.assertEqual(m["decisions"][0]["conflict_policy"], "skip")

    def test_sha256_integrity(self):
        content = "important document content for hashing"
        self._create_source("hash_test.txt", content)
        decisions = [{
            "source": "hash_test.txt",
            "renamed": "2026-01-01 Hash Test (v1).txt",
            "destination": "10 Finance",
        }]
        create_transfer_batch(
            self.root, decisions, self.outbox, "batch-hash")

        with open(os.path.join(self.outbox, "batch-hash",
                               "transfer-manifest.json")) as f:
            m = json.load(f)
        manifest_hash = m["files"][0]["sha256"]

        dest_file = os.path.join(
            self.outbox, "batch-hash", "payload",
            "10 Finance", "2026-01-01 Hash Test (v1).txt")
        actual_hash = sha256_file(dest_file)
        self.assertEqual(manifest_hash, actual_hash)

    def test_skips_empty_rename(self):
        """Files with empty rename are skipped during batch creation."""
        self._create_source("norename.pdf")
        decisions = [{
            "source": "norename.pdf",
            "renamed": "",
            "destination": "10 Finance",
        }]
        result, err = create_transfer_batch(
            self.root, decisions, self.outbox, "batch-norename")
        self.assertIsNotNone(result)
        self.assertEqual(result["files"], 0)

    def test_duplicate_batch_id_rejected(self):
        self._create_source("file.txt", "content")
        decisions = [{"source": "file.txt", "renamed": "2026-01-01 File (v1).txt",
                      "destination": "10 Finance"}]
        create_transfer_batch(self.root, decisions, self.outbox, "dup-batch")
        result, err = create_transfer_batch(
            self.root, decisions, self.outbox, "dup-batch")
        self.assertIsNone(result)
        self.assertIn("already exists", err)

    def test_skips_missing_source(self):
        decisions = [{"source": "nonexistent.pdf",
                      "renamed": "2026-01-01 Ghost (v1).pdf",
                      "destination": "10 Finance"}]
        result, err = create_transfer_batch(
            self.root, decisions, self.outbox, "batch-ghost")
        self.assertIsNotNone(result)
        self.assertEqual(result["files"], 0)

    def test_multiple_files_batch(self):
        for i in range(5):
            self._create_source(f"file{i}.txt", f"content {i}")
        decisions = [
            {"source": f"file{i}.txt",
             "renamed": f"2026-01-0{i+1} File {i} (v1).txt",
             "destination": "10 Finance"}
            for i in range(5)
        ]
        result, _ = create_transfer_batch(
            self.root, decisions, self.outbox, "batch-multi")
        self.assertEqual(result["files"], 5)

    def test_sources_not_deleted(self):
        """Two-phase prune contract: sources NEVER deleted during staging."""
        self._create_source("precious.pdf", "do not delete")
        decisions = [{"source": "precious.pdf",
                      "renamed": "2026-01-01 Precious (v1).pdf",
                      "destination": "10 Finance"}]
        create_transfer_batch(
            self.root, decisions, self.outbox, "batch-prune")
        self.assertTrue(os.path.exists(
            os.path.join(self.root, "precious.pdf")))


class TestOverwriteProtection(unittest.TestCase):
    """Overwrite protection and conflict handling."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.root = os.path.join(self.tmpdir, "tosort")
        self.outbox = os.path.join(self.tmpdir, "outbox")
        os.makedirs(self.root)
        os.makedirs(self.outbox)

    def tearDown(self):
        shutil.rmtree(self.tmpdir)

    def test_batch_dir_not_overwritten(self):
        """Creating a batch with an existing batch_id must fail."""
        with open(os.path.join(self.root, "f.txt"), "w") as f:
            f.write("test")
        decisions = [{"source": "f.txt", "renamed": "2026-01-01 F (v1).txt",
                      "destination": ""}]
        create_transfer_batch(self.root, decisions, self.outbox, "exists")
        result, err = create_transfer_batch(
            self.root, decisions, self.outbox, "exists")
        self.assertIsNone(result)
        self.assertIn("already exists", err)


if __name__ == "__main__":
    unittest.main(verbosity=2)
