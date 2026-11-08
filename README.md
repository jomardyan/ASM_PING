# Windows x64 assembly ping

A NASM IPv4 ICMP ping client using Windows APIs, without a C runtime. It shows
tables in a console and plain text when redirected. Normal ICMP probes do not
require an administrator prompt.

## Build and run

Requires Windows x64 and the Microsoft C++ build tools (Visual Studio or Build
Tools). NASM is bundled in `build/nasm-3.02/`. No Windows SDK libraries are needed:
the build script regenerates import libraries from the checked-in `.def` files.

```powershell
.\build.ps1
.\ping.exe -n 4 127.0.0.1
.\ping.exe -n 2 -a localhost
.\ping.exe -t -w 1000 example.com
.\ping.exe -?
```

The script locates the x64 linker using `vswhere` or `PATH`. You can supply
`-LinkerPath`, `-NasmPath`, and `-OutputDirectory`. `ping.exe` and `ping.obj` go to
the output directory; temporary import libraries go in its `.ping-build` folder.
Use `powershell -File .\build.ps1` if invoking the script from another shell.

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
| `-i ttl` | Outgoing IPv4 TTL | 1–255; Windows default if omitted |
| `-v tos` | Type of Service | 0–255; Windows may ignore it |
| `-f` | Set Don't Fragment | Off by default |
| `-r count` | Record up to this many route hops | 1–9; routers may omit them |
| `-4` | Select IPv4 | The supported address family |
| `-h`, `-?` | Display help | No networking required |

Use exactly one target: an IPv4 address or ASCII hostname, up to 255 bytes. Use
punycode for internationalized domain names. Windows command-line quoting is
supported, including executable paths containing spaces or Unicode characters.
Short numeric values can be attached (`-n4`) or separate (`-n 4`). `/` also works as a
prefix for the short options. Long options are exact and case-sensitive;
`--interval` requires a separate value (`--interval 250`, not `--interval=250`). Flags
reject extra characters. `-R`, `-6`, `-j`, `-k`, `-s`, and
`-S` are explicitly unsupported; this is not a complete replacement for Windows
`ping.exe`.

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
Ctrl+Break tests use isolated hidden consoles.
Tests need the same build tools; set `PING_TEST_LINKER` if the linker is not
discoverable with `vswhere`.

For a live pending-I/O interruption check, set `PING_TEST_TIMEOUT_TARGET` to a
known nonresponsive IPv4 address before running the tests. This adds a probe to
that address with a ten-minute timeout, then interrupts it after 400 ms and
requires prompt exit. This catches Windows handle-close waits that a simulated
reply cannot reproduce.

The memory script samples actual ping runs and reports the OS peak working set
and largest observed private-byte count. Short-lived peaks between samples can
be missed.

The asynchronous reply handling follows Microsoft's
[IcmpSendEcho2 API](https://learn.microsoft.com/en-us/windows/win32/api/icmpapi/nf-icmpapi-icmpsendecho2)
and [IcmpParseReplies API](https://learn.microsoft.com/en-us/windows/win32/api/icmpapi/nf-icmpapi-icmpparsereplies).
