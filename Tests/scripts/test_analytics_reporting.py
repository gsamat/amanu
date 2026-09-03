import importlib.util
import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
ANALYTICS = ROOT / "scripts" / "analytics"


def load_reporting():
    spec = importlib.util.spec_from_file_location(
        "weekly_digest", ANALYTICS / "weekly_digest.py")
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class AnalyticsReportingTests(unittest.TestCase):
    def test_saved_reports_cover_the_product_journey(self):
        sql = (ANALYTICS / "reports.sql").read_text()
        for name in (
            "Activation (cross-session approximation)",
            "Core processing pipeline",
            "Automatic recording pipeline",
            "Transcript value pipeline",
        ):
            self.assertIn(name, sql)
        for event in (
            "installed", "setup_completed", "recording_started",
            "recording_finished", "transcript_finished", "summary_finished",
            "speaker_names_finished",
        ):
            self.assertIn(f'"value":"{event}"', sql)
        self.assertIn("session-based", sql)
        self.assertIn('"property":"trigger","operator":"neq","value":"manual"', sql)
        self.assertIn('"property":"trigger","operator":"neq","value":"cli"', sql)
        self.assertIn("ON CONFLICT (report_id)", sql)

    def test_weekly_query_uses_the_stable_install_identity(self):
        sql = (ANALYTICS / "weekly-digest.sql").read_text()
        self.assertIn("COALESCE(s.distinct_id, s.session_id::text)", sql)
        self.assertIn("transcript_finished", sql)
        self.assertIn("speaker_names_finished", sql)
        self.assertIn("summary_backend_failed", sql)
        self.assertIn("model", sql)
        self.assertIn("backend", sql)
        self.assertIn("app_version", sql)
        self.assertIn("transcription_cloud_provider", sql)
        self.assertIn("recording_triggers", sql)

    def test_digest_is_readable_and_calls_out_small_samples(self):
        reporting = load_reporting()
        payload = {
            "period": {"start": "2026-08-24", "end": "2026-08-31"},
            "metrics": {
                "installed": 12, "setup_completed": 9, "activated": 7,
                "active_users": 19, "recording_started": 52,
                "recording_finished": 49, "transcript_finished": 43,
                "summary_finished": 35, "speaker_names_finished": 11,
                "transcript_fallback": 3, "artifact_opened": 22,
            },
            "previous": {"installed": 10, "active_users": 16},
            "stt": [
                {"engine": "parakeet", "model": "parakeet-v3", "count": 31},
                {"engine": "assemblyai", "model": "universal", "count": 12},
            ],
            "summaries": [
                {"backend": "openai-api", "model": "gpt-5", "count": 35},
            ],
            "failures": [
                {"event": "transcript_failed", "reason": "no_network", "count": 4},
            ],
            "versions": [{"version": "0.4.13", "users": 19}],
            "recording_triggers": [{"trigger": "mic_activity", "count": 30}],
            "configurations": [{
                "transcription_engine": "auto", "cloud_provider": "assemblyai",
                "summary_backend": "openai-api", "users": 8,
            }],
        }
        text = reporting.format_digest(payload)
        self.assertIn("12 installs", text)
        self.assertIn("7 activated (58.3% of installs)", text)
        self.assertIn("52 → 49 → 43 → 35", text)
        self.assertIn("parakeet / parakeet-v3: 31", text)
        self.assertIn("transcript_failed / no_network: 4", text)
        self.assertIn("0.4.13: 19", text)
        self.assertIn("mic_activity: 30", text)
        self.assertIn("auto / assemblyai / openai-api: 8", text)
        self.assertIn("small samples", text.lower())

    def test_database_output_must_be_a_json_object(self):
        reporting = load_reporting()
        with self.assertRaises(ValueError):
            reporting.parse_payload("[]")
        self.assertEqual(reporting.parse_payload(json.dumps({"metrics": {}})), {"metrics": {}})


if __name__ == "__main__":
    unittest.main()
