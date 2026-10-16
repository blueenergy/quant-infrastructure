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

    def test_tags_cancelled_so_a_timeout_stays_visible(self):
        # GitHub reports a job that exceeds its timeout-minutes as 'cancelled',
        # not 'failure' -- so filtering on 'failure' alone is exactly how the
        # 2026-09-21 stalled registry push stayed invisible for 3.5 hours.
        needs = {
            "test-build": {"result": "success"},
            "docker": {"result": "cancelled"},
            "release": {"result": "skipped"},
        }
        self.assertEqual(failed_job_names(json.dumps(needs)), ["docker (cancelled)"])

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

    def test_alert_text_switches_to_a_warning_payload(self):
        # A host that is nearly out of disk is not a failed job. If this ever
        # regresses to the failure title, the robot reports the wrong thing on
        # exactly the alerts that are supposed to arrive *before* anything fails.
        payload = build_payload(
            repository="blueenergy/quant-infrastructure",
            workflow="Deploy app stack",
            event="repository_dispatch",
            ref="main",
            sha="abcdef123456",
            actor="shuyolin",
            run_url="https://github.com/blueenergy/quant-infrastructure/actions/runs/1",
            failed_jobs=[],
            alert_title="宿主机告警 blueenergy/quant-infrastructure",
            alert_text="- [disk pressure on 115] / is 91% used",
        )
        self.assertEqual(payload["markdown"]["title"], "宿主机告警 blueenergy/quant-infrastructure")
        text = payload["markdown"]["text"]
        self.assertIn("disk pressure on 115", text)
        self.assertIn("91% used", text)
        self.assertNotIn("失败", text)
        self.assertIn("打开 Actions", text)

    def test_alert_without_text_stays_a_failure(self):
        # The two modes are chosen by alert_text alone, so a caller that sets
        # only a title (or a stray empty env var) cannot silently downgrade a
        # real failure report into a warning.
        payload = build_payload(
            repository="blueenergy/quantFinance",
            workflow="CI",
            event="push",
            ref="main",
            sha="abcdef123456",
            actor="shuyolin",
            run_url="",
            failed_jobs=["docker"],
            alert_title="宿主机告警",
        )
        self.assertEqual(payload["markdown"]["title"], "[CI] 失败 blueenergy/quantFinance")


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
