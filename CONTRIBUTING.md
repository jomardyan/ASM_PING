# Contributing

ASM PING is a Windows x64 command-line ICMP client written in NASM assembly. Keep
changes focused and include enough context for someone else to reproduce the
behavior.

## Development setup

Use Windows x64, Visual Studio or Visual Studio Build Tools with the **Desktop
development with C++** workload, and Python 3. Clone the repository, open
PowerShell in its directory, and run:

```powershell
.\build.ps1
py -3 tests\test_ping.py
```

The build bootstraps a pinned, checksum-verified NASM release into
`.ping-build/tools`. Supply `-NasmPath` to use an existing installation. The linker
is discovered using `vswhere` or `PATH`; `-LinkerPath` overrides that choice.
For tests, use `PING_TEST_LINKER` if the linker is not discoverable,
`PING_TEST_NASM` for a custom assembler, and `PING_TEST_BUILD_DIR` for a custom
build output directory. Consult
[README.md](README.md#verification) for optional live-network verification.

## Repository layout

| Path | Purpose |
| --- | --- |
| `ping_win64.asm` | CLI parsing, ICMP requests, console output, statistics, and cleanup |
| `net_resolve.asm` | IPv4/IPv6 endpoint resolution and address formatting |
| `build.ps1` | Tool discovery, NASM bootstrap, import libraries, and executable build |
| `build/*.def` | Windows API import definitions |
| `build/get-nasm.ps1` | Pinned NASM download, checksum verification, and cache |
| `build/mem.ps1` | Optional process-memory sampling |
| `tests/test_ping.py` | Standard-library regression tests and loopback integration tests |
| `tests/winapi_stubs.asm` | Deterministic Windows API fixtures used only in test builds |
| `.github/workflows/` | Windows CI and release automation |
| `docs/GITHUB_SETUP.md` | Repository metadata and release setup for maintainers |

Generated executables, objects, downloaded tools, import libraries, and temporary
test files are not source files. Keep them out of commits.

## Making a change

1. Create a branch and keep the change limited to one problem or feature.
2. Preserve Win64 calling conventions, stack alignment, API buffer layouts, and
   handle lifetimes when changing assembly code.
3. Add or update regression coverage when changing CLI behavior, reply handling,
   error paths, or interruption behavior. Test fixtures must remain separate from
   the production executable.
4. Update the option reference and examples when user-visible behavior changes.
5. Build and run the test suite, then run `git diff --check` before opening a pull
   request. Include the commands you ran and any tests you could not run.

Default integration tests use loopback addresses. Keep tests deterministic and
independent of public hosts. Optional live-target tests must remain opt-in.

## Reporting a bug

Use the bug-report issue form. Include the Windows version, the commit or release,
the exact command, expected behavior, and actual output. Mention whether output
was redirected and whether you set `PING_PRETTY` or any test environment variables.
Replace addresses or hostnames you do not want to share before posting logs.

For feature requests, describe the task you want to accomplish, the proposed CLI
behavior, and how you expect it to interact with existing options.
