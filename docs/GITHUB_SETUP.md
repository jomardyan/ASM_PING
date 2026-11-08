# GitHub setup

The repository includes build and test workflows, draft release automation, issue
forms, and a pull request template. Creating a remote repository and publishing
releases are separate maintainer actions.

## Repository listing

Suggested metadata:

| Field | Suggested value |
| --- | --- |
| Name | `ping-win64-asm` |
| Description | Windows x64 ICMP ping client in NASM assembly, with IPv4/IPv6, source selection, timestamps, and console tables. |
| Topics | `windows`, `x64`, `assembly`, `nasm`, `icmp`, `ping`, `ipv4`, `ipv6`, `cli`, `network-diagnostics` |

Before the first public push:

1. Review the [MIT license](../LICENSE) and the repository contents for the first
   release.
2. Review the files and Git history for private information and files that should
   not be published. Removing a file from the working tree does not remove it
   from earlier commits.
3. Create an empty GitHub repository using the intended owner and visibility.
   Keep the local README and other prepared files as the source of truth.
4. Add that repository as the Git remote, review `git status`, commit the intended
   source changes, and push `main`.
5. Fill in the About description and topics, enable Issues and Actions if needed,
   and check the first **Windows CI** run.

No owner, remote URL, maintainer email, or badge URL is assumed in these files.
Add repository-specific links once the actual repository exists.

## Continuous integration

The **Windows CI** workflow runs on branch pushes, pull requests, and manual
dispatch. It builds and tests on Windows, then uploads a `ping-windows-x64`
artifact. Contributors can use that artifact to inspect the executable built
from a particular successful run.

After the first successful run, consider requiring its build/test check before
merging changes into `main`. Select the actual check shown by GitHub rather than
guessing its name. Keep workflow permissions limited to the operations each job
needs; release creation uses a separate workflow.

## Releases

1. Update `CHANGELOG.md` and run the local build and test suite.
2. Commit the release contents and push a version tag, such as `v1.0.0`, pointing
   to that commit. Version tags use `vMAJOR.MINOR.PATCH`, with an optional prerelease
   or build suffix.
3. The release workflow builds and tests the tagged source, then creates a
   **draft** GitHub release. Its assets are `ping-<tag>-windows-x64.zip` and
   `SHA256SUMS.txt`. The archive contains the executable and project documentation,
   including `LICENSE` when present.
4. Inspect the workflow result, download and try the archive, review the release
   notes, and publish the draft when it is ready.

To inspect a downloaded archive's checksum in PowerShell:

```powershell
Get-FileHash .\ping-v1.0.0-windows-x64.zip -Algorithm SHA256
```

Compare the result with the matching entry in `SHA256SUMS.txt`.
