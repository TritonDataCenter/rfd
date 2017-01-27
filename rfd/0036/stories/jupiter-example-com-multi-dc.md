# Running jupiter.example.com in multiple data centers

Story details include:

- multiple data centers
- supervision

The operators of [jupiter.example.com](./jupiter-example-com.md) have distributed the application among a number of Triton data centers for both global availability and performance reasons. The operators have set a minimum number of instances in each data center for each service that must always remain running. The expected instances per data center per service may look like this:

|        | us-west-1 | us-sw-1 | us-east-1 | eu-ams-1 |
|--------|-----------|---------|-----------|----------|
| Nginx  | 2         | 1       | 2         | 1        |
| PHP    | 2         | 1       | 2         | 1        |
| Consul | 3         | 1       | 3         | 1        |

The developers have chosen this configuration so that they can have at least two data centers with significant fault tolerance, and two additional data centers running in a minimal configuration for additional redundancy in case the other data centers fail. However, there is no provision in Mariposa to specify application behavior across data centers (i.e.: Mariposa doesn't know that you consider this your "primary" DC, or that your "backup").

If instances within a data center fail, Mariposa will attempt to replace them within the same data center. Instance failure is detected by health checks run by Mariposa. The operators have elected to use Mariposa's ContainerPilot integration for those.

In the case of a complete failure of one of the data centers, Mariposa has no mechanism to provision replacement instances in a _new_ data center. Instead, the operators expect the CDN requests will fail over to the remaining data centers. They've configured auto-scaling to add additional capacity in each data center based on usage metrics from those instances.

Further reading: [Health-checking, monitoring, and scaling jupiter.example.com](./jupiter-example-com-monitoring-and-health.md).