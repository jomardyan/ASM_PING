"""Windows regression tests. Run `py -3 tests/test_ping.py` after build.ps1.

Real probes use loopback only. Instrumented executables exercise Win32 failure
paths and malformed replies without relying on DNS, routers, or a firewall.
"""
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
BUILD_DIR = Path(os.environ.get('PING_TEST_BUILD_DIR', str(ROOT))).resolve()
EXE = BUILD_DIR / 'ping.exe'
ANSI = re.compile(r'\x1b\[[0-9;]*m')
TIMESTAMP = re.compile(r'^\[(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z)\] (.+)$',
                       re.MULTILINE)


def application_source():
    source = (ROOT / 'ping_win64.asm').read_text()
    # Inline the resolver before replacing Win32 boundaries in the test build.
    return source.replace('%include "net_resolve.asm"',
                          (ROOT / 'net_resolve.asm').read_text())


def run_ping(args, *, exe=EXE, pretty=None, mode=None):
    env = os.environ.copy()
    env.pop('PING_PRETTY', None)
    if pretty is not None:
        env['PING_PRETTY'] = pretty
    if mode is not None:
        env['PING_TEST_MODE'] = str(mode)
    return subprocess.run([str(exe), *args], capture_output=True, timeout=10,
                          env=env, encoding='utf-8', errors='strict')


def interrupt_worker(exe, mode, target='127.0.0.1', flood='0', interval='0'):
    """Runs in a separate hidden console so CTRL_BREAK cannot affect the caller."""
    env = os.environ.copy()
    env.pop('PING_PRETTY', None)
    env['PING_TEST_MODE'] = mode
    flags = ['--flood'] if flood == '1' else []
    if interval != '0':
        flags += ['--interval', interval]
    p = subprocess.Popen([exe, *flags, '-t', '-w', '600000', target],
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env,
                         creationflags=subprocess.CREATE_NEW_PROCESS_GROUP)
    try:
        time.sleep(0.4)
        start = time.monotonic()
        p.send_signal(signal.CTRL_BREAK_EVENT)
        out, err = p.communicate(timeout=3)
        print(json.dumps({'elapsed': time.monotonic() - start,
                          'code': p.returncode, 'out': out.decode(),
                          'err': err.decode()}))
    finally:
        if p.poll() is None:
            p.kill()
            p.communicate()


class PingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if sys.platform != 'win32':
            raise unittest.SkipTest('Windows x64 is required')
        if not EXE.is_file():
            raise RuntimeError(f'Build the application first with build.ps1: {EXE}')
        nasm_version = json.loads((ROOT / 'build/nasm.json').read_text(encoding='utf-8'))['version']
        cached_nasm = ROOT / '.ping-build' / 'tools' / ('nasm-' + nasm_version) / 'nasm.exe'
        cls.nasm = os.environ.get('PING_TEST_NASM') or str(cached_nasm)
        if not Path(cls.nasm).is_file():
            raise RuntimeError('NASM not found. Run build.ps1 first or set PING_TEST_NASM.')
        cls.temp = tempfile.TemporaryDirectory(prefix='ping tests ')
        cls.addClassCleanup(cls.temp.cleanup)
        cls.work = Path(cls.temp.name)
        cls.mock = cls.work / 'mock ping.exe'
        vswhere = Path(os.environ['ProgramFiles(x86)']) / 'Microsoft Visual Studio/Installer/vswhere.exe'
        linker = os.environ.get('PING_TEST_LINKER')
        if not linker:
            linker = subprocess.check_output([
                str(vswhere), '-latest', '-products', '*', '-requires',
                'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '-find',
                r'VC\Tools\MSVC\**\bin\Hostx64\x64\link.exe'], text=True).strip().splitlines()[0]
        cls.linker = linker
        source = application_source()
        for name in ('GetConsoleMode', 'SetConsoleMode', 'GetConsoleOutputCP',
                     'getaddrinfo', 'freeaddrinfo', 'getnameinfo',
                     'SetConsoleCtrlHandler', 'GetLastError', 'GetSystemTime',
                     'IcmpCreateFile', 'Icmp6CreateFile', 'IcmpSendEcho2',
                     'IcmpSendEcho2Ex', 'Icmp6SendEcho2', 'IcmpCloseHandle',
                     'CreateThread', 'WriteFile'):
            source = re.sub(r'\bcall\s+' + name + r'\b', 'call    test_' + name, source)
        source += '\n' + (ROOT / 'tests/winapi_stubs.asm').read_text()
        cls.assemble(source, cls.mock, 'main')

    @classmethod
    def assemble(cls, source, exe, entry):
        asm = exe.with_suffix('.asm')
        obj = exe.with_suffix('.obj')
        asm.write_text(source, encoding='utf-8')
        subprocess.run([cls.nasm, '-f', 'win64',
                        '-Wall', '-w-reloc', '-Werror', str(asm), '-o', str(obj)],
                       check=True, capture_output=True)
        libs = [str(BUILD_DIR / '.ping-build' / (name + '.lib'))
                for name in ('kernel32', 'shell32', 'ws2_32', 'iphlpapi')]
        subprocess.run([cls.linker, '/nologo', '/machine:x64', '/subsystem:console',
                        '/entry:' + entry, '/nodefaultlib', '/out:' + str(exe),
                        str(obj), *libs], check=True, capture_output=True)

    def assert_table(self, output):
        lines = [line for line in ANSI.sub('', output).splitlines() if line]
        self.assertTrue(lines)
        self.assertTrue(all(len(line) == 80 for line in lines),
                        [(len(line), line) for line in lines if len(line) != 80])

    def test_loopback_and_payload_bounds(self):
        for size in (0, 32, 65500):
            with self.subTest(size=size):
                p = run_ping(['-n', '1', '-l', str(size), '127.0.0.1'])
                self.assertEqual(p.returncode, 0, p.stdout)
                self.assertIn(f'bytes={size}', p.stdout)
                self.assertIn('Sent = 1, Received = 1, Lost = 0 (0% loss)', p.stdout)
                self.assertNotIn('\x1b', p.stdout)
                self.assertNotIn('time=<', p.stdout)

    def test_real_options_and_reverse_lookup(self):
        p = run_ping(['/n1', '-l0', '-i64', '-v0', '-f', '-r9', '-a', '-4', 'localhost'])
        self.assertEqual(p.returncode, 0, p.stdout)
        self.assertIn('Received = 1', p.stdout)

    def test_ipv6_loopback_payload_bounds_and_implicit_family(self):
        for size in (0, 32, 65500):
            for family in ([], ['-6']):
                with self.subTest(size=size, family=family):
                    p = run_ping([*family, '-n1', '-l', str(size), '::1'])
                    self.assertEqual(p.returncode, 0, p.stdout)
                    self.assertIn(f'Reply from ::1: bytes={size}', p.stdout)
                    self.assertIn('Sent = 1, Received = 1, Lost = 0 (0% loss)', p.stdout)
                    self.assertNotIn('TTL=', p.stdout)

    def test_ipv6_hostname_hop_limit_and_reverse_lookup(self):
        for flags in (['-6'], ['-6', '-a'], ['-6', '-i64'], ['/6', '/i64']):
            with self.subTest(flags=flags):
                p = run_ping([*flags, '-n1', 'localhost'])
                self.assertEqual(p.returncode, 0, p.stdout)
                self.assertIn('::1', p.stdout)
                self.assertIn('Received = 1', p.stdout)
                self.assertNotIn('TTL=', p.stdout)
        p = run_ping(['-n1', 'localhost'])
        self.assertEqual(p.returncode, 0, p.stdout)
        self.assertIn('127.0.0.1', p.stdout)

    def test_source_selection_loopback_and_argument_forms(self):
        cases = [(['-4', '-S', '127.0.0.1'], '127.0.0.1'),
                 (['-S127.0.0.1'], 'localhost'),
                 (['--source', '127.0.0.1'], '127.0.0.1'),
                 (['-6', '-S', '::1'], '::1'),
                 (['-S::1'], 'localhost'),
                 (['--source', '::1'], '::1'),
                 (['/S::1'], '::1'),
                 (['-S', '::1%0'], '::1')]
        for flags, target in cases:
            with self.subTest(flags=flags, target=target):
                p = run_ping([*flags, '-n1', target])
                self.assertEqual(p.returncode, 0, p.stdout)
                self.assertIn('Source', p.stdout)
                self.assertIn('Sent = 1, Received = 1, Lost = 0 (0% loss)', p.stdout)
                if '::1' in ' '.join(flags):
                    self.assertNotIn('TTL=', p.stdout)
                else:
                    self.assertIn('TTL=', p.stdout)

    def test_address_family_conflicts_and_ipv4_only_options(self):
        for flags, target in [(['-4'], '::1'), (['-6'], '127.0.0.1'),
                              (['-4', '-6'], '::1'), (['-6', '-4'], '127.0.0.1'),
                              (['-4', '-S::1'], '127.0.0.1'),
                              (['-6', '-S127.0.0.1'], '::1'),
                              (['-S127.0.0.1'], '::1'),
                              (['-S::1'], '127.0.0.1')]:
            with self.subTest(flags=flags, target=target):
                p = run_ping([*flags, '-n1', target])
                self.assertEqual(p.returncode, 2, p.stdout)
                self.assertNotIn('Reply from ', p.stdout)
        for option in ('-f', '-r1', '-v0', '-v255'):
            for family in ([], ['-6']):
                with self.subTest(option=option, family=family):
                    p = run_ping([*family, option, '-n1', '::1'])
                    self.assertEqual(p.returncode, 2, p.stdout)
                    self.assertIn('IPv4', p.stdout)

    def test_source_requires_numeric_address_and_valid_scope(self):
        for source in ('', 'localhost', 'example.test', 'bad host', '::gg',
                       '127.0.0.1x', '::1%not-an-index', '1:2:3:4:5:6:7:8:9',
                       '::1%', '::1%4294967296', '::1%1%2', '127.0.0.1%1',
                       '\x1b[31m', 'h\u00f4st', 'a' * 256):
            for option in ('-S', '--source'):
                with self.subTest(option=option, source=source[:40]):
                    p = run_ping([option, source, '-n1', '127.0.0.1'])
                    self.assertEqual(p.returncode, 2, p.stdout)
                    self.assertNotIn('Reply from ', p.stdout)
        for option in ('-S', '--source'):
            p = run_ping([option])
            self.assertEqual(p.returncode, 2, p.stdout)
        for target in ('::1%', '::1%4294967296', '::1%1%2', '127.0.0.1%1'):
            with self.subTest(target=target):
                p = run_ping(['-n1', target])
                self.assertEqual(p.returncode, 2, p.stdout)
                self.assertNotIn('Reply from ', p.stdout)

    def test_ipv6_tables_source_and_missing_returned_ttl(self):
        for size in (0, 65500):
            p = run_ping(['-6', '-S::1', '-n1', '-l', str(size), '::1'], pretty='1')
            self.assertEqual(p.returncode, 0, p.stdout)
            self.assert_table(p.stdout)
            self.assertIn('Source', p.stdout)
            self.assertIn('::1', p.stdout)
            self.assertRegex(ANSI.sub('', p.stdout), r'\u2502\s*1\s*\u2502[^\n]+\u2502\s*-\s*\u2502')

    def test_ipv6_flood_interval_quiet_and_timestamps(self):
        p = run_ping(['-6', '-S::1', '--flood', '--interval', '600000',
                      '--timestamp', '-n3', '::1'], pretty='1')
        self.assertEqual(p.returncode, 0, p.stdout)
        records = TIMESTAMP.findall(p.stdout)
        self.assertEqual(len(records), 3, p.stdout)
        self.assertTrue(all(result.startswith('Reply from ::1:') for _, result in records))
        self.assertIn('Sent = 3, Received = 3, Lost = 0 (0% loss)', p.stdout)
        self.assertNotIn('TTL=', p.stdout)
        start = time.monotonic()
        p = run_ping(['--quiet', '--interval', '100', '-6', '-n3', '::1'])
        self.assertEqual(p.returncode, 0, p.stdout)
        self.assertGreaterEqual(time.monotonic() - start, 0.18)
        self.assertIn('Sent = 3, Received = 3, Lost = 0 (0% loss)', p.stdout)
        self.assertNotIn('Reply from ', p.stdout)

    def test_source_api_arguments_and_ipv6_fixture_replies(self):
        for target in ('127.0.0.1', '::1'):
            for pretty in (None, '1'):
                with self.subTest(target=target, pretty=pretty):
                    p = run_ping(['-S', target, '-n1', '-w17', target],
                                 exe=self.mock, mode=26, pretty=pretty)
                    self.assertEqual(p.returncode, 0, p.stdout)
                    self.assertIn('23ms', p.stdout)
                    if pretty:
                        self.assert_table(p.stdout)
                    else:
                        self.assertIn('Sent = 1, Received = 1', p.stdout)

    def test_ipv6_network_errors_and_setup_failure(self):
        for mode, expected in ((2, 'Request timed out.'), (3, 'General failure.'),
                               (4, 'Transmit failed, error 54321'),
                               (22, 'Reply from 2001:db8::1: Hop limit expired in transit.'),
                               (23, 'Destination unreachable.'),
                               (24, 'Packet too big.'), (25, 'IPv6 scope mismatch.')):
            for pretty in (None, '1'):
                with self.subTest(mode=mode, pretty=pretty):
                    p = run_ping(['-6', '--flood', '-n2', '::1'],
                                 exe=self.mock, mode=mode, pretty=pretty)
                    self.assertEqual(p.returncode, 1, p.stdout)
                    self.assertIn(expected.lower(), p.stdout.lower())
                    if pretty:
                        self.assert_table(p.stdout)
                    else:
                        self.assertIn('Sent = 2, Received = 0, Lost = 2 (100% loss)', p.stdout)
                    self.assertNotIn('Average =', p.stdout)
        p = run_ping(['-6', '-n1', '::1'], exe=self.mock, mode=19)
        self.assertEqual(p.returncode, 2, p.stdout)
        self.assertIn('error: could not create ICMP handle', p.stdout)

    def test_ipv6_worker_creation_failure(self):
        p = run_ping(['-6', '-n1', '::1'], exe=self.mock, mode=28)
        self.assertEqual(p.returncode, 2, p.stdout)
        self.assertIn('error:', p.stdout)
        self.assertNotIn('Reply from ', p.stdout)

    def test_scoped_ipv6_reply_formatting_and_reverse_name_match(self):
        p = run_ping(['-6', '-a', '-Sfe80::1%12', '-n1', 'fe80::1%12'],
                     exe=self.mock, mode=29)
        self.assertEqual(p.returncode, 0, p.stdout)
        self.assertIn('Source address: fe80::1%12', p.stdout)
        self.assertIn('Reply from scoped-test [fe80::1%12]: bytes=32 time=23ms', p.stdout)
        self.assertNotIn('TTL=', p.stdout)

    def test_failures_have_failure_exit_code(self):
        p = run_ping(['-n1', '-w1', '0.0.0.0'])
        self.assertEqual(p.returncode, 1, p.stdout)
        self.assertIn('Lost = 1 (100% loss)', p.stdout)
        self.assertNotIn('Average =', p.stdout)

    def test_invalid_numeric_values(self):
        cases = {'n': ('0', '100001', '4294967297'),
                 'l': ('65501', '4294967296'),
                 'w': ('0', '600001', '4294967297'),
                 'i': ('0', '256', '4294967297'),
                 'v': ('256', '4294967296'),
                 'r': ('0', '10', '4294967297')}
        for opt, values in cases.items():
            for value in (*values, '', '-1', '+1', '1x', '9' * 1000):
                with self.subTest(opt=opt, value=value[:30]):
                    p = run_ping(['-' + opt, value, '127.0.0.1'])
                    self.assertEqual(p.returncode, 2, p.stdout)
                    self.assertIn('invalid or missing option value', p.stdout)
            self.assertEqual(run_ping(['-' + opt]).returncode, 2)

    def test_exact_flags_and_unsupported_options(self):
        for flag in ('-fgarbage', '-t1', '-a1', '-41', '-hxxx', '/?x', '-', '-z',
                     '-61', '-j', '-k', '-s', '-R'):
            with self.subTest(flag=flag):
                p = run_ping([flag, '127.0.0.1'])
                self.assertEqual(p.returncode, 2)
                self.assertNotIn('\x00', p.stdout)

    def test_invalid_targets_and_duplicates(self):
        for target in ('', 'a' * 256, 'b' * 20000, 'bad host', '\x1b[31m', 'h\u00f4st'):
            with self.subTest(target=target[:30]):
                p = run_ping(['-n1', target])
                self.assertEqual(p.returncode, 2, p.stdout)
                self.assertIn('target must be', p.stdout)
        self.assertEqual(run_ping(['127.0.0.1', 'localhost']).returncode, 2)

    def test_help_and_missing_target(self):
        for flag in ('-h', '-?', '/?', '/H'):
            p = run_ping([flag])
            self.assertEqual(p.returncode, 0)
            self.assertIn('usage:', p.stdout)
        self.assertEqual(run_ping([]).returncode, 1)

    def test_quoted_unicode_executable_and_arguments(self):
        target = self.work / 'ping with spaces \u03bb.exe'
        shutil.copyfile(EXE, target)
        env = os.environ.copy()
        env.pop('PING_PRETTY', None)
        p = subprocess.run(f'"{target}" -n "1" "127.0.0.1"', capture_output=True,
                           text=True, timeout=5, env=env)
        self.assertEqual(p.returncode, 0, p.stdout)
        self.assertIn('Received = 1', p.stdout)

    def test_pretty_widths_and_environment_exactness(self):
        p = run_ping(['-n1', '-l65500', '127.0.0.1'], pretty='1')
        self.assertEqual(p.returncode, 0)
        self.assert_table(p.stdout)
        self.assertIn('65500', p.stdout)
        for value in ('0', '10', '1garbage', '1' * 100):
            p = run_ping(['-n1', '127.0.0.1'], pretty=value)
            self.assertNotIn('\x1b', p.stdout)
            self.assertIn('Pinging ', p.stdout)

    def test_timing_has_no_final_sleep(self):
        start = time.monotonic()
        p = run_ping(['-n2', '127.0.0.1'])
        elapsed = time.monotonic() - start
        self.assertEqual(p.returncode, 0)
        self.assertIn('Sent = 2, Received = 2', p.stdout)
        self.assertGreaterEqual(elapsed, 0.9)
        self.assertLess(elapsed, 2.5)

    def test_flood_count_and_unpaced_loopback(self):
        timings = {}
        for flood in (False, True):
            flags = ['--flood'] if flood else []
            start = time.monotonic()
            p = run_ping([*flags, '-n3', '127.0.0.1'])
            timings[flood] = time.monotonic() - start
            self.assertEqual(p.returncode, 0, p.stdout)
            self.assertEqual(p.stdout.count('Reply from '), 3, p.stdout)
            self.assertIn('Sent = 3, Received = 3, Lost = 0 (0% loss)', p.stdout)
        self.assertGreaterEqual(timings[False], 1.8, timings)
        self.assertLess(timings[True], timings[False] - 0.8, timings)

    def test_flood_defaults_and_existing_options(self):
        p = run_ping(['--flood', '127.0.0.1'])
        self.assertEqual(p.returncode, 0, p.stdout)
        self.assertEqual(p.stdout.count('Reply from '), 4, p.stdout)
        self.assertIn('Sent = 4, Received = 4, Lost = 0 (0% loss)', p.stdout)
        # The long flag works after the target and alongside Don't Fragment.
        p = run_ping(['-n2', '-f', '-w25', '127.0.0.1', '--flood'], pretty='1')
        self.assertEqual(p.returncode, 0, p.stdout)
        self.assert_table(p.stdout)
        output = ANSI.sub('', p.stdout)
        self.assertRegex(output, r'Sent\s*\u2502 2')
        self.assertRegex(output, r'Received\s*\u2502 2')

    def test_flood_flag_is_exact_and_case_sensitive(self):
        for flag in ('--flood1', '--flood=1', '--flooding', '--floo', '--Flood',
                     '--FLOOD', '-flood', '/flood', '/-flood', '---flood'):
            with self.subTest(flag=flag):
                p = run_ping([flag, '127.0.0.1'])
                self.assertEqual(p.returncode, 2, p.stdout)
                self.assertNotIn('Reply from ', p.stdout)

    def test_flood_failure_statistics_and_no_error_delay(self):
        for mode, expected in ((1, 'Reply from 192.0.2.1: TTL expired'),
                               (2, 'Request timed out.'), (3, 'General failure.'),
                               (4, 'Transmit failed, error 54321')):
            with self.subTest(mode=mode):
                start = time.monotonic()
                p = run_ping(['--flood', '-n3', '-w1', '127.0.0.1'],
                             exe=self.mock, mode=mode)
                elapsed = time.monotonic() - start
                self.assertEqual(p.returncode, 1, p.stdout)
                self.assertEqual(p.stdout.count(expected), 3, p.stdout)
                self.assertIn('Sent = 3, Received = 0, Lost = 3 (100% loss)', p.stdout)
                self.assertNotIn('Average =', p.stdout)
                self.assertLess(elapsed, 1.5)

    def test_interval_bounds_and_separate_values(self):
        for value in ('1', '600000'):
            with self.subTest(value=value):
                start = time.monotonic()
                p = run_ping(['--interval', value, '-n1', '127.0.0.1'])
                self.assertEqual(p.returncode, 0, p.stdout)
                self.assertIn('Sent = 1, Received = 1', p.stdout)
                self.assertLess(time.monotonic() - start, 1.5)
        for value in ('0', '600001', '4294967296', '4294967297', '', '-1',
                      '+1', '1x', '1.5', '9' * 1000):
            with self.subTest(value=value[:30]):
                p = run_ping(['--interval', value, '127.0.0.1'])
                self.assertEqual(p.returncode, 2, p.stdout)
                self.assertIn('invalid or missing option value', p.stdout)
        p = run_ping(['--interval'])
        self.assertEqual(p.returncode, 2, p.stdout)
        self.assertIn('invalid or missing option value', p.stdout)

    def test_new_long_options_are_exact_and_case_sensitive(self):
        for option in ('interval', 'quiet', 'timestamp', 'source'):
            for flag in (f'--{option}1', f'--{option}=1', f'--{option}ing',
                         '--' + option[:-1], '--' + option.title(),
                         '--' + option.upper(), '-' + option,
                         '/' + option, '/-' + option, '---' + option):
                with self.subTest(flag=flag):
                    p = run_ping([flag, '127.0.0.1'])
                    self.assertEqual(p.returncode, 2, p.stdout)
                    self.assertNotIn('Reply from ', p.stdout)

    def test_interval_paces_requests_and_flood_overrides_in_either_order(self):
        start = time.monotonic()
        p = run_ping(['-n3', '127.0.0.1', '--interval', '150'])
        elapsed = time.monotonic() - start
        self.assertEqual(p.returncode, 0, p.stdout)
        self.assertIn('Sent = 3, Received = 3', p.stdout)
        self.assertGreaterEqual(elapsed, 0.25)
        self.assertLess(elapsed, 1.5)
        for flags in (['--interval', '600000', '--flood'],
                      ['--flood', '--interval', '600000']):
            with self.subTest(flags=flags):
                start = time.monotonic()
                p = run_ping([*flags, '-n3', '127.0.0.1'])
                self.assertEqual(p.returncode, 0, p.stdout)
                self.assertIn('Sent = 3, Received = 3', p.stdout)
                self.assertLess(time.monotonic() - start, 1.5)

    def test_quiet_preserves_success_statistics_and_suppresses_routes(self):
        for pretty in (None, '1'):
            with self.subTest(pretty=pretty):
                p = run_ping(['--flood', '-n3', '-r2', '127.0.0.1', '--quiet'],
                             exe=self.mock, mode=5, pretty=pretty)
                self.assertEqual(p.returncode, 0, p.stdout)
                self.assertNotIn('Reply from ', p.stdout)
                self.assertNotIn('route:', p.stdout)
                self.assertNotIn('192.0.2.1', p.stdout)
                self.assertNotIn('TTL', p.stdout)
                self.assertNotIn('From', p.stdout)
                if pretty:
                    self.assert_table(p.stdout)
                    self.assertIn('PING ', p.stdout)
                    self.assertRegex(p.stdout, r'Sent\s*\u2502 3')
                    self.assertRegex(p.stdout, r'Received\s*\u2502 3')
                    self.assertRegex(p.stdout, r'Lost\s*\u2502 0')
                    for metric in ('Min RTT', 'Max RTT', 'Avg RTT'):
                        self.assertRegex(p.stdout, metric + r'\s*\u2502 23ms')
                else:
                    self.assertIn('Pinging ', p.stdout)
                    self.assertIn('Sent = 3, Received = 3, Lost = 0 (0% loss)', p.stdout)
                    self.assertIn('Minimum = 23ms, Maximum = 23ms, Average = 23ms', p.stdout)

    def test_quiet_network_failures_still_count_as_lost(self):
        for pretty in (None, '1'):
            for mode in (1, 2, 3, 4):
                with self.subTest(pretty=pretty, mode=mode):
                    p = run_ping(['--quiet', '--flood', '-n3', '127.0.0.1'],
                                 exe=self.mock, mode=mode, pretty=pretty)
                    self.assertEqual(p.returncode, 1, p.stdout)
                    for hidden in ('Reply from ', 'Request timed out.', 'General failure.',
                                   'Transmit failed', 'TTL expired', 'Average ='):
                        self.assertNotIn(hidden, p.stdout)
                    if pretty:
                        self.assert_table(p.stdout)
                        self.assertRegex(p.stdout, r'Sent\s*\u2502 3')
                        self.assertRegex(p.stdout, r'Received\s*\u2502 0')
                        self.assertRegex(p.stdout, r'Lost\s*\u2502 3')
                        self.assertRegex(p.stdout, r'Loss\s*\u2502 100%')
                        self.assertRegex(p.stdout, r'Min RTT\s*\u2502 -')
                    else:
                        self.assertIn('Sent = 3, Received = 0, Lost = 3 (100% loss)', p.stdout)

    def test_quiet_before_first_probe_and_diagnostic_errors(self):
        for pretty in (None, '1'):
            p = run_ping(['--quiet', '-t', '127.0.0.1'],
                         exe=self.mock, mode=11, pretty=pretty)
            self.assertEqual(p.returncode, 1, p.stdout)
            if pretty:
                self.assert_table(p.stdout)
                self.assertRegex(p.stdout, r'Sent\s*\u2502 0')
            else:
                self.assertIn('Sent = 0, Received = 0, Lost = 0 (0% loss)', p.stdout)
        for flags in (['--quiet'], ['--timestamp'], ['--quiet', '--timestamp']):
            with self.subTest(flags=flags):
                p = run_ping([*flags, '--interval', '0', '127.0.0.1'])
                self.assertEqual(p.returncode, 2, p.stdout)
                self.assertIn('invalid or missing option value', p.stdout)
                p = run_ping([*flags, '-n1', '127.0.0.1'], exe=self.mock, mode=19)
                self.assertEqual(p.returncode, 2, p.stdout)
                self.assertIn('error: could not create ICMP handle', p.stdout)
                self.assertEqual(TIMESTAMP.findall(p.stdout), [])

    def test_timestamp_is_current_utc_and_forces_plain_output(self):
        for exe, mode, pretty in ((EXE, None, None), (EXE, None, '1'),
                                  (self.mock, 16, None), (self.mock, 17, None),
                                  (self.mock, 15, '1')):
            with self.subTest(mode=mode, pretty=pretty):
                before = datetime.now(timezone.utc)
                p = run_ping(['--timestamp', '--flood', '-n2', '127.0.0.1'],
                             exe=exe, mode=mode, pretty=pretty)
                after = datetime.now(timezone.utc)
                self.assertEqual(p.returncode, 0, p.stdout)
                self.assertIn('Pinging ', p.stdout)
                self.assertIn('Sent = 2, Received = 2', p.stdout)
                self.assertNotIn('\x1b', p.stdout)
                self.assertNotIn('\u2502', p.stdout)
                records = TIMESTAMP.findall(p.stdout)
                self.assertEqual(len(records), 2, p.stdout)
                for stamp, result in records:
                    parsed = datetime.strptime(stamp, '%Y-%m-%dT%H:%M:%S.%fZ').replace(
                        tzinfo=timezone.utc)
                    self.assertGreaterEqual(parsed, before - timedelta(seconds=1))
                    self.assertLessEqual(parsed, after + timedelta(seconds=1))
                    self.assertTrue(result.startswith('Reply from '), result)

    def test_timestamp_padding_and_route_continuation(self):
        for mode, expected in ((20, '2026-01-02T03:04:05.006Z'),
                               (21, '2026-12-31T23:59:59.999Z')):
            with self.subTest(mode=mode):
                p = run_ping(['--timestamp', '-n1', '127.0.0.1'], exe=self.mock, mode=mode)
                self.assertEqual(p.returncode, 0, p.stdout)
                records = TIMESTAMP.findall(p.stdout)
                self.assertEqual(len(records), 1, p.stdout)
                self.assertEqual(records[0][0], expected)
        p = run_ping(['--timestamp', '-n1', '-r2', '127.0.0.1'], exe=self.mock, mode=5)
        self.assertEqual(p.returncode, 0, p.stdout)
        self.assertEqual(len(TIMESTAMP.findall(p.stdout)), 1, p.stdout)
        self.assertRegex(p.stdout, r'TTL=64\n route: 192\.0\.2\.1 198\.51\.100\.2\n')

    def test_timestamp_network_errors_and_quiet_precedence(self):
        for mode, expected in ((1, 'Reply from 192.0.2.1: TTL expired'),
                               (2, 'Request timed out.'), (3, 'General failure.'),
                               (4, 'Transmit failed, error 54321')):
            with self.subTest(mode=mode):
                p = run_ping(['--timestamp', '--flood', '-n2', '127.0.0.1'],
                             exe=self.mock, mode=mode, pretty='1')
                self.assertEqual(p.returncode, 1, p.stdout)
                records = TIMESTAMP.findall(p.stdout)
                self.assertEqual(len(records), 2, p.stdout)
                self.assertTrue(all(result.startswith(expected) for _, result in records))
                self.assertIn('Sent = 2, Received = 0, Lost = 2 (100% loss)', p.stdout)
        for flags in (['--quiet', '--timestamp'], ['--timestamp', '--quiet']):
            for mode, code in ((5, 0), (2, 1)):
                with self.subTest(flags=flags, mode=mode):
                    p = run_ping([*flags, '--flood', '-n2', '-r2', '127.0.0.1'],
                                 exe=self.mock, mode=mode, pretty='1')
                    self.assertEqual(p.returncode, code, p.stdout)
                    self.assertIn('Ping statistics', p.stdout)
                    self.assertIn('Sent = 2', p.stdout)
                    self.assertNotIn('\x1b', p.stdout)
                    self.assertNotIn('Reply from ', p.stdout)
                    self.assertNotIn('Request timed out.', p.stdout)
                    self.assertNotIn('route:', p.stdout)
                    self.assertEqual(TIMESTAMP.findall(p.stdout), [])

    def test_status_and_error_messages(self):
        for mode, expected in ((1, 'Reply from 192.0.2.1: TTL expired'),
                               (2, 'Request timed out.'), (3, 'General failure.'),
                               (4, 'Transmit failed, error 54321')):
            for pretty in (None, '1'):
                with self.subTest(mode=mode, pretty=pretty):
                    p = run_ping(['-n1', '127.0.0.1'], exe=self.mock, mode=mode, pretty=pretty)
                    self.assertEqual(p.returncode, 1, p.stdout)
                    self.assertIn(expected, p.stdout)
                    if pretty:
                        self.assert_table(p.stdout)

    def test_route_decoding_and_malformed_options(self):
        p = run_ping(['-n1', '-r2', '127.0.0.1'], exe=self.mock, mode=5)
        self.assertEqual(p.returncode, 0, p.stdout)
        self.assertIn('route: 192.0.2.1 198.51.100.2', p.stdout)
        for mode in (5, 6, 7, 8, 9):
            p = run_ping(['-n1', '-r2', '127.0.0.1'], exe=self.mock, mode=mode, pretty='1')
            self.assertEqual(p.returncode, 0, p.stdout)
            self.assert_table(p.stdout)
            if mode != 5:
                self.assertNotIn('route:', p.stdout)
        p = run_ping(['-n1', '-r9', '127.0.0.1'], exe=self.mock, mode=18, pretty='1')
        self.assertEqual(p.returncode, 0, p.stdout)
        self.assert_table(p.stdout)
        for hop in range(1, 10):
            self.assertIn(f'198.51.100.{hop}', p.stdout)
        self.assertNotIn('...', p.stdout)

    def test_large_statistics_and_unhandled_console_events(self):
        exe = self.work / 'statistics.exe'
        source = application_source() + '''
section .data
test_stats_name db 'large-counter-test', 0
section .text
global test_stats_main
test_stats_main:
    sub rsp, 78h
    mov rcx, -11
    call GetStdHandle
    mov [rel hstdout], rax
    mov r14, -1
    mov r15, 1
    call loss_percent
    call print_dec
    lea rcx, [rel s_nl]
    call print_sz
    mov rax, -1
    call print_dec
    lea rcx, [rel s_nl]
    call print_sz
    mov ecx, 2
    call ctrl_handler
    call print_dec
    lea rcx, [rel s_nl]
    call print_sz
    lea rax, [rel test_stats_name]
    mov [rel g_name], rax
    mov r14, 4294967300
    mov r15, 4294967296
    mov qword [rel g_min], 23
    mov qword [rel g_max], 23
    mov rax, 98784247808
    mov [rel g_sum], rax
    jmp main.stats
'''
        self.assemble(source, exe, 'test_stats_main')
        p = run_ping([], exe=exe)
        self.assertEqual(p.returncode, 0, p.stdout)
        self.assertTrue(p.stdout.startswith('99\n18446744073709551615\n0\n'), p.stdout)
        self.assertIn('Sent = 4294967300, Received = 4294967296, Lost = 4 (0% loss)', p.stdout)
        self.assertIn('Average = 23ms', p.stdout)

    def test_long_resolver_names_are_bounded_and_sanitized(self):
        for family in ('-4', '-6'):
            for pretty in (None, '1'):
                with self.subTest(family=family, pretty=pretty):
                    p = run_ping([family, '-n1', '-a', 'example.test'],
                                 exe=self.mock, mode=10, pretty=pretty)
                    self.assertEqual(p.returncode, 0, p.stdout)
                    self.assertIn('y' + 'x' * 19 + '?', p.stdout)
                    self.assertNotIn('x' * 256, p.stdout)
                    if pretty:
                        self.assert_table(p.stdout)
                        self.assertIn('...', p.stdout)

    def test_reverse_lookup_failure_keeps_numeric_target(self):
        for target in ('127.0.0.1', '::1'):
            with self.subTest(target=target):
                p = run_ping(['-n1', '-a', target], exe=self.mock, mode=27)
                self.assertEqual(p.returncode, 0, p.stdout)
                self.assertIn(target, p.stdout)
                self.assertIn('Sent = 1, Received = 1', p.stdout)

    def test_interruption_before_first_send(self):
        for pretty in (None, '1'):
            p = run_ping(['-t', '127.0.0.1'], exe=self.mock, mode=11, pretty=pretty)
            self.assertEqual(p.returncode, 1, p.stdout)
            if pretty:
                self.assert_table(p.stdout)
                self.assertRegex(p.stdout, r'Sent\s*\u2502 0')
            else:
                self.assertIn('Sent = 0, Received = 0, Lost = 0 (0% loss)', p.stdout)

    def test_partial_and_failed_writes(self):
        for pretty in (None, '1'):
            p = run_ping(['-n1', '127.0.0.1'], exe=self.mock, mode=15, pretty=pretty)
            self.assertEqual(p.returncode, 0, p.stdout)
            if pretty:
                self.assert_table(p.stdout)
            else:
                self.assertIn('bytes=32 time=23ms TTL=64', p.stdout)
        for mode in (13, 14):
            p = run_ping(['-t', '127.0.0.1'], exe=self.mock, mode=mode)
            self.assertEqual(p.returncode, 2)

    def test_console_fallback_and_vt(self):
        p = run_ping(['-n1', '127.0.0.1'], exe=self.mock, mode=16)
        self.assertEqual(p.returncode, 0, p.stdout)
        self.assertNotIn('\x1b', p.stdout)
        self.assertIn('+---', p.stdout)
        self.assert_table(p.stdout)
        p = run_ping(['-n1', '127.0.0.1'], exe=self.mock, mode=17)
        self.assertEqual(p.returncode, 0, p.stdout)
        self.assertIn('\x1b[', p.stdout)
        self.assert_table(p.stdout)

    def test_ctrl_break_during_sleep_and_pending_reply(self):
        cases = [(EXE, '0', 0, '127.0.0.1'), (self.mock, '12', 1, '127.0.0.1'),
                 (EXE, '0', 0, '::1'), (self.mock, '12', 1, '::1')]
        if os.environ.get('PING_TEST_TIMEOUT_TARGET'):
            # Optional live pending-I/O regression; choose an address that drops ICMP.
            cases.append((EXE, '0', 1, os.environ['PING_TEST_TIMEOUT_TARGET']))
        for exe, mode, code, target in cases:
            with self.subTest(mode=mode, target=target):
                startup = subprocess.STARTUPINFO()
                startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
                startup.wShowWindow = 0
                p = subprocess.run([sys.executable, str(Path(__file__).resolve()),
                                    '--interrupt-worker', str(exe), mode, target],
                                   capture_output=True, text=True, timeout=6,
                                   creationflags=subprocess.CREATE_NEW_CONSOLE,
                                   startupinfo=startup)
                self.assertEqual(p.returncode, 0, p.stderr)
                data = json.loads(p.stdout)
                self.assertEqual(data['code'], code, data)
                self.assertIn('Ping statistics', data['out'])
                self.assertLess(data['elapsed'], 1.5)

    def test_flood_ctrl_break_during_replies_and_pending_reply(self):
        for exe, mode, code in ((EXE, '0', 0), (self.mock, '12', 1)):
            with self.subTest(mode=mode):
                startup = subprocess.STARTUPINFO()
                startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
                startup.wShowWindow = 0
                p = subprocess.run([sys.executable, str(Path(__file__).resolve()),
                                    '--interrupt-worker', str(exe), mode,
                                    '127.0.0.1', '1'],
                                   capture_output=True, text=True, timeout=6,
                                   creationflags=subprocess.CREATE_NEW_CONSOLE,
                                   startupinfo=startup)
                self.assertEqual(p.returncode, 0, p.stderr)
                data = json.loads(p.stdout)
                self.assertEqual(data['code'], code, data)
                self.assertIn('Ping statistics', data['out'])
                if mode == '12':
                    self.assertIn('Sent = 1, Received = 0, Lost = 1 (100% loss)',
                                  data['out'])
                else:
                    self.assertRegex(data['out'], r'Sent = [1-9]\d*, Received = [1-9]\d*')
                self.assertLess(data['elapsed'], 1.5)

    def test_long_custom_interval_remains_interruptible(self):
        startup = subprocess.STARTUPINFO()
        startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        startup.wShowWindow = 0
        p = subprocess.run([sys.executable, str(Path(__file__).resolve()),
                            '--interrupt-worker', str(EXE), '0',
                            '127.0.0.1', '0', '600000'],
                           capture_output=True, text=True, timeout=6,
                           creationflags=subprocess.CREATE_NEW_CONSOLE,
                           startupinfo=startup)
        self.assertEqual(p.returncode, 0, p.stderr)
        data = json.loads(p.stdout)
        self.assertEqual(data['code'], 0, data)
        self.assertIn('Sent = 1, Received = 1, Lost = 0 (0% loss)', data['out'])
        self.assertLess(data['elapsed'], 1.5)


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--interrupt-worker':
        interrupt_worker(*sys.argv[2:])
    else:
        unittest.main(verbosity=2)
