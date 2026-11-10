"""Offline tests for the host trader reconciler create path.

No docker, no Mongo, no production DB: ``_docker`` and the image lookup are
replaced with recorders, and output dirs point at a temp directory.
"""

from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).with_name("trader_reconciler.py")
spec = importlib.util.spec_from_file_location("trader_reconciler", MODULE_PATH)
reconciler = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reconciler)


class _FakeDocker:
    def __init__(self):
        self.calls = []

    def __call__(self, *args, timeout=30):
        self.calls.append(args)

        class _Result:
            returncode = 0
            stdout = ""
            stderr = ""

        return _Result()


class ReconcilerCreateTest(unittest.TestCase):
    def test_generate_config_carries_account_and_transport(self):
        with tempfile.TemporaryDirectory() as tmp:
            reconciler.AUTOGEN_DIR = Path(tmp)
            account = {
                "_id": "sec-test",
                "user_id": "user-test",
                "qmt_account_id": "62129066",
                "trader_client_id": "quant-trader-selftest",
            }
            path = reconciler._generate_config(account)
            config = json.loads(path.read_text(encoding="utf-8"))

        self.assertEqual(config["securities_account_id"], "sec-test")
        self.assertEqual(config["user_id"], "user-test")
        self.assertEqual(config["broker"], "qmt_bridge")
        self.assertEqual(config["qmt_bridge"]["account_id"], "62129066")
        self.assertEqual(config["qmt_bridge"]["transport"], "file")
        self.assertEqual(config["qmt_bridge"]["file"]["client_id"], "quant-trader-selftest")
        self.assertEqual(config["qmt_bridge"]["file"]["root"], "/app/bqbox/trade")
        self.assertTrue(config["qmt_bridge"]["rpc_allow_order_methods"])

    def test_create_container_command(self):
        fake_docker = _FakeDocker()
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            mailbox = tmp_path / "bqbox"
            mailbox.mkdir()
            reconciler.AUTOGEN_DIR = tmp_path / "autogen"
            reconciler.DATA_DIR = tmp_path / "data"
            reconciler.LOG_DIR = tmp_path / "logs"
            reconciler._docker = fake_docker
            reconciler._image = lambda: "test-image:sha-123"
            account = {
                "_id": "sec-test",
                "user_id": "user-test",
                "qmt_account_id": "62129066",
                "qmt_mailbox_root": str(mailbox),
                "trader_client_id": "quant-trader-selftest",
                "trader_container_name": "quant-trader-selftest",
            }
            reconciler._create_container(account)

        run_call = fake_docker.calls[-1]
        self.assertEqual(run_call[0], "run")
        command = " ".join(run_call)
        self.assertIn("--name quant-trader-selftest", command)
        self.assertIn("--network host", command)
        self.assertIn("test-image:sha-123", command)
        self.assertIn(f"{mailbox}:/app/bqbox", command)
        self.assertIn("/app/config/config.json:ro", command)

    def test_refuses_non_trader_container_name(self):
        fake_docker = _FakeDocker()
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(RuntimeError):
                reconciler._create_container(
                    {
                        "_id": "sec-test",
                        "user_id": "user-test",
                        "qmt_mailbox_root": tmp,
                        "qmt_account_id": "1",
                        "trader_client_id": "x",
                        "trader_container_name": "some-other-container",
                    }
                )

    def test_missing_mailbox_refuses_to_create(self):
        fake_docker = _FakeDocker()
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(RuntimeError):
                reconciler._create_container(
                    {
                        "_id": "sec-test",
                        "user_id": "user-test",
                        "qmt_mailbox_root": str(Path(tmp) / "does-not-exist"),
                        "qmt_account_id": "1",
                        "trader_client_id": "x",
                        "trader_container_name": "quant-trader-selftest",
                    }
                )


if __name__ == "__main__":
    unittest.main()
