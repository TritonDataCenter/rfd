---
authors: Josh Wilsdon <jwilsdon@joyent.com>, Angela Fong <angela.fong@joyent.com>
state: publish
---

# RFD 18 Support for using labels to select networks and packages

## Current support for packages/networks in sdc-docker

Currently a user creating a docker container does not select their networks in
their `docker run` commandline though they can specify the -P in order to get a
an external NIC. The external NIC is based on the default network configured
for the data center. The fabric network they're given is always the network
configured in UFDS as the default for their account.

Users also do not directly select their package. The package is chosen based on
the `-m` parameter if passed (if not, we treat as 1024m). We'll find the
smallest package that fits their memory limit, and since all the packages have
the same ratios of cpu/disk/memory all the other parameters are scaled
appropriately.


## Impetus

In order to allow customers to specify non-default networks, we'd like the
ability for them to add these at container creation. This will allow them to use
different network setups for different containers without needing to interact
with cloudapi, except to create and manage the networks themselves.

In order to support SDC setups where there are multiple hardware profiles with
different different ratios of cpu/disk/memory, we need to be able to support
selecting a package. If a customer has for example one set of hardware that has
a higher ratio of CPU to disk/memory (high-cpu) and another set that has a
higher ratio of disk to memory/cpu (high-disk) and a 3rd set of servers in the
middle (normal), their users would currently not be able to specify which
package/hardware family to use.

The proposal here is to allow them to use docker labels to select a package so
that they can create separate packages for each of these hardware profiles and
add traits (normal, high-disk, high-cpu in this case) to both the hardware and
packages to ensure that things are distributed to the correct hardware for the
package.


## Relevant Docker syntax

When creating a container you can add labels via:

```
docker create [...] --label <LabelName>=<LabelValue> [...]
docker run [...] --label <LabelName>=<LabelValue> [...]
```

labels can only be set in a `docker run` or in your Dockerfile when doing a
`docker build`. It is not possible to change labels for an existing container.

For existing containers, you can see labels on the container with:

```
docker inspect <container>
```

Which will return as Config.Labels an object containing the key/value pairs of
the container's labels. You can also filter by label when doing `docker ps` such
as:

```
docker ps --filter "label=<LabelName>[=<LabelValue>]"
```

with LabelValue being optional.


## Proposed Implementation

What we propose here is to make a reserved namespace for labels that have
special meanings for sdc-docker. These would look like:

```
com.joyent.<key>=<value>     # Joyent/Triton-specific use cases
```
or
```
triton.<key>=<value>         # Triton-specific use cases
```

and the first of these would be `com.joyent.package`. If a user specifes this
key and a value that's either a package UUID, package name or package shortend
uuid (as used by `triton`), we'll ignore any -m value or other current package
selection criteria and give the user the specific package they referenced. If
their `<value>` here does not match an existing package, an error will be
returned and the docker container will not be provisioned. When provisioned the
actual label we'll attach to the container can be the package uuid (this is what
you'll see if you `docker inspect`).

We would also add a corresponding "magic" lookup when using a `docker ps`
filter. What we would do is allow any of:

```
docker ps --filter "label=com.joyent.package=<PackageName>"
docker ps --filter "label=com.joyent.package=<ShortUUID>"
docker ps --filter "label=com.joyent.package=<UUID>"
```

to match packages, even though the actual label is just the uuid. We'll do the
lookup from PAPI to allow all 3 of these to work so that customers can set and
query based on them.

Similar to package, we'd add `triton.networks` and `triton.network.public` to
provide users the flexibility of selecting networks from the ones they have
access to. As users may want more than one network attached to a container,
`triton.networks` should allow multiple values. Since we cannot have multiple
`--network` or `--label` options with the same key, the current thinking is
that we'd allow:

```
docker create --label "triton.networks=networkA,networkB [...]
```

where the value for the key here is a comma separated list of one or more
networks. Then when doing filtering we could allow:

```
docker ps --filter "label=triton.networks=networkA,networkB"
docker ps --filter "label=triton.networks=networkA"
```

so that you could look up VMs with a specific combination of networks, or all
VMs matching a single network.

When user wants a container to present itself on a public network that is
different from the default external network configured in the data center, the
user would specify the `triton.network.public` label to set the desired
"public" network, whether it is external or internal.

The single-value `--network` argument will still be supported for compatibility
with Docker. It should work together with `--label triton.network.public`.
However if both `--network` and `--label triton.networks` are specified, the
`--network` value will be ignored.

Combining the different network arguments above would enable the user to
attach a container to the desired default or non-default, fabric or non-fabric
networks at provisioning time.

When the same network is passed more than once through these argunments, the
duplicated values should be eliminated so that the container does not end up
having more than one NIC on the same network.

Finally network pools should be allowed and work in the same way as individual
networks when it comes to specifying networks in these network arguments.


## Future Considerations

 * should add a cache for PAPI data in sdc-docker


## Tickets

 * [DOCKER-502](https://mnx.atlassian.net/browse/DOCKER-502) -- adding support for selecting packages
 * [DOCKER-585](https://mnx.atlassian.net/browse/DOCKER-585) -- adding support for selecting networks
 * [DOCKER-897](https://mnx.atlassian.net/browse/DOCKER-897) -- expanding support to non-fabric networks
 * [DOCKER-936](https://mnx.atlassian.net/browse/DOCKER-936) -- expanding support to multiple networks
 * [DOCKER-1020](https://mnx.atlassian.net/browse/DOCKER-1020) -- adding support for selecting network for exposed ports
