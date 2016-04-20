---
authors: Josh Wilsdon <jwilsdon@joyent.com>
state: draft
---

# RFD 29 Nothing in SDC should rely on ur outside bootstrapping and emergencies

## Introduction

This was originally filed as a ticket in JIRA 20150915 and has been moved here
instead.

The original intention of the Ur agent was that it be used for bootstrapping.
It is a convenient way to do this as it lives in the platform and accepts
commands so long as networking is up, regardless of the state of the system
otherwise. This means a brand new CN booting for the first time will have Ur
running and we can send the initial setup script.

Unfortunately, Ur is also being used for other things. Because it is so
convenient, it's also being used for:

 * loading a list of vmadm VMs periodically (dump-hourly-sdc-data.sh in sdc zone)
 * sending out sysinfo many times to answer broadcast requests (from CNAPI?)
 * gathering kstats
 * sdcadm to:
     * update manatee
     * vmadm get (vmGetRemote)
     * installing images with imgadm
     * disabling registrar
     * running 'vmadm reprovision'
     * update the user script
     * add delegated datasets
     * get the manatee-adm status
     * get svcadm status
     * many other things

The interface here is sloppy in that we're just running arbitrary commands
against a CN. This is not good as it means we're now coupled to the specific
output / behavior of these commands for a specific platform. It also makes it
difficult to track since for the most part these commands are not logging what
they're doing.

In order to fix this, we should make sure that nothing except bootstrapping
(joysetup + initial agents install) in SDC depends on Ur. This will force tools
to use a more specific API and likely to add things to CNAPI/cn-agent that
abstract away the details of the CN commands themselves.

