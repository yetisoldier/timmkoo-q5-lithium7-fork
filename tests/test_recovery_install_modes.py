#!/usr/bin/env python3
"""Verify that upgrade mode cannot call the factory-reset data operations."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import unittest
from unittest.mock import patch

PATH = Path(__file__).resolve().parents[1] / 'build/install_adb_recovery.py'
spec = importlib.util.spec_from_file_location('q5_installer', PATH)
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class FakeRecovery:
    def __init__(self):
        self.commands = []
        self.version = '1.0.0'
        self.android = '7.1.2'
        self.packages = True
        self.keys = True
        self.key_hash = 'b' * 64

    def shell(self, command):
        self.commands.append(command)
        if command == 'cat /system/etc/q5-release.json':
            return json.dumps({'name': 'Lithium 7 for Q5 Gen 7 (Q5 Mint)',
                               'android': self.android, 'version': self.version})
        if command.startswith('twrp mount '):
            return 'Mounted'
        if command == 'sha256sum /data/system/packages.xml':
            assert self.packages, 'Missing package database'
            return 'a' * 64 + '  /data/system/packages.xml\n'
        if command.startswith('for key in '):
            return self.key_hash + '  /data/misc/vold/expand_1234-abcd.key\n' if self.keys else ''
        if command == 'twrp format data':
            self.packages = self.keys = False
            return 'Formatted'
        if command == 'twrp wipe cache':
            return 'Wiped'
        if command.startswith('test ! -e /data/system/packages.xml'):
            return 'clean' if not self.packages else ''
        if command.startswith('test ! -d /data/misc/vold'):
            return 'clean' if not self.keys else ''
        raise AssertionError('Unexpected recovery command')


class Modes(unittest.TestCase):
    def test_upgrade_preserves_data(self):
        recovery = FakeRecovery()
        before = installer.prepare_upgrade(recovery.shell)
        installer.finish_data(recovery.shell, False, before)
        self.assertTrue(recovery.packages and recovery.keys)
        self.assertFalse(any('format' in c or 'wipe' in c for c in recovery.commands))

    def test_changed_key_refused(self):
        recovery = FakeRecovery()
        before = installer.prepare_upgrade(recovery.shell)
        recovery.key_hash = 'c' * 64
        with self.assertRaises(AssertionError):
            installer.finish_data(recovery.shell, False, before)

    def test_unsupported_source_refused(self):
        for field, value in [('version', '0.9.0'), ('android', '4.4.2')]:
            recovery = FakeRecovery()
            setattr(recovery, field, value)
            with self.assertRaises(AssertionError):
                installer.prepare_upgrade(recovery.shell)

    def test_missing_data_refused(self):
        recovery = FakeRecovery()
        recovery.packages = False
        with self.assertRaises(AssertionError):
            installer.prepare_upgrade(recovery.shell)

    def test_factory_reset_is_explicit(self):
        recovery = FakeRecovery()
        installer.finish_data(recovery.shell, True, None)
        self.assertFalse(recovery.packages or recovery.keys)
        self.assertIn('twrp format data', recovery.commands)
        self.assertIn('twrp wipe cache', recovery.commands)

    def test_missing_upgrade_state_refused(self):
        with self.assertRaises(AssertionError):
            installer.finish_data(FakeRecovery().shell, False, None)

    def test_arguments_are_mutually_exclusive(self):
        for flags in [[], ['--upgrade', '--factory-reset']]:
            with patch('sys.argv', [str(PATH), '--serial', 'test', *flags]):
                with self.assertRaises(SystemExit) as error, contextlib.redirect_stderr(io.StringIO()):
                    installer.main()
                self.assertEqual(error.exception.code, 2)


if __name__ == '__main__':
    unittest.main()
