# Health-checking, monitoring, and scaling jupiter.example.com

Story details include:

- monitoring and scaling
- healthchecks
- supervision

The operators of [jupiter.example.com](./jupiter-example-com.md) depend on automated health checks in Mariposa to automatically reprovision new instances for those that may have failed, and monitoring tools to alert them to exceptional performance situations and automatically scale the application as needed.

[INSERT SPECIFIC METRICS, including scaling thresholds, here]

- Memory, disk, CPU load, CPU latency, and network bytes for all containers as provided by Container Monitor (RFD27)
- Nginx's requests handled and requests not handled counts (more than 0 of the latter are cause for an alarm), as provided by autopilotpattern/nginx's ContainerPilot telemetry
- Consul's quorum status, as may be provided by autopilotpattern/consul's ContainerPilot telemetry
- Generated metrics from Nginx and PHP/Apache logs, as may be provided by 3rd party logging services or other integrations, including the count of http 5xx log entries divided by http 2xx entries

[INSERT HEALTHCHECKS here]

Additional reading: [jupiter.example.com in multiple data centers](./jupiter-example-com-multi-dc.md).
