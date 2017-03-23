# Example Data Service Corp managed services

[incomplete]

Story details include:

- One detail
- Another detail

Example Data Service Corp (EDSC) provides managed database services to other customers. EDSC offers managed services for a number of products, but in this case they're providing managed MySQL services to Ambitious Corp.

EDSC accepts orders for managed services via their own interfaces (ticketing system, API, etc.). Those interfaces are not operated by Joyent. When they receive an order for a new database, they trigger their own provisioning workflows that interact with Triton APIs to create a project in Mariposa for the new database instance.

They operate MySQL using a variation of [Autopilot Pattern MySQL](https://github.com/autopilotpattern/mysql). The automated operations of the Autopilot Pattern are critical to reducing the  marginal cost of each DB instance they manage. Equally critical are the features Mariposa provides to present that service to the customer.

The database would be useless without network access to it, so EDSC's ordering interface asks customers like Ambitious Corp to specify an existing Triton fabric network to provide the service on. Ambitious Corp may have to specify a network UUID, or, if EDSC's purchase APIs are deeply integrated with Triton, Ambitious Corp may be able to specify the network by name. 

When making the order, Ambitious Corp or other customers are effectively inviting EDSC to share a Triton fabric network with them. Making this work will require challenge-response workflows in Triton and Mariposa. It is also possible that a future, deeper integration would support direct provisioning or delegation of shared fabric networks between customer and provider.

The customer may elect to share the default fabric network for their project (we assume that's the network to which all or most of their instances in that project will be connected). Or, the customer may choose to create a separate fabric network that is specific to the managed database service. In that case, the customer will need to explicitly connect their instances to that network if they need to interact with the managed database service. Similarly, EDSC may also choose to connect all the instances of their managed database service, including instances that play a supporting role (think Consul, in the Autopilot Pattern MySQL context). Or, they may choose to connect only a limited set of instances to the shared fabric network.

- Shared network
- Limited visibility to project
- Discovery forwarding