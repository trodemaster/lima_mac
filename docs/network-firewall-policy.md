# NAT-mode network sandbox: IP + DNS-name filtering, inbound and outbound

Scope: Lima's `usernet` NAT networking (an in-process `gvisor-tap-vsock`
netstack), targeting **both VZ and QEMU backends through the same config and
the same enforcement code** — not a VZ-only feature. Goal is a **strict
sandbox**: the guest can only reach an explicitly allowed set of
destinations (by IP/CIDR and by DNS name), and only explicitly allowed
things can reach the guest — not a best-effort convenience filter.

Status: design only, nothing built. This is a real patch project against
the vendored `gvisor-tap-vsock` (three enforcement points, not one) — there
is no free or partial version of this that's still meaningfully "strict."

## Dependency clarification: gVisor vs. `gvisor-tap-vsock`

These are two different projects, layered — worth being precise since
everything in this doc patches only one of them:

- **`github.com/containers/gvisor-tap-vsock` v0.8.9** — Lima's **direct**
  dependency (`go.mod:29`, `// gomodjail:unconfined`). This is the library
  Lima actually calls (`pkg/networks/usernet/gvproxy.go`, `client.go`) and
  the one that owns all three enforcement points below: the TCP/UDP
  forwarders, the DNS handler, and the ports forwarder.
- **`gvisor.dev/gvisor`** (Google's gVisor) — an **indirect** dependency
  (`go.mod:138`), pulled in *by* `gvisor-tap-vsock`. Lima only gets gVisor's
  `pkg/tcpip` netstack package (the `stack.Stack`, `gonet` adapters,
  `tcp`/`udp` transport implementations) — never `runsc`, gVisor's
  container-sandbox runtime. Lima does not run gVisor as a sandbox anywhere;
  it uses gVisor's TCP/IP stack as a library, one layer removed, via
  `gvisor-tap-vsock`.

**Implication for this design:** the patch target is `gvisor-tap-vsock`,
not gVisor. gVisor's netstack code is what `gvisor-tap-vsock`'s forwarders
are built on top of, but nothing here touches it directly.

---

## Correcting the previous pass at this doc

An earlier version of this doc leaned on `AddDNS` (`pkg/networks/usernet/client.go`
→ `gvproxyclient.Client.AddDNS`, a live HTTP call the running gvproxy
instance already exposes) as a "ship now, no patch needed" first phase. That
was the wrong frame for what's actually being built here:

- `AddDNS` only ever **adds an override record** — there is no deny/NXDOMAIN
  primitive in the library (`pkg/services/dns/dns.go`'s handler falls
  through to normal upstream resolution for anything it doesn't have an
  override for). Pointing a name at a black-hole IP is a workaround, not
  enforcement, and it does nothing at all if the guest (or malware in it)
  connects to a raw IP directly — which defeats the point of a *strict*
  sandbox.
- A filter that only covers hostnames a guest chooses to resolve, and does
  nothing for raw IP traffic, is not a sandbox boundary — it is trivially
  bypassed. Treat DNS-name filtering as one input to the same enforcement
  point that also checks IP/CIDR, not a separate, weaker, shippable-first
  feature.
- Nothing in the previous finding was wrong (the wiring, the HTTP API, the
  live-update capability all check out and are still useful — see below),
  it was just being used to justify skipping the actual enforcement work.

## Three enforcement points, all inside the vendored library, all needing a patch

There is no existing hook for any of these three. All three live in
`gvisor-tap-vsock@v0.8.9` (vendored per `go.mod`), all three are called from
`pkg/virtualnetwork/services.go` during `virtualnetwork.New()` — the single
place Lima's own `pkg/networks/usernet/gvproxy.go` constructs the netstack.

### 1. Outbound — guest-initiated connections

`pkg/services/forwarder/tcp.go` and `udp.go`: `tcp.NewForwarder`/`udp.Forwarder`
resolve the destination and call `net.Dial(...)` directly, no policy check.
This is where an IP/CIDR allow-or-deny check belongs — reject before
`net.Dial` runs, using the already-resolved destination address (`r.ID().LocalAddress`
after NAT translation).

### 2. DNS — the name half of the same policy

`pkg/services/dns/dns.go`'s `dnsHandler.handle`/`addAnswers`: today, an
unmatched query always falls through to the upstream resolver. For a strict
sandbox this needs a real deny path — check the queried name against the
same policy structure that gates outbound IPs, and answer NXDOMAIN (or a
configured refusal) for anything not allowed, **before** falling through to
upstream resolution. This is necessary but not sufficient on its own (per
above) — it exists to stop resolution early and give clean, fast failures
for policy-denied names, while enforcement (1) is what actually stops the
connection regardless of how the destination address was obtained.

`types.Record` already carries an optional `Regexp` field the library
understands (`pkg/types/configuration.go`) — wildcard/pattern rules for
hostnames are plumbing-compatible without further library changes once
enforcement exists.

### 3. Inbound — host-initiated connections into the guest

`pkg/services/forwarder/ports.go`'s `PortsForwarder.Expose` is the only path
anything reaches the guest through in NAT/`usernet` mode — there is no
"external inbound" here by construction (the guest isn't reachable from the
LAN at all in this mode), so inbound filtering in this design *is* "what is
`Expose` allowed to forward into." It's invoked over the same control HTTP
API `AddDNS` uses (`POST /services/forwarder/expose`, mounted in
`pkg/virtualnetwork/services.go`), currently called by Lima itself only for
SSH forwarding (`usernet.Client.ResolveAndForwardSSH`) and any user-defined
`portForwards:` entries — but the HTTP endpoint has no allowlist of its own;
anything with access to the control socket can `Expose` any guest `ip:port`.
For a strict sandbox, `Expose` needs the same allow/deny check as (1),
applied to the *remote* (guest-side) `ip:port` before the proxy is created —
this also closes off the control socket itself as a bypass path, not just
guest-initiated traffic.

---

## One config, two backends: VZ and QEMU both already feed the same netstack

The three enforcement points live entirely inside `gvisor-tap-vsock`,
downstream of whatever transport hands it packets — they don't know or care
whether those packets arrived via VZ or QEMU. A single patch covers both
backends automatically. Checked both drivers directly to confirm the wiring
and find what, if anything, still needs to change:

- **QEMU already connects natively.** `pkg/driver/qemu/qemu.go:784` / `:814`
  wire an explicit named `usernet` network straight to a gvproxy instance via
  `-netdev socket,id=net0,fd={{fd_connect ...}}` against
  `usernet.Sock(nw.Lima, usernet.QEMUSock)`. QEMU speaks `gvisor-tap-vsock`'s
  native `QemuProtocol` wire framing (`listenQEMU`/`AcceptQemu` in
  `pkg/virtualnetwork/virtualnetwork.go`) directly — no translation layer.
- **VZ needs a shim QEMU doesn't.** VZ's raw network device attachment
  doesn't speak that framing, so `pkg/driver/vz/network_darwin.go` converts
  with `qemuPacketConn`/`packetConn` (`DialQemu`, `PassFDToUnix`). VZ is the
  backend with *more* transport-layer code here, not less.
- **The gap is the default path, not capability.** VZ's `startUsernet()`
  (`pkg/driver/vz/vm_darwin.go`) always starts an in-process gvproxy when no
  named network is configured — that's why VZ+NAT already goes through
  `gvisor-tap-vsock` today. QEMU's equivalent default-path code
  (`qemu.go:778-781`) instead falls back to QEMU's own built-in `-netdev
  user` (its bundled slirp), bypassing `gvisor-tap-vsock` entirely when no
  named network is set. Closing this gap means giving QEMU a
  `startUsernet()`-equivalent default (spin up an in-process gvproxy the
  same way VZ does) — copying an existing pattern, not inventing new
  capability.

**Net effect:** once (a) the `gvisor-tap-vsock` policy patch exists and (b)
QEMU's default NAT path is switched to also go through an in-process
gvproxy instance (matching VZ), the same `network.policy` config block
enforces identically on both backends, from one implementation. No
per-backend special-casing needed in the policy logic itself — only the
"does this backend's default path route through gvisor-tap-vsock at all"
question differs, and only for QEMU.

## Policy shape (one structure, checked at all three points)

```go
type Policy struct {
	DefaultAction PolicyAction // Allow or Deny

	AllowCIDRs []net.IPNet
	DenyCIDRs  []net.IPNet

	AllowHosts []HostRule // exact name or regexp, mirroring types.Record
	DenyHosts  []HostRule
}
```

Checked in order at each enforcement point: exact/regexp host rules first
(cheap, and closes the DNS-level check before resolution even happens),
then CIDR rules against the resolved/dialed IP. `DefaultAction` makes this
genuinely support both an allowlist sandbox (`Deny` default, enumerate what's
permitted) and a denylist mode (`Allow` default, enumerate what's blocked) —
a strict sandbox almost certainly wants `Deny`-default, but the mechanism
should support both since the same code serves (1), (2), and (3).

## What the existing `AddDNS`/`Expose` HTTP wiring is actually good for

Not enforcement, but genuinely useful as the **live update transport**: since
`gvproxyclient.Client` already round-trips to the running instance over
`endpointSock` (`pkg/networks/usernet/client.go`), a policy update endpoint
(`POST /services/policy` or similar, added alongside the patch) could let
`limactl` push a changed allow/deny list to a running instance without a
restart — the same pattern `AddDNS`/`Expose` already prove works. Worth
keeping in the design, just not as a substitute for the enforcement patch
itself.

---

## Config surface (lima.yaml, sketch)

```yaml
network:
  policy:
    default: deny
    allow:
      - cidr: 10.0.0.0/8
      - host: "*.internal.example.com"
      - host: api.example.com
    deny:
      - cidr: 169.254.0.0/16   # beyond the existing EC2-metadata special case
```

Scope: per-instance to start (simplest mental model — "this sandboxed VM's
network policy"), revisit global/shared policy defs only if multiple
instances need the same rule set repeated.

---

## Explicitly out of scope

- **`bridged`/`shared` modes, Linux, `lima-privileged-net`, issue #5495** —
  different backend (kernel bridge, not a Go netstack), separate effort if
  ever pursued. See prior investigation (git history of this file) if that
  reasoning needs to be re-derived.
- **`vzNAT`** (Apple's own NAT attachment) — not used by this path; Lima
  already routes VZ+NAT through `gvisor-tap-vsock` instead, per the
  confirmed `startUsernet()` architecture above.
- **QEMU's own built-in `-netdev user` (slirp)** — not being extended or
  patched; QEMU is brought into scope by routing it through
  `gvisor-tap-vsock` instead (see below), not by adding filtering to QEMU's
  own networking.

## Open questions

- Upstream vs. fork: this is now a 3-point patch (forwarder, DNS, ports),
  which is a bigger ask of `gvisor-tap-vsock` maintainers than a single
  field — may be more realistic to maintain as a Lima-side fork/vendor patch
  first, propose upstream once the shape is proven.
- Logging/observability for denied attempts (outbound dial, DNS query, and
  inbound expose) — a strict sandbox needs an audit trail, not just silent
  drops, to be debuggable and trustworthy.
- Does policy apply per-instance only, or does a "sandbox profile" concept
  spanning multiple instances make sense for the botlockbox-style use case
  this is presumably feeding into?
- UDP parity: (1) and (3) both need UDP handled identically to TCP for the
  policy to be complete — easy to accidentally ship TCP-only and call it
  done.

## Recommendation

Treat this as one patch covering all three enforcement points together —
shipping only DNS-name filtering, or only outbound IP filtering, doesn't
satisfy "strict" and would be worth explicitly rejecting as a milestone.
Prototype as a Lima-side fork of the vendored `gvisor-tap-vsock`, wire the
`Policy` struct into `virtualnetwork.New()`'s construction of the TCP/UDP
forwarders, DNS handler, and ports forwarder in one change, then decide on
upstreaming once it's proven against a real workload.

Build and validate against **QEMU first**, since it already speaks
`gvisor-tap-vsock`'s native protocol with no shim in the way — faster
iteration loop for the enforcement patch itself. Add the QEMU
default-path change (matching VZ's `startUsernet()`) either alongside or
right after, so `network.policy` works out of the box on both backends
without the user having to hand-configure a named `usernet` network just to
get the sandbox.
