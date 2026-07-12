# Domain Context

- **Module:** One named update capability with declared platform support, dependency detection, and a single execution handler.
- **Selected module:** A module included after defaults, `--full`, `--only`, `--skip`, and configuration precedence are applied.
- **Supported module:** A module with an implementation for the current platform. Support does not imply its backing command is installed.
- **Official standalone install:** An installation created by the project installer in the documented project-owned layout and carrying a valid authorization receipt.
- **Payload:** The platform-specific executable implementation distributed in a release asset.
- **Active payload:** The validated payload named by the current pointer and used for the next invocation.
- **Rollback payload:** The last known runnable payload retained behind the previous pointer for recovery.
- **Install receipt:** `install-source.json`, the authorization record describing an official standalone Windows install and its source. Its `installed_version` is the newest payload fully installed and validated by the installer; during recoverable activation, that payload may differ from the still-active `current.txt` pointer.
- **Doctor finding:** One local, read-only integrity check result with an `ok`, `warn`, or `fail` status and recovery guidance when applicable.
