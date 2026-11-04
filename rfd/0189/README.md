---
authors: Nick Wilkens <nwilkens@edgecast.io>
state: draft
discussion: https://github.com/TritonDataCenter/rfd/issues?q="RFD+189"
---

# RFD 189 Console Access Through CloudAPI

## Problem Statement

Text console access to Triton instances is only available on the compute node,
through `vmadm console` or `zlogin -C`. Users who lock themselves out of an
instance (broken network config, failed boot, firewall mistakes) need an
operator to help them.

CloudAPI has had ConnectMachineVNC since API version 8.4.0, but that only
covers the graphical console of KVM and bhyve instances. There is no remote
access to:

- the serial console of KVM and bhyve instances
- the zone console of SmartOS (joyent, joyent-minimal) instances
- the zone console of LX instances

## Proposed Solution

Add a CloudAPI websocket endpoint, ConnectMachineConsole, that relays an
instance's text console. The compute node never exposes a console without a
short-lived, single-use ticket.

1. The client opens a websocket to `GET /:login/machines/:id/console`.
2. CloudAPI checks that console access is enabled, the brand is supported, and
   the instance is running.
3. CloudAPI asks CNAPI for a ticket (`POST /servers/:s/vms/:uuid/console`).
   CNAPI runs `vmadm info <uuid> console` through cn-agent, and vmadmd issues
   a ticket: admin IP, port and a random token.
4. CloudAPI connects to vmadmd, sends the token and waits for `OK`. vmadmd
   connects to the console and, for zone consoles, does the zoneadmd
   handshake.
5. Only then does CloudAPI accept the websocket upgrade and start relaying.
   Every failure before this point is a normal HTTP error.

| Brand          | Console        | Backend socket                       |
| -------------- | -------------- | ------------------------------------ |
| kvm            | serial         | `/zones/<uuid>/root/tmp/vm.console`  |
| bhyve          | serial         | `/var/run/zones/<uuid>.console_sock` |
| joyent         | zone           | `/var/run/zones/<uuid>.console_sock` |
| joyent-minimal | zone           | `/var/run/zones/<uuid>.console_sock` |
| lx             | zone           | `/var/run/zones/<uuid>.console_sock` |
| docker (lx)    | not supported  |                                      |

The bhyve zone console is attached to the guest's first serial port, which is
why it is reported as `serial`.

## Security

### Threat model

The console gives interactive access to an instance, often at a login prompt
and sometimes at a shell that was left logged in. It must never be reachable
without CloudAPI authentication and authorization for that instance.

The earlier draft of this work had vmadmd keep an unauthenticated TCP listener
open on the admin network for every running instance. Anything that could
reach the admin network could attach to any console. That design is replaced
by the ticket scheme below.

### Tickets

- A ticket is issued only when `console` is requested by name from
  `vmadm info`. It is never part of `all`.
- The token is 32 bytes from `crypto.randomBytes`, hex encoded. It is valid
  for one connection and expires after 30 seconds.
- vmadmd stores tickets keyed by the SHA-256 of the token and never logs the
  token.
- vmadmd has one listener on the admin IP with an ephemeral port. It is only
  open while unused tickets exist. When the last ticket is used or expires the
  listener closes and any unauthenticated connections are dropped.
- A connection has 5 seconds to send its token. At most 16 unauthenticated
  connections are accepted at once, 4 tickets per VM and 256 per compute node
  can be outstanding.
- Tickets and sessions are revoked when the VM leaves the running state, for
  every brand.

### Sessions

- One session per VM. A second session gets `ERR busy`, which CloudAPI
  returns as 409 ConsoleBusy.
- zoneadmd serves a single console client, so a session also fails with
  `busy` while an operator has `zlogin -C` attached, and an operator's
  `zlogin -C` is refused while a CloudAPI session is open. For KVM, qemu's
  serial socket queues a second client rather than refusing it, so an operator
  using `vmadm console` during a CloudAPI session will see no output until the
  session ends.
- Sessions end after 30 minutes without traffic or 8 hours in total.

### Authorization

- The endpoint is disabled unless the operator sets the CloudAPI SAPI
  metadata `CLOUDAPI_CONSOLE_ACCESS=true`.
- The RBAC action is `connectmachineconsole`. It is separate from
  `getmachine` and `connectmachinevnc`, so sub-users need it granted
  explicitly.
- CloudAPI audit logs record the request with status 101 when the session
  starts.

### Known limitations

- The token and the console stream cross the admin network in cleartext
  between CloudAPI and vmadmd. This matches VNC and the other internal Triton
  APIs: an attacker who can read or modify admin network traffic can already
  drive CNAPI and cn-agent directly. Encrypting this hop would only help as
  part of authenticating Triton's internal services in general.
- watershed buffers a whole websocket frame before handing it to CloudAPI and
  has no frame size limit, so a client can make CloudAPI allocate a large
  frame. ConnectMachineVNC has the same exposure. The fix belongs in
  watershed as a maximum frame size option.

## Interfaces

### CloudAPI

```
GET /:login/machines/:id/console
```

Available from CloudAPI 9.23.0 for API version 9. The websocket carries raw
console bytes in binary frames both ways. Accepted subprotocols are `console`
and `binary`. Text frames from the client close the session.

| Error                 | Status | When                                        |
| --------------------- | ------ | ------------------------------------------- |
| ConsoleAccessDisabled | 403    | `CLOUDAPI_CONSOLE_ACCESS` is not set        |
| MachineHasNoConsole   | 400    | docker container or unsupported brand       |
| MachineStopped        | 400    | instance is not running                     |
| ConsoleBusy           | 409    | another session holds the console           |
| ConsoleUnavailable    | 503    | no ticket, or vmadmd or the console failed  |
| UpgradeRequired       | 400    | missing websocket upgrade headers           |

After the upgrade, CloudAPI closes the websocket with a reason when the
session ends, for example `console closed` when the VM stops.

### CNAPI

```
POST /servers/:server_uuid/vms/:uuid/console
```

```json
{
  "host": "10.99.99.7",
  "port": 40123,
  "token": "<64 hex chars>",
  "type": "zone",
  "expires_in": 30
}
```

Returns 404 if the VM does not exist and 409 if it is not running. CNAPI waits
20 seconds for cn-agent, which keeps it inside the ticket lifetime.

### vmadm and vmadmd

`vmadm info <uuid> console` returns the ticket above under `console`. The
`console` info type is now accepted for every brand, and joyent,
joyent-minimal and lx accept `all`.

Wire protocol on the ticket port:

```
client -> vmadmd   <token>\n
vmadmd -> client   OK\n         then the raw console stream
                   ERR <reason>\n   then close
```

Reasons are `invalid token`, `busy`, `console unavailable`,
`console not responding` and `console handshake failed`.

For zone consoles vmadmd sends `IDENT C 0\n` to the zoneadmd socket, the same
identification `zlogin -C` sends. zoneadmd answers `OK\n` and immediately
starts relaying console output, so output can arrive in the same read as the
`OK`. vmadmd buffers up to the newline and forwards the rest. When another
client holds the console zoneadmd answers with that client's pid instead,
which vmadmd reports as `busy`.

### node-triton

```
triton instance console INST
```

Puts the terminal in raw mode and relays it to the console. Ctrl-] anywhere
in the input disconnects. Exits 0 when the user disconnects or the console
closes, and non-zero with the close reason when the session is dropped.

## Repositories

| Repository   | Change                                                            |
| ------------ | ----------------------------------------------------------------- |
| smartos-live | `console_broker.js` ticket broker, vmadmd integration, proptable  |
| sdc-cnapi    | `VmConsole` endpoint                                              |
| sdc-cloudapi | `ConnectMachineConsole` endpoint, errors, SAPI flag              |
| node-triton  | `triton instance console`                                         |

## Deployment

The pieces can ship in any order. Console access works once all of these are
in place, and the CloudAPI flag is what turns it on:

1. A platform with the vmadmd change on the compute nodes. Compute nodes on
   older platforms return a CNAPI error, which CloudAPI reports as
   ConsoleUnavailable.
2. CNAPI with `VmConsole`.
3. CloudAPI 9.23.0, then `sapiadm update $(sdc-sapi /services?name=cloudapi |
   json -Ha uuid) metadata.CLOUDAPI_CONSOLE_ACCESS=true`.
4. node-triton with `triton instance console`.

### Operator troubleshooting

```
# Issue a ticket by hand and connect to it
vmadm info <uuid> console
printf '%s\n' <token> | nc <host> <port>

# vmadmd console events (tickets, sessions, failures)
grep '"component":"console"' $(svcs -L vmadmd) | bunyan
```

## Testing

- smartos-live: `src/vm/tests/test-console-broker.js` covers tickets, single
  use, expiry, listener shutdown, the zoneadmd handshake (including output
  sent with `OK` and the busy reply), one session per VM, revocation, idle and
  maximum session time, and limits. It passes on node 0.10, the platform's
  node.
- sdc-cnapi: `test/test-vm-console.js` covers ticket validation and error
  mapping.
- sdc-cloudapi: `test/console-unit.test.js` covers the token exchange, busy
  and failure replies, timeouts, relay flow control, the input backlog limit
  and text frames.
- node-triton: `test/unit/consoleEscape.test.js` covers escape detection.
- Still to do on real hardware: kvm, bhyve, joyent and lx instances end to end,
  stop and reboot during a session, and `zlogin -C` contention.

## Alternatives Considered

### Always-on listener per VM

The first implementation. Rejected because it exposes every console to the
admin network without authentication.

### A dedicated cn-agent task instead of `vmadm info`

A `machine_console_ticket` task would make the side effect explicit, but needs
changes to sdc-cn-agent and node-vmadm as well. The CNAPI interface is already
a POST, so the compute node side can move to a dedicated task later without
changing CNAPI or CloudAPI.

### Reading `/dev/zcons/<zone>/zoneconsole` directly

The zoneadmd socket already handles the console device, and going through it
keeps zoneadmd's single-client rule, so vmadmd and `zlogin -C` cannot both
write to a console at once.

### Spawning `zlogin -C` per session

Works, but adds a process per session for no gain over the zoneadmd socket.

### Extending ConnectMachineVNC

VNC and the text console have different clients and brand support. A separate
endpoint keeps both simple.

## Future Work

- A maximum frame size option in watershed, used by both console and VNC.
- Read-only sessions under a separate RBAC action.
- A browser client using xterm.js and pre-signed URLs.
- Selecting the second KVM serial port.

## References

- illumos `zcons(4D)`, `zlogin(1)`
- illumos-joyent `usr/src/cmd/zoneadmd/zcons.c` (console socket protocol)
- sdc-cloudapi `lib/endpoints/vnc.js`
