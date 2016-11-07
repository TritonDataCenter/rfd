---
authors: Robert Mustacchi <rm@joyent.com>
state: draft
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2016 Joyent, Inc.
-->

# RFD 66 USBA improvements for USB 3.x

A single USB device is broken into multiple logical `endpoints`. A given
endpoint or has a direction and a type. For example, a USB mass storage
device usually has two endpoints, a BULK IN endpoint and a BULK OUT
endpoint.

Each endpoint in USB is represented by an endpoint descriptor. Device
drivers use a series of general function calls to obtain access to one
of these endpoints, which in the USBA (USB Architecture) are called
`pipes`. To open a pipe, device drivers need to lookup the endpoint
descriptor, which is done through a series of calls in the illumos
device driver interface (DDI). These are stable interfaces.

While these interfaces work well for USB 2.0, they do not work well for
USB 3.x. USB 3.x has introduced what are called endpoint companion
descriptors. These companion descriptors define additional information
which is required by the host-controll interface to properly program it.

## The Current Model

Today, the way that device drivers generally work is that they first get
a descriptor tree, which describes all of the variants of the device and
endpoints. Device drivers will access a given descriptor by first
calling
[`usb_get_dev_data(9F)`](http://illumos.org/man/9f/usb_get_dev_data). They
will copy the descriptor that they need and then they will free the data
through either
[`usb_free_dev_data(9F)`](http://illumos.org/man/9f/usb_free_dev_data) or
through
[`usb_free_descr_tree(9F)`](http://illumos.org/man/9f/usb_free_descr_tree).

While drivers have the `usb_client_dev_data_t *` around, they lookup
endpoint descriptors with the
[`usb_lookup_ep_data(9F)`](http://illumos.org/man/9f/usb_lookup_ep_data)
function. This returns a `usb_ep_data_t *` structure which has the
`usb_ep_descr_t` structure required to open the pipe.

The lifetime of this `usb_ep_data_t *` is bounded by the drivers calling
`usb_free_descr_tree(9F)` and `usb_free_dev_data(9F)`. Most drivers
lookup the `usb_ep_data_t *`, copy out the `usb_ep_descr_t`, and then open
the pipe, potentially before or after freeing the broader
`usb_client_dev_data_t *`. 

This causes problems for host controllers, as we have no way of knowing
where in the configuration tree a given descriptor comes from. Further,
the main function that is used to open a pipe,
[`usb_pipe_xopen(9F)`](http://illumos.org/man/9f/usb_pipe_open) does not
have any way for us to pass additional information here, which will be
passed to the HCI.

## Constraints

The following describe some of the higher level constraints we have on
this problem:

* We must not break the existing DDI or drivers
* We would like to minimize changes required to client drivers
* We should expect that the USB-IF will add more endpoint descriptors as
they have with both USB 3.0 and USB 3.1.
* As much as possible, devices that work today should continue to work

## `usb_pipe_xopen(9F)`

What we propose is to add a series of new structures and functions which
can account for the requirements of having additional endpoint
descriptors, while minimizing changes for USB drivers. As such, we want
to introduce a new function, `usb_pipe_xopen()` which takes all the same
arguments as `usb_pipe_open()`, except rather than taking a
`usb_ep_descr_t`, it will take some a new extended description. This
should look like:

```
#define	USB_EP_XDESCR_VERSION_ONE	1
#define	USB_EP_XDESCR_CURRENT_VERSION	USB_EP_XDESCR_VERSION_ONE

typedef enum usb_ep_xdescr_flags {
	USB_EP_XFLAGS_SS_COMP	= 1 << 0
} usb_ep_xdescr_flags_t;

typedef struct usb_ep_xdescr {
	uint_t			uex_version;
	usb_ep_xdescr_flags_t	uex_flags;
	usb_ep_descr_t 		uex_ep;
	usb_ep_ss_comp_descr_t	uex_ep_ss;
} usb_ep_xdescr_t;
```

A device driver can manually construct this structure; however, we will
provide the following convenience function which takes the
`usb_ep_data_t *` and fills in the `usb_ep_xdescr_t` appropriately:

```
int
usb_ep_xdescr_fill(uint_t version, dev_info_t *dip, usb_ep_data_t *ep_data,
    usb_ep_xdescr_t *xdesc);	
```

Here, version should be `USB_EP_XDESCR_VERSION`, this will be used to help
us know what the correct size of the structure is. The flags member will
be filled in with what descriptors are present. It is assumed that the
standard `usb_ep_descr_t` is always filled in. When we have support for
USB 3.1 in the system, this will change as follows:

```
#define	USB_EP_XDESCR_VERSION_ONE	1
#define	USB_EP_XDESCR_VERSION_TWO	2
#define	USB_EP_XDESCR_CURRENT_VERSION	USB_EP_XDESCR_VERSION_TWO

typedef enum usb_ep_xdescr_flags {
	USB_EP_XFLAGS_SS_COMP		= 1 << 0,
	USB_EP_XFLAGS_SSP_ISOC_COMP	= 1 << 1
} usb_ep_xdescr_flags_t;

typedef struct usb_ep_xdescr {
	uint_t				uex_version;
	usb_ep_xdescr_flags_t		uex_flags;
	usb_ep_descr_t 			uex_ep;
	usb_ep_ss_comp_descr_t		uex_ep_ss;
	usb_ep_ssp_isoc_comp_descr_t	uex_ep_ssp_isoc;
} usb_ep_xdescr_t;
```

The new usb_pipe_xopen function will look like:

```
int
usb_pipe_xopen(dev_info_t *dip, usb_ep_xdescr_t *descr,
    usb_pipe_policy_t *pipe_policy, usb_flags_t flags,
    usb_pipe_handle_t *pipe_handle);
```

## New Driver Flow

So device drivers which previously used the flow (note many drivers swap
steps 4 and 5):

1. `usb_get_dev_data(9F)`
2. `usb_lookup_ep_data(9F)`
3. copy `ep_desc_t` locally
4. `usb_pipe_open(9F)`
5. `usb_free_descr_tree(9F)`
6. ...

Will instead be replaced with the following:

1. `usb_get_dev_data(9F)`
2. `usb_lookup_ep_data(9F)`
3. copy `ep_descr_t` locally (if needed)
4. `usb_ep_xdescr_fill(9F)`
5. `usb_pipe_xopen(9F)`
6. `usb_free_descr_tree(9F)`
7. ...

This means that most drivers simply need to change one or two functions
calls, adding a call to `usb_ep_xdescr_fill()` and changing the call from
`usb_pipe_open()` to `usb_pipe_xopen()`. Experimentally for a few drivers,
this is pretty simple. Some drivers may opt to instead of keeping the
`usb_ep_descr_t` around, they can now keep the `usb_ep_xdescr_t` around.

### USB 3.x devices and `usb_pipe_open(9F)`

USB devices come in many generations and speeds. Many common devices,
such as USB keyboards still use normal USB 1.1 and USB 2.0 speeds. In
addition, many drivers in the system are for devices which are only USB
1.x or USB 2.0 and thus do not need to support USB 3.x devices.

Most individual devices don't need to change, as they often represent a
rather specific set of deviecs; however, most class drivers will want to
be updated so we can properly use them with USB 3.0. The other benefit
is that once support is added for USB 3.1 devices in a later release,
there should be no need to change the class driver, unless it needs to
do something special for the new devices to take advantage of some
functionality.

In this new world with xhci, a driver that uses `usb_pipe_open(9F)` will
not work when a device negotiates to USB 3.x speed. However, such
devices that are plugged into a USB 2.x only port, will end up
negotiating and declaring themselves as a USB 2.1 device and this will
not end up causing many problems.

## Reference Manual Pages

### `usb_ep_xdescr(9S)`

```
USB_EP_XDESCR(9S)         Data Structures for Drivers        USB_EP_XDESCR(9S)

NAME
     usb_ep_xdescr, usb_ep_xdescr_t - extended endpoint descriptor

SYNOPSIS
     #include <sys/usb/usba.h>

INTERFACE LEVEL
     illumos DDI Specific

DESCRIPTION
     The usb_ep_xdescr_t structure is used to describe an endpoint descriptor
     as well account for the continuing evolutions in the USB specification.

     Starting with the USB 3.0 specification, USB 3.0 endpoints have an
     endpoint SuperSpeed companion descriptor. See usb_ep_ss_comp_descr(9S)
     for a description of the descriptor. In the USB 3.1 specification,
     certain endpoints will have additional companion descriptors.

     The usb_ep_xdescr_t structure, combined with the usb_ep_xdescr_fill(9F)
     and usb_pipe_xopen(9F) are designed to abstract away the need for USB
     client device drivers to need to be updated in the face of these newer
     endpoints, whose information is required for host controller devices to
     properly program the device.

     After looking up endpoint data, through the usb_lookup_ep_data(9F),
     device drivers should call the usb_ep_xdescr_fill(9F) function. After
     that, the usb_ep_xdescr_t structure will be filled in.

STRUCTURE MEMBERS
     The usb_ep_xdescr_t structure has the following members:

           uint_t                  uex_version;
           usb_ep_xdescr_flags_t   uex_flags;
           usb_ep_descr_t          uex_ep;
           usb_ep_ss_comp_descr_t  uex_ep_ss;

     The uex_version member is used to describe the current version of this
     structure. This member will be set to the value passed in by the device
     driver to usb_ep_xdescr_fil(9F).  Device drivers should ignore this field
     and should not modify the value placed there or modify it.

     The uex_flags member is an enumeration that defines a number of flags.
     Each flag indicates whether or not a given member is present or valid.
     Before accessing any member other than uex_ep, the device driver should
     check the flag here, otherwise its contents may be undefined. Currently
     the following flags are defined:

           USB_EP_XFLAGS_SS_COMP
                   Indicates that a SuperSpeed endpoint companion descriptor
                   is present and has been filled in. The member uex_ep_ss is
                   valid.

     The uex_ep member contains a traditional USB endpoint descriptor. Its
     contents are defined in usb_ep_descr(9S).  There is no flag for this
     member in uex_flags, it is always valid.

     The uex_ep_ss member contains a USB 3.0 SuperSpeed endpoint companion
     descriptor as defined in usb_ep_ss_comp_descr(9S).  This member is only
     valid if the USB_EP_XFLAGS_SS_COMP flag is specified in uex_flags.

SEE ALSO
     usb_ep_xdescr_fill(9F), usb_pipe_xopen(9F), usb_ep_descr(9S),
     usb_ep_ss_comp_descr(9S)

illumos                       September 16, 2016                       illumos
```

### usb_ep_xdescr_fill(9F)

```
USB_EP_XDESCR_FILL(9F)   Kernel Functions for Drivers   USB_EP_XDESCR_FILL(9F)

NAME
     usb_ep_xdescr_fill - fill extended endpoint description from endpoint data

SYNOPSIS
     #include <sys/usb/usba.h>

     int
     usb_ep_xdescr_fill(uint_t version, dev_info_t *dip,
         usb_ep_data_t *ep_data, usb_ep_xdescr_t *ep_xdescr);

INTERFACE STABILITY
     illumos DDI specific

PARAMETESR
     version       Indicates the current version of the usb_ep_xdescr_t
                   structure the driver is using. Callers should always
                   specify USB_EP_XDESCR_CURRENT_VERSION.

     dip           Pointer to the device's dev_info structure.

     ep_data       Pointer to endpoint data retrieved by calling
                   usb_lookup_ep_data(9F).

     ep_xdescr     Pointer to the extended endpoint descriptor that will be
                   filled out.

DESCRIPTION
     The usb_ep_xdescr_fill() function is used to fill in the members of the
     extended endpoint descriptor ep_xdescr based on the endpoint descriptor
     data in ep_data.  Once filled in, ep_xdescr can be used to open a pipe by
     calling usb_pipe_xopen(9F).

     Prior to USB 3.0, only one descriptor, the usb_ep_descr(9S), was needed
     to describe an endpoint. However, with USB 3.0 additional companion
     descriptors have been added and are required to successfully configure
     open an endpoint. After calling this, all descriptors needed to
     successfully open a pipe will be placed into ep_xdescr and the endpoint
     data, ep_data, is no longer required.

CONTEXT
     The usb_ep_xdescr_fill() is generally only called from a drivers
     attach(9E) entry point; however, it may be called from either user or
     kernel context.

RETURN VALUES
     Upon successful completion, the usb_ep_xdescr_fill() function returns
     USB_SUCCESS.  Otherwise an error number is returned.

ERRORS
     USB_INVALID_ARGS   The value of version is unknown, or one of dip,
                        ep_data, and ep_xdescr was an invalid pointer.

     USB_FAILURE        An unknown error occurred.

SEE ALSO
     usb_lookup_ep_data(9F), usb_pipe_xopen(9F), usb_ep_descr(9S),
     usb_ep_ss_comp_descr(9S), usb_ep_xdescr(9S)

illumos                         August 7, 2016                         illumos
```

### usb_pipe_xopen(9F)

```
USB_PIPE_XOPEN(9F)       Kernel Functions for Drivers       USB_PIPE_XOPEN(9F)

NAME
     usb_pipe_open, usb_pipe_xopen - Open a USB pipe to a device

SYNOPSIS
     #include <sys/usb/usba.h>

     int
     usb_pipe_open(dev_info_t *dip, usb_ep_descr_t *endpoint,
         usb_pipe_policy_t *pipe_policy, usb_flags_t flags,
         usb_pipe_handle_t *pipe_handle);

     int
     usb_pipe_xopen(dev_info_t *dip, usb_ep_xdescr_t *extended_endpoint,
         usb_pipe_policy_t *pipe_policy, usb_flags_t flags,
         usb_pipe_handle_t *pipe_handle);

INTERFACE LEVEL
     Solaris DDI specific (Solaris DDI)

PARAMETERS
     dip           Pointer to the device's dev_info structure.

     endpoint      Pointer to endpoint descriptor.

     extended_endpoint
                   Pointer to an extended endpoint descriptor retrieved from
                   calling usb_ep_xdescr_fill(9F).

     pipe_policy   Pointer to pipe_policy. pipe_policy provides hints on pipe
                   usage.

     flags         USB_FLAGS_SLEEP is only flag that is recognized. Wait for
                   memory resources if not immediately available.

     pipe_handle   Address to where new pipe handle is returned. (The handle
                   is opaque.)

DESCRIPTION
     A pipe is a logical connection to an endpoint on a USB device. The
     usb_pipe_xopen() function creates such a logical connection and returns
     an initialized handle which refers to that connection.

     The USB 3.0 specification defines four endpoint types, each with a
     corresponding type of pipe. Each of the four types of pipes uses its
     physical connection resource differently. They are:

     Control Pipe
             Used for bursty, non-periodic, reliable, host-initiated
             request/response communication, such as for command/status
             operations. These are guaranteed to get approximately 10% of
             frame time and will get more if needed and if available, but
             there is no guarantee on transfer promptness. Bidirectional.

     Bulk Pipe
             Used for large, reliable, non-time-critical data transfers. These
             get the bus on a bandwidth-available basis. Unidirectional.
             Sample uses include printer data.

     Interrupt Pipe
             Used for sending or receiving small amounts of reliable data
             infrequently but with bounded service periods, as for interrupt
             handling. Unidirectional.

     Isochronous Pipe
             Used for large, unreliable, time-critical data transfers. Boasts
             a guaranteed constant data rate as long as there is data, but
             there are no retries of failed transfers. Interrupt and
             isochronous data are together guaranteed 90% of frame time as
             needed. Unidirectional. Sample uses include audio.

     The type of endpoint to which a pipe connects (and therefore the pipe
     type) is defined by the bmAttributes field of that pipe's endpoint
     descriptor.  (See usb_ep_descr(9S)).

     Prior to the USB 3.0 specification, only the usb_ep_descr(9S) was
     required to identify all of the attributes of a given pipe. Starting with
     USB 3.0 there are additional endpoint companion descriptors required to
     open a pipe. To support SuperSpeed devices, the new usb_pipe_xopen()
     function must be used rather than the older usb_pipe_open() function. The
     usb_ep_xdescr(9S) structure can be automatically filled out and obtained
     by calling the usb_ep_xdescr_fill(9F) function.

     Opens to interrupt and isochronous pipes can fail if the required
     bandwidth cannot be guaranteed.

     The polling interval for periodic (interrupt or isochronous) pipes,
     carried by the endpoint argument's bInterval field, must be within range.
     Valid ranges are:

     Full speed: range of 1-255 maps to 1-255 ms.

     Low speed: range of 10-255 maps to 10-255 ms.

     High speed: range of 1-16 maps to (2**(bInterval-1)) * 125us.

     Super speed: range of 1-16 maps to (2**(bInterval-1)) * 125us.

     Adequate bandwidth during transfers is guaranteed for all periodic pipes
     which are opened successfully. Interrupt and isochronous pipes have
     guaranteed latency times, so bandwidth for them is allocated when they
     are opened.  (Please refer to Sections 4.4.7 and 4.4.8 of the USB 3.1
     specification which address isochronous and interrupt transfers.) Opens
     of interrupt and isochronous pipes fail if inadequate bandwidth is
     available to support their guaranteed latency time. Because periodic pipe
     bandwidth is allocated on pipe open, open periodic pipes only when
     needed.

     The bandwidth required by a device varies based on polling interval, the
     maximum packet size (wMaxPacketSize) and the device speed. Unallocated
     bandwidth remaining for new devices depends on the bandwidth already
     allocated for previously opened periodic pipes.

     The pipe_policy parameter provides a hint as to pipe usage and must be
     specified. It is a usb_pipe_policy_t which contains the following fields:

           uchar_t         pp_max_async_reqs:

     The pp_max_async_reqs member is a hint indicating how many asynchronous
     operations requiring their own kernel thread will be concurrently in
     progress, the highest number of threads ever needed at one time.  Allow
     at least one for synchronous callback handling and as many as are needed
     to accommodate the anticipated parallelism of asynchronous* calls to the
     following functions: usb_pipe_close(9F), usb_set_cfg(9F),
     usb_set_alt_if(9F), usb_clr_feature(9F), usb_pipe_reset(9F),
     usb_pipe_drain_reqs(9F), usb_pipe_stop_intr_polling(9F), and
     usb_pipe_stop_isoc_polling(9F).

     Setting to too small a value can deadlock the pipe.  Asynchronous calls
     are calls made without the USB_FLAGS_SLEEP flag being passed.  Note that
     a large number of callbacks becomes an issue mainly when blocking
     functions are called from callback handlers.

     The control pipe to the default endpoints (endpoints for both directions
     with addr 0, sometimes called the default control pipe or default pipe)
     comes pre-opened by the hub. A client driver receives the default control
     pipe handle through usb_get_dev_data(9F).  A client driver cannot open
     the default control pipe manually. Note that the same control pipe may be
     shared among several drivers when a device has multiple interfaces and
     each interface is operated by its own driver.

     All explicit pipe opens are exclusive; attempts to open an opened pipe
     fail.

     On success, the pipe_handle argument points to an opaque handle of the
     opened pipe. On failure, it is set to NULL.

CONTEXT
     May be called from user or kernel context regardless of arguments. May
     also be called from interrupt context if the USB_FLAGS_SLEEP option is
     not set.

RETURN VALUES
     USB_SUCCESS
             Open succeeded.

     USB_NO_RESOURCES
             Insufficient resources were available.

     USB_NO_BANDWIDTH
             Insufficient bandwidth available. (isochronous and interrupt
             pipes).

     USB_INVALID_CONTEXT
             Called from interrupt handler with USB_FLAGS_SLEEP set.

     USB_INVALID_ARGS
             dip and/or pipe_handle is NULL. Pipe_policy is NULL.

     USB_INVALID_PERM
             Endpoint is NULL, signifying the default control pipe. A client
             driver cannot open the default control pipe.

     USB_NOT_SUPPORTED
             Isochronous or interrupt endpoint with maximum packet size of
             zero is not supported.

     USB_HC_HARDWARE_ERROR
             Host controller is in an error state.

     USB_FAILURE
             Pipe is already open. Host controller not in an operational
             state. Polling interval (Bep_descr bInterval field) is out of
             range (intr or isoc pipes).

             The device referred to by dip is at least a SuperSpeed device and
             the older usb_pipe_open() function was used.

EXAMPLES
           usb_ep_data_t *ep_data;
           usb_ep_xdescr_t ep_xdescr;
           usb_pipe_policy_t policy;
           usb_pipe_handle_t pipe;
           usb_client_dev_data_t *reg_data;
           uint8_t interface = 1;
           uint8_t alternate = 1;
           uint8_t first_ep_number = 0;

           /* Initialize pipe policy. */
           bzero(policy, sizeof(usb_pipe_policy_t));
           policy.pp_max_async_requests = 2;

           /* Get tree of descriptors for device. */
           if (usb_get_dev_data(dip, USBDRV_VERSION, &reg_data,
               USB_FLAGS_ALL_DESCR, 0) != USB_SUCCESS) {
                   ...
           }

           /* Get first interrupt-IN endpoint. */
           ep_data = usb_lookup_ep_data(dip, reg_data, interface, alternate,
               first_ep_number, USB_EP_ATTR_INTR, USB_EP_DIR_IN);
           if (ep_data == NULL) {
                   ...
           }

           /* Translate the ep_data into the filled in usb_ep_xdescr_t */
           if (usb_ep_xdescr_fill(USB_EP_XDESCR_CURRENT_VERSION, dip,
               ep_data, &ep_xdescr) != USB_SUCCESS) {
                  ...
           }

           /* Open the pipe.  Get handle to pipe back in 5th argument. */
           if (usb_pipe_open(dip, &ep_data.ep_descr
               &policy, USB_FLAGS_SLEEP, &pipe) != USB_SUCCESS) {
                   ...
           }

SEE ALSO
     usb_get_alt_if(9F), usb_get_cfg(9F), usb_get_dev_data(9F),
     usb_get_status(9F), usb_pipe_bulk_xfer(9F), usb_pipe_close(9F),
     usb_pipe_ctrl_xfer(9F), usb_pipe_get_state(9F), usb_pipe_intr_xfer(9F),
     usb_pipe_isoc_xfer(9F), usb_pipe_reset(9F), usb_pipe_set_private(9F),
     usb_callback_flags(9S), usb_ep_descr(9S)

     Universal Serial Bus 3.1 Specification, http://www.usb.org.

illumos                       September 16, 2016                       illumos
```
