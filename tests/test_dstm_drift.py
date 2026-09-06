import importlib.util
import json
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "check_dstm_drift.py"
SPEC = importlib.util.spec_from_file_location("check_dstm_drift", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def source(*bodies):
    return "\n\n".join(bodies) + "\n"


def routine(name, body):
    return f"sub {name} {{\n{body}\n}}"


class DstmDriftTests(unittest.TestCase):
    def setUp(self):
        self.config = {
            "upstream_repository": "example/upstream",
            "reviewed_upstream_commit": "abc123",
            "direct_mirrors": ["shared"],
            "adapted_from_upstream": ["adapted"],
            "identity_normalizations": [
                ["Plugins::BlissMixerLab", "Plugins::BlissMixer"]
            ],
            "intentional_adaptations": {"adapted": "Adds an extension field."},
        }
        self.reviewed = source(
            routine("shared", "return Plugins::BlissMixer->value();"),
            routine("adapted", "return { count => 5 };"),
        )
        self.extension = source(
            routine("shared", "return Plugins::BlissMixerLab->value();"),
            routine("adapted", "return { count => 5, extension => 1 };"),
        )

    def test_extracts_named_top_level_routines(self):
        routines = MODULE.extract_subroutines(self.reviewed)
        self.assertEqual(["shared", "adapted"], list(routines))
        self.assertTrue(routines["shared"].startswith("sub shared"))
        self.assertNotIn("sub adapted", routines["shared"])

    def test_normalization_ignores_layout_comments_and_plugin_identity(self):
        upstream = "sub shared { # explanation\n return 'value #1'; }"
        extension = "sub shared{return 'value #1';}"
        self.assertEqual(
            MODULE.canonicalize(upstream, []),
            MODULE.canonicalize(extension, []),
        )

    def test_reviewed_pair_has_no_drift(self):
        self.assertEqual(
            [],
            MODULE.analyse(
                self.config, self.reviewed, self.reviewed, self.extension
            ),
        )

    def test_direct_mirror_difference_requires_review(self):
        changed_extension = self.extension.replace("->value()", "->other_value()")
        drift = MODULE.analyse(
            self.config, self.reviewed, self.reviewed, changed_extension
        )
        self.assertEqual([("direct mirror differs", "shared")], [
            (item.category, item.function) for item in drift
        ])

    def test_new_change_to_adapted_upstream_routine_requires_review(self):
        changed_upstream = self.reviewed.replace("count => 5", "count => 10")
        drift = MODULE.analyse(
            self.config, self.reviewed, changed_upstream, self.extension
        )
        self.assertEqual([("adapted upstream routine changed", "adapted")], [
            (item.category, item.function) for item in drift
        ])
        report = MODULE.render_report(self.config, "def456", drift)
        self.assertIn("Adds an extension field.", report)
        self.assertIn("-return { count => 5 };", report)
        self.assertIn("+return { count => 10 };", report)

    def test_repository_configuration_is_complete(self):
        config = json.loads(
            (ROOT / "compat" / "dstm-drift.json").read_text(encoding="utf-8")
        )
        tracked = config["direct_mirrors"] + config["adapted_from_upstream"]
        self.assertEqual(len(tracked), len(set(tracked)))
        self.assertIn("_dstmMix", config["adapted_from_upstream"])
        self.assertIn("_getMixData", config["adapted_from_upstream"])
        self.assertEqual(
            set(config["adapted_from_upstream"]),
            set(config["intentional_adaptations"]),
        )


if __name__ == "__main__":
    unittest.main()
