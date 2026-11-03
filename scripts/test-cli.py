#!/usr/bin/env python3
"""Exercise the shipped CLI as a subprocess against a real Unix socket."""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import unittest

BINARY = Path(sys.argv.pop(1) if len(sys.argv) > 1 else
              'build/Build/Products/Debug/Glint.app/Contents/Helpers/glint').resolve()
PANE = '12345678-1234-1234-1234-123456789abc:1'


class CLITests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='glint-cli-', dir='/tmp')
        self.root = Path(self.temp.name)
        self.path = self.root / 'control.sock'
        self.token = 'test-only-token'
        self.path.with_suffix('.token').write_text(self.token)
        self.path.with_suffix('.token').chmod(0o600)
        self.addCleanup(self.temp.cleanup)

    def run_cli(self, *args):
        return subprocess.run([str(BINARY), '--socket', str(self.path), *args],
                              text=True, capture_output=True, timeout=8)

    def exchange(self, args, response):
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(str(self.path))
        self.path.chmod(0o600)
        listener.listen(1)
        listener.settimeout(5)
        captured = []
        errors = []

        def serve():
            try:
                conn, _ = listener.accept()
                with conn:
                    with conn.makefile('rb') as reader:
                        captured.append(json.loads(reader.readline()))
                    payload = (json.dumps(response, ensure_ascii=False) + '\n').encode()
                    for offset in range(0, len(payload), 2048):
                        conn.sendall(payload[offset:offset + 2048])
            except Exception as error:
                errors.append(error)
            finally:
                listener.close()

        worker = threading.Thread(target=serve, daemon=True)
        worker.start()
        result = self.run_cli(*args)
        worker.join(6)
        self.assertFalse(worker.is_alive())
        self.assertFalse(errors, errors)
        self.assertEqual(len(captured), 1)
        return result, captured[0]

    def test_list(self):
        result, request = self.exchange(['panes', 'list'], {'ok': True, 'panes': [{'pane': PANE}]})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(request, {'cmd': 'list'})
        self.assertEqual(json.loads(result.stdout)['panes'][0]['pane'], PANE)

    def test_read_unicode_scrollback_and_large_partial_response(self):
        # Keep enough chunks to catch repeated scans of the accumulated response.
        text = ('你好😀\t  output\n' * 300000) + 'end'
        result, request = self.exchange(
            ['pane', 'read', PANE, '--scrollback', '--max-lines', '10000'],
            {'ok': True, 'pane': PANE, 'text': text})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, text + '\n')
        self.assertEqual(request, {'cmd': 'read-text', 'pane': PANE, 'scrollback': True,
                                   'maxLines': 10000, 'token': self.token})
        self.assertNotIn(self.token, result.stdout + result.stderr)

    def test_read_json(self):
        response = {'ok': True, 'text': 'hello\nworld'}
        result, _ = self.exchange(['pane', 'read', PANE, '--json'], response)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), response)

    def test_send_quoted_unicode_and_newlines(self):
        text = "literal '$HOME' `whoami`\n你好😀"
        result, request = self.exchange(['pane', 'send', PANE, '--text', text, '--enter'], {'ok': True})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(request['text'], text)
        self.assertIs(request['enter'], True)
        self.assertEqual(request['token'], self.token)

    def test_help_text_can_be_sent_as_input(self):
        result, request = self.exchange(['pane', 'send', PANE, '--text', '--help'], {'ok': True})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(request['text'], '--help')

    def test_help_after_socket_options_without_control(self):
        for prefix in [[], ['--debug'], ['--socket', str(self.path)]]:
            for command in [[], ['panes'], ['pane'], ['pane', 'read'],
                            ['pane', 'send'], ['pane', 'key'], ['pane', 'focus']]:
                with self.subTest(prefix=prefix, command=command):
                    result = subprocess.run([str(BINARY), *prefix, *command, '--help'],
                                            capture_output=True, text=True, timeout=5)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn('Usage / 用法:', result.stdout)
                    self.assertEqual(result.stderr, '')
        self.assertFalse(self.path.exists())

    def test_help_does_not_hide_invalid_socket_options(self):
        for options in [['--debug', '--debug'], ['--socket', str(self.path), '--debug'],
                        ['--debug', '--socket', str(self.path)], ['--unknown']]:
            with self.subTest(options=options):
                result = subprocess.run([str(BINARY), *options, '--help'],
                                        capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stdout, '')

    def test_keys(self):
        result, request = self.exchange(['pane', 'key', PANE, 'down', 'A', 'enter'], {'ok': True})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(request['keys'], ['down', 'A', 'enter'])
        self.assertEqual(request['token'], self.token)

    def test_focus_is_explicit(self):
        result, request = self.exchange(['pane', 'focus', PANE], {'ok': True})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(request, {'cmd': 'focus', 'pane': PANE})

    def test_server_rejection_has_failure_exit_and_no_token_leak(self):
        result, _ = self.exchange(['pane', 'read', PANE], {'ok': False, 'error': 'disabled'})
        self.assertEqual(result.returncode, 1)
        self.assertIn('disabled', result.stderr)
        self.assertEqual(result.stdout, '')
        self.assertNotIn(self.token, result.stderr)

    def test_offline_does_not_start_glint_or_create_socket(self):
        self.path.with_suffix('.token').unlink()
        for args in [['panes', 'list'], ['pane', 'read', PANE],
                     ['pane', 'send', PANE, '--text', 'hello'], ['pane', 'focus', PANE]]:
            result = self.run_cli(*args)
            self.assertEqual(result.returncode, 1)
            self.assertIn('External control', result.stderr)
            self.assertFalse(self.path.exists())
            self.assertFalse(self.path.with_suffix('.token').exists())

    def test_invalid_arguments_are_rejected_before_connecting(self):
        for args in [['unknown'], ['pane', 'read', 'bad'], ['pane', 'read', PANE, '--max-lines', '0'],
                     ['pane', 'read', PANE, '--max-lines', '10001'],
                     ['pane', 'read', PANE, '--max-lines', '2.5'],
                     ['pane', 'send', PANE, '--enter'], ['pane', 'key', PANE, 'ctrl-c'],
                     ['pane', 'focus', PANE, 'extra']]:
            result = self.run_cli(*args)
            self.assertEqual(result.returncode, 2, (args, result.stderr))

    def test_install_link_and_help_without_control(self):
        directory = self.root / 'bin'
        args = [str(BINARY), 'install', '--directory', str(directory)]
        result = subprocess.run(args, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        inode = (directory / 'glint').lstat().st_ino
        result = subprocess.run(args, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 1)
        self.assertEqual((directory / 'glint').lstat().st_ino, inode)
        link = directory / 'glint'
        self.assertTrue(link.is_symlink())
        self.assertEqual(link.resolve(), BINARY)
        result = subprocess.run(['glint', '--help'], env={**os.environ, 'PATH': str(directory)},
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('External control', result.stdout)
        self.assertFalse(self.path.exists())
        # Uninstalling through PATH resolves this CLI, not cwd/glint or the GUI.
        result = subprocess.run(['glint', 'uninstall', '--directory', str(directory)],
                                env={**os.environ, 'PATH': str(directory)},
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(link.exists())
        self.assertTrue(BINARY.is_file())
        result = subprocess.run(args, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_install_repairs_only_links_to_other_glint_bundles(self):
        directory = self.root / 'bin'
        directory.mkdir()
        link = directory / 'glint'
        old = self.root / 'Moved/Glint.app/Contents/Helpers/glint'
        link.symlink_to(old)
        result = subprocess.run([str(BINARY), 'install', '--directory', str(directory)],
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(link.resolve(), BINARY)
        link.unlink()
        link.symlink_to(old)
        result = subprocess.run([str(BINARY), 'uninstall', '--directory', str(directory)],
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(link.is_symlink())

    def test_install_and_uninstall_preserve_another_existing_glint(self):
        directory = self.root / 'bin'
        directory.mkdir()
        other = self.root / 'Other/Glint.app/Contents/Helpers/glint'
        other.parent.mkdir(parents=True)
        other.write_text('#!/bin/sh\nexit 0\n')
        other.chmod(0o755)
        link = directory / 'glint'
        link.symlink_to(other)
        inode = link.lstat().st_ino
        for command in ['install', 'uninstall']:
            result = subprocess.run([str(BINARY), command, '--directory', str(directory)],
                                    capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertEqual(link.resolve(), other.resolve())
            self.assertEqual(link.lstat().st_ino, inode)
            self.assertIn('another', result.stderr)
        self.assertTrue(other.is_file())

    def test_custom_socket_rejects_unsafe_permissions_without_sending_token(self):
        for target in ['directory', 'socket', 'token', 'token-symlink']:
            with self.subTest(target=target):
                listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                listener.bind(str(self.path))
                listener.listen(1)
                listener.settimeout(0.3)
                self.path.chmod(0o600)
                token = self.path.with_suffix('.token')
                if target == 'directory': self.root.chmod(0o755)
                if target == 'socket': self.path.chmod(0o666)
                if target == 'token': token.chmod(0o644)
                if target == 'token-symlink':
                    original = self.root / 'original-token'
                    token.rename(original)
                    token.symlink_to(original)
                requests = []
                def serve():
                    try:
                        conn, _ = listener.accept()
                        with conn:
                            requests.append(conn.recv(4096))
                            conn.sendall(b'{"ok":true,"text":"unsafe"}\n')
                    except (TimeoutError, BrokenPipeError): pass
                    finally: listener.close()
                worker = threading.Thread(target=serve, daemon=True)
                worker.start()
                result = self.run_cli('pane', 'read', PANE)
                worker.join(1)
                self.root.chmod(0o700)
                token.unlink()
                token.write_text(self.token)
                token.chmod(0o600)
                self.path.unlink()
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn('unsafe', result.stderr.lower())
                self.assertEqual(requests, [])

    def test_oversized_encoded_request_is_rejected_before_connecting(self):
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.addCleanup(listener.close)
        listener.bind(str(self.path))
        self.path.chmod(0o600)
        listener.listen(1)
        listener.settimeout(0.1)
        # JSON escaping expands this under-argv-limit input beyond the protocol limit.
        result = self.run_cli('pane', 'send', PANE, '--text', '\x01' * 180000)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn('request-too-large', result.stderr)
        self.assertNotIn(self.token, result.stderr)
        with self.assertRaises(TimeoutError): listener.accept()

    def test_uninstall_preserves_other_files_and_links(self):
        directory = self.root / 'bin'
        directory.mkdir()
        link = directory / 'glint'
        link.write_text('another tool')
        args = [str(BINARY), 'uninstall', '--directory', str(directory)]
        result = subprocess.run(args, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(link.read_text(), 'another tool')
        link.unlink()
        link.symlink_to('/missing/another-tool')
        result = subprocess.run(args, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(os.readlink(link), '/missing/another-tool')

    def test_uninstall_absent_reports_not_installed(self):
        result = subprocess.run([str(BINARY), 'uninstall', '--directory', str(self.root / 'absent')],
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 1)
        self.assertFalse((self.root / 'absent').exists())

    def test_install_preserves_other_files_and_links(self):
        directory = self.root / 'bin'
        directory.mkdir()
        link = directory / 'glint'
        link.write_text('other command')
        result = subprocess.run([str(BINARY), 'install', '--directory', str(directory)],
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(link.read_text(), 'other command')
        link.unlink()
        link.symlink_to('/missing/other-command')
        result = subprocess.run([str(BINARY), 'install', '--directory', str(directory)],
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(os.readlink(link), '/missing/other-command')


if __name__ == '__main__':
    unittest.main()
