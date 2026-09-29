from pathlib import Path
import unittest

import yaml


WORKFLOW = Path(__file__).resolve().parents[2] / ".github/workflows/windows-beta.yml"


class WindowsBetaWorkflowSafetyTests(unittest.TestCase):
    def test_manual_build_does_not_publish_or_upload_by_default(self):
        workflow = yaml.load(WORKFLOW.read_text(), Loader=yaml.BaseLoader)
        inputs = workflow["on"]["workflow_dispatch"]["inputs"]
        steps = workflow["jobs"]["build"]["steps"]
        upload = next(step for step in steps if step.get("name") == "Upload installer and update feed")
        release = next(step for step in steps if step.get("name") == "Publish GitHub beta release and update feed")

        self.assertEqual(inputs["publish_release"]["default"], "false")
        self.assertEqual(inputs["upload_artifact"]["default"], "false")
        self.assertEqual(upload["if"], "inputs.upload_artifact")
        self.assertEqual(release["if"], "inputs.publish_release")


if __name__ == "__main__":
    unittest.main()
