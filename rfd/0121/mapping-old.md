### Configuration mapping

This is how properties are handled by the initial implementation of bhyve.  It
should align with how things are done for kvm.

| SmartOS Config        | Resource                      | Property      |
|-----------------------|-------------------------------|---------------|
| alias                 | attr name=alias               | value         |
| archive_on_delete     | attr name=archive_on_delete   | value         |
| billing_id            | attr name=billing_id          | value         |
| boot                  | attr name=boot                | value         |
| boot_timestmap        | xxx                           | xxx           |
| brand                 | global                        | brand         |
| cpu_cap               | capped-cpu                    | ncpus         |
| cpu_shares            | global                        | cpu-shares    |
| cpu_type              | *not supported in this brand* |               |
| create_timestmap      | attr name=create-timestamp    | value         |
| server_uuid           | *dynamic, based on server*    |               |
| customer_metadata     | *stored `<zonepath>/config/`* |               |
| datasets              | *not supported in this brand* |               |
| delegate_datasets     | *not supported in this brand* |               |
| disks                 | *Each disk gets a unique `device` resource* | |
| disks.\*.block_size   | device                        | property name=block-size |
| disks.\*.boot         | device                        | property name=boot |
| disks.\*.compression  | device                        | property name=compression |
| disks.\*.nocreate     | device                        | property name=nocreate |
| disks.\*.image_name   | device                        | property name=image-name |
| disks.\*.image_size   | device                        | property name=image-size |
| disks.\*.image_uuid   | device                        | property name=image-uuid |
| disks.\*.refreservation | device                      | property name=refreservation |
| disks.\*.size         | device                        | property name=size |
| disks.\*.media        | device                        | proeprty name=media |
| disks.\*.model        | device                        | property name=model |
| disks.\*.zpool        | xxx                           | xxx           |
| disk_driver           | xxx                           | xxx           |
| do_not_inventory      | attr name=do-not-inventory    | value         |
| dns_domain            | attr name=dns-domain          | value         |
| filesystems           | *not supported in this brand* |               |
| filesystems.\*.type   | *not supported in this brand* |               |
| filesystems.\*.source | *not supported in this brand* |               |
| filesystems.\*.target | *not supported in this brand* |               |
| filesystems.\*.raw    | *not supported in this brand* |               |
| filesystems.\*.options | *not supported in this brand* |              |
| firewall_enabled      | xxx                           | xxx           |
| fs_allowed            | *not supported in this brand* |               |
| hostname              | attr name=hostname            | value         |
| image_uuid            | xxx                           | xxx           |
| internal_metadata     | *see `<zonepath>/config/`*    |               |
| internal_metadata_namespace | xxx                     |               |
| indestructable_delegated | xxx                        | xxx           |
| indestructable_zoneroot | *zfs snapshot and hold*     |               |
| kernel_version        | *not supported in this brand* |               |
| limit_priv            | *not supported in this brand (set to fixed value)* | |
| maintain_resolvers    | attr name=maintain-resolvers  | value         |
| max_locked_memory     | capped-memory                 | locked        |
| max_lwps              | global                        | max-lwps      |
| max_physical_memory   | capped-memory                 | physical      |
| max_swap              | capped-memory                 | swap          |
| mdata_exec_timeout    | *not supported in this brand* |               |
| nics                  | *Each nic gets a unique `net` resource* |     |
| nics.\*.allow_dhcp_spoofing           | net           | property name=allow-dhcp-spoofing |
| nics.\*.allow_ip_spoofing             | net           | property name=allow-ip-spoofing |
| nics.\*.allow_mac_spoofing            | net           | property name=allow-mac-spoofing |
| nics.\*.allow_restricted_traffic      | net           | property name=allow-restricted-traffic |
| nics.\*.allow_unfilterd_promisc       | net           | property name=allow-unfiltered-promisc |
| nics.\*.allow_blocked_outgoing_ports  | net           | property name=allow-blocked-outgoing-ports |
| nics.\*.allow_allowed_ips             | net           | property name=allow-allowed-ips |
| nics.\*.allow_dhcp_server             | net           | property name=allow-dhcp-server |
| nics.\*.gateway       | net                           | property name=gateway   |
| nics.\*.gateways      | net                           | property name=gateways  |
| nics.\*.interface     | net                           | physical                |
| nics.\*.ip            | net                           | property name=ip        |
| nics.\*.ips           | net                           | property name=ips       |
| nics.\*.mac           | net                           | mac-addr                |
| nics.\*.model         | net                           | model                   |
| nics.\*.mtu           | net                           | property name=mtu       |
| nics.\*.netmask       | net                           | property name=metask    |
| nics.\*.network_uuid  | net                           | property name=network-uuid |
| nics.\*.nic_tag       | net                           | global-nic              |
| nics.\*.primary       | net                           | property name=primary   |
| nics.\*.vlan_id       | net                           | vlan-id                 |
| nics.\*.vrrp_primary_ip | *not supported in this brand* |                       |
| nics.\*.vrrp__vrid    | *not supported in this brand* |                         |
| nic_driver            | *not supported in this brand* |               |
| nowait                | attr name=nowait              | value         |
| owner_uuid            | attr name=owner-uuid          | value         |
| package_name          | attr name=package-name        | value         |
| package_version       | attr name=package-version     | value         |
| pid                   | *dynamic*                     |               |
| qemu_opts             | *not supported in this brand* |               |
| qemu_extra_opts       | *not supported in this brand* |               |
| quota                 | *zfs property*                |               |
| ram                   | attr name=ram                 | value *in megabytes* |
| resolvers             | attr name=resolvers           | value         |
| routes                | *see `<zonepath>`/config/`*   |               |
| snapshots             | *not supported in this brand* |               |
| space_opts            | *not supported in this brand* |               |
| spice_password        | *not supported in this brand* |               |
| spice_port            | *not supported in this brand* |               |
| state                 | *dynamic*                     |               |
| tmpfs                 | *not supported in this brand* |               |
| transition_expire     | xxx                           | xxx           |
| transition_to         | xxx                           | xxx           |
| type                  | *fixed `BHYVE`*               |               |
| uuid                  | global                        | uuid          |
| vcpus                 | attr name=vcpus               | value         |
| vga                   | xxx                           | xxx           |
| virtio_txburst        | xxx                           | xxx           |
| virtio_txtimer        | xxx                           | xxx           |
| vnc_password          | xxx                           | xxx           |
| vnc_port              | xxx                           | xxx           |
| zfs_data_compression  | *not supported in this brand* |               |
| zfs_data_recsize      | *not supported in this brand* |               |
| zfs_filesystem_limit  | *not supported in this brand* |               |
| zfs_io_priority       | global                        | zfs-io-priority |
| zfs_root_compression  | *not supported in this brand* |               |
| zfs_root_recsize      | *not supported in this brand* |               |
| zfs_snapshot_limit    | *not supported in this brand* |               |
| zfs_max_size          | *not supported in this brand* |               |
| zlog_max_size         | *not supported in this brand* |               |
| zone_state            | xxx                           | xxx           |
| zonepath              | global                        | zonepath      |
| zonename              | global                        | zonename      |
| zoneid                | *dynamic*                     |               |
| zpool                 | xxx                           | xxx           |
