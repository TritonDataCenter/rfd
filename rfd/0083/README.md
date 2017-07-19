---
authors: Trent Mick <trent.mick@joyent.com>
state: publish
---

# RFD 83 Triton `http_proxy` support

Some Triton DataCenter standups, by policy, require the use of an HTTP(S)
proxy endpoint for external access. There are a few operator processes that
require external access:

- querying and importing images from https://images.joyent.com for use by users
  of the DC;
- querying and importing images from https://updates.joyent.com for upgrading
  Triton DataCenter component;
- uploading Triton data dumps, manatee backups, and logs to a possibly remote
  Manta; and
- operator usage of `updates-imgadm` (to query updates.joyent.com) and
  `joyent-imgadm` (to query images.joyent.com).

Therefore Triton DataCenter needs to support setting an HTTP proxy. As of
the 2015-08-20 release, Triton DataCenter *does* support an HTTP proxy.

# Overview

HTTP proxy support in Triton DataCenter is entirely through the operator setting
an "http_proxy" config variable on the "sdc" SAPI application to the full URL
to the HTTP proxy. tl;dr:

    sapiadm update $(sdc-sapi /applications?name=sdc | json -H 0.uuid) \
        metadata.http_proxy=http://YourProxyUser:YourProxyPassword@YourProxy:YourProxyPort

# Operator Guide

The operator guide for using an HTTP proxy with Triton DataCenter lives here:
<https://docs.joyent.com/private-cloud/install/headnode-installation/proxy-support>

# User Guide

There should be no impact to users of the DC. The HTTP proxy is completely for
operator interaction.

# Developer Guide

As stated above, the HTTP proxy is completely controlled by the `http_proxy`
SAPI app metadata var. Various core services use that value:

- The 'imgapi' service uses the `http_proxy` for all access to remote IMGAPI
  clients.
  <https://github.com/joyent/sdc-imgapi/blob/f6c069cfb438086206ef34206e322e8dab18973a/sapi_manifests/imgapi/template#L62>
- The 'sdc' service writes a ["/opt/smartdc/sdc/etc/http_proxy.env"
  file](https://github.com/joyent/sdc-sdc/blob/86137f5743c5ade5a10d09faaf0ebc21c332572d/sapi_manifests/http_proxy_env/template)
  with the `http_proxy` value. That .env file is `source`d by the
  `updates-imgadm` and
  [`joyent-imgadm`](https://github.com/joyent/sdc-sdc/blob/86137f5743c5ade5a10d09faaf0ebc21c332572d/bin/joyent-imgadm#L14)
  scripts that live in that zone.
- The 'adminui' service uses the `http_proxy` for access to images.joyent.com
  to show available images.
  <https://github.com/joyent/sdc-adminui/blob/a3cd71de3bed3c7870048301968222d6c05108d4/sapi_manifests/adminui/template#L35>

## Testing HTTP proxy support

This section describes how developers can manually test HTTP proxy support in
Triton DataCenter.

### Setup an HTTP proxy on your Mac

    brew install tinyproxy

Edit your /usr/local/etc/tinyproxy.conf to the equiv of this:

```
User nobody
Group nobody
Port 8888
Timeout 600
DefaultErrorFile "/usr/local/Cellar/tinyproxy/1.8.3/share/tinyproxy/default.html"
StatFile "/usr/local/Cellar/tinyproxy/1.8.3/share/tinyproxy/stats.html"
LogLevel Info
MaxClients 100
MinSpareServers 5
MaxSpareServers 20
StartServers 10
MaxRequestsPerChild 0
Allow 127.0.0.1
ViaProxyName "tinyproxy"
ConnectPort 443
ConnectPort 563

# ---- Added to default tinyproxy.conf.default config:

LogFile "/usr/local/var/log/tinyproxy/tinyproxy.log"
#Allow 10.88.88.1/24

# Allow connections from the NAT'd COAL admin network.
Allow 10.99.99.0/24
```

Start tinyproxy on one terminal:

    tinyproxy -d

Tail its log in another terminal:

    tail -f /usr/local/var/log/tinyproxy/tinyproxy.log

Verify it works (the "10.99." IP here is VMware "vmnet1" interface added to
your computer):

    https_proxy=http://10.99.99.254:8888 curl -i https://google.com


### Disable remote access over the external network for the GZ, sdc and imgapi zones:

    ssh coal
    route delete default 10.88.88.2
    sdc-login -l sdc 'route delete default 10.88.88.2' </dev/null
    sdc-login -l imgapi 'route delete default 10.88.88.2' </dev/null
    sdc-login -l adminui 'route delete default 10.88.88.2' </dev/null

Verify that:

    [root@headnode (coal) ~]# ping 8.8.8.8
    ping: sendto No route to host

Also things like updates-imgadm are now broken:

    updates-imgadm ping


### Configure SDC to use your HTTP proxy

    # sapiadm update $(sdc-sapi /applications?name=sdc | json -H 0.uuid) \
    #     metadata.http_proxy=http://10.88.88.1:8888
    sapiadm update $(sdc-sapi /applications?name=sdc | json -H 0.uuid) \
        metadata.http_proxy=http://10.99.99.254:8888

Wait a minute or two for config-agent, or if you are impatient:

    sdc-login -l sdc svcadm restart config-agent </dev/null
    sdc-login -l imgapi svcadm restart config-agent </dev/null
    sdc-login -l adminui svcadm restart config-agent </dev/null


### Test away

In the COAL imgapi0 zone you should now be able to use the proxy to reach out:

    https_proxy=http://10.99.99.254:8888 curl -i https://google.com

For example:

    [(coal:imgapi0) ~]# https_proxy=http://10.99.99.254:8888 curl -i https://google.com
    HTTP/1.0 200 Connection established
    Proxy-agent: tinyproxy/1.8.3

    HTTP/1.1 302 Found
    ...

In the COAL GZ and the sdc zone:

    updates-imgadm ping

    joyent-imgadm list name=base

In the GZ:

    sdcadm up ...
    sdcadm platform install --latest

    sdc-imgadm -d import -S https://images.joyent.com \
        8879c758-c0da-11e6-9e4b-93e32a67e805 2> >(bunyan)

On your Mac:

    docker pull alpine
    docker run -ti busybox /bin/sh

AdminUI: importing images should work now:

    https://10.88.88.3/images-import


### Restore

When you are done testing, you'll need to restore routes so you no longer need the proxy.

```
sdc-sapi /applications/$(sdc-sapi /applications?name=sdc | json -H 0.uuid) \
    -X PUT -d '{"action": "delete", "metadata": {"http_proxy": null}}'

sdc-login -l adminui 'route add default 10.88.88.2' </dev/null
sdc-login -l imgapi 'route add default 10.88.88.2' </dev/null
sdc-login -l sdc 'route add default 10.88.88.2' </dev/null
route add default 10.88.88.2
```
