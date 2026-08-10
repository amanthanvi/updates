# T3 Connect and Pi model-update research — 2026-08-10

Primary-source runbook for pairing this Linux T3 Code host over Tailscale and
diagnosing Pi model/update failures. Commands below are recommendations, not a
record that they were executed. Do not paste pairing URLs, pairing tokens,
session credentials, `auth.json`, or T3 Connect status JSON into public logs.

Source snapshots used for implementation claims:

- T3 Code `f21d5e444e9a6b5876253ca8618a4dc8d4f2146c`
- Pi `936aff00918de1187f085f123c2812d8f2d67745`

## Executive findings

1. **Tailscale pairing and T3 Connect are different access targets.** A
   Tailscale URL is an ordinary directly paired bearer endpoint. Full T3
   Connect uses an account-linked, relay-provisioned Cloudflare tunnel. T3's
   own architecture says Tailscale is an endpoint provider/transport, not a
   relay target or separate runtime type.
   [T3 remote architecture](https://github.com/pingdotgg/t3code/blob/f21d5e444e9a6b5876253ca8618a4dc8d4f2146c/docs/internals/remote.md#known-environments-and-connection-targets)
2. **For this already-running loopback service, pair with
   `t3 pair --tailscale`.** It reuses the server, ensures Tailscale Serve HTTPS,
   and mints a fresh one-time owner credential. It does not require restarting
   `t3code.service`. The resulting reachable endpoint is normally the HTTPS
   MagicDNS URL, not bare `http://100.x.y.z:3773`.
   [T3 Remote Access: Quick Pairing](https://github.com/pingdotgg/t3code/blob/f21d5e444e9a6b5876253ca8618a4dc8d4f2146c/docs/user/remote-access.md#quick-pairing-for-a-running-server)
3. **Use `t3 connect link --publish-only` when the desired combination is T3
   Connect account/activity integration plus a Tailscale data path.** The flag
   intentionally provisions no managed tunnel and says to reach the environment
   out of band, for example with Tailscale. Direct bearer pairing is still
   required on each client. Full `t3 connect link` instead installs/uses
   `cloudflared` and asks the T3 relay to provision an endpoint.
   [Connect CLI implementation](https://github.com/pingdotgg/t3code/blob/f21d5e444e9a6b5876253ca8618a4dc8d4f2146c/apps/server/src/cli/connect.ts#L377-L445)
4. **Pi's three update operations are independent.** `pi update` updates Pi
   itself only; `pi update --all` updates Pi and installed packages but still
   does not refresh model catalogs; `pi update --models` refreshes only remote
   model catalogs. Thus a successful plain update cannot prove that model
   metadata was refreshed.
   [Pi update parser and help](https://github.com/earendil-works/pi/blob/936aff00918de1187f085f123c2812d8f2d67745/packages/coding-agent/src/package-manager-cli.ts#L109-L175),
   [update execution](https://github.com/earendil-works/pi/blob/936aff00918de1187f085f123c2812d8f2d67745/packages/coding-agent/src/package-manager-cli.ts#L820-L880)
5. **`pi update --models` has a hard shared 15-second deadline.** It
   force-refreshes all configured dynamic provider catalogs concurrently; one
   stalled catalog can consume the shared deadline and make the entire command
   report `Model catalog refresh timed out.` The catalog transport retries
   immediate transport failures and selected transient HTTP statuses, but has
   no shorter per-attempt timeout, so a request that merely stalls cannot retry
   before the outer abort fires.
   [Pi catalog CLI timeout](https://github.com/earendil-works/pi/blob/936aff00918de1187f085f123c2812d8f2d67745/packages/coding-agent/src/package-manager-cli.ts#L397-L423),
   [concurrent provider refresh](https://github.com/earendil-works/pi/blob/936aff00918de1187f085f123c2812d8f2d67745/packages/ai/src/models.ts#L386-L446),
   [management HTTP retry policy](https://github.com/earendil-works/pi/blob/936aff00918de1187f085f123c2812d8f2d67745/packages/coding-agent/src/utils/management-http.ts#L1-L67)
6. **“Old models” can be a local selection/configuration problem even when the
   catalog is current.** Pi combines package-bundled models, a persisted remote
   overlay in `~/.pi/agent/models-store.json`, custom definitions/overrides in
   `~/.pi/agent/models.json`, authentication availability, and
   `enabledModels`/default selections in settings. `pi --list-models` lists
   authenticated available models; `enabledModels` limits Ctrl+P cycling, not
   the underlying catalog.
   [Pi model runtime construction](https://github.com/earendil-works/pi/blob/936aff00918de1187f085f123c2812d8f2d67745/packages/coding-agent/src/core/model-runtime.ts#L172-L216),
   [custom model documentation](https://github.com/earendil-works/pi/blob/936aff00918de1187f085f123c2812d8f2d67745/packages/coding-agent/docs/models.md),
   [model cycling setting](https://github.com/earendil-works/pi/blob/936aff00918de1187f085f123c2812d8f2d67745/packages/coding-agent/docs/settings.md#model-cycling)

## T3: choose the intended access path

### Recommended: direct Tailscale HTTPS pairing

This is the most direct interpretation of “pair this machine with my other
devices via its Tailscale address.” Every client device must be logged into a
tailnet allowed to reach this machine. Tailscale Serve exposes a loopback
service privately to the tailnet over HTTPS and remains subject to tailnet ACLs.
[Tailscale Serve documentation](https://tailscale.com/docs/features/tailscale-serve)

On the host, verify rather than reconfigure the running service:

```bash
systemctl --user is-active t3code.service
tailscale status
tailscale serve status
tailscale ip -4
```

Mint a short-lived link for one device:

```bash
npx t3@latest pair --tailscale --ttl 10m --label "personal-device"
```

Scan the QR code in the T3 mobile app or enter the full pairing URL in a T3
desktop client. Repeat with a newly minted credential for each additional
device. The token is exchanged once for an authenticated device session; it is
not the credential used on every later connection. Manage/revoke access with
`t3 auth`.
[T3 pairing and session model](https://github.com/pingdotgg/t3code/blob/f21d5e444e9a6b5876253ca8618a4dc8d4f2146c/docs/user/remote-access.md#how-pairing-works),
[access management](https://github.com/pingdotgg/t3code/blob/f21d5e444e9a6b5876253ca8618a4dc8d4f2146c/docs/user/remote-access.md#managing-access-later)

Prefer the emitted `https://<machine>.<tailnet>.ts.net/` address. T3 documents
that a bare numeric address entered without a scheme is interpreted as HTTP;
plain `http://100.x.y.z:3773` works only when the server itself listens on that
reachable address and cannot be used by the hosted HTTPS app because browsers
block mixed content. With a loopback-bound background server behind Tailscale
Serve, the HTTPS MagicDNS endpoint is the correct path.
[T3 Tailscale endpoint behavior](https://github.com/pingdotgg/t3code/blob/f21d5e444e9a6b5876253ca8618a4dc8d4f2146c/docs/user/remote-access.md#tailscale-endpoints),
[Tailscale IP CLI](https://tailscale.com/docs/reference/tailscale-cli#ip)

The hosted pairing URL is only a client-side bootstrap. `app.t3.codes` does not
proxy the traffic; the browser connects directly to the Tailscale HTTPS
endpoint. Pairing credentials live in the URL fragment so they are not sent to
the hosted app origin, but they remain sensitive in history, screenshots, and
copy/paste.
[T3 hosted web pairing](https://github.com/pingdotgg/t3code/blob/f21d5e444e9a6b5876253ca8618a4dc8d4f2146c/docs/user/remote-access.md#hosted-web-app-pairing)

### T3 Connect account integration over the Tailscale data path

If T3 Connect login, mobile activity, and notifications are desired but the
actual server connection should stay on Tailscale:

```bash
npx t3@latest connect link --publish-only --headless
systemctl --user restart t3code.service
npx t3@latest connect status
npx t3@latest pair --tailscale --ttl 10m --label "personal-device"
```

Over SSH, Connect automatically selects out-of-band OAuth even without
`--headless`: it prints an authorization URL to open on a browser-equipped
device, then prompts for the returned code. A successfully stored Connect
credential is separate from the bearer credential minted by `t3 pair`.
[Connect headless authorization source](https://github.com/pingdotgg/t3code/blob/f21d5e444e9a6b5876253ca8618a4dc8d4f2146c/apps/server/src/cli/connect.ts#L52-L113)

Do not publish `connect status --json`: it can include account/environment
identifiers and the provisioned relay URL. Human-readable status is sufficient
for validation.

### Full managed T3 Connect tunnel

Use this only when clients should connect without joining the same tailnet:

```bash
npx t3@latest connect link --headless
systemctl --user restart t3code.service
npx t3@latest connect status
```

Full linking obtains T3 Connect account authorization, installs or reuses the
managed `cloudflared` relay client, marks remote exposure desired, and relies on
server startup reconciliation to provision the environment link. It is not a
Tailscale-IP flow. The background systemd service and T3 Connect are managed
separately; signing out of Connect does not uninstall the service.
[Connect CLI implementation](https://github.com/pingdotgg/t3code/blob/f21d5e444e9a6b5876253ca8618a4dc8d4f2146c/apps/server/src/cli/connect.ts),
[T3 background service and Connect](https://github.com/pingdotgg/t3code/blob/f21d5e444e9a6b5876253ca8618a4dc8d4f2146c/docs/user/background-service.md#using-it-with-t3-connect)

T3 `0.0.32` has an unresolved report in its own issue tracker where Connect
authorization succeeds but relay provisioning returns HTTP 403 and status stays
at `pending server startup`. The report identifies no documented local fix or
entitlement rule. Treat a reproduced 403 as an upstream/account-side blocker,
retain the service log, and use direct Tailscale pairing rather than repeatedly
relinking or exposing port 3773 publicly.
[T3 Code issue #5612](https://github.com/pingdotgg/t3code/issues/5612)

## Pi: exact update and model-catalog behavior

### Current stable version and endpoints

On 2026-08-10 UTC, both the Pi-owned latest-version API and npm `latest`
dist-tag reported `@earendil-works/pi-coding-agent` `0.84.1`; the installed
version observed before this research was also `0.84.1`. A plain self-update
therefore should say that Pi is already current unless a different executable
or install prefix is selected.
[Pi release v0.84.1](https://github.com/earendil-works/pi/releases/tag/v0.84.1),
[Pi version-check source](https://github.com/earendil-works/pi/blob/936aff00918de1187f085f123c2812d8f2d67745/packages/coding-agent/src/utils/version-check.ts#L1-L88),
[npm package](https://www.npmjs.com/package/@earendil-works/pi-coding-agent/v/0.84.1)

The self-update version lookup is:

```text
GET https://pi.dev/api/latest-version
```

It has a ten-second overall budget and two additional retries when invoked by
`pi update`. Provider catalogs use:

```text
GET https://pi.dev/api/models/providers/<url-encoded-provider-id>
```

Catalog requests carry `If-None-Match` when an ETag-backed cached body exists.
Pi treats 304 as unchanged, 404/501 as no remote overlay, retains cached data on
transient failure, and refreshes automatically no more often than every four
hours unless forced by `update --models`.
[remote catalog provider](https://github.com/earendil-works/pi/blob/936aff00918de1187f085f123c2812d8f2d67745/packages/coding-agent/src/core/remote-catalog-provider.ts)

### Why the refresh times out

`pi update --models` first restores cached provider state with network disabled,
then force-fetches every configured refreshable provider concurrently. The CLI
wraps both runtime creation and refresh in one 15-second `AbortController`. If
the signal aborts, it deliberately emits `Model catalog refresh timed out.` even
if most providers succeeded.

This is a known failure class. Pi issue #7323 reports the exact command and
error under intermittent stalled `pi.dev` requests. It was auto-closed rather
than resolved by a maintainer; later users reported the same symptom. The
separate open issue #7153 documents unbounded interactive catalog stalls, and a
Pi collaborator agreed that the UI should use cache-first asynchronous refresh.
These reports corroborate the code path but are not release-fix commitments.
[Pi issue #7323](https://github.com/earendil-works/pi/issues/7323),
[Pi issue #7153](https://github.com/earendil-works/pi/issues/7153)

### Cache and configuration precedence

The relevant user files are under `~/.pi/agent` unless
`PI_CODING_AGENT_DIR` overrides the directory:

| File | Purpose | Effect on “old models” |
| --- | --- | --- |
| `models-store.json` | Pi-managed remote catalog entries keyed by provider, including models, `checkedAt`, `lastModified`, and ETag | A failed refresh keeps its prior cached body. |
| `models.json` | User-defined providers, custom models, built-in model overrides | A matching custom model ID replaces the built-in/remote entry; unknown custom IDs are added. |
| `settings.json` | Defaults and UI behavior, including `defaultProvider`, `defaultModel`, `enabledModels` | Old patterns/defaults can keep the UI selecting or cycling old names even when newer models exist. |
| `auth.json` and environment credentials | Provider authentication | `--list-models` and `/model` show models only for providers with complete auth. |

Pi constructs every built-in provider from package-generated static metadata,
restores a persisted remote overlay, then merges remote models by ID (replace on
match, append when new). It ignores a remote overlay whose `Last-Modified` is
not newer than the package's generated catalog timestamp. Consequently,
deleting the cache is not the first fix: it removes the last-known overlay and
forces more full downloads on a path already timing out.
[remote merge and freshness logic](https://github.com/earendil-works/pi/blob/936aff00918de1187f085f123c2812d8f2d67745/packages/coding-agent/src/core/remote-catalog-provider.ts#L9-L42),
[file-backed model store](https://github.com/earendil-works/pi/blob/936aff00918de1187f085f123c2812d8f2d67745/packages/coding-agent/src/core/models-store.ts#L45-L145),
[model configuration schema](https://github.com/earendil-works/pi/blob/936aff00918de1187f085f123c2812d8f2d67745/packages/coding-agent/src/core/model-config.ts#L194-L298)

`enabledModels` and the CLI `--models` option are model-pattern filters for
Ctrl+P cycling. They do not request catalog updates. `--list-models [search]`
lists currently available authenticated models and accepts an optional fuzzy
search string.
[Pi list-models implementation](https://github.com/earendil-works/pi/blob/936aff00918de1187f085f123c2812d8f2d67745/packages/coding-agent/src/cli/list-models.ts),
[CLI model options](https://github.com/earendil-works/pi/blob/936aff00918de1187f085f123c2812d8f2d67745/packages/coding-agent/src/cli/args.ts#L265-L295)

## Pi diagnostic sequence

Start by proving executable identity and update semantics:

```bash
type -a pi
command -v pi
readlink -f "$(command -v pi)"
pi --version
pi update --help
```

Then inspect model state without exposing credentials:

```bash
pi --list-models
pi --list-models openai
jq '{defaultProvider,defaultModel,enabledModels}' ~/.pi/agent/settings.json
jq -r '.providers | keys[]' ~/.pi/agent/models.json 2>/dev/null || true
jq -r 'keys[]' ~/.pi/agent/models-store.json 2>/dev/null || true
jq 'to_entries | map({provider:.key, checkedAt:.value.checkedAt, lastModified:.value.lastModified, etagPresent:(.value.etag != null), modelCount:(.value.models | length)})' ~/.pi/agent/models-store.json
```

Do not print `auth.json` values. Provider names alone can be listed with
`jq -r 'keys[]' ~/.pi/agent/auth.json`, but environment-provided credentials
may configure additional providers.

Isolate catalog transport one provider at a time. Replace `<provider>` only
with an already-observed provider ID:

```bash
curl --fail --silent --show-error --max-time 10 \
  --output /dev/null \
  --write-out '<provider> status=%{http_code} total=%{time_total}s\n' \
  'https://pi.dev/api/models/providers/<provider>'
```

Run this for each authenticated or cached provider. A single provider that
repeatedly hits the ten-second curl deadline explains the global Pi deadline.
Also compare resolution and the direct version endpoint:

```bash
getent ahosts pi.dev
curl --fail --silent --show-error --max-time 10 https://pi.dev/api/latest-version
```

If every provider endpoint responds reliably, retry exactly once:

```bash
pi update --models
pi --list-models
```

If it still times out, preserve evidence before touching the cache:

```bash
cp -a ~/.pi/agent/models-store.json ~/.pi/agent/models-store.json.before-refresh
```

Only after a backup and successful per-provider probes should a maintainer
consider moving `models-store.json` aside and forcing a clean refresh. Moving
is preferable to deleting because it preserves the last-known catalog and its
validators. `PI_OFFLINE=1` or `pi --offline` is a valid way to keep using
package-bundled and cached models while `pi.dev` is unreliable, but it is not a
way to perform an update: offline mode explicitly disables Pi network/version
checks.
[Pi offline handling](https://github.com/earendil-works/pi/blob/936aff00918de1187f085f123c2812d8f2d67745/packages/coding-agent/src/main.ts#L569-L576)

## Upstream repair opportunities

The minimum Pi fix is source-level, not local timeout inflation:

1. give each catalog attempt a bounded timeout smaller than the existing global
   15-second refresh budget;
2. retry a stalled attempt while preserving caller cancellation;
3. return provider-specific successes/errors instead of converting any global
   abort into one undifferentiated timeout;
4. keep the existing cached catalog on all transient failures;
5. add a deterministic test with one catalog that accepts a request but never
   returns headers.

The installed release already has the correct high-level cache preservation and
generation-checked concurrent publication model. A surgical fix belongs around
the catalog call to `fetchWithRetry` and the `refreshModelCatalogs` deadline,
with regression tests in `remote-catalog-provider.test.ts` and package-manager
CLI tests. Do not patch generated model lists or add a machine-specific retry
loop to `aman-pi-mono-setup`; that would hide the transport bug and diverge from
upstream behavior.

For T3, no local code change is needed for the Tailscale route. If full Connect
continues returning 403 after fresh account authorization, capture redacted
`connect status` plus the relevant `boot-service.log` error and follow issue
#5612. Do not replace private Tailscale Serve with public Funnel or a wildcard
listener merely to bypass Connect provisioning.
