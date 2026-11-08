# Windows x64 assembly ping

A NASM IPv4 and IPv6 ICMP ping client using Windows APIs, without a C runtime. It shows
tables in a console and plain text when redirected. Normal ICMP probes do not
require an administrator prompt.

Features include source-address selection, IPv6 interface scopes, configurable
probe intervals, continuous and flood modes, UTC timestamps, quiet output, IPv4
route recording, and summary statistics. Ctrl+C and Ctrl+Break stop a run and
print its results.

## Quick start

Build from source using the instructions below, or download a Windows x64 archive
from this repository's **Releases** page when a release is available. Extract the
archive and run `ping.exe` in PowerShell:

```powershell
.\ping.exe -n 4 127.0.0.1
.\ping.exe -6 -n 4 ::1
.\ping.exe -6 -S ::1 -n 2 localhost
.\ping.exe --timestamp --interval 500 -n 10 127.0.0.1
.\ping.exe -?
```

Use `.\ping.exe` to run this client from its directory; an unqualified `ping`
command may run the Windows built-in program instead.

## Build from source

Requires Windows x64 and the Microsoft C++ build tools (Visual Studio or Build
Tools), with the **Desktop development with C++** workload. The build script
downloads a pinned NASM version from its official distribution, verifies the
archive's SHA-256 checksum, and caches it under `.ping-build/tools`. The first
build needs an internet connection unless you provide `-NasmPath`. No Windows
SDK libraries are needed: import libraries are generated from the checked-in
`.def` files. The pinned NASM version and checksums are recorded in
[build/nasm.json](build/nasm.json).

```powershell
.\build.ps1
.\ping.exe -n 2 -a localhost
.\ping.exe -4 --source 127.0.0.1 -n 2 127.0.0.1
.\ping.exe -t -w 1000 example.com
```

The script locates the x64 linker using `vswhere` or `PATH`. You can supply
`-LinkerPath`, `-NasmPath`, and `-OutputDirectory`. `ping.exe` goes to the output
directory; object files and import libraries go in its `.ping-build` folder.
The NASM cache stays in the repository's `.ping-build/tools` directory, even when
you choose a different output directory.
Use `powershell -File .\build.ps1` if invoking the script from another shell.

For an existing NASM installation or an offline build:

```powershell
.\build.ps1 -NasmPath 'C:\Tools\nasm\nasm.exe'
```

## Options and behavior

| Option | Meaning | Range/default |
| --- | --- | --- |
| `-t` | Continue until Ctrl+C or Ctrl+Break | Overrides `-n` |
| `--flood` | Send the next request as soon as the previous one finishes | Off by default; exact, case-sensitive spelling |
| `--interval ms` | Minimum time between request starts | 1–600000 ms; default 1000; `--flood` overrides it |
| `--quiet` | Show the configuration header and final statistics, suppress per-request output | Off by default |
| `--timestamp` | Prefix completed results with a UTC timestamp | Forces plain text, including in a console |
| `-a` | Resolve the destination address to a hostname once | Falls back to the original name/IP |
| `-n count` | Number of requests | 1–100000; default 4 |
| `-l size` | Payload size in bytes | 0–65500; default 32 |
| `-w timeout` | Reply timeout in milliseconds | 1–600000; default 4000 |
| `-i ttl` | Outgoing IPv4 TTL or IPv6 hop limit | 1–255; Windows default if omitted |
| `-v tos` | IPv4 Type of Service | 0–255; Windows may ignore it |
| `-f` | Set IPv4 Don't Fragment | Off by default |
| `-r count` | Record up to this many IPv4 route hops | 1–9; routers may omit them |
| `-4`, `-6` | Select IPv4 or IPv6 | Mutually exclusive; hostnames default to IPv4 |
| `-S address`, `--source address` | Select a numeric local source address | Same address family as the destination; Windows chooses if omitted |
| `-h`, `-?` | Display help | No networking required |

Use exactly one target: an IPv4 address, unbracketed IPv6 address, or ASCII hostname,
up to 255 bytes. Use
punycode for internationalized domain names. Windows command-line quoting is
supported, including executable paths containing spaces or Unicode characters.
Short numeric values can be attached (`-n4`) or separate (`-n 4`). `/` also works as a
prefix for the short options. Long options are exact and case-sensitive;
`--interval` and `--source` require separate values (`--interval 250`, not
`--interval=250`). `-S::1` and `-S ::1` both work. Uppercase `-S` selects the source;
lowercase `-s` remains unsupported. Flags reject extra characters. `-R`, `-j`,
`-k`, and `-s` are explicitly unsupported; this is not a complete replacement for Windows
`ping.exe`.

An IPv6 literal automatically selects IPv6. An explicit source address also selects
its family unless `-4` or `-6` is given; conflicting source, target, and family
selections are rejected before sending. Hostnames use IPv4 by default, or IPv6 with
`-6` or an IPv6 source. The source must be a numeric address assigned to the local
machine, rather than a hostname. The selected source appears in the header.
For link-local IPv6 addresses, append the numeric interface scope, for example
`fe80::1234%12`, to the target and source where needed. Scope zero may be omitted.
Windows reports an error if the selected source or interface cannot be used.
The IPv4-only `-f`, `-r`, and `-v` options are rejected in IPv6 mode.

IPv6 replies report the responding address, request payload size, and round-trip
time. The Windows IPv6 echo API does not expose a returned payload-length field or
received hop limit, so the displayed byte count uses the requested payload size.
The TTL column shows `-` for IPv6, and plain IPv6 output omits `TTL=`. `-i` still
controls the outgoing hop limit. Reverse lookup with `-a` works for both families
and falls back to the original name or numeric address when no name is available.

By default, requests start at least one second apart. `--interval` changes that
minimum start-to-start interval in milliseconds. A slow request consumes that
interval; there is no extra delay after it completes or after the final request.
`--flood` removes this deliberate interval. It keeps one ICMP request pending at
a time and sends the next immediately after a reply, error, or timeout. The reply
timeout (`-w`) still applies, so unanswered requests wait for that timeout before
the next send. Count defaults to four; use `-n` for a finite count or `-t` to keep
running. The header identifies flood mode; per-request output and final statistics
use the normal plain or table format. If both `--interval` and `--flood` are given,
flood mode wins regardless of their order. `-f` continues to mean Don't Fragment.

```powershell
.\ping.exe --flood 127.0.0.1
.\ping.exe --flood -n 100 -w 1000 127.0.0.1
.\ping.exe --flood -t 127.0.0.1
.\ping.exe --interval 250 -n 8 127.0.0.1
```

`--quiet` suppresses individual replies, network errors, and route hops while
keeping the target/configuration header and final statistics. Sent, received,
loss, and RTT calculations are unchanged, and argument/setup errors remain
visible. Quiet mode works with either plain output or console tables.

`--timestamp` adds an ISO 8601 UTC timestamp when each reply or network error is
reported, for example:

```text
[2026-11-08T12:34:56.007Z] Reply from 127.0.0.1: bytes=32 time<1ms TTL=128
```

It forces plain text even on a console or when `PING_PRETTY=1`, making the output
easy to save as a log. Headers, statistics, and setup errors are not timestamped;
route lines follow their timestamped reply without a second timestamp.
`--quiet --timestamp` keeps the plain header and statistics and suppresses the
per-request records entirely.

```powershell
.\ping.exe --quiet --interval 200 -n 10 127.0.0.1
.\ping.exe --timestamp --interval 500 -n 10 127.0.0.1 > ping.log
```

Ctrl+C and Ctrl+Break wake both reply waits and interval waits, then print statistics.
Initial hostname resolution uses synchronous Winsock calls and is not covered
by the ICMP timeout or interruption handler.

Only successful echo replies count as received. Network failures and ICMP error
responses count as lost. Exit codes are **0** for at least one successful reply
or help, **1** for no successful replies or a missing target, and **2** for invalid
arguments, resolution/setup failures, or output errors. A request interrupted
while pending counts as sent and lost.

Console tables use 80 columns. UTF-8 and supported OEM code pages have box drawing;
other code pages use ASCII borders. ANSI colors are enabled only when the console
accepts VT mode, and the original console mode is restored on normal exit.
Long names are abbreviated with `...` in tables. Route hops wrap across rows.
Redirect output for full hostname text. To force UTF-8 tables and ANSI colors in
a pipe or file, set `PING_PRETTY` to exactly `1` (`--timestamp` overrides this):

```powershell
$env:PING_PRETTY = '1'
.\ping.exe -n 1 127.0.0.1 > result.txt
Remove-Item Env:\PING_PRETTY
```

## Verification

```powershell
.\build.ps1
py -3 tests\test_ping.py
.\build\mem.ps1 -runs 1
```

The Python standard-library tests run real loopback probes and compile a separate
instrumented executable for deterministic error, resolver, console, output, and
malformed reply cases. Test fixtures never enter the production executable.
Flood tests cover loopback timing and counts, exact flag parsing, simulated
failures, and interruption. Interval tests cover value bounds, pacing, flood
precedence, and interruption during a long interval. Quiet and timestamp tests
cover replies, failures, routes, statistics, console behavior, and UTC formatting.
IPv6 and source-address tests cover both loopback families, payload bounds,
hostname resolution, numeric sources, scope validation, family conflicts,
IPv4-only options, API argument layout, error replies, and pending-worker interruption.
Ctrl+Break tests use isolated hidden consoles.
Tests need the same build tools; set `PING_TEST_LINKER` if the linker is not
discoverable with `vswhere`. Set `PING_TEST_NASM` to use a custom NASM executable,
and `PING_TEST_BUILD_DIR` to test an executable built in a custom output directory.

For a live pending-I/O interruption check, set `PING_TEST_TIMEOUT_TARGET` to a
known nonresponsive IPv4 address before running the tests. This adds a probe to
that address with a ten-minute timeout, then interrupts it after 400 ms and
requires prompt exit. This catches Windows handle-close waits that a simulated
reply cannot reproduce.

The memory script samples actual ping runs and reports the OS peak working set
and largest observed private-byte count. Short-lived peaks between samples can
be missed.

The IPv4 asynchronous reply handling follows Microsoft's
[IcmpSendEcho2 API](https://learn.microsoft.com/en-us/windows/win32/api/icmpapi/nf-icmpapi-icmpsendecho2)
and [IcmpParseReplies API](https://learn.microsoft.com/en-us/windows/win32/api/icmpapi/nf-icmpapi-icmpparsereplies).
Explicit IPv4 source addresses use
[IcmpSendEcho2Ex](https://learn.microsoft.com/en-us/windows/win32/api/icmpapi/nf-icmpapi-icmpsendecho2ex).
IPv6 uses a synchronous
[Icmp6SendEcho2](https://learn.microsoft.com/en-us/windows/win32/api/icmpapi/nf-icmpapi-icmp6sendecho2)
call on a worker thread so the reply timeout remains effective while the main
thread can respond promptly to Ctrl+C or Ctrl+Break.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the development workflow, test setup,
and guidance for bug reports and pull requests. GitHub Actions builds the client
and runs the regression suite on Windows. The [GitHub setup guide](docs/GITHUB_SETUP.md)
covers repository metadata and release publication.

## License

This project is licensed under the [MIT License](LICENSE).

NASM is a separate build tool distributed under its own BSD-2-Clause license.
The bootstrap retains NASM's `LICENSE` beside the downloaded assembler in
`.ping-build/tools/nasm-<version>/`. NASM is not included in the project's release
archives.
