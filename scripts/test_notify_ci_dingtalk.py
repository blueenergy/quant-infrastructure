#!/usr/bin/env python3
"""Unit tests for scripts/notify_ci_dingtalk.py (stdlib unittest)."""

from __future__ import annotations

import json
import unittest
import urllib.parse
from unittest import mock

from notify_ci_dingtalk import (
    WEBHOOK_URL_ENV,
    build_payload,
    failed_job_names,
    main,
    send,
    signed_url,
)


class FailedJobNamesTests(unittest.TestCase):
    def test_picks_failure_and_ignores_skipped(self):
        needs = {
            "test-build": {"result": "failure"},
            "docker": {"result": "skipped"},
            "release": {"result": "success"},
        }
        self.assertEqual(failed_job_names(json.dumps(needs)), ["test-build"])

    def test_empty_and_garbage(self):
        self.assertEqual(failed_job_names(""), [])
        self.assertEqual(failed_job_names("not-json"), [])
        self.assertEqual(failed_job_names("[]"), [])


class SignedUrlTests(unittest.TestCase):
    def test_no_secret_returns_url(self):
        url = "https://oapi.dingtalk.com/robot/send?access_token=abc"
        self.assertEqual(signed_url(url, ""), url)

    def test_appends_timestamp_and_sign(self):
        url = "https://oapi.dingtalk.com/robot/send?access_token=abc"
        signed = signed_url(url, "SEC123", now_ms=1700000000000)
        parsed = urllib.parse.urlparse(signed)
        qs = urllib.parse.parse_qs(parsed.query)
        self.assertEqual(qs["access_token"], ["abc"])
        self.assertEqual(qs["timestamp"], ["1700000000000"])
        self.assertTrue(qs["sign"][0])


class PayloadTests(unittest.TestCase):
    def test_markdown_title_and_actions_link(self):
        payload = build_payload(
            repository="blueenergy/quantFinance",
            workflow="CI",
            event="push",
            ref="main",
            sha="abcdef123456",
            actor="shuyolin",
            run_url="https://github.com/blueenergy/quantFinance/actions/runs/1",
            failed_jobs=["test-build"],
        )
        self.assertEqual(payload["msgtype"], "markdown")
        self.assertEqual(payload["markdown"]["title"], "[CI] 失败 blueenergy/quantFinance")
        text = payload["markdown"]["text"]
        self.assertIn("test-build", text)
        self.assertIn("`abcdef1`", text)
        self.assertIn("打开 Actions", text)


class SendTests(unittest.TestCase):
    def test_http_200_with_errcode_is_failure(self):
        payload = {"msgtype": "markdown", "markdown": {"title": "t", "text": "t"}}
        fake = mock.MagicMock()
        fake.read.return_value = b'{"errcode":310000,"errmsg":"sign not match"}'
        fake.__enter__.return_value = fake
        fake.__exit__.return_value = False
        with mock.patch("urllib.request.urlopen", return_value=fake):
            with self.assertRaisesRegex(RuntimeError, "310000"):
                send("https://oapi.dingtalk.com/robot/send?access_token=abc", payload, "", 5)


class MainTests(unittest.TestCase):
    def test_missing_url_skips(self):
        self.assertEqual(main(env={}), 0)


if __name__ == "__main__":
    unittest.main()
