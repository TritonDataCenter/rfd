---
authors: Josh Wilsdon <jwilsdon@joyent.com>
state: predraft
---

# RFD 18 Support for using labels to select networks and packages

## Current support for packages/networks in sdc-docker

Currently a user creating a docker container does not select their networks in
their `docker run` commandline though they can specify the -P in order to get a
an external NIC. The fabric network they're given is always the network
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
com.joyent.<key>=<value>
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

Similar to package, we'd add `com.joyent.networks` for allowing a user to
specify a list of networks they have access to. As users may want more than one
attached to a container, this should allow multiple values. Since we cannot have
multiple --label options with the same key, the current thinking is that we'd
allow:

```
docker create --label "com.joyent.networks=networkA,networkB [...]
```

where the value for the key here is a comma separated list of one or more
networks. Then when doing filtering we could allow:

```
docker ps --filter "label=com.joyent.networks=networkA,networkB"
docker ps --filter "label=com.joyent.network=networkA"  # with some magic
```

so that you could look up VMs with a specific combination of networks, or all
VMs matching a single network.


## Future Considerations

 * should add a cache for PAPI data in sdc-docker


## Open Questions

 * Are we ok with the special cases required here for:
     * the lookup by single network
     * the lookup/specification of package by any of UUID, short UUID, name

 * Any other problems with the overall approach?

 * Which namespace should we use for these special labels?
     * [ZAPI-671](https://devhub.joyent.com/jira/browse/ZAPI-671) might suggest
       using triton.* namespace instead of com.joyent.*?
     * fwiw [Docker Docs](https://docs.docker.com/engine/userguide/labels-custom-metadata/#label-keys-namespaces)
       suggest that "All (third-party) tools should prefix their keys with the
       reverse DNS notation of a domain controlled by the author. For example,
       `com.example.some-label`."

## Tickets

 * [DOCKER-502](https://devhub.joyent.com/jira/browse/DOCKER-502) -- adding support for selecting packages
 * [DOCKER-585](https://devhub.joyent.com/jira/browse/DOCKER-585) -- adding support for selecting networks
