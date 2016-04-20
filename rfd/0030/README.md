---
authors: Josh Wilsdon <jwilsdon@joyent.com>
state: predraft
---

# RFD 30 Handling "lastexited" for zones when CN is rebooted or crashes

With OS-3429, SmartOS added support for the creation of the /lastexited file in
the zoneroot of a zone when the zone's init process exits. This is handled by
zoneadmd.

This functionality is used by vmadm for the 'exit_status' and 'exit_timestamp'
fields which are propagated to VMAPI as part of the VM objects and are then used
by sdc-docker to generate the STATUS value to display in the `docker ps` output.

Unfortunately there are cases where a zone is halted and this file is not
written out. There will always be the possibility of CN panic, but this can also
occur when a CN is rebooted.

# Open Questions:

 * should we use some other method to determine exit_timestamp when we see a
   lastbooted file so we know the zone was booted at least once? If so: what?
 * should we use a specific value for exit_status when we know a zone stopped,
   but we don't know what the exit status actually was?
 * should vmadm provide the alternate exit_timestamp and exit_status values or
   should those be added at a different point in the stack?

