# Project manifest

The project manifest defines all the services of a project, as well as other details that may be added in time. Each project has a single active manifest that defines the expected state of the entire project.

```yaml
services:
  nginx:
    service_type: continuous
    compute_type: docker
    image: autopilotpattern/nginx:latest
    package: g4-highcpu-512M
    ports: 
      - 80
      - 443
  redis:
    service_type: continuous
    compute_type: docker
    image: autopilotpattern/redis:latest
    package: g4-general-4G
```

[Please see the service manifest details elsewhere](https://github.com/joyent/rfd/blob/master/rfd/0036/service-manifest.md).

Additional object types that might be expected in future iterations of the project manifest include [network fabrics](https://docs.joyent.com/public-cloud/network/sdn), [RFD36 volumes](https://github.com/joyent/rfd/blob/master/rfd/0026/README.md), and Manta storage "buckets".
