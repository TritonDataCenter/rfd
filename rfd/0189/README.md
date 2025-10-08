---
authors: Nick Wilkens <nwilkens@edgecast.io>
state: draft
discussion: https://github.com/TritonDataCenter/rfd/issues?q="RFD+189"
---

# RFD 189 Console Access Through CloudAPI

## Problem Statement

Currently, console access to Triton instances is only available through direct compute node access via the `vmadm console` command. This requires operators or users to have SSH access to compute nodes, which is not always desirable or practical.

VNC console access exists for KVM and Bhyve instances through CloudAPI (added in API v8.4.0), but this only provides graphical console access and is limited to HVM brands. There is no remote text-based console access for:

- Serial console access to KVM instances (for boot debugging, firmware access)
- Zone console access to SmartOS native zones (Joyent, Joyent-minimal brands)
- Zone console access to LX instances
- Zone console access to Bhyve instances (as an alternative to VNC)

This limitation prevents:
- Remote troubleshooting without compute node SSH access
- Early boot debugging (before networking is configured)
- Recovery from network misconfigurations
- Access to boot loaders, firmware, and BIOS
- Integration with web-based console clients
- Automated console access for monitoring and diagnostics

## Proposed Solution

Expose console access through CloudAPI via WebSocket endpoints, similar to the existing VNC implementation. Console access will be available for all VM brands through a unified interface:

- **KVM**: Serial console (COM1/ttyS0) via unix socket
- **Bhyve**: Zone console via zoneadmd console socket
- **Joyent/Joyent-minimal**: Zone console via zoneadmd console socket
- **LX**: Zone console via zoneadmd console socket

The implementation follows the proven VNC architecture:
1. Client connects to CloudAPI WebSocket endpoint
2. CloudAPI queries CNAPI for console connection details
3. CNAPI queries vmadmd (via vm-agent) for host and port
4. vmadmd maintains TCP proxies to console sockets on compute nodes
5. CloudAPI establishes TCP connection and proxies bidirectional byte streams

## Principles and Constraints

### Design Principles

1. **Consistency with VNC**: Follow the existing VNC implementation pattern for authentication, authorization, WebSocket handling, and error management
2. **Brand Agnostic**: Support all VM brands through a unified interface
3. **Security First**: Require CloudAPI authentication, respect RBAC policies, provide audit logging
4. **No CN Access Required**: Users should not need compute node SSH access
5. **Backward Compatibility**: Additive changes only, no breaking changes to existing APIs
6. **Operational Simplicity**: Minimal operator intervention, self-managing proxies

## User Interaction

### End Users

**CloudAPI Endpoint**:
```
GET /:account/machines/:machine/console
```

Upgrades HTTP connection to WebSocket for bidirectional console access.

**CLI Usage** (node-triton):
```bash
# Connect to instance console
triton instance console <instance>
triton inst console <instance>

# Interactive terminal session
# Press Ctrl-] to disconnect
```

**Example Session**:
```
$ triton inst console my-instance
Connecting to console... (Ctrl-] to disconnect)

my-instance console login: root
Password:
Last login: Tue Sep 30 22:00:00 2025 on console
[root@my-instance ~]#
[root@my-instance ~]# ^]
[Disconnecting...]
$
```

**Verification** (that it's working):
- Console connects and displays output
- Keyboard input works
- Escape sequence (Ctrl-]) disconnects cleanly
- Multiple concurrent connections supported

**Troubleshooting** (if broken):
- **"Machine is not running"**: Instance must be in 'running' state
- **"Connection closed immediately"**: Check CloudAPI/CNAPI logs, verify vmadmd is running on CN
- **"No console output"**: Check vmadmd console proxy logs, verify console socket exists
- **"Permission denied"**: Verify machine ownership and RBAC policies

### Operators

**Monitoring**:
- vmadmd logs show console proxy creation/destruction
- CloudAPI audit logs show console access attempts
- CNAPI logs show console endpoint queries

**Troubleshooting**:
```bash
# Check if console proxy exists for VM
vmadm info <uuid> console

# Check vmadmd console proxy logs
tail -f /var/svc/log/system-smartdc-vmadmd:default.log | grep console

# Check console socket exists
ls -l /var/run/zones/<uuid>.console_sock  # for joyent/lx/bhyve
ls -l /zones/<uuid>/root/tmp/vm.console    # for kvm

# Test console proxy directly
nc <admin-ip> <console-port>
```

**Deployment**:
- Update vmadmd on compute nodes (requires platform update or manual deployment)
- Update CNAPI (via `sdcadm update cnapi`)
- Update CloudAPI (via `sdcadm update cloudapi`)
- Update node-triton CLI (via npm or package manager)

## Repositories Being Changed

1. **smartos-live** (`src/vm/sbin/vmadmd.js`, `src/vm/node_modules/proptable.js`)
   - Add console proxy infrastructure to vmadmd
   - Add runtime_info support for all brands

2. **sdc-cnapi** (`lib/endpoints/vms.js`)
   - Add console endpoint to query vmadmd

3. **sdc-cloudapi** (`lib/endpoints/console.js`, `lib/errors.js`, `lib/app.js`)
   - Add WebSocket console endpoint
   - Add error types
   - Mount endpoint

4. **node-triton** (`lib/do_instance/do_console.js`, `lib/tritonapi.js`, `lib/cloudapi2.js`, `lib/do_instance/index.js`)
   - Add `triton instance console` command

## Public Interface Changes

### CloudAPI

**New Endpoint**:
```
GET /:account/machines/:machine/console
```

**API Version**: 9.0.0

**Request**: WebSocket upgrade
**Response**: 101 Switching Protocols, WebSocket connection

**Errors**:
- 400 MachineStoppedError - Instance is not running
- 404 ResourceNotFoundError - Instance not found
- 401/403 - Authentication/authorization failures

**Protocol**: Binary WebSocket, raw byte stream, no terminal emulation

**Escape Sequence**: Ctrl-] (0x1d) to disconnect (client-side)

### CNAPI

**New Endpoint**:
```
GET /servers/:server_uuid/vms/:uuid/console
```

**Response**:
```json
{
  "host": "10.0.0.5",
  "port": 45678,
  "type": "socket"
}
```

### CLI (node-triton)

**New Command**:
```
triton instance console [OPTIONS] INST
```

**Options**:
- `-h, --help`: Show help

**Behavior**:
- Connects stdin/stdout to WebSocket
- Sets terminal to raw mode
- Ctrl-] to disconnect
- Restores terminal on exit

## Private Interface Changes

### vmadmd

**New Functions**:
- `spawnConsoleProxy(vmobj)` - Create TCP proxy for console access
- `clearConsoleProxy(uuid)` - Destroy console proxy
- `reloadConsoleProxy(vmobj)` - Reload console proxy
- `infoConsole()` - Return console connection details

**New Object**:
- `CONSOLE` - Tracks console proxy state (host, port, server, type, path)

**vm.info() Extension**:
- Add 'console' as valid info type for all brands
- Returns `{console: {host, port, type}}` structure

**Console Socket Paths**:
- KVM: `<zonepath>/root/tmp/vm.console` (serial console)
- Others: `/var/run/zones/<zonename>.console_sock` (zoneadmd console)

**Handshake Protocol** (non-KVM brands):
- Send: `IDENT C 0\n`
- Receive: `OK <details>\n`
- Then: Start bidirectional data flow

**Proxy Lifecycle**:
- Created when VM starts (alongside VNC proxy)
- Destroyed when VM stops
- Ephemeral TCP port on admin network
- One proxy per VM, multiple connections supported

### Brand Features (proptable.js)

**runtime_info** added to all brands:
- `kvm`: `['all', 'block', 'blockstats', 'chardev', 'console', 'cpus', 'kvm', 'pci', 'spice', 'status', 'version', 'vnc']`
- `bhyve`: `['all', 'vnc', 'console']`
- `joyent`: `['console']`
- `joyent-minimal`: `['console']`
- `lx`: `['console']`

This enables `vmadm info <uuid> console` for all brands.

## Implementation Details

### Architecture

```
┌─────────┐                    ┌──────────┐                    ┌───────┐
│  Client │                    │ CloudAPI │                    │ CNAPI │
│ (triton)│                    │          │                    │       │
└────┬────┘                    └────┬─────┘                    └───┬───┘
     │                              │                              │
     │ GET /console (WebSocket)     │                              │
     ├─────────────────────────────>│                              │
     │                              │                              │
     │                              │ GET /vms/:uuid/console       │
     │                              ├─────────────────────────────>│
     │                              │                              │
     │                              │ {host, port, type}           │
     │                              │<─────────────────────────────┤
     │                              │                              │
     │ 101 Switching Protocols      │                              │
     │<─────────────────────────────┤                              │
     │                              │                              │
     │                              │                              │
     │    WebSocket ←──────────────→ TCP Proxy ←───────────────────┼─────────┐
     │                              │                              │         │
     │                              │                              │         v
     │                              │                              │   ┌──────────┐
     │                              │                              │   │  vmadmd  │
     │                              │                              │   │  (on CN) │
     │                              │                              │   └─────┬────┘
     │                              │                              │         │
     │                              │                              │         │ TCP
     │                              │                              │         v
     │                              │                              │   ┌──────────┐
     │                              │                              │   │ Console  │
     │                              │                              │   │  Socket  │
     │                              │                              │   └──────────┘
```

### Console Socket Types

| Brand | Console Type | Socket Path | Handshake Required |
|-------|--------------|-------------|-------------------|
| KVM | Serial Console | `/zones/<uuid>/root/tmp/vm.console` | No |
| Bhyve | Zone Console | `/var/run/zones/<uuid>.console_sock` | Yes (IDENT/OK) |
| Joyent | Zone Console | `/var/run/zones/<uuid>.console_sock` | Yes (IDENT/OK) |
| Joyent-minimal | Zone Console | `/var/run/zones/<uuid>.console_sock` | Yes (IDENT/OK) |
| LX | Zone Console | `/var/run/zones/<uuid>.console_sock` | Yes (IDENT/OK) |

### Handshake Protocol (Zoneadmd Console)

For non-KVM brands, the console_sock requires a handshake:

1. **Client connects** to unix socket
2. **Client sends**: `IDENT <locale> <flags>\n`
   - Example: `IDENT C 0\n`
3. **Server responds**: `OK <zonename> <ttyname>\n`
   - Example: `OK a0f29ee3-0ec7-4e0c-9eca-f7332391c51d /dev/zconsole\n`
4. **Data flow begins**: Bidirectional byte stream

This handshake is implemented in vmadmd's console proxy for non-KVM brands.

### Component Changes

#### vmadmd (smartos-live)

**Global State**:
```javascript
var CONSOLE = {};  // Tracks console proxy state
```

**Core Functions**:
```javascript
// Create TCP proxy to console socket
function spawnConsoleProxy(vmobj)

// Destroy console proxy
function clearConsoleProxy(uuid)

// Reload console proxy (e.g., on VM restart)
function reloadConsoleProxy(vmobj)

// Return console info via vm.info()
function infoConsole()
```

**Proxy Implementation**:
```javascript
server = net.createServer(function (c) {
    var console = net.Stream();

    if (isKvm) {
        // KVM: Direct pipe
        c.pipe(console);
        console.pipe(c);
        console.connect(consolePath);
    } else {
        // Zoneadmd: Handshake then pipe
        console.connect(consolePath);
        console.once('connect', function () {
            console.write('IDENT C 0\n');
            console.once('data', function (data) {
                if (data.toString().indexOf('OK') === 0) {
                    c.pipe(console);
                    console.pipe(c);
                }
            });
        });
    }
});
```

**Lifecycle Integration**:
- `spawnConsoleProxy()` called when VM starts (alongside spawnRemoteDisplay)
- `clearConsoleProxy()` called when VM stops (in clearVM)
- Proxies survive vmadmd restarts (recreated on startup)

#### CNAPI

**Endpoint Handler**:
```javascript
VM.console = function handlerVmConsole(req, res, next) {
    var types = ['console'];
    req.stash.vm.info(
        { req_id: req.getId(), types: types },
        function (error, infoResponse) {
            var vminfo = JSON.parse(infoResponse);
            res.send({
                host: vminfo.console.host,
                port: vminfo.console.port,
                type: vminfo.console.type
            });
        }
    );
};
```

**Route Registration**:
```javascript
http.get(
    { path: '/servers/:server_uuid/vms/:uuid/console', name: 'VmConsole' },
    ensure({...}),
    VM.console
);
```

#### CloudAPI

**WebSocket Endpoint** (`lib/endpoints/console.js`):
- Based on VNC endpoint implementation
- Uses Finite State Machine (FSM) pattern via mooremachine
- States: init → upgrade → getport → connect → connected
- Binary WebSocket protocol
- TCP connection to vmadmd console proxy

**Error Types** (`lib/errors.js`):
```javascript
function MachineHasNoConsoleError(brand)  // 400
```

**FSM States**:
1. **init**: Initial state
2. **upgrade**: Upgrade HTTP to WebSocket
3. **getport**: Query CNAPI for console details
4. **connect**: Establish TCP connection to vmadmd
5. **connected**: Bidirectional data proxying
6. **error/closed**: Cleanup and termination

#### node-triton CLI

**Console Command** (`lib/do_instance/do_console.js`):
- Sets stdin to raw mode for direct terminal access
- Handles Ctrl-] escape sequence (0x1d)
- Restores terminal on exit
- Bidirectional piping: stdin → WebSocket, WebSocket → stdout

**API Methods**:
- `TritonApi.prototype.getInstanceConsole(id, cb)` - High-level API
- `CloudApi.prototype.getMachineConsole(uuid, cb)` - WebSocket connection

## Testing

### Unit Tests

1. **vmadmd**: Console proxy creation, lifecycle, handshake
2. **CNAPI**: Endpoint validation, vm-agent communication
3. **CloudAPI**: Authentication, WebSocket upgrade, FSM transitions

### Integration Tests

1. **End-to-end**: Client → CloudAPI → CNAPI → vmadmd → console
2. **Multi-brand**: Test with KVM, Bhyve, Joyent, LX instances
3. **Concurrent connections**: Multiple clients to same console
4. **Lifecycle**: Connection during VM stop/restart
5. **Error scenarios**: Invalid machine, stopped machine, network failures

### Manual Testing

1. **KVM**: Boot messages, GRUB interaction, serial console login
2. **Bhyve**: UEFI messages, OS boot, zone console login
3. **Joyent**: Zone boot messages, login prompt, shell access
4. **LX**: Linux boot messages, login, container shell

### Load Testing

- Concurrent connections (10, ...)
- Connection duration (hours)
- Memory usage per connection (<200KB)
- CPU usage per connection (<0.5%)

## Operational Considerations

### Monitoring

**Metrics** (vmadmd):
- Console proxy count (gauge)
- Console connections active (gauge)
- Console connection errors (counter)
- Proxy creation/destruction rate (counter)

**Metrics** (CloudAPI):
- Console endpoint requests (counter)
- WebSocket upgrade success/failure (counter)
- Connection duration (histogram)
- Error rate by type (counter)

**Alerts**:
- Console connection failure rate > 1%
- Console proxy memory usage > 500KB per connection
- No console connections for 24h (possible issue)

### Logging

**vmadmd** (INFO level):
```
spawning console listener for <uuid> on <ip> (brand: <brand>)
console proxy for <uuid> listening on <ip>:<port> (type: socket, path: <path>)
console connection started from [<ip>]:<port> for VM <uuid>
console connection ended from [<ip>]:<port> for VM <uuid>
```

**CloudAPI** (audit logs):
```
{
  "action": "ConnectMachineConsole",
  "machine": "<uuid>",
  "account": "<account>",
  "remoteAddress": "<ip>",
  "timestamp": "..."
}
```

### Troubleshooting

**Common Issues**:

1. **Console closes immediately**
   - Check: vmadmd running on CN?
   - Check: Console proxy spawned? (`vmadm info <uuid> console`)
   - Check: CloudAPI/CNAPI logs for errors

2. **No console output**
   - Check: VM actually running?
   - Check: Console socket exists? (`ls -l /var/run/zones/<uuid>.console_sock`)
   - Check: Handshake succeeding? (vmadmd logs)

3. **Permission denied**
   - Check: Machine ownership
   - Check: RBAC policies
   - Check: CloudAPI authentication

4. **Port conflicts**
   - vmadmd uses ephemeral ports (unlikely)
   - Check: netstat output for conflicts

## Alternative Approaches Considered

### 1. Direct /dev/zcons Device Access

**Approach**: Proxy `/dev/zcons/<zonename>/zoneconsole` device directly

**Rejected**:
- Device is a symlink to kernel pseudo-device
- fs.createReadStream() doesn't work with character devices
- net.connect() fails with ENOTSOCK
- Would need complex PTY handling

**Why zoneadmd socket is better**:
- Already handles device I/O properly
- Protocol is documented (zlogin behavior)
- No PTY management needed
- Existing, proven interface

### 2. Spawn zlogin Process Per Connection

**Approach**: vmadmd spawns `zlogin -C <uuid>` for each connection, proxies stdio

**Rejected**:
- More complex lifecycle management
- Additional process overhead

**Why socket proxy is better**:
- Lower overhead (just TCP proxy)
- Simpler implementation
- No process management

### 3. Reuse VNC Endpoint

**Approach**: Overload VNC endpoint to support console

**Rejected**:
- Different semantics (graphical vs text)
- Different use cases
- Confusing API
- Makes VNC code more complex

## Future Enhancements

### Multiple Serial Ports (KVM)

Support selection of serial port:
```
GET /:account/machines/:machine/console?port=0  # serial0 (default)
GET /:account/machines/:machine/console?port=1  # serial1 (metadata)
```

### Session Recording

Optional recording of console sessions for audit/compliance:
- Configurable per account or globally
- Storage in Manta or local
- Playback capability
- Privacy/compliance considerations

### Read-Only Mode

View-only console access without input:
- Different permission level
- Monitoring use case
- Lower privilege requirement

### Connection Sharing

Multiple clients connected to same console:
- Broadcast mode (all see same output)
- Requires state management in vmadmd
- Complex lifecycle handling

### Web-Based Console Client

Browser-based terminal emulator:
- xterm.js integration
- No CLI required
- AdminUI integration
- Mobile access

## References

- **VNC Implementation**: RFD discussion (if exists), CloudAPI vnc.js
- **Metadata Socket**: RFD 69 (explains vm.ttyb usage)
- **Zone Console**: illumos zcons(4D) man page
- **zlogin Source**: illumos-joyent/usr/src/cmd/zlogin/zlogin.c
- **Console Handshake**: zlogin handshake_zone_sock() function
