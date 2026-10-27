"""Unit test of tools/docs/check-alliteration.py: alliteration rule, repeated-opener rule, allow-lists, CLI."""
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


def owins(text, openers_allow=()):
    """(line, window) of every hit with an empty alliteration allow-list and the given opener allow-list."""
    return [(n, w) for n, w, _ in ca.hits("X.md", text, [], list(openers_allow))]


def run_cli(*args):
    return subprocess.run([sys.executable, "-I", GATE, *args], capture_output=True, text=True)


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
            r = run_cli(bad, good)
            self.assertEqual(r.returncode, 1)
            self.assertIn("bad.md:1: Panel picks power profile  |  Panel picks power profile.", r.stdout)
            self.assertIn("TOTAL 1 hits in 2 files", r.stdout)
            self.assertEqual(run_cli(good).returncode, 0)


class RepeatedOpeners(unittest.TestCase):
    def test_neighbouring_bullets(self):
        found = ca.hits("X.md", "- Kernel 6.12 default.\n- Kernel 6.1 fallback.\n", [])
        self.assertEqual(found, [(2, "opener 'kernel' x2", "repeats line 1: Kernel 6.1 fallback.")])
        self.assertEqual(owins("- Kernel 6.12 default.\n- Fallback kernel 6.1.\n"), [])
        self.assertEqual(owins("1) Kernel 6.12.\n2) Kernel 6.1.\n"), [(2, "opener 'kernel' x2")])
        self.assertEqual(owins("1. Kernel 6.12.\n2. Kernel 6.1.\n"), [(2, "opener 'kernel' x2")])

    def test_bullets_around_headings(self):
        self.assertEqual(owins("## Kernels\n- Kernel 6.12.\n- Kernel 6.1.\n"), [(3, "opener 'kernel' x2")])
        self.assertEqual(owins("- Kernel 6.12.\n## Kernels\n- Kernel 6.1.\n"), [])

    def test_multi_line_bullet(self):
        # continuation line opening with the bullet's word is the same sentence
        self.assertEqual(owins("- Kernel 6.12 default\n  kernel 6.1 fallback.\n- Boot takes time.\n"), [])
        # two sentences of one bullet, reported on the bullet's first line
        self.assertEqual(owins("- Kernel 6.12 default.\n  Kernel 6.1 fallback.\n"), [(1, "opener 'kernel' x2")])

    def test_nested_list_isolation(self):
        self.assertEqual(owins("- Kernel 6.12 default.\n  - Kernel module tree.\n  - Boot files.\n- Boot takes time.\n"), [])
        self.assertEqual(owins("- Kernel 6.12.\n  - Boot files.\n- Kernel 6.1.\n"), [(3, "opener 'kernel' x2")])

    def test_loose_list_and_list_breaks(self):
        self.assertEqual(owins("- Kernel 6.12 default.\n\n- Kernel 6.1 fallback.\n"), [(3, "opener 'kernel' x2")])
        self.assertEqual(owins("- Kernel 6.12 default.\n\n  More on it.\n\n- Kernel 6.1 fallback.\n"), [(5, "opener 'kernel' x2")])
        self.assertEqual(owins("- Kernel 6.12 default.\n\nPlain paragraph here.\n\n- Kernel 6.1 fallback.\n"), [])
        self.assertEqual(owins("- Kernel 6.12 default.\n\n## Heading\n\n- Kernel 6.1 fallback.\n"), [])
        self.assertEqual(owins("- Kernel 6.12.\n\n| a | b |\n\n- Kernel 6.1.\n"), [])
        self.assertEqual(owins("- Kernel 6.12.\n\n```\ncode\n```\n\n- Kernel 6.1.\n"), [])

    def test_code_and_link_led_bullets_skipped(self):
        self.assertEqual(owins("- `h96-perf` tool.\n- `h96-perf` again.\n"), [])
        self.assertEqual(owins("- **`h96-perf`** tool.\n- **`h96-perf`** again.\n"), [])
        self.assertEqual(owins("- [Kernel switch](a.md)\n- [Kernel debs](b.md)\n"), [])
        self.assertEqual(owins("- [Kernel switch](a.md): how.\n- [Kernel debs](b.md): what.\n"), [])
        self.assertEqual(owins("- <b>Kernel</b> 6.12.\n- <b>Kernel</b> 6.1.\n"), [])

    def test_bold_and_emoji_led_bullets_count(self):
        self.assertEqual(owins("- **Kernel 6.12**: default.\n- **Kernel 6.1**: fallback.\n"), [(2, "opener 'kernel' x2")])
        self.assertEqual(owins("- ✅ Kernel 6.12.\n- ✅ Kernel 6.1.\n"), [(2, "opener 'kernel' x2")])
        self.assertEqual(owins("- \U0001F680 Kernel 6.12.\n- \U0001F680 Kernel 6.1.\n"), [(2, "opener 'kernel' x2")])

    def test_contents_list_repeating_headings_skipped(self):
        doc = "# Doc\n\n1. Kernel switch\n2. Kernel debs\n\n## Kernel switch\n\n## Kernel debs\n"
        self.assertEqual(owins(doc), [])
        self.assertEqual(owins("1. Kernel switch\n2. Kernel debs\n"), [(2, "opener 'kernel' x2")])

    def test_table_rows_and_fenced_code_skipped(self):
        self.assertEqual(owins("| Kernel | a |\n| Kernel | b |\n"), [])
        self.assertEqual(owins("```\n- Kernel a\n- Kernel b\nRun one script.\n```\n"), [])
        self.assertEqual(owins("    - Kernel a\n    - Kernel b\n"), [])

    def test_neighbouring_sentences(self):
        self.assertEqual(owins("Kernel 6.12 is default. Kernel 6.1 is fallback.\n"), [(1, "opener 'kernel' x2")])
        self.assertEqual(owins("Kernel 6.12 is default.\nKernel 6.1 is fallback.\n"), [(1, "opener 'kernel' x2")])
        self.assertEqual(owins("Kernel 6.12 is default.\n\nKernel 6.1 is fallback.\n"), [])
        self.assertEqual(owins("Kernel 6.12 is default. Boot is quick. Kernel 6.1 is fallback.\n"), [])
        # sentence ends when bold, parenthesis or quote closes after the stop
        self.assertEqual(owins("**Kernel 6.12, default.** Kernel 6.1 is fallback.\n"), [(1, "opener 'kernel' x2")])
        self.assertEqual(owins("Kernel 6.12 (default.) Kernel 6.1 is fallback.\n"), [(1, "opener 'kernel' x2")])
        self.assertEqual(owins("It protects you from *\"boots, yet unstable.\"* It cannot do more.\n"), [(1, "opener 'it' x2")])

    def test_quote_block(self):
        self.assertEqual(owins("> Kernel 6.12 is default.\n> Kernel 6.1 is fallback.\n"), [(1, "opener 'kernel' x2")])
        self.assertEqual(owins("> - Kernel 6.12.\n> - Kernel 6.1.\n"), [(2, "opener 'kernel' x2")])

    def test_crlf_text(self):
        self.assertEqual(owins("- Kernel 6.12.\r\n- Kernel 6.1.\r\n"), [(2, "opener 'kernel' x2")])
        self.assertEqual(owins("Kernel 6.12 is default.\r\nKernel 6.1 is fallback.\r\n"), [(1, "opener 'kernel' x2")])
        self.assertEqual(owins("Kernel 6.12 is default.\r\n\r\nKernel 6.1 is fallback.\r\n"), [])
        self.assertEqual(owins("```\r\n- Kernel a\r\n- Kernel b\r\n```\r\n| Kernel | Kernel |\r\n"), [])

    def test_clause_rule(self):
        self.assertEqual(owins("One kernel, one boot file.\n"), [(1, "clause 'one' x2")])
        self.assertEqual(owins("Box has one kernel, one boot file.\n"), [])   # first clause opens with "box"
        self.assertEqual(owins("Pick one kernel; one boot file; one driver.\n"), [(1, "clause 'one' x2")])
        self.assertEqual(owins("Kernel debs, kernel switch, both listed.\n"), [])
        self.assertEqual(owins("Same kernel, same tree, same tools.\n"), [(1, "clause 'same' x3")])

    def test_phrases(self):
        self.assertEqual(owins("Run one script and go.\n"), [(1, "phrase 'one script'")])
        self.assertEqual(owins("Base image, nothing installed by default.\n"), [(1, "phrase 'nothing installed'")])
        self.assertEqual(owins("Works offline, no download needed.\n"), [(1, "phrase 'no download needed'")])
        self.assertEqual(owins("Run `one script` now.\n"), [])
        self.assertEqual(owins("Run one scripted check now.\n"), [])

    def test_opener_skip_words(self):
        self.assertEqual(owins("See kernel page. See boot page.\n"), [])
        self.assertEqual(owins("- Use kernel 6.12.\n- Use kernel 6.1.\n"), [])
        self.assertEqual(owins("- The kernel.\n- The boot files.\n"), [])

    def test_openers_allow_list(self):
        text = "- Steam ARM 3.1 runtime.\n- Steam Frame rating.\n"
        self.assertEqual(owins(text), [(2, "opener 'steam' x2")])
        self.assertEqual(owins(text, ["Steam"]), [])
        self.assertEqual(owins(text, ["steam"]), [])
        self.assertEqual(owins("Steam runs it. Steam stops it.\n", ["Steam"]), [])

    def test_combined_output_sorted_by_line(self):
        text = ("Kernel 6.12 is default. Kernel 6.1 is fallback.\n\nOne kernel, one boot file.\n\n"
                "Panel picks power profile per boot.\n\nRun one script and go.\n")
        self.assertEqual(owins(text), [(1, "opener 'kernel' x2"), (3, "clause 'one' x2"),
                                       (5, "Panel picks power profile"), (7, "phrase 'one script'")])

    def test_openers_allow_file_parses_comments(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "openers-allow.txt")
            open(p, "w").write("# header comment\nSteam  # product name\n\nPanVK\n")
            self.assertEqual(ca.load_allow(p), ["Steam", "PanVK"])
        self.assertTrue(all("#" not in a and " " not in a for a in ca.load_allow(ca.DEFAULT_OPENERS_ALLOW)))

    def test_cli_opener_hit_allow_flag_and_usage(self):
        with tempfile.TemporaryDirectory() as d:
            bad, allow = os.path.join(d, "bad.md"), os.path.join(d, "openers.txt")
            open(bad, "w").write("- Kernel 6.12.\n- Kernel 6.1.\n")
            open(allow, "w").write("Kernel  # test entry\n")
            r = run_cli(bad)
            self.assertEqual(r.returncode, 1)
            self.assertIn("bad.md:2: opener 'kernel' x2  |  repeats line 1: Kernel 6.1.", r.stdout)
            self.assertIn("FAIL", r.stdout)
            self.assertEqual(run_cli("--openers-allow", allow, bad).returncode, 0)
            r = run_cli("--help")
            self.assertEqual((r.returncode, r.stdout), (2, ""))
            self.assertIn("check-alliteration.py FILE.md", r.stderr)
            self.assertEqual(run_cli(os.path.join(d, "missing.md")).returncode, 2)
            self.assertEqual(run_cli().returncode, 2)


if __name__ == "__main__":
    unittest.main()
