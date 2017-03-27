# Kubernetes on Mariposa

```yaml
cns
    namespace:
        public: mydomain.example.com
services:
    controller:
        description: Controller nodes run primary Kubernetes services and etcd
        service_type: continuous
        compute_type: kvm
        image: triton-kubernetes-controller
        resources:
            package: g4-general-4G
            max_instances: 5
        restart:
            - on-failure
            - on-cn-restart
        placement:
            cn:
                - project!=~{{ .this.project }}
                - service!=~{{ .this.service }}
        cns:
            service:
                - controller
            ttl: 0s
            hysteresis: 5m
    worker:
        description: Worker nodes are stateless and can be scaled up and down as needed
        service_type: continuous
        compute_type: kvm
        image: triton-kubernetes-worker
        resources:
            package: g4-general-8G
        restart:
            - on-failure
            - on-cn-restart
        placement:
            cn:
                - project!=~{{ .this.project }}
                - service!=~{{ .this.service }}
        cns:
            service:
                - worker
            ttl: 0s
            hysteresis: 5m
        ports
            - 80
            - 443
```