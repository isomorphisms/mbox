"""Differential checks: fast scanner must match preserved linewise reference."""
import importlib.util
import io
from pathlib import Path
import random
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / "bin" / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


fast = load("spec_list_fast", "spec-list-inventory.py")
reference = load("spec_list_reference", "spec-list-inventory-reference.py")


class InventoryDifferentialTests(unittest.TestCase):
    def compare(self, payload, chunk_sizes=(1, 2, 3, 4, 5, 6, 7, 8, 31, 4096, 1048576)):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "sample.mbox"
            path.write_bytes(payload)
            try:
                expected = reference.scan(path, 3)
            except reference.Refusal:
                for size in chunk_sizes:
                    fast.CHUNK = size
                    with self.assertRaises(fast.Refusal):
                        fast.scan(path, 3, 0)
                return
            try:
                for size in chunk_sizes:
                    fast.CHUNK = size
                    self.assertEqual(fast.scan(path, 3, 0), expected,
                                     "Mismatch at chunk size %d" % size)
            finally:
                fast.CHUNK = 1048576
            self.assertEqual(path.read_bytes(), payload)

    def test_framing_and_selection(self):
        e = b"From a\n"
        for payload in (
            b"",
            e + b"Subject: SPEC-LIST\n\nhello\n",
            e + b"Subject: SPEC-LIST\r\n\r\nFrom split\n\n",
            e + b"Subject: SPEC-\n LIST\n\nnot selected\n",
            e + b"Subject: SPEC-LIST\nFrom no-header-separator\n\n",
            e + b"To: keep\n\n" + b"x" * 10000 + b"\nFrom x\nCc: spec-list\n\n",
            e + b"To: no\n\nFrom next\n",
            e + b"Subject: x\n\tSPEC-LIST\n\n>From escaped\n",
            e + b"Subject: XSPEC-LISTS\nList-ID: SPEC-LIST\n\n",
            e + b"Subject: x\n\n" + b"z" * 102400 + b"\nFrom final",
            b"From eof",
            b"nonempty preamble\nFrom a\n\n",
            b"From " + b"x" * 4096 + b"\n",
            e + b"Subject: " + b"x" * (4 * 1024 * 1024 + 1) + b"\n",
        ):
            with self.subTest(length=len(payload), prefix=payload[:32]):
                self.compare(payload)

    def test_randomized_framing(self):
        rng = random.Random(1729)
        lines = (b"From y\n", b"Fromy\n", b">From y\n", b"x\r\n",
                 b"X: SPEC-LIST\n", b"Subject: SPEC-LIST\n",
                 b"To: x\n", b"To: spec-list\r\n", b" \tSPEC-LIST\n",
                 b"\n", b"\r\n", b"x", b"abc", b"\x00\xff\n")
        for _ in range(50):
            payload = b"From initial\n" + b"".join(rng.choice(lines)
                       for _ in range(rng.randint(1, 55)))
            self.compare(payload)

    def test_large_body_single_line(self):
        self.compare(b"From a\nSubject: spec-list\n\n" + b"q" * (8 * 1024 * 1024)
                     + b"\nFrom b\nSubject: no\n\nend",
                     chunk_sizes=(17, 4096, 1048576))

    def test_progress_on_stderr_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "sample.mbox"
            path.write_bytes(b"From a\nSubject: SPEC-LIST\n\n"
                             + b"x" * (2 * 1024 * 1024))
            fast.CHUNK = 1048576
            diagnostic = io.StringIO()
            actual = fast.scan(path, 0, 1, diagnostic)
            self.assertEqual(actual["selected"], 1)
            self.assertIn("progress\t", diagnostic.getvalue())
            output = io.StringIO()
            fast.report(actual, output)
            self.assertNotIn("progress", output.getvalue())


if __name__ == "__main__":
    unittest.main()
