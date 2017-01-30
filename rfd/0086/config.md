## Configuration syntax improvements

JSON as a configuration language leaves much to be desired. It has no comments, is unforgiving in editing (we've specifically written code in ContainerPilot to point out extraneous trailing commas in the config!). Any configuration language change should also support those users we know who are generating ContainerPilot configurations automatically.

We will abandon JSON in favor of the more human-friendly YAML configuration language. It has a particular advantage for those users who are generating configuration because of the ubiquity of YAML-generating libraries (this is its major advantage over Hashicorp HCL). During ContainerPilot configuration loading, we can check for files in `/etc/containerpilot.d/` (a configurable location via the `-config` flag) and merge them together.

The merging process is as follows:

- Lexigraphically sort all the config files.
- Multiple `service`, `health`, `sensor` blocks are unioned.
- Keys with the same name replace those that occurred previously.

For example consider the two YAML files below.

1.yml
```
consul:
  host: localhost:8500

services:
  nginx:
    port: 80

  app-A:
    port: 8000

health:
  nginx:
    check-A:
      command: curl -s --fail localhost/health

```

2.yml
```
consul:
  host: consul.svc.triton.zone

services:
  app-A:
    port: 9000

  app-B:
    port: 8000

health:
  nginx:
    check-B:
      command: curl -s --fail localhost/otherhealth

```

These will be merged as follows:

```
consul:
  host: consul.svc.triton.zone

services:
  nginx:
    port: 80

  app-A:
    port: 9000

  app-B:
    port: 8000

health:
  nginx:
    check-A:
      command: curl -s --fail localhost/health
    check-B:
      command: curl -s --fail localhost/otherhealth

```


The full example configuration for ContainerPilot found in the existing docs would look like the following:


```
consul:
  host: localhost:8500

logging:
  level: INFO
  format: default
  output: stdout

service:
  app:
    port: 80
    heartbeat: 5
    tll: 10
    tags:
    - app
    - prod
    interfaces:
    - eth0
    - eth1[1]
    - 192.168.0.0/16
    - 2001:db8::/64
    - eth2:inet
    - eth2:inet6
    - inet
    - inet6
    - static:192.168.1.100"

    stopTimeout: 5
    preStop: /usr/local/bin/preStop-script.sh
    postStop: /usr/local/bin/postStop-script.sh

    depends:
      setup:
        wait: success
      nginx:
        onChange: /usr/local/bin/reload-nginx.sh
        poll: 30
        timeout: "30s"
      consul-agent:
        wait: healthy
      app:
        onChange: /usr/local/bin/reload-app.sh
        poll: 10
        timeout: "10s"

  setup:
    command: /usr/local/bin/preStart-script.sh {{.ENV_VAR_NAME}}
    advertise: false
    restart: never

  consul-agent:
    port: 8500
    command: consul -agent -join consul
    advertise: false
    restart: always

  consul-template:
    command: >
      consul-template -consul consul
          -template /tmp/template.ctmpl:/tmp/result
    advertise: false
    restart: always

  task1:
    command: /usr/local/bin/tash.sh arg1
    frequency: 1500ms
    timeout: 100ms
    advertise: false


health:
  nginx:
    check-A:
      command: >
        /usr/bin/curl --fail -s -o /dev/null http://localhost/app
      poll: 5
      timeout: "5s"

telemetry:
  port: 9090
  interfaces:
  - eth0

sensor:
  name: metric_id
  help: help text
  type: counter
  poll: 5
  check: /usr/local/bin/sensor.sh

```

_Related GitHub issues:_
- [support containerpilot.d config directory](https://github.com/joyent/containerpilot/issues/236)
- [onEvent hook](https://github.com/joyent/containerpilot/issues/227)
- [environment section for config](https://github.com/joyent/containerpilot/issues/232)
- [more env vars](https://github.com/joyent/containerpilot/issues/229)
- [configurable service names](https://github.com/joyent/containerpilot/issues/193)
