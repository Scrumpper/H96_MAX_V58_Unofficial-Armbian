"""Unit test of tools/docs/check-alliteration.py: hit, allow-list, code span, fence, table, phrase, exit code."""
import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest

GATE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools", "docs", "check-alliteration.py")
_spec = importlib.util.spec_from_file_location("check_alliteration", GATE)
ca = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ca)
ALLOW = ca.load_allow(ca.DEFAULT_ALLOW)


def wins(text, allow=()):
    return [w for _, w, _ in ca.hits("X.md", text, list(allow))]


class CheckAlliteration(unittest.TestCase):
    def test_hit_and_window(self):
        self.assertEqual(wins("Panel picks power profile per boot.\n"), ["Panel picks power profile"])

    def test_one_hit_per_sentence_and_line_number(self):
        found = ca.hits("X.md", "Clean line.\nPanel picks power profile; big box boots badly.\n")
        self.assertEqual([(n, w) for n, w, _ in found], [(2, "Panel picks power profile"), (2, "big box boots badly")])

    def test_three_of_four_with_gap(self):
        self.assertEqual(wins("power stays put under pressure.\n"), ["power stays put pressure"])

    def test_two_shared_letters_pass(self):
        self.assertEqual(wins("power profile changes tonight.\n"), [])

    def test_stopwords_and_short_words_ignored(self):
        self.assertEqual(wins("to the top of it, do an up or so.\n"), [])
        self.assertEqual(wins("top tier tools.\n"), ["top tier tools"])

    def test_allow_list_names(self):
        text = "PanVK Panthor Panfrost packages installed.\n"
        self.assertEqual(wins(text), ["PanVK Panthor Panfrost packages"])
        self.assertEqual(wins(text, ["PanVK", "Panthor", "Panfrost"]), [])
        self.assertEqual(wins(text, ALLOW), [])

    def test_allow_phrase_and_hyphen_suffix(self):
        self.assertEqual(wins("Steam Deck interface shows Cortex-A76 cores.\n", ["Steam Deck", "Cortex-A"]), [])
        self.assertEqual(wins("aptX-HD and aptX adaptive codecs listed.\n", ["aptX"]), [])
        self.assertEqual(wins("Proton default for Direct3D 8 draws them.\n", ["Proton", "Direct3D"]), [])

    def test_code_span_link_target_url_ignored(self):
        self.assertEqual(wins("Run `perf power profile` first.\n"), [])
        self.assertEqual(wins("See [page](power-profile-panel.md) now.\n"), [])
        self.assertEqual(wins("Read https://example.org/power/profile/panel now.\n"), [])

    def test_fence_table_and_indented_code_skipped(self):
        self.assertEqual(wins("```\npanel picks power profile\n```\n| panel | picks power profile |\n    panel picks power profile\n"), [])

    def test_allow_file_parses_comments(self):
        self.assertIn("Steam", ALLOW)
        self.assertTrue(all("#" not in a for a in ALLOW))

    def test_cli_exit_codes(self):
        with tempfile.TemporaryDirectory() as d:
            bad, good = os.path.join(d, "bad.md"), os.path.join(d, "good.md")
            open(bad, "w").write("Panel picks power profile.\n")
            open(good, "w").write("Panel keeps one setting.\n")
            r = subprocess.run([sys.executable, "-I", GATE, bad, good], capture_output=True, text=True)
            self.assertEqual(r.returncode, 1)
            self.assertIn("bad.md:1: Panel picks power profile  |  Panel picks power profile.", r.stdout)
            self.assertIn("TOTAL 1 hits in 2 files", r.stdout)
            self.assertEqual(subprocess.run([sys.executable, "-I", GATE, good], capture_output=True).returncode, 0)


if __name__ == "__main__":
    unittest.main()
