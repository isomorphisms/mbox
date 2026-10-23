import hashlib
import importlib.util
from pathlib import Path
import random
import tempfile
import unittest

MODULE = Path(__file__).resolve().parents[1] / 'bin' / 'plaintext-index.py'
spec = importlib.util.spec_from_file_location('plaintext_index', MODULE)
idx = importlib.util.module_from_spec(spec)
spec.loader.exec_module(idx)
ref_spec = importlib.util.spec_from_file_location(
    'spec_list_inventory', MODULE.parent / 'spec-list-inventory.py')
if (MODULE.parent / 'spec-list-inventory.py').exists():
    reference = importlib.util.module_from_spec(ref_spec)
    ref_spec.loader.exec_module(reference)
else:
    reference = None


def envelope_offsets(payload):
    # Independent reference: split on the literal mboxo delimiter, including LF
    # in the previous occurrence. These tests use valid compact envelopes.
    starts = [0]
    pos = -1
    while True:
        pos = payload.find(b'\nFrom ', pos + 1)
        if pos == -1:
            break
        starts.append(pos + 1)
    ends = starts[1:] + [len(payload)]
    return list(zip(starts, ends)) if payload else []


def run_scan(payload, chunk):
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / 'mbox'
        path.write_bytes(payload)
        found = []
        before = idx.CHUNK
        try:
            idx.CHUNK = chunk
            with open(path, 'rb') as stream:
                count, digest = idx.scan(stream, len(payload), lambda *e: found.append(e), 0)
            return count, digest, found
        finally:
            idx.CHUNK = before


class IndexTests(unittest.TestCase):
    def test_chunk_boundary_and_occurrences(self):
        rng = random.Random(1024)
        lines = (b'abc', b'From z\n', b'>From x\n', b'\n', b'\xff\n', b'\nSubject: SPEC-LIST\n')
        for _ in range(75):
            parts = []
            for i in range(rng.randint(1, 10)):
                parts.append(b'From sample\nFrom: a@example.com\nSubject: ' +
                             (b'SPEC-LIST' if i % 2 == 0 else b'hello') + b'\n\n' +
                             b''.join(rng.choice(lines) for j in range(rng.randint(1, 20))))
            payload = b''.join(parts)
            expected = envelope_offsets(payload)
            for chunk in (1, 2, 3, 4, 5, 6, 7, 17, 31, 4096):
                count, digest, found = run_scan(payload, chunk)
                self.assertEqual([(e[1], e[2]) for e in found], expected)
                self.assertEqual(count, len(expected))
                self.assertEqual(digest, hashlib.sha256(payload).hexdigest())
                for (_, start, end, entry_digest, *_rest) in found:
                    self.assertEqual(entry_digest, hashlib.sha256(payload[start:end]).hexdigest())

    @unittest.skipIf(reference is None, 'requires existing reference inventory')
    def test_reference_inventory_agreement(self):
        rng = random.Random(317)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'mbox'
            for _ in range(50):
                entries = []
                for j in range(rng.randint(1, 12)):
                    headers = rng.choice((
                        b'From: SPEC-LIST\n', b'To: sample@example.com\n',
                        b'Subject: spec-\n list\n', b'Cc: SPEC-LIST\r\n',
                        b'List-Id: SPEC-LIST\n', b'Subject: something\n'))
                    body = rng.choice((b'abcdef\n', b'>From escaped\n',
                                       b'From split\n\n', b'\x00\xff\n'))
                    entries.append(b'From test\n' + headers + b'\n' + body)
                payload = b''.join(entries)
                path.write_bytes(payload)
                expected = reference.scan(path, 0, 0)
                count, digest, found = run_scan(payload, rng.choice((1, 5, 13, 4096)))
                self.assertEqual(count, expected['total'])
                self.assertEqual(sum(bool(e[4]) for e in found), expected['selected'])
                self.assertEqual(sum(e[2] - e[1] for e in found if e[4]),
                                 expected['selected_octets'])

    def test_build_verify_private_and_duplicates(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            mailbox = root / 'mbox'
            item = b'From a\nFrom: Alice\nDate: Fri, 23 Oct 2026 10:00:00 -0400\nSubject: SPEC-LIST\n\nText\n'
            mailbox.write_bytes(item + item + b'From b\nTo: Someone\n\nelse\n')
            untouched = mailbox.read_bytes()
            idx.build(mailbox, root / 'index', 0)
            idx.verify(mailbox, root / 'index', 0)
            snapshot = idx.current_snapshot(root / 'index')
            lists = (snapshot / 'lists.tsv').read_text().splitlines()
            self.assertEqual(len(lists), 2)
            self.assertEqual(lists[0].split('\t')[4], lists[1].split('\t')[4])
            self.assertNotEqual(lists[0].split('\t')[2], lists[1].split('\t')[2])
            self.assertEqual(mailbox.read_bytes(), untouched)
            self.assertEqual((root / 'index').stat().st_mode & 0o777, 0o700)
            self.assertEqual((snapshot / 'source.state').stat().st_mode & 0o777, 0o600)
            self.assertIn('2026-10-23T14:00:00Z', (snapshot / 'dates.tsv').read_text())
            self.assertIn('spec-list', (snapshot / 'subjects.tsv').read_text())
            # Future arrivals cannot silently make the index look current.
            with mailbox.open('ab') as f:
                f.write(b'From late\n\n')
            with self.assertRaisesRegex(idx.Refusal, 'SOURCE_CHANGED'):
                idx.verify(mailbox, root / 'index', 0)

    def test_corrupt_index_detected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / 'mbox'
            source.write_bytes(b'From a\nSubject: SPEC-LIST\n\n')
            idx.build(source, root / 'index', 0)
            snapshot = idx.current_snapshot(root / 'index')
            with (snapshot / 'messages.tsv').open('a') as f:
                f.write('garbage\n')
            with self.assertRaisesRegex(idx.Refusal, 'INDEX_CORRUPTED'):
                idx.verify(source, root / 'index', 0)

    def test_empty(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / 'empty'
            source.touch()
            idx.build(source, root / 'index', 0)
            idx.verify(source, root / 'index', 0)

    def test_mutation_during_build_refuses_publication(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / 'mbox'
            source.write_bytes(b'From a\n\n' + b'x' * 1000)
            original_scan = idx.scan
            def mutating_scan(stream, opening_size, callback, progress):
                result = original_scan(stream, opening_size, callback, progress)
                with source.open('ab') as f:
                    f.write(b'From newly-arrived\n\n')
                return result
            try:
                idx.scan = mutating_scan
                with self.assertRaisesRegex(idx.Refusal, 'CHANGED_DURING_SCAN'):
                    idx.build(source, root / 'index', 0)
                self.assertFalse((root / 'index' / 'CURRENT').exists())
            finally:
                idx.scan = original_scan

    def test_long_header_refused(self):
        payload = b'From a\nSubject: ' + b'a' * (idx.HEADER_LIMIT + 8) + b'\n\n'
        with self.assertRaisesRegex(idx.Refusal, 'oversized header'):
            run_scan(payload, 65536)

    def test_escape_controls(self):
        self.assertEqual(idx.plain(b'a\tb\nc\r\x1b\xff'), 'a\\tb\\nc\\r\\x1b\\\\xff')


if __name__ == '__main__':
    unittest.main()
