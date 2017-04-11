## Configuration syntax improvements

JSON as a configuration language leaves much to be desired. It has no comments, is unforgiving in editing (we've specifically written code in ContainerPilot to point out extraneous trailing commas in the config!). Any configuration language change should also support those users we know who are generating ContainerPilot configurations automatically.

We will abandon JSON in favor of the somewhat more human-friendly [JSON5](https://github.com/json5/json5) configuration language. It has a particular advantage for those users who are generating configuration because JSON documents are valid JSON5 documents. YAML and [Hashicorp's HCL](https://github.com/hashicorp/hcl) were possible alternatives but feedback from the community and resulted in pushback on both due to either difficulty of correctly hand-writing (in the case of YAML) or lack of library support (in the case of HCL).

The `CONTAINERPILOT` environment variable and `-config` command line flag will no longer support passing in the contents of the configuration file as a string. Instead they will now indicate the directory location for configuration files, with a default value of `/etc/containerpilot.d` (note that we're removing the `file://` prefix as well). During ContainerPilot configuration loading, we can check for files in the config directory and merge them together. The merging process is as follows:

- Lexigraphically sort all the config files.
- Multiple `jobs` (formerly `services`), `watches` (formerly `backends`), and `sensor` blocks are unioned.
- Keys with the same name replace those that occurred previously.

For example consider the two JSON5 files below.

1.json5
```json5
{
  consul: "localhost:8500",
  jobs: [
    {
      name: "nginx",
      port: 80,
      health: {
        exec: "curl -s --fail localhost/health",
        poll: 5,
        ttl: 10
      }
    },
    {
      name: "appA",
      port: 8000
    }
  ]
}
```


2.json5
```json5
{
  consul: "consul.svc.triton.zone:8500",
  jobs: [
    {
      name: "appA",
      port: 9000
    },
    {
      name: "appB",
      port: 8000
    }
  ]
}
```

These will be merged as follows:

```json5
{
  consul: "consul.svc.triton.zone:8500",
  jobs: [
    {
      name: "nginx",
      port: 80,
      health: {
        exec: "curl -s --fail localhost/health",
        poll: 5,
        ttl: 10
      }
    },
    {
      name: "appA",
      port: 9000
    },
    {
      name: "appB",
      port: 8000
    }
  ]
}
```

Details about configuration semantics changes can be found in the discussion of [first-class support for multi-process containers](multiprocess.md).

_Related GitHub issues:_
- [support containerpilot.d config directory](https://github.com/joyent/containerpilot/issues/236)
- [onEvent hook](https://github.com/joyent/containerpilot/issues/227)
- [environment section for config](https://github.com/joyent/containerpilot/issues/232)
- [more env vars](https://github.com/joyent/containerpilot/issues/229)
- [configurable service names](https://github.com/joyent/containerpilot/issues/193)
