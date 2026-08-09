# Update and maintenance research — 2026-08-09

Primary-source runbook for this Ubuntu VM and the `amanthanvi` agent setup
repositories. Commands below are recommendations, not a record that they were
executed. Local facts are a pre-maintenance snapshot taken on 2026-08-09 UTC.

## Executive findings

1. **Restore working space before updating.** `/` was a 58 GiB ext4 filesystem
   with only about 7 MiB free. The largest user-owned reclaim candidates were
   `~/.npm` (about 12 GiB), `~/.cache` (about 3.4 GiB), and the old `~/.nvm`
   tree (about 3.4 GiB). Expand the Proxmox virtual disk as durable remediation;
   cache cleanup is only immediate headroom.
2. **Migrate Node deliberately.** The active Node was NVM-managed Node 24.18.0.
   Pi and OpenCode were NVM global packages, while Claude and the active Codex
   were standalone binaries. Export and reinstall npm globals under fnm before
   retiring NVM. Do not copy an old global `node_modules` directory.
3. **Fix two concrete `updates` gaps.** `module_pi` runs `pi update`, which only
   updates Pi itself; current Pi documents `pi update --all` for Pi plus
   installed packages. The Node bootstrap also explicitly sources NVM whenever
   `~/.nvm/nvm.sh` exists, so a half-finished fnm migration can silently select
   the old runtime.
4. **Claude is on the wrong channel for “latest.”** The native installation was
   healthy at `~/.local/bin/claude`, but live settings selected
   `"autoUpdatesChannel": "stable"`. Anthropic says stable is typically about
   one week behind; `claude update` follows the selected channel. Change the
   effective setting to `latest` and install/update latest explicitly.
5. **Preserve the existing Tailscale Serve routes.** Tailscale was online, but
   HTTPS port 443 already routed `/` to `127.0.0.1:7790` and another path to
   `127.0.0.1:8091`. Capture the Serve JSON before starting T3; do not use a
   blanket reset because `npx t3 serve --tailscale-serve` may replace or compete
   with the existing root handler.

## Observed baseline

| Area | Pre-maintenance state | Consequence |
| --- | --- | --- |
| OS | Ubuntu 24.04.4 LTS, KVM guest | Supported by all four agent CLIs; use Noble package documentation. |
| Root storage | `/dev/sda1`, ext4, plain GPT partition, last partition on a 60 GiB disk | After host-side disk enlargement, partition 1 and ext4 can grow in place; no LVM step. |
| Node | NVM Node 24.18.0, npm 12.0.2; fnm absent | Meets T3's current Node constraint, but globals must move with the manager. |
| Claude Code | Native 2.1.212; stable channel | Native updater is correct, channel is not the requested latest channel. |
| Codex | Standalone 0.147.0 active; duplicate NVM npm install also present | Keep the standalone install; exclude the duplicate npm package during migration. |
| Pi | `@earendil-works/pi-coding-agent` 0.84.1 under NVM | Reinstall under fnm, then update Pi and packages together. |
| OpenCode | `opencode-ai` 1.18.15 under NVM; `autoupdate: false` | Reinstall under fnm and retain an explicit central update step. |
| Tailscale | 1.102.2, daemon enabled/running, tailnet DNS name `devbox.tail4c2549.ts.net` | T3 remote access prerequisites are substantially present; existing Serve routes require care. |

Version observations are not release recommendations: re-query upstream at
execution time rather than pinning this table.

## Recommended execution order

### 1. Recover minimum headroom, then expand the VM disk

Start with read-only accounting:

```bash
df -hT /
du -xhd1 "$HOME" /var 2>/dev/null | sort -h
npm cache verify
sudo journalctl --disk-usage
sudo apt-get -s autoremove
```

The npm cache is explicitly a cache, not a persistent data store. npm recommends
`npm cache verify` for integrity/garbage collection; when immediate capacity is
required, `npm cache clean --force` is the supported forced removal path.
[`npm cache` documentation](https://docs.npmjs.com/cli/v12/commands/npm-cache/)

Lowest-risk immediate reclaim:

```bash
npm cache verify
npm cache clean --force
sudo apt-get clean
```

`apt-get clean` removes downloaded package archives. `autoclean` removes only
archives no longer downloadable, while `autoremove` removes automatically
installed dependencies that are no longer needed; simulate and review
`autoremove` before applying it.
[`apt-get(8)` for Ubuntu Noble](https://manpages.ubuntu.com/manpages/noble/man8/apt-get.8.html)

If journals are material, rotate before vacuuming so active files are included:

```bash
sudo journalctl --rotate --vacuum-size=500M
```

`journalctl` documents that vacuuming affects archived journal files and that
combining `--rotate` with `--vacuum-*` maximizes its effect.
[`journalctl(1)` for Ubuntu Noble](https://manpages.ubuntu.com/manpages/noble/man1/journalctl.1.html)

Do not bulk-delete `~/.cache`, container volumes, agent histories, or setup
repositories. If Docker is material, inspect `docker system df` first and prune
only known-unused objects; volumes are deliberately not pruned by default
because they may contain data.
[`docker system prune` guidance](https://docs.docker.com/engine/manage-resources/pruning/)

For durable capacity, take or verify a recoverable VM backup/snapshot, then on
the **Proxmox host** identify the exact VM and disk from `qm config <vmid>` and
grow only that disk, for example:

```bash
qm config <vmid>
qm disk resize <vmid> <scsi-or-virtio-disk> +40G
```

Proxmox supports increasing a guest disk and warns that shrinking is not
supported. The exact VM ID and device must be resolved on the host; they cannot
be inferred safely from inside this guest.
[`qm(1)`](https://pve.proxmox.com/pve-docs/qm.1.html),
[`Proxmox disk-resize guidance`](https://pve.proxmox.com/wiki/Resize_disks)

Then, in this guest, confirm `/dev/sda` is larger and dry-run the partition
change before applying it:

```bash
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS
sudo growpart -N /dev/sda 1
sudo growpart /dev/sda 1
sudo resize2fs /dev/sda1
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS
df -hT /
```

`growpart -N` reports the proposed change without modifying the partition.
`resize2fs` grows ext2/3/4 but does not enlarge the partition itself, hence the
two-step order. This host's root partition is last on disk and ext4, so the
layout is suitable once the virtual disk exposes contiguous free space.
[`growpart(1)`](https://manpages.ubuntu.com/manpages/noble/man1/growpart.1.html),
[`resize2fs(8)`](https://manpages.ubuntu.com/manpages/noble/man8/resize2fs.8.html)

### 2. Complete Ubuntu maintenance without forcing phased updates

Use `apt-get` in automation and refresh indexes before upgrading:

```bash
sudo dpkg --audit
sudo apt-get update
sudo apt-get upgrade
apt list --upgradable
sudo apt-get check
systemctl --failed
test ! -e /var/run/reboot-required || cat /var/run/reboot-required.pkgs
```

Ubuntu documents `apt update` followed by `apt upgrade`; it recommends `apt` for
interactive use and `apt-get`/`apt-cache` for scripts. A normal `upgrade` does
not remove installed packages. If packages remain because dependency changes
are required, inspect `sudo apt-get -s dist-upgrade` and apply only after the
removal/addition proposal is reviewed.
[`Ubuntu package-management guide`](https://ubuntu.com/server/docs/package-management/),
[`apt-get(8)`](https://manpages.ubuntu.com/manpages/noble/man8/apt-get.8.html)

Do not force packages that are merely phased for this machine. Phasing is an
Ubuntu safety mechanism; held-back packages can become eligible automatically.
[`Ubuntu phased-update explanation`](https://ubuntu.com/server/docs/explanation/software/about-apt-upgrade-and-phased-updates/)

### 3. Migrate NVM to fnm while preserving global commands

fnm supports `.nvmrc` and `.node-version`, but its documented commands do not
provide NVM's cross-version `reinstall-packages` behavior. Treat npm global
packages as an inventory to reinstall, not files to copy.
[`fnm README`](https://github.com/Schniz/fnm#readme),
[`fnm commands`](https://github.com/Schniz/fnm/blob/master/docs/commands.md),
[`npm global folder layout`](https://docs.npmjs.com/cli/v11/configuring-npm/folders/)

Before changing the shell or manager, capture the old prefix, dependency
versions, and key executable paths:

```bash
node --version
npm --version
npm prefix -g
npm ls -g --depth=0 --json > "$HOME/npm-globals-before-fnm.json"
for cmd in node npm npx pi opencode codex claude; do
  command -v "$cmd" || true
done
```

Install fnm using its official installer, then initialize Bash explicitly:

```bash
curl -fsSL https://fnm.vercel.app/install | bash
eval "$(fnm env --use-on-cd --shell bash)"
fnm install 24.18.0 --use
fnm default 24.18.0
```

The official shell setup is `eval "$(fnm env --use-on-cd --shell bash)"`;
`fnm install --use` and `fnm default` are documented commands.
[`fnm installation and shell setup`](https://github.com/Schniz/fnm#installation),
[`fnm commands`](https://github.com/Schniz/fnm/blob/master/docs/commands.md)

Generate an exact package review list from the saved inventory. Exclude npm,
Corepack, and `@openai/codex`: npm ships with the selected Node installation,
Corepack is runtime tooling, and this host already has an active standalone
Codex installation.

```bash
jq -r '
  .dependencies
  | to_entries[]
  | select(.key != "npm" and .key != "corepack" and .key != "@openai/codex")
  | "\(.key)@\(.value.version)"
' "$HOME/npm-globals-before-fnm.json" > "$HOME/npm-globals-to-install.txt"
cat "$HOME/npm-globals-to-install.txt"
```

After reviewing that list, reinstall under fnm:

```bash
xargs -r npm install -g < "$HOME/npm-globals-to-install.txt"
hash -r
npm prefix -g
npm ls -g --depth=0
pi --version
opencode --version
```

npm places global packages and their executables under the active global
prefix, so changing Node managers changes where those commands are resolved.
[`npm prefix`](https://docs.npmjs.com/cli/v11/commands/npm-prefix/),
[`installing packages globally`](https://docs.npmjs.com/downloading-and-installing-packages-globally/)

Open a new login shell and verify `command -v node npm pi opencode codex claude`
before removing NVM startup lines. Only after that succeeds, move `~/.nvm` to
Trash or another recoverable location. This final removal matters here because
the current `updates` implementation sources `~/.nvm/nvm.sh` whenever it exists,
even if fnm was initialized first.

### 4. Update and validate each agent CLI

#### Claude Code

This host uses Anthropic's recommended native installation. Native installs
auto-update, `claude update` follows `autoUpdatesChannel`, and `latest` receives
releases immediately while `stable` is deliberately delayed.
[`Claude Code installation and updates`](https://code.claude.com/docs/en/installation)

For the explicit user requirement, change the effective
`autoUpdatesChannel` from `stable` to `latest`, then:

```bash
claude install latest
claude update
claude --version
claude doctor
claude auth status
```

Use `/status` inside Claude to confirm which settings sources are effective;
managed, command-line, local-project, project, and user layers can override one
another.
[`Claude settings precedence`](https://code.claude.com/docs/en/settings)

#### Pi

Current upstream ownership and package name are `earendil-works/pi` and
`@earendil-works/pi-coding-agent`. Its current install requires Node 22.19 or
newer. Upstream distinguishes Pi-only updates from package-wide updates:

```bash
pi update --all
pi update --models
pi --version
```

`pi update` updates Pi itself; `pi update --all` updates Pi plus installed
packages, and `--models` refreshes the model registry.
[`Pi coding-agent README`](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/README.md),
[`Pi package management`](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/packages.md)

The tracked Pi settings keys remain represented in the current settings
reference; retain configuration and extensions while correcting stale naming
and update instructions.
[`Pi settings reference`](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/settings.md)

#### OpenAI Codex

Keep the active standalone installation and avoid recreating the duplicate npm
installation during fnm migration. OpenAI currently recommends its standalone
installer, while npm and Homebrew remain alternatives. PATH decides which
coexisting installation runs.
[`Codex README`](https://github.com/openai/codex/blob/main/README.md),
[`Codex standalone installer source`](https://github.com/openai/codex/blob/main/scripts/install/install.sh)

```bash
readlink -f "$(command -v codex)"
codex update
codex --version
codex doctor --json
```

The tracked setup sets `check_for_update_on_startup = false`; OpenAI documents
that as appropriate only when updates are centrally managed, so the `updates`
workflow must remain the explicit updater. Use `/debug-config` in the TUI to
inspect effective values and their sources. Do not use
`codex --strict-config features list` as a generic validator: the installed CLI
rejects that option for the `features` command.
[`Codex configuration reference`](https://learn.chatgpt.com/docs/config-file/config-reference),
[`Codex developer commands`](https://learn.chatgpt.com/docs/developer-commands?surface=cli)

#### OpenCode

The tracked configuration intentionally disables automatic updates. Retain that
policy only if the central workflow performs the documented explicit upgrade:

```bash
opencode upgrade --method npm
opencode --version
```

OpenCode documents `opencode upgrade [target]` and the `npm` install method.
Configuration is merged from multiple locations rather than replaced wholesale,
and `autoupdate` accepts `false` or notification-only behavior.
[`OpenCode CLI`](https://opencode.ai/docs/cli/),
[`OpenCode configuration`](https://opencode.ai/docs/config/)

### 5. Run T3 over Tailscale Serve without losing routes

T3 currently requires Node `^22.16`, `^23.11`, or `>=24.10` and at least one
authenticated supported provider CLI. Node 24.18.0 meets that constraint.
[`T3 installation`](https://github.com/pingdotgg/t3code/blob/main/docs/user/install.md),
[`T3 README`](https://github.com/pingdotgg/t3code/blob/main/README.md)

Preflight and preserve the existing Serve configuration:

```bash
node --version
tailscale status --json
tailscale ip -4
tailscale serve status --json > "$HOME/tailscale-serve-before-t3.json"
claude auth status
codex login status
```

Tailscale Serve is tailnet-private, subject to tailnet access controls, and its
HTTPS mode requires HTTPS certificates to be enabled for the tailnet. Serve and
Funnel cannot use the same port simultaneously.
[`Tailscale Serve`](https://tailscale.com/docs/features/tailscale-serve)

Launch the exact requested mode, with `@latest` making update intent explicit:

```bash
npx t3@latest serve --tailscale-serve
```

T3 documents that this mode configures Tailscale Serve on HTTPS port 443 and
prints the URL and pairing material. Pairing tokens are credentials: do not put
them in shell history, tickets, or logs.
[`T3 remote access`](https://github.com/pingdotgg/t3code/blob/main/docs/user/remote-access.md)

From another authenticated tailnet device, open the printed HTTPS URL and finish
pairing. In parallel, verify the mapping and daemon state:

```bash
tailscale status
tailscale serve status --json
systemctl is-active tailscaled
```

Compare the result to `tailscale-serve-before-t3.json`; confirm that the prior
`/interview-prep-alexandria` route still works and that the root-route change was
intentional. Do not run `tailscale serve reset` unless all saved handlers are
meant to be removed. For persistence across reboots, use T3's documented
background-service workflow rather than an ad-hoc shell process.
[`Tailscale Serve CLI`](https://tailscale.com/docs/reference/tailscale-cli/serve),
[`T3 background service`](https://github.com/pingdotgg/t3code/blob/main/docs/user/background-service.md),
[`T3 updating`](https://github.com/pingdotgg/t3code/blob/main/docs/user/updating.md)

## Repository changes supported by evidence

These are PR/issue candidates; validate each repository's current default branch
immediately before filing.

| Repository | Evidence-backed change | Suggested artifact |
| --- | --- | --- |
| `amanthanvi/updates` | Change Pi action and docs from `pi update` to `pi update --all`; add a regression test for the exact command. | PR |
| `amanthanvi/updates` | Add fnm-aware Node initialization or prefer an already-resolved active Node manager; retain NVM fallback and test both paths. | PR |
| `amanthanvi/aman-pi-mono-setup` | Replace stale `badlogic/pi-mono` / “incoming rename” language with current `earendil-works/pi` package and current Node minimum; document `pi update --all`. | PR |
| `amanthanvi/aman-claude-code-setup` | Make the intended release channel explicit. For this request, track `latest`, then test the installer/doctor flow and settings precedence. | PR if repository policy agrees; otherwise issue documenting stable-vs-latest decision |
| `amanthanvi/aman-codex-setup` | Keep one supported Codex install path and make `codex update` + `codex doctor --json` the central verification path because startup checks are disabled. | Issue or PR only if the duplicate-install condition is reproducible from setup scripts |
| `amanthanvi/aman-opencode-setup` | Ensure explicit `opencode upgrade --method npm` remains in the update path when `autoupdate` is false; validate plugins from OpenCode's cache/config model, not only npm globals. | PR if current doctor still assumes npm-global plugins |
| `amanthanvi/aman-agent-skills`, `amanthanvi/aman-fleet` | No primary-source or inspected-local evidence of a defect from this research lane. | Do not file speculative issues |

## Completion gates

Consider the maintenance complete only when all of these are true:

- `/` has durable free space and `df -hT /` agrees with the expanded block
  device size.
- `dpkg --audit` is empty, `apt-get check` succeeds, and any remaining upgrades
  are explained by phasing or an explicit hold.
- A fresh login shell resolves `node`, `npm`, `pi`, and `opencode` from fnm;
  Claude and Codex still resolve to their standalone launchers.
- The old and new npm global inventories are reconciled; required commands pass
  version/auth smoke checks before NVM is moved to Trash.
- `claude doctor` and `codex doctor --json` report no actionable installation or
  configuration errors.
- `pi update --all` and the explicit OpenCode upgrade complete successfully.
- T3 is reachable from a second tailnet device over HTTPS, pairing succeeds,
  and all intentional pre-existing Tailscale Serve routes still work.
- The full `updates` run exits successfully after the fnm and Pi fixes, followed
  by `./scripts/lint.sh` and `./scripts/test.sh` in the `updates` repository.

## Safety notes

- Proxmox disk selection, partition editing, NVM removal, and Tailscale route
  replacement are the highest-risk steps. Preserve rollback material and verify
  exact targets before mutation.
- Re-running installers can change PATH order. Always inspect both `command -v`
  and `readlink -f` before concluding which CLI was updated.
- Never publish auth output, pairing tokens, package inventories containing
  private package names, or saved Tailscale Serve JSON.
- The setup repositories are expected to be newer than this host in many areas;
  open only issues/PRs backed by a reproducible mismatch, not by version numbers
  in this snapshot alone.
