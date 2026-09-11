# ouro-mcp

A standalone **Zig 0.16 / Linux io_uring** MCP bridge. Each process serves one
newline-delimited stdin/stdout connection and connects on demand to installed
applications' existing Unix MCP sockets. It does not launch applications,
execute descriptor exports, manage services, or activate UIs. Socket activation
belongs to the application installer and service manager.

## Build and test

Requires Linux with enabled io_uring, Zig 0.16.0, and libc development headers.
Python 3.11+ is used only for independent test fixtures, never by the bridge.

```sh
zig build -Doptimize=ReleaseSafe
zig build test
python3 -m unittest discover -s tests -v
zig-out/bin/ouro-mcp --app dev.ourokit.contacts
```

The executable is `zig-out/bin/ouro-mcp`. Repeat `--app ID` to restrict exposure;
without filters it exposes every valid discovered application. There is no
daemon or shared bridge process. `.agents/setup` installs the checksum-pinned
compiler in a fresh Amp orb; it does not configure or start services.

## Protocol and host compatibility

Only **MCP 2026-07-28** is supported. Every request must contain
`params._meta["io.modelcontextprotocol/protocolVersion"]` and an object at
`params._meta["io.modelcontextprotocol/clientCapabilities"]`. There is no
`initialize` handshake or legacy fallback. For example, send this single line:

```json
{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}
```

The bridge implements `server/discover`, `tools/list`, `tools/call`,
`subscriptions/listen` for `toolsListChanged`, and `notifications/cancelled`.
Subscriptions are acknowledged by a notification, not a terminal response.
Notifications carry the upstream subscription's original ID. Cancellation
translates upstream request IDs into bridge-owned downstream IDs. IDs and all
JSON numbers retain their lexemes; no floating-point conversion is involved.

**The current Amp host is not compatible.** A parent-project integration check
on September 11, 2026 used an isolated `amp mcp doctor` configuration. Amp sent
legacy `initialize`; the bridge returned `-32601` with the supported revision.
Doctor reported server status **error**, despite its own exit status being zero.
Use a modern-per-request-metadata host. Adding legacy support is a separate
product decision, not an automatic fallback.

Only complete results are supported; a missing `resultType` is treated as
`complete`. Multi-round-trip results are rejected. The bridge does not advertise
client capabilities to applications: its downstream identity and empty
capability set are fixed, and it does not forward host authentication,
progress/log subscriptions, or extension metadata. Arguments and complete
results otherwise retain their shape. It never retries a tool call, including
after disconnect or an ambiguous response. A subsequent, independently issued
host call may establish a new connection.

## Discovery and cache

The source of truth is [the version 1 contract](mcp-discovery-contract.md).

* Installed catalogs are read in XDG user/system order. A malformed selected
  descriptor masks lower-priority copies. Discovery does not connect to apps.
* Runtime overrides must match an installed app's ID and endpoint, have a live
  same-UID PID/start-time pair, and pass ownership, mode, and non-symlink checks.
  Descriptor directories are opened component-by-component relative to the
  runtime directory. The endpoint names the socket itself; no suffix is added.
* Exposed names are `ouro_` plus SHA-256 of `application_id + NUL + tool_name`.
  Descriptions preserve the app's description after an `[application/tool]`
  prefix. Object keys and tool ordering are canonicalized for comparison, while
  array ordering and numeric lexemes are preserved.
* Descriptors are rescanned on access and at one-second intervals. Timer scans
  never create connections. Publication at an unchanged endpoint preserves
  in-flight mutations and marks old catalog fetches dirty.
* First use connects, requests a tools-change subscription, validates its ack,
  then obtains a live catalog or a fresh shared cache entry. Only ordinary
  `-32601`/`-32602` subscription errors or an empty accepted filter permit
  on-access fallback. Invalid acknowledgment order is a connection error.
* Cache keys cover selected origin/content, runtime descriptor, socket endpoint
  and runtime directory, protocol, UID, bridge identity/capabilities, and sorted
  app filters. Both public and private entries are restricted to that context
  and UID; public entries are not broadened to other contexts.
* Tool-list caches live in `$XDG_CACHE_HOME/ouro/mcp` (default `~/.cache/ouro/mcp`).
  Expiry is persisted with random early jitter of up to 10% and a conservative
  30-day upper bound. Zero/negative/missing TTLs are immediately stale. Pagination
  uses the earliest page expiry, not the time the final page arrives.
* Nonblocking `flock` coordinates refreshes; the loop checks again every 100 ms
  and rereads freshness after acquiring the lock. Lockfiles are never unlinked.
  Atomic epoch markers invalidate cached and in-flight pre-change generations.
  Readers check the epoch before and after loading; writers stamp the epoch
  captured before fetching. Corrupt entries are misses. Cache write failure
  does not fail a completed live catalog.
* An offline bridge rechecks caches on later `tools/list` accesses and returns
  to the installed/runtime baseline when they expire. TTLs never wake apps.
  Tool-call results are never cached.

The filesystem is a same-user trust boundary, not an authentication mechanism.
Descriptors and cache files should be on a local filesystem. Bounded catalog
reads, directory traversal, and atomic cache writes use synchronous libc file
operations; stdin/stdout/socket reads, writes, connects, cancellation, and
timers use io_uring. A remote or stalled filesystem can therefore delay this
process. Cache locks themselves never block the I/O loop.

## Resource limits and shutdown

| Resource | Bound |
|---|---|
| Wire frame, including newline | 256 KiB |
| Descriptor/cache file | 256 KiB |
| JSON nesting | 128 levels |
| Installed applications | 64 |
| Directory entries visited per scan | 4,096 |
| Installed descriptor bytes per scan | 16 MiB |
| Tools per app / downstream pages | 512 / 16 |
| Aggregate exposed catalog | 1,024 tools and <256 KiB |
| Pending host requests | 128 total, 30 tool calls per app |
| Upstream subscriptions / ID encoding | 32 / 1 KiB |
| Each peer's output queue | 128 frames and 1 MiB |
| Connect, ack, refresh, request, frame, write deadlines | 10 seconds |
| EOF output drain | At most 1 second |

Upstream pagination is unnecessary within the aggregate bound and is rejected;
bounded downstream pagination is collected before publication. Capacity errors
are explicit, not truncated catalogs. A malformed or oversized application
frame closes only that application's bridge connection. An oversized stdin
frame, saturated stdout, or broken stdout terminates that bridge process rather
than recursively queuing error responses into a full queue.

EOF cancels this bridge's in-flight requests and subscriptions, drains its
bounded queued output, and closes only its own descriptors. Transport closure
ends upstream subscriptions without queuing a batch of completion messages.
Other bridge instances and the app's service lifetime are unaffected. Closing
io_uring slots remain unavailable until operation **and** cancellation CQEs have
retired; shutdown retires kernel references before releasing the ring.

## Verification

`tests/` uses independent fake Unix services and subprocess stdio clients. It
covers offline no-connect discovery, precedence, runtime liveness/security,
multiple bridge processes, shared refresh locks, cache epochs/TTL/scope/jitter,
dirty rereads, cancellation, no replay, number lexemes end to end and through
caches, publication during an in-flight mutation, malformed/oversized frames,
slow peers, deadlines, catalog limits, and output saturation.

The Ourokit parent project owns `tests/mcp_bridge.py`. Against the publication
fix executable it verified real `systemd-socket-activate` with one headless
Ourokit app: two bridges share counter state, reload replaces tools and notifies
both hosts, one bridge's EOF leaves the other usable, and a third discovers the
runtime catalog while the installed baseline stays unchanged. This test is not
copied into this repository because it depends on Ourokit's own test helpers.

Official protocol references:
[stdio](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/stdio),
[versioning](https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning),
[discovery](https://modelcontextprotocol.io/specification/2026-07-28/server/discover),
[subscriptions](https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/subscriptions),
[cancellation](https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/cancellation),
[caching](https://modelcontextprotocol.io/specification/2026-07-28/server/utilities/caching).
