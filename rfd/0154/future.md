# Out of scope

The following ideas have been considered but have been kept from the initial proposal for the sake of implementation of MVP.

## Specify a per-disk image during instance creation

There may be some times where it would be nice to pass an `image_uuid` to each disk during VM creation.

Consider the case where there there are images for both the OS disk and the data disk. One scenario where this has been discussed is to avoid long file system creation times. In this example, the second disk may be a terabyte or larger disk with ext3 or ext4. Such an arrangement can shave tens of minutes off of the first boot.

```
{
  "package": "c4fa76e0-6178-ec20-b64a-e5567f3d62d5",
  "disks": [
    {
      "image": "aa788e1f-e143-c46e-9417-b4212486c4ae"
    },
    {
      "image": "4403b4a8-76ae-c023-ce74-9766187c92e1",
    }
  ]
}
```

## Specify an image while creating a disk.

This is much like the scenario above, but it would be used when adding a disk to an existing instance.

```
{
  "image": "4403b4a8-76ae-c023-ce74-9766187c92e1"
}
```

## Specify the slot a disk will occupy during CreateMachine and CreateMachineDisk

The following used with CreateMachineDisk will cause the new disk to be added as `disk7`.

```
{
  "size": 10240,
  "slot": "disk7"
}
```

If specified with an image that contains an ISO, it may be useful to add it as a CD rather than a disk.

```
{
  "image": "8765a900-6bf9-ef47-8e1e-affd7afeda5d",
  "slot": "cdrom0"
}
```

## Specify various vmadm properties during CreateMachine and CreateMachineDisk

Suppose you have an image that is installation media and the installer expects to boot from a DVD and lacks virtio drivers.  In such a case, this could be helpful during `CreateMachine`:


```
{
  "package": "c4fa76e0-6178-ec20-b64a-e5567f3d62d5",
  "disks": [
    {
      "size": 102400
    },
    {
      "image": "8765a900-6bf9-ef47-8e1e-affd7afeda5d",
      "model": "ahci",
      "slot": "cdrom0"
    }
  ]
}
```

This example creates an empty 100 GiB root disk and uses the installer in image `8765a900-6bf9-ef47-8e1e-affd7afeda5d` to perform the installation.

## Packages that provide default `disks` section

It may be desirable to be able to a simple `triton` CLI to deploy an instance with a storage configuration that is different from Triton's default.  For instance, this command:

```
$ triton instance create $package $image
```

... with a package that contains:

```json
{
  ...,
  "disks": [ { "size": 102400 } ],
  ...
}
```

... will create an instance that has one disk (the boot disk) that is 100 GiB in size.

If `CreateMachine` were to also specify `disks`, the `disks` in the package would be ignored.
