from pathlib import Path
import unittest

import yaml


WORKFLOW = Path(__file__).resolve().parents[2] / ".github/workflows/windows-beta.yml"


class WindowsBetaWorkflowSafetyTests(unittest.TestCase):
    def test_manual_build_uploads_artifact_without_publishing_release_by_default(self):
        workflow = yaml.load(WORKFLOW.read_text(), Loader=yaml.BaseLoader)
        inputs = workflow["on"]["workflow_dispatch"]["inputs"]
        steps = workflow["jobs"]["build"]["steps"]
        upload = next(step for step in steps if step.get("name") == "Upload installer and update feed")
        release = next(step for step in steps if step.get("name") == "Publish GitHub beta release and update feed")

        self.assertEqual(inputs["publish_release"]["default"], "false")
        self.assertEqual(inputs["upload_artifact"]["default"], "true")
        self.assertEqual(upload["if"], "inputs.upload_artifact")
        self.assertEqual(release["if"], "inputs.publish_release")

    def test_artifact_upload_requires_azure_signing_configuration(self):
        workflow = yaml.load(WORKFLOW.read_text(), Loader=yaml.BaseLoader)
        steps = workflow["jobs"]["build"]["steps"]
        guard = next(step for step in steps if step.get("name") == "Require Azure signing for artifact upload")
        detect_index = next(i for i, step in enumerate(steps) if step.get("id") == "artifact_signing")
        guard_index = steps.index(guard)
        upload_index = next(i for i, step in enumerate(steps) if step.get("name") == "Upload installer and update feed")

        self.assertLess(detect_index, guard_index)
        self.assertLess(guard_index, upload_index)
        self.assertEqual(
            guard["if"],
            "inputs.upload_artifact && steps.artifact_signing.outputs.available != 'true'",
        )
        self.assertIn("exit 1", guard["run"])


if __name__ == "__main__":
    unittest.main()
