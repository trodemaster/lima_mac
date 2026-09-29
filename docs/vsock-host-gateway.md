# A scoped vsock RPC gateway for guest→host calls

Design notes for a potential upstream proposal: a small, fixed-verb RPC channel
over an existing VZ vsock port that lets the **guest** ask the **host** to
perform a narrow set of host-side actions (open a URL, write the clipboard,
post a notification, …) — the mirror image of
[host-capability-helper.md](host-capability-helper.md), which is host→helper
for capabilities `limactl` can't hold. This doc is guest→host, over a
transport Lima already has wired up.

Status: proposal sketch, not started. No upstream issue yet.

---

## Motivation

Came out of a networking investigation (VZ + sockets: could
`gvisor-tap-vsock` replace `socket_vmnet`; could vsock carry host-delegated
actions for the guest). The networking-replacement question resolved to "no,
different problem" (see
[network-firewall-policy.md](network-firewall-policy.md) for the firewall
half of that investigation). This doc is the second half: vsock is already a
private, non-network-exposed, per-VM channel — worth using deliberately for a
*small, well-defined* set of host actions rather than leaving it as
transport-only.

The scope is deliberately narrow: a fixed-function gateway/proxy, not a
generic "run a process on the host" exec channel. A guest is a lower-trust
principal than the host user; a general exec RPC turns any guest compromise
into host code execution. A short allowlisted verb set keeps the blast radius
to whatever each verb actually does.

---

## What Lima already has to build on

- `pkg/driver/vz/vm_darwin.go` already reserves a fixed vsock port (2222) for
  the guest agent and negotiates SSH-over-vsock vs. usernet fallback
  (`useSSHOverVsock`, `startVsockForwarder`).
- `pkg/driver/vz/vsock_forwarder.go` has the primitives: `dialVsock` opens an
  arbitrary vsock port against `m.SocketDevices()`; `startVsockForwarder`
  shows the accept-loop / `tcpproxy.DialProxy` pattern for bridging a vsock
  port to a `net.Listener`.
- `pkg/driver/vz/vz_driver_darwin.go` already threads a
  `SetVsockEventCallback` (`driver.VsockEventEmitter`) through the driver for
  vsock lifecycle events — the same wiring point a gateway's `Serve` loop
  would start from.

So the transport and the per-driver wiring pattern both exist; what's missing
is the protocol and the verb registry.

---

## Protocol sketch

Reserve a new fixed vsock port (e.g. `2223`) alongside the guest-agent port.
Length-prefixed JSON, one request/response per connection — no long-lived
multiplexed session, since the verb set is small and calls are infrequent:

```
[4 bytes BE length][JSON body]
```

```go
type Request struct {
	ID     string          `json:"id"`     // client-generated, echoed back
	Verb   string          `json:"verb"`   // "openURL" | "clipboardWrite" | "notify" | ...
	Params json.RawMessage `json:"params"`
}

type Response struct {
	ID    string          `json:"id"`
	OK    bool            `json:"ok"`
	Data  json.RawMessage `json:"data,omitempty"`
	Error string          `json:"error,omitempty"`
}
```

### Server (host side, hostagent)

```go
type Handler func(ctx context.Context, params json.RawMessage) (any, error)

type Gateway struct {
	handlers map[string]Handler // fixed set, registered at startup — no dynamic registration
}

func (g *Gateway) Serve(ctx context.Context, vsockListener net.Listener) error {
	for {
		conn, err := vsockListener.Accept()
		// ...
		go g.handleConn(ctx, conn) // decode Request, dispatch, encode Response, close
	}
}
```

Each handler validates its own `Params` strictly — e.g. `openURL` checks the
scheme is `http`/`https` before calling `open`. No verb takes a raw command
line or argv; that constraint is what keeps this a gateway instead of exec.

### Client (guest side)

```go
func Call(ctx context.Context, verb string, params, out any) error {
	conn, err := net.Dial("vsock", fmt.Sprintf("2:%d", HostGatewayPort)) // CID 2 = host
	// write framed Request, read framed Response, unmarshal Data into out, or return Error
}
```

Ship as a small package plus a `lima-guestagent host-call <verb> <json>` CLI
shim so guest-side scripts can call it without linking Go.

---

## Where changes land (conceptual, in Lima)

- New `pkg/hostgateway` (protocol types, server `Gateway`, guest-side `Call`
  client) — sibling to `pkg/hosthelper` from
  [host-capability-helper.md](host-capability-helper.md), but note the trust
  direction is reversed: here the *host* is the more-privileged, unprivileged
  requests come from the *guest*, so the server must be the paranoid side
  (strict `Params` validation, fixed verb registry, no dynamic dispatch).
- `pkg/driver/vz/vm_darwin.go` reserves the new vsock port next to 2222 and
  starts `Gateway.Serve` the same way `startVsockForwarder` is started today.
- `cmd/lima-guestagent` gets the `host-call` subcommand wrapping the client.
- `website/content/en/docs/` — a page documenting the verb set, same
  documentation posture as `socket_vmnet` / the eventual host-helper docs.

## Verb registry (starting set, TBD)

| Verb | Params | Notes |
|---|---|---|
| `openURL` | `{url}` | scheme allowlist (`http`, `https`) |
| `clipboardWrite` | `{data, uti}` | plain bytes + type tag, same shape as the clipboard RPC in host-capability-helper.md |
| `clipboardRead` | `{}` | -> `{data, uti}` |
| `notify` | `{title, body}` | maps to `UNUserNotificationCenter` / `osascript display notification` |

Room to grow, but each addition should be argued for individually — this
table is the actual security boundary, not the transport.

---

## Open questions

- Is this VZ-only, or should the QEMU driver also expose it? QEMU has no
  native vsock device the way VZ does; would need a different transport
  (usernet unix socket) for parity, which changes the "why vsock" framing.
- Auth: vsock is already host↔guest-exclusive (no network exposure), but a
  compromised guest can still call every registered verb. Is that
  acceptable given the verb set is inherently low-privilege by construction,
  or does this want a per-instance opt-in / per-verb config gate
  (`hostGateway.allow: [openURL, notify]` in the instance YAML)?
- Relationship to `host-capability-helper.md`: could the two share a proto
  package even though the trust direction is inverted? Worth deciding before
  either gets an upstream issue, so they don't fork the same IPC idioms
  independently.
- Versioning/compat: same concern as `HostHelper.Info` in the capability-helper
  doc — an `Info`-style verb reporting the registry and protocol version, so
  older/newer guest agents degrade gracefully against a given host.

## Recommendation

Prototype as a Lima fork/branch feature behind a driver-level flag before
opening an upstream issue: implement `openURL` and `notify` first (no binary
payloads, easy to reason about, immediately useful), validate the vsock
wiring end-to-end, then decide whether clipboard should live here or stay
exclusively in the host-capability-helper design (it currently appears in
both docs' verb tables — pick one home before upstreaming either).
