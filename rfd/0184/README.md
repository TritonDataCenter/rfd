---
authors: Nahum Shalman <nahum.shalman@mnx.io>
state: published
---

# RFD 184 SmartOS BHYVE Image Builder Brand

## Problem statement

We currently build our BHYVE images in a `joyent` branded zone which has to be manually
modified to allow access to sensitive device nodes
[as documented](https://github.com/TritonDataCenter/triton-cloud-images/blob/401f1b8/README.md#granting-permission-for-a-zone-to-use-bhyve)
This need for additional `zonecfg` manipulation makes it hard to automate dynamically creating zones suitable for doing these builds.

## Proposed Solution

- Create a dedicated brand that already has access to those device nodes
- Wire up `vmadm` to know how to use that brand to simplify spinning up build zones
- Wire up just enough in triton to know how to create zones using that brand so that operators can use it
- Wire up automation to automate building (and testing) images on a regular cadence

## Implementation Details

The brand will need a name. We are using `builder` as the new brand name.

### Phase 0:
Before actually shipping the new brand we want to prevent a breakage for SmartOS users that we encountered in testing, namely that `smartos-ui` will break
if it encounters zones of a brand it doesn't recognize. If built properly, this update can be shipped at any time before the new brand lands.

- Update [smartos-ui] to not break when it encounters a `builder` branded zone.
- Allow [smartos-ui] to provision `builder` branded zones if the brand exists.

### Phase 1:
Before shipping the new brand to SmartOS we must ensure that its presence won't be dangerous for Triton operators.

- Create the brand in [illumos-joyent]
- Wire it up into `vmadm` in [smartos-live]
- Verify that it works to do bhyve builds as documented in [triton-cloud-images]
- Verify that Triton doesn't automatically expose this new brand to CloudAPI in a dangerous way
- Document the "rescue" procedure for a `builder` branded zone on a system that rolls back to a platform image that doesn't support it.

### Phase 2:
- Figure out what else is needed in Triton to make it possible for operators to use this brand
- Do it
- Test it
  - Verify that non-operators cannot take advantage of it.

### Phase 3:
- Automate builds from [triton-cloud-images]
- Automate testing of those builds
- Automate shipping those builds after verification

### Possible Future Work
- If this brand is used to create build zones for SmartOS platform images, we could then create some in-zone VM based tests to help validate builds.

## Open Questions

- Is there a better name to use than `builder`?
- How do we keep this functionality from being visible to non-admins from CloudAPI?
  - In theory this should at least be partly gated by packages. If no packages
    reference this brand, it shouldn't be possible to accidentally use it.
  - This testing is critical for Phase 1

## Proof of Concept

Demo builds for phases 0 and 1 are available. To walk through what this change would look like from the SmartOS perspective, follow along with this test procedure (assumes you are currently running 20250306T000316Z.)

On a test machine running an up to date SmartOS platform image:
Install the updated [smartos-ui] build:
```
uiadm remove && uiadm install $(uiadm avail -b PR-16 | tail -n 1 | tee /dev/stderr)
```
Verify that the UI still behaves as expected (no user visible change; provisioning a Smartos Zone image only offers `joyent` or `joyent-minimal` for the brand.)

Update to a test platform image that includes the new brand:
```
piadm install https://us-central.manta.mnx.io/nshalman/public/rfd184/platform-20250318T153511Z.tgz
piadm activate 20250318T153511Z
reboot
```

Verify that the UI now allows you to provision a `builder` branded zone.
Some example json to use:
```json
{
  "alias": "cloud-image-builder",
  "hostname": "cloud-image-builder",
  "brand": "builder",
  "limit_priv": "default,proc_clock_highres,sys_dl_config",
  "max_physical_memory": 8192,
  "tmpfs": 8192,
  "fs_allowed": "ufs,pcfs,tmpfs",
  "cpu_cap": 600,
  "image_uuid": "e44ed3e0-910b-11ed-a5d4-00151714048c",
  "zfs_root_compression": "lz4",
  "quota": 50,
  "delegate_dataset": true,
  "resolvers": [
    "8.8.8.8",
    "8.8.4.4"
  ],
  "nics": [
    {
      "allow_ip_spoofing": true,
      "nic_tag": "admin",
      "ip": "dhcp"
    }
  ]
}
```

Confirm that `vmadm` is also happy, e.g.:
```
vmadm list brand=builder
```

Verify that the zone can do a VM image build:
```
zlogin `vmadm list -Ho uuid brand=builder`
pkgin up
pkgin -y fug
pkgin -y in git
git clone https://github.com/TritonDataCenter/triton-cloud-images
cd triton-cloud-images
./build_all.sh ubuntu-24.04
```

Roll back the platform image to the preceding one that does not have the `builder` brand
```
piadm activate 20250306T000316Z
reboot
```

Note what is broken. Non-`builder` zones and VMs should all be fine as should the UI.
The builder branded zone will be stopped which is expected. Trying to start it will cause `vmadm` to dump core. This is also expected.

Test the rescue procedure for that zone to convert it back to a `joyent` branded zone (note that this is gross and something we're generally trying to avoid, but having it documented for completeness is good.)
```
UUID=`vmadm list -Ho uuid brand=builder`
sed -e 's|brand="builder"|brand="joyent"|' -i.builderbak /etc/zones/$UUID.xml
svcadm restart vminfod
zonecfg -z $UUID <<EOF
set limitpriv=default,proc_clock_highres,sys_dl_config
add device
set match="/dev/viona"
end
add device
set match="/dev/vmm*"
end
commit
exit
EOF
vmadm start $UUID
```

For completeness you can roll back the UI to the regular release and it shouldn't be broken
and you can of course delete the zone.
```
uiadm remove && uiadm install latest
vmadm delete $UUID

```

[illumos-joyent]: https://github.com/TritonDataCenter/illumos-joyent
[smartos-live]: https://github.com/TritonDataCenter/smartos-live
[smartos-ui]: https://github.com/TritonDataCenter/smartos-ui
[triton-cloud-images]: https://github.com/TritonDataCenter/triton-cloud-images
