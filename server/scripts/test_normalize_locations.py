"""Tests for normalize_locations.py's data-file handling. Run: python3 -m unittest discover server/scripts"""
import contextlib
import importlib.util
import os
import tempfile
import unittest

_spec = importlib.util.spec_from_file_location(
    "normalize_locations", os.path.join(os.path.dirname(os.path.abspath(__file__)), "normalize_locations.py"))
nl = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(nl)


class DataFileTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = os.path.join(self._tmp.name, "data")
        os.mkdir(self.root)
        self.outside = os.path.join(self._tmp.name, "secret.txt")
        with open(self.outside, "w") as f:
            f.write("secret\n")

    def write(self, name, text):
        with open(os.path.join(self.root, name), "w") as f:
            f.write(text)

    def read(self, name):
        with nl.open_data_file(self.root, name, "--test") as f:
            return f.read()

    def test_reads_a_file_inside(self):
        self.write("a.txt", "hello")
        self.assertEqual(self.read("a.txt"), "hello")

    def test_rejects_parent_escape(self):
        with self.assertRaises(SystemExit) as cm:
            self.read("../secret.txt")
        self.assertIn("outside", str(cm.exception))

    def test_rejects_symlink_pointing_outside(self):
        os.symlink(self.outside, os.path.join(self.root, "link.txt"))
        with self.assertRaises(SystemExit) as cm:
            self.read("link.txt")
        self.assertIn("outside", str(cm.exception))

    def test_rejects_directory(self):
        os.mkdir(os.path.join(self.root, "sub"))
        with self.assertRaises(SystemExit) as cm:
            self.read("sub")
        self.assertIn("not a readable file", str(cm.exception))

    def test_rejects_missing_file(self):
        with self.assertRaises(SystemExit):
            self.read("nope.txt")

    def test_rejects_missing_data_dir(self):
        with self.assertRaises(SystemExit) as cm:
            with nl.open_data_file(os.path.join(self.root, "gone"), "a.txt", "--test"):
                pass
        self.assertIn("not a directory", str(cm.exception))

    def test_filesystem_root_as_data_dir(self):
        target = os.path.realpath(self.outside)
        rel = os.path.relpath(target, "/")
        with nl.open_data_file("/", rel, "--test") as f:
            self.assertEqual(f.read(), "secret\n")

    def test_empty_countries_file_exits(self):
        self.write("countries.tsv", "")
        with self.assertRaises(SystemExit) as cm:
            nl.load_countries(self.root, "countries.tsv", "--countries")
        self.assertIn("no countries loaded", str(cm.exception))

    def test_empty_cities_file_names_the_file(self):
        self.write("cities.txt", "")
        with self.assertRaises(SystemExit) as cm:
            nl.load_cities(self.root, "cities.txt", "--cities")
        self.assertIn("'cities.txt'", str(cm.exception))

    def test_default_countries_table_loads(self):
        codes = nl.load_countries(os.path.dirname(nl.COUNTRIES_TSV), os.path.basename(nl.COUNTRIES_TSV), "default")
        self.assertIn("US", codes)


if __name__ == "__main__":
    with contextlib.suppress(SystemExit):
        unittest.main()
