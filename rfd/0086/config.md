## Configuration syntax improvements

JSON as a configuration language leaves much to be desired. It has no comments, is unforgiving in editing (we've specifically written code in ContainerPilot to point out extraneous trailing commas in the config!). Any configuration language change should also support those users we know who are generating ContainerPilot configurations automatically.

We will abandon JSON in favor of the somewhat more human-friendly [JSON5](https://github.com/json5/json5) configuration language. It has a particular advantage for those users who are generating configuration because JSON documents are valid JSON5 documents. YAML and [Hashicorp's HCL](https://github.com/hashicorp/hcl) were possible alternatives but feedback from the community and resulted in pushback on both due to either difficulty of correctly hand-writing (in the case of YAML) or lack of library support (in the case of HCL).

The `CONTAINERPILOT` environment variable and `-config` command line flag will no longer support passing in the contents of the configuration file as a string. Instead they will now indicate the directory location for configuration files, with a default value of `/etc/containerpilot.d` (note that we're removing the `file://` prefix as well). During ContainerPilot configuration loading, we can check for files in the config directory and merge them together. The merging process is as follows:

- Lexigraphically sort all the config files.
- Multiple `jobs` (formerly `services`), `health`, `sensor` blocks are unioned.
- Keys with the same name replace those that occurred previously.

For example consider the two JSON5 files below.

1.json5
```json5
{
  consul: {
    host: "localhost:8500"
  },
  jobs: [
    {
      name: "nginx",
      port: 80
    },
    {
      name: "appA",
      port: 8000
    }
  ],
  health: [
    {
      name: "checkA",
      job: "nginx"
      exec: "curl -s --fail localhost/health"
    }
  ]
}
```


2.json5
```json5
{
  consul: {
    host: "consul.svc.triton.zone:8500"
  },
  jobs: [
    {
      name: "appA",
      port: 9000
    },
    {
      name: "appB",
      port: 8000
    }
  ],
  health: [
    {
      name: "checkB",
      job: "nginx"
      exec: "curl -s --fail localhost/otherhealth"
    }
  ]
}
```

These will be merged as follows:

```json5
{
  consul: {
    host: "consul.svc.triton.zone:8500"
  },
  jobs: [
    {
      name: "nginx",
      port: 80
    },
    {
      name: "appA",
      port: 9000
    },
    {
      name: "appB",
      port: 8000
    }
  ],
  health: [
    {
      name: "checkA",
      job: "nginx"
      exec: "curl -s --fail localhost/health"
    },
    {
      name: "checkB",
      job: "nginx"
      exec: "curl -s --fail localhost/otherhealth"
    }
  ]
}
```


The full example configuration for ContainerPilot found in the existing docs would look like the following:


```json5
{
  consul: {
    host: "localhost:8500"
  },
  logging: {
    level: "INFO",
    format: "default",
    output: "stdout"
  },
  jobs: [
    {
      name: "app",
      // we want to start this job when the "setup" job has exited
      // with success but give up after 60 sec
      when: {
          source: "setup",
          event: "exitSuccess",
          timeout: "60s"
      },
      exec: "/bin/app",
      restart: "never",
      port: 80,
      heartbeat: 5,
      tll: 10,
      stopTimeout: 5,
      tags: [
        "app",
        "prod"
      ],
      interfaces: [
        "eth0",
        "eth1[1]",
        "192.168.0.0/16",
        "2001:db8::/64",
        "eth2:inet",
        "eth2:inet6",
        "inet",
        "inet6",
        "static:192.168.1.100", // a trailing comma isn't an error!
        ]
    },
    {
      name: "setup",
      // we can create a chain of "prestart" events
      when: {
          source: "consul-agent",
          event: "healthy"
      },
      exec: "/usr/local/bin/preStart-script.sh",
      restart: "never"
    },
    {
      name: "preStop",
      when: {
          source: "app",
          event: "stopping"
      },
      exec: "/usr/local/bin/preStop-script.sh",
      restart: "never",
    },
    {
      name: "postStop",
      when: {
          source: "app",
          event: "stopped"
      },
      exec: "/usr/local/bin/postStop-script.sh",
    },
    {
      // a service that doesn't have a "when" field starts up on the
      // global "startup" event by default
      name: "consul-agent",
      // note we don't have a port here because we don't intend to
      // advertise one to the service discovery backend
      exec: "consul -agent -join consul",
      restart: "always"
    },
    {
      name: "consul-template",
      exec: ["consul-template", "-consul", "consul",
             "-template", "/tmp/template.ctmpl:/tmp/result"],
      restart: "always",
    },
    {
      name: "task1",
      exec: "/usr/local/bin/tash.sh arg1",
      frequency: "1500ms",
      timeout: "100ms",
    },
    {
      name: "reload-app",
      when: "watch.app changes",
      exec: "/usr/local/bin/reload-app.sh",
    },
    {
      name: "reload-nginx",
      when: "watch.nginx changes",
      exec: "/usr/local/bin/reload-nginx.sh",
    }
  ],
  health: {
    {
      name: "checkA",
      job: "nginx",
      exec: "/usr/bin/curl --fail -s -o /dev/null http://localhost/app",
      poll: 5,
      timeout: "5s",
    }
  }
  watches: {
    {
      name: "app",
      poll: 10,
      timeout: "10s"
    },
    {
      name: "nginx",
      poll: 30,
      timeout: "30s",
    }
  },
  control: {
    socket: "/var/run/containerpilot.socket"
  },
  telemetry: {
    port: 9090,
    interfaces: "eth0"
  },
  sensors: [
    {
      name: "metric_id"
      help: "help text"
      type: "counter"
      poll: 5
      exec: "/usr/local/bin/sensor.sh"
    }
  ]
}
```

_Related GitHub issues:_
- [support containerpilot.d config directory](https://github.com/joyent/containerpilot/issues/236)
- [onEvent hook](https://github.com/joyent/containerpilot/issues/227)
- [environment section for config](https://github.com/joyent/containerpilot/issues/232)
- [more env vars](https://github.com/joyent/containerpilot/issues/229)
- [configurable service names](https://github.com/joyent/containerpilot/issues/193)
