# Modernize TLS Options

SSL and now TLS are the bedrock of on-the-wire security on the Internet. In the
recent past, TLS has taken a beating. There have been demonstrated weaknesses
in the protocol itself, and in several ciphers and modes. Encryption only gets
weaker with time. We also know that attacks are growing more sophisticated, and
attackers more determined.

It's time that Triton and Manta do everything they can to support and encourage
a higher standard of secure connections.

# Endpoints

Currently, Triton and Manta have four endpoints that need to be secured.

1. cloudapi
1. muppet (Manta loadbalancer)
1. sdc-docker
1. cmon

CloudapI and muppet currently use `stud` to handle TLS termination. Cmon and
sdc-docker handle TLS termination directly in `node.js`.

# Recommended TLS Options

This document will not, itself, evaluate specific TLS implementations, protocol
versions, ciphers, etc. However, it is recommended that we adhere to the best
known security standards.

At the time of this writing, the following websites are considered to be good,
trusted sources of recomended best practices.

* [cipherli.st](https://cipherli.st) includes recomended settings for various
common applications.
* [SSL Labs SSL Test](https://ssllabs.com/ssltest) Rates HTTP servers A-F
* [HT Bridge SSL Server Security Test](https://www.htbridge.com/ssl/) Rates TLS
servers on any port A-F

Therefore, the following enhancements are recomended.

* Remove RC4, it is considered insecure.
* Remove 3DES, it is considered weak.

# Stud Configuration

The current cipher list in `stud.conf` for both cloudapi and muppet is:

    ciphers = "EECDH+CHACHA20:EECDH+AES128:RSA+AES128:EECDH+AES256:RSA+AES256:EECDH+3DES:RSA+3DES:HIGH:RC4-SHA:!MD5:!aNULL:!PSK"

The recomended cipher list for hitch (the successor to stud), as per
[cipherli.st](https://cipherli.st) is:

    ciphers = "EECDH+AESGCM:EDH+AESGCM:AES256+EECDH:AES256+EDH"

The minimum change to achieve the intended goal is to remove `EECDH+3DES`,
`RSA+3DES`, and `RC4-SHA`:

    ciphers = "EECDH+CHACHA20:EECDH+AES128:RSA+AES128:EECDH+AES256:RSA+AES256:HIGH:!MD5:!aNULL:!PSK"

# Compatibility Matrix

For compatibility, we've chosen to test with a set of "ancient" and "modern"
smartos images, as well as clients. Each base image will be tested with the
oldest reasonable application and sdk version, as well as the newest reasonable
application and sdk version.

For the application, "reasonable" means the oldest and newest versions
available in the pkgsrc repository.

These tests were run against the proposed minimum change as above.

| Base Image         | Application Version | Library Version       | Result |
| ------------------ | ------------------- | --------------------- | ------ |
| base64@1.9.1       | nodejs-0.8.26       | node-smartdc@7.0.0[1] | PASS   |
| base64@1.9.1       | nodejs-0.10.28\*[2] | node-manta@1.1.0[3]   | PASS   |
| base64@1.9.1       | nodejs-0.10.28\*[4] | node-triton@2.0.0     | PASS   |
| base64@1.9.1       | python-2.7.3\*      | python-manta@2.1.1[5] | PASS   |
| base64@1.9.1       | python-2.7.3\*      | urllib[6]             | PASS   |
| base64@1.9.1       | jdk-6u26            | java-manta@1.4.0      | PASS   |
| | | | |
| base64@1.9.1       | nodejs-0.10.28\*    | node-smartdc@8.1.0\*  | PASS   |
| base64@1.9.1       | nodejs-0.10.28\*    | node-manta@4.3.0\*    | PASS   |
| base64@1.9.1       | nodejs-0.10.28\*    | node-triton@5.2.0\*   | PASS   |
| base64@1.9.1       | python-2.7.3\*      | python-manta@2.6.0\*  | PASS   |
| base64@1.9.1       | jdk-8u131\*         | java-manta@3.0.0\*    | PASS   |
| | | | |
| base-64-lts@16.4.1 | nodejs-0.10.48      | node-smartdc@7.0.0    | PASS   |
| base-64-lts@16.4.1 | nodejs-0.10.48      | node-manta@1.1.0[3]   | PASS   |
| base-64-lts@16.4.1 | nodejs-0.10.48      | node-triton@2.0.0     | PASS   |
| base-64-lts@16.4.1 | python-2.7.12\*     | python-manta@2.1.1[5] | PASS   |
| base-64-lts@16.4.1 | jdk-6u26            | java-manta@1.4.0      | N/A[7] |
| | | | |
| base-64-lts@16.4.1 | nodejs-7.5.0\*      | node-smartdc@8.1.0\*  | PASS   |
| base-64-lts@16.4.1 | nodejs-7.5.0\*      | node-manta@4.3.0\*    | PASS   |
| base-64-lts@16.4.1 | nodejs-7.5.0\*      | node-triton@5.2.0\*   | PASS   |
| base-64-lts@16.4.1 | python-2.7.12\*     | python-manta@2.6.0\*  | PASS   |
| base-64-lts@16.4.1 | python-2.7.12\*     | urllib[6]             | PASS   |
| base-64-lts@16.4.1 | jdk-8u131\*         | java-manta@3.0.0\*    | PASS   |


\* This is the latest available for this image at the time of testing.

1. node-smartdc@7.0.0 requires node 0.8.14, therefore 0.6 was not tested
1. node-manta does not install properly with node 0.8.26
1. node-manta@1.1.0 is the oldest version command line tools
1. node-triton@2.0.0 requires node 0.10.0, therefore 0.6 and 0.8 were not tested
1. python-manta==2.1.0 is the oldest version with `MANTA_NO_AUTH`
1. urllib is a python core library so there are not alternate versions
1. Older versions of java-manta are not supported, and are not expected to be in use on this image.
