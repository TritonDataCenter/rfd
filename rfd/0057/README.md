---
authors: Todd Whiteman <todd.whiteman@joyent.com>, Trent Mick <trent.mick@joyent.com>
state: publish
---

# RFD 57 Moving to Content Addressable Docker Images

# Why?

Docker are moving to use 'content addressable' image layers - which basically
means they are using a hash (sha256) of the image layer as the image layer id,
before they were using a separate random id. Example image id now looks like:
'sha256:b3549bff6e9847a0170e769bac608be4a6c73a95e628a33a4040dbcd05139fa8'.

It would be advantageous for Triton to also use 'content addressable' images,
sdc-docker can drop the limitation that an image can only be referenced in one
registry (e.g. currently you cannot re-tag busybox to quay.io/busybox). Sharing
of images could also increase, as currently we require redownloading of the same
image when it's from a separate registry, whereas with a hash of the image
layer(s) you can trust it's the same content regardless of where it came from.

# Docker Terminology

 * *registry v1* - old registry API  (unsupported by docker hub as of Nov 2015)
 * *registry v2* - newest registry API (docker 1.6)
 * *image v1* - old image schema format - uses a random image/layer id
 * *[image v2 schema 1](https://github.com/docker/distribution/blob/master/docs/spec/manifest-v2-1.md)* -
   contains sha256 layer info, also contains backward compat v1 info (docker 1.3)
 * *[image v2 schema 2](https://github.com/docker/distribution/blob/master/docs/spec/manifest-v2-2.md)* -
   content addressable images, manifest lists (docker 1.10)

# Changes to Triton

All code that uses docker id references will need to be updated to allow and
handle the sha256 prefixed 'sha256:123...' image id format. Mostly this will be
for the image lookup code paths, here are some of the commands that will need
updating:

 * docker build (base image reference, generating sha256 id's, v2 schemas)
 * docker commit (generating sha256 id's, v2 schemas)
 * docker history (image lookup)
 * docker images (image listing)
 * docker inspect (image lookup, v2 schemas)
 * docker pull (image lookup, v2 schemas, imgapi storage)
 * docker push (image lookup, v2 schemas)
 * docker rmi (image lookup)
 * docker tag (image lookup)

## Pull

Require docker images to be pulled in the docker v2 image schema format (either
schema v2.1 or schema v2.2 format). Triton won't support pulling of older v1
images anymore, and we'll up-convert v2.1 manifests to v2.2 during the pull
step.

## Existing Docker Images

Currently, the image `config` (json) is stored in `docker_images` and
`docker_image_tags` bucket in Moray, we'll keep these (v1) images as they are,
but also create a new `docker_images_v2` and `docker_image_tags_v2` Moray bucket
to handle all new image pulls.

The code for docker commands (history, images, inspect, rmi, run) will be
updated to support both Moray buckets, which will allow users to keep using their
current v1 images, but also allow us to keep moving towards v2 image support.
These docker commands (build, commit, pull, push and tag) will be made to only
support v2 images.

## Docker_images_v2 Moray Bucket

Similar to docker-images, the bucket key will be '${DIGEST}-${ACCOUNT_UUID}', so
that each individual account holder will get their own copy of the docker image
metadata, containing these key fields.

* `config_digest` the sha256 of the 'image JSON' (aka metadata).
* `head` false if it's an intermediate (non referencable) build layer
* `created` date the image was built
* `image` docker image JSON (contains config, author, os, etc...)
* `image_uuid` reference to the underlying IMGAPI layer (bits)
* `manifest_str` the docker manifest (JSON) string, schemaVersion == 2
* `manifest_digest` the sha256 of the 'manifest_str' above.
* `parent` reference to the parent docker config_digest
* `owner_uuid` user uuid for who created/pulled this image
* `size` complete size of the image (including all parent layers)

The underlying image file layers (blobs) will be stored in IMGAPI and will be
shared across the whole DC.

See Appendix for an example docker_images_v2 instance.

# IMGAPI

For docker images, the IMGAPI image uuid will be a digest of *all* of the file
layer digests (i.e. the raw blobs we download from the registry) for that image.
For example, given the manifest with layers containing these digests::

    var digests = [
      'sha256:84ff92691f909a05b224e1c56abb4864f01b4f8e3c854e4bb4c7baf1d3f6d652',
      'sha256:847f49d214bac745aad71de7e5c4ca2fa729c096ca749151bf9566b7e2e565d9',
      'sha256:84ff92691f909a05b224e1c56abb4864f01b4f8e3c854e4bb4c7baf1d3f6d652'
    ];
    var uuid = createHash('sha256').update(digests.join(' ')).digest('hex'));

For v2.1 manifests (which don't contain all of the v2.2 manifest information),
an `uncompressedDigest` will be generated during download (docker pull) and
once fully downloaded this uncompressed digest will be saved onto the IMGAPI
manifest.files object. The uncompressedDigest is needed by the docker image
manifest upconvert process to generate a v2.2 docker image manifest, to
populatate the docker image config rootfs.diff_ids array. When we drop
support for v2.1 manifests, we can drop the uncompressedDigest field as well.

Note that there should be no conflict with imgapi uuid's, as both the v1 and
v2 image methods use differeing image uuid obfuscation techniques.

## IMGAPI uuid reasoning

The reason why we use a digest of the image layers is because the docker file
layers (blobs) do not have a parent/child relationship - instead the
parent/child relationship is defined by the docker manifest. It is quite
possible to have a docker image which references the same file layer multiple
times (e.g. ADD file.txt /file.txt; RM /file.txt; ADD file.txt), as such we
couldn't take a direct layer digest to UUID mapping, as we cannot express this
image layer in IMGAPI with two different parents (origin). Using a digest of all
of the layers allows us to maintain the parent/child relationship, but also to
share the common base file layers (e.g. FROM busybox) between different docker
images.

# Docker build/commit

Docker build will need to generate/store the uncompressedDigest - currently
docker build streams the image data (so it doesn't know the final sha256), so an
IMGAPI renameUuid step is required so that the image uuid can uses the final
compressed sha256 layer digest, this rename would occur after upload, but before
the image is activated.

# Unhandled v2.2 manifest items

Note: These items are mentioned in the v2.2 manifest documentation, but I've
yet to encounter them in the wild, so these are not implemented.

* `layers.*.urls` - Provides a list of URLs from which the content may be
  fetched. This field is optional and uncommon. This is not handled by Triton.

* `application/vnd.docker.image.rootfs.foreign.diff.tar.gzip` - may be pulled
  from a remote location but they should never be pushed. This is not handled
  by Triton.



# Appendix 1: Examples from Todd

## Image manifest v2.2

```json
$ H1="Accept: application/vnd.docker.distribution.manifest.v2+json"
$ H2="Accept: application/vnd.docker.distribution.manifest.list.v2+json"
$ curl -k -H "$H1" -H "$H2" -X GET https://192.168.99.100:5000/v2/bbox/manifests/latest | json
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.docker.distribution.manifest.v2+json",
  "config": {
    "mediaType": "application/vnd.docker.container.image.v1+json",
    "size": 2122,
    "digest": "sha256:b97bf8f04079397cefa8d7a888266c10ee7e8a88813d41c655ead9ae9ca910bc"
  },
  "layers": [
    {
      "mediaType": "application/vnd.docker.image.rootfs.diff.tar",
      "size": 10240,
      "digest": "sha256:84ff92691f909a05b224e1c56abb4864f01b4f8e3c854e4bb4c7baf1d3f6d652"
    },
    {
      "mediaType": "application/vnd.docker.image.rootfs.diff.tar",
      "size": 3573760,
      "digest": "sha256:847f49d214bac745aad71de7e5c4ca2fa729c096ca749151bf9566b7e2e565d9"
    },
    {
      "mediaType": "application/vnd.docker.image.rootfs.diff.tar",
      "size": 10240,
      "digest": "sha256:84ff92691f909a05b224e1c56abb4864f01b4f8e3c854e4bb4c7baf1d3f6d652"
    }
  ]
}
```

## Image config "application/vnd.docker.container.image.v1+json" format

Note the 'history' and 'rootfs' properties are now in the config (in v2.1 they
are on the manifest). There is no 'parent' attribute (although there is still a
Config.Image which was the original parent for this image).

```json
$ curl -k -X GET https://192.168.99.100:5000/v2/bbox/blobs/sha256:b97bf8f04079397cefa8d7a888266c10ee7e8a88813d41c655ead9ae9ca910bc | json
{
  "author": "Jérôme Petazzoni <jerome@docker.com>",
  "architecture": "amd64",
  "comment": "",
  "created": "2016-06-08T22:03:43.175Z",
  "config": {
    "AttachStdin": false,
    "AttachStderr": false,
    "AttachStdout": false,
    "Cmd": [
      "/bin/sh"
    ],
    "Domainname": "",
    "Entrypoint": null,
    "Env": null,
    "Hostname": "",
    "Image": "4deca60f7d4ac566e8f88c8af3f89b32c389d49ec4584eb8eafaf5f6cb840c1c",
    "Labels": null,
    "OnBuild": null,
    "OpenStdin": false,
    "StdinOnce": false,
    "Tty": false,
    "User": "",
    "Volumes": null,
    "WorkingDir": ""
  },
  "container_config": {
    "AttachStdin": false,
    "AttachStderr": false,
    "AttachStdout": false,
    "Cmd": [
      "/bin/sh",
      "-c",
      "#(nop) [\"/bin/sh\"]"
    ],
    "Domainname": "",
    "Entrypoint": null,
    "Env": null,
    "Hostname": "",
    "Image": "4deca60f7d4ac566e8f88c8af3f89b32c389d49ec4584eb8eafaf5f6cb840c1c",
    "Labels": null,
    "OnBuild": null,
    "OpenStdin": false,
    "StdinOnce": false,
    "Tty": false,
    "User": "",
    "Volumes": null,
    "WorkingDir": ""
  },
  "history": [
    {
      "created": "2016-06-08T22:03:42.473Z",
      "created_by": "/bin/sh -c #(nop) MAINTAINER Jérôme Petazzoni <jerome@docker.com>",
      "empty_layer": false,
      "author": "Jérôme Petazzoni <jerome@docker.com>"
    },
    {
      "created": "2016-06-08T22:03:43.098Z",
      "created_by": "/bin/sh -c #(nop) ADD file:c36f77eebbf6ed4c99488f33a7051c95ad358df4414dfed5006787f39b3cf518 in /",
      "empty_layer": false,
      "author": "Jérôme Petazzoni <jerome@docker.com>"
    },
    {
      "created": "2016-06-08T22:03:43.175Z",
      "created_by": "/bin/sh -c #(nop) [\"/bin/sh\"]",
      "empty_layer": false,
      "author": "Jérôme Petazzoni <jerome@docker.com>"
    }
  ],
  "rootfs": {
    "type": "layers",
    "diff_ids": [
      "sha256:84ff92691f909a05b224e1c56abb4864f01b4f8e3c854e4bb4c7baf1d3f6d652",
      "sha256:847f49d214bac745aad71de7e5c4ca2fa729c096ca749151bf9566b7e2e565d9",
      "sha256:84ff92691f909a05b224e1c56abb4864f01b4f8e3c854e4bb4c7baf1d3f6d652"
    ]
  }
}
```

## Image manifest v 2.1

```
{
   "name": "hello-world",
   "tag": "latest",
   "architecture": "amd64",
   "fsLayers": [
      {
         "blobSum": "sha256:5f70bf18a086007016e948b04aed3b82103a36bea41755b6cddfaf10ace3c6ef"
      },
      {
         "blobSum": "sha256:5f70bf18a086007016e948b04aed3b82103a36bea41755b6cddfaf10ace3c6ef"
      },
      {
         "blobSum": "sha256:cc8567d70002e957612902a8e985ea129d831ebe04057d88fb644857caa45d11"
      },
      {
         "blobSum": "sha256:5f70bf18a086007016e948b04aed3b82103a36bea41755b6cddfaf10ace3c6ef"
      }
   ],
   "history": [
      {
         "v1Compatibility": "{\"id\":\"e45a5af57b00862e5ef5782a9925979a02ba2b12dff832fd0991335f4a11e5c5\",\"parent\":\"31cbccb51277105ba3ae35ce33c22b69c9e3f1002e76e4c736a2e8ebff9d7b5d\",\"created\":\"2014-12-31T22:57:59.178729048Z\",\"container\":\"27b45f8fb11795b52e9605b686159729b0d9ca92f76d40fb4f05a62e19c46b4f\",\"container_config\":{\"Hostname\":\"8ce6509d66e2\",\"Domainname\":\"\",\"User\":\"\",\"Memory\":0,\"MemorySwap\":0,\"CpuShares\":0,\"Cpuset\":\"\",\"AttachStdin\":false,\"AttachStdout\":false,\"AttachStderr\":false,\"PortSpecs\":null,\"ExposedPorts\":null,\"Tty\":false,\"OpenStdin\":false,\"StdinOnce\":false,\"Env\":[\"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\"],\"Cmd\":[\"/bin/sh\",\"-c\",\"#(nop) CMD [/hello]\"],\"Image\":\"31cbccb51277105ba3ae35ce33c22b69c9e3f1002e76e4c736a2e8ebff9d7b5d\",\"Volumes\":null,\"WorkingDir\":\"\",\"Entrypoint\":null,\"NetworkDisabled\":false,\"MacAddress\":\"\",\"OnBuild\":[],\"SecurityOpt\":null,\"Labels\":null},\"docker_version\":\"1.4.1\",\"config\":{\"Hostname\":\"8ce6509d66e2\",\"Domainname\":\"\",\"User\":\"\",\"Memory\":0,\"MemorySwap\":0,\"CpuShares\":0,\"Cpuset\":\"\",\"AttachStdin\":false,\"AttachStdout\":false,\"AttachStderr\":false,\"PortSpecs\":null,\"ExposedPorts\":null,\"Tty\":false,\"OpenStdin\":false,\"StdinOnce\":false,\"Env\":[\"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\"],\"Cmd\":[\"/hello\"],\"Image\":\"31cbccb51277105ba3ae35ce33c22b69c9e3f1002e76e4c736a2e8ebff9d7b5d\",\"Volumes\":null,\"WorkingDir\":\"\",\"Entrypoint\":null,\"NetworkDisabled\":false,\"MacAddress\":\"\",\"OnBuild\":[],\"SecurityOpt\":null,\"Labels\":null},\"architecture\":\"amd64\",\"os\":\"linux\",\"Size\":0}\n"
      },
      {
         "v1Compatibility": "{\"id\":\"e45a5af57b00862e5ef5782a9925979a02ba2b12dff832fd0991335f4a11e5c5\",\"parent\":\"31cbccb51277105ba3ae35ce33c22b69c9e3f1002e76e4c736a2e8ebff9d7b5d\",\"created\":\"2014-12-31T22:57:59.178729048Z\",\"container\":\"27b45f8fb11795b52e9605b686159729b0d9ca92f76d40fb4f05a62e19c46b4f\",\"container_config\":{\"Hostname\":\"8ce6509d66e2\",\"Domainname\":\"\",\"User\":\"\",\"Memory\":0,\"MemorySwap\":0,\"CpuShares\":0,\"Cpuset\":\"\",\"AttachStdin\":false,\"AttachStdout\":false,\"AttachStderr\":false,\"PortSpecs\":null,\"ExposedPorts\":null,\"Tty\":false,\"OpenStdin\":false,\"StdinOnce\":false,\"Env\":[\"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\"],\"Cmd\":[\"/bin/sh\",\"-c\",\"#(nop) CMD [/hello]\"],\"Image\":\"31cbccb51277105ba3ae35ce33c22b69c9e3f1002e76e4c736a2e8ebff9d7b5d\",\"Volumes\":null,\"WorkingDir\":\"\",\"Entrypoint\":null,\"NetworkDisabled\":false,\"MacAddress\":\"\",\"OnBuild\":[],\"SecurityOpt\":null,\"Labels\":null},\"docker_version\":\"1.4.1\",\"config\":{\"Hostname\":\"8ce6509d66e2\",\"Domainname\":\"\",\"User\":\"\",\"Memory\":0,\"MemorySwap\":0,\"CpuShares\":0,\"Cpuset\":\"\",\"AttachStdin\":false,\"AttachStdout\":false,\"AttachStderr\":false,\"PortSpecs\":null,\"ExposedPorts\":null,\"Tty\":false,\"OpenStdin\":false,\"StdinOnce\":false,\"Env\":[\"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\"],\"Cmd\":[\"/hello\"],\"Image\":\"31cbccb51277105ba3ae35ce33c22b69c9e3f1002e76e4c736a2e8ebff9d7b5d\",\"Volumes\":null,\"WorkingDir\":\"\",\"Entrypoint\":null,\"NetworkDisabled\":false,\"MacAddress\":\"\",\"OnBuild\":[],\"SecurityOpt\":null,\"Labels\":null},\"architecture\":\"amd64\",\"os\":\"linux\",\"Size\":0}\n"
      },
   ],
   "schemaVersion": 1,
   "signatures": [
      {
         "header": {
            "jwk": {
               "crv": "P-256",
               "kid": "OD6I:6DRK:JXEJ:KBM4:255X:NSAA:MUSF:E4VM:ZI6W:CUN2:L4Z6:LSF4",
               "kty": "EC",
               "x": "3gAwX48IQ5oaYQAYSxor6rYYc_6yjuLCjtQ9LUakg4A",
               "y": "t72ge6kIA1XOjqjVoEOiPPAURltJFBMGDSQvEGVB010"
            },
            "alg": "ES256"
         },
         "signature": "XREm0L8WNn27Ga_iE_vRnTxVMhhYY0Zst_FfkKopg6gWSoTOZTuW4rK0fg_IqnKkEKlbD83tD46LKEGi5aIVFg",
         "protected": "eyJmb3JtYXRMZW5ndGgiOjY2MjgsImZvcm1hdFRhaWwiOiJDbjAiLCJ0aW1lIjoiMjAxNS0wNC0wOFQxODo1Mjo1OVoifQ"
      }
   ]
}
```

## Image config v1 format (needed?)

```
{
    "id": "a9561eb1b190625c9adb5a9513e72c4dedafc1cb2d4c5236c9a6957ec7dfd5a9",
    "parent": "c6e3cedcda2e3982a1a6760e178355e8e65f7b80e4e5248743fa3549d284e024",
    "created": "2014-10-13T21:19:18.674353812Z",
    "author": "Alyssa P. Hacker &ltalyspdev@example.com&gt",
    "architecture": "amd64",
    "os": "linux",
    "Size": 271828,
    "config": {
        "User": "alice",
        "Memory": 2048,
        "MemorySwap": 4096,
        "CpuShares": 8,
        "ExposedPorts": {
            "8080/tcp": {}
        },
        "Env": [
            "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "FOO=docker_is_a_really",
            "BAR=great_tool_you_know"
        ],
        "Entrypoint": [
            "/bin/my-app-binary"
        ],
        "Cmd": [
            "--foreground",
            "--config",
            "/etc/my-app.d/default.cfg"
        ],
        "Volumes": {
            "/var/job-result-data": {},
            "/var/log/my-app-logs": {},
        },
        "WorkingDir": "/home/alice",
    }
}
```

## A docker_images_v2 example

This is docker_images_v2 model instance for alpine:
```
{
    "config_digest": "sha256:a41a7446062d197dd4b21b38122dcc7b2399deb0750c4110925a7dd37c80f118",
    "created": 1495755202,
    "head": true,
    "image": {
        "architecture": "amd64",
        "config": {
            "Hostname": "9ac68176ac52",
            "Domainname": "",
            "User": "",
            "AttachStdin": false,
            "AttachStdout": false,
            "AttachStderr": false,
            "Tty": false,
            "OpenStdin": false,
            "StdinOnce": false,
            "Env": ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],
            "Cmd": ["/bin/sh"],
            "ArgsEscaped": true,
            "Image": "sha256:a96393421091145abdc0ce8f02691166ed0fe7f769b4dfc7f700b4b11d4a80df",
            "Volumes": null,
            "WorkingDir": "",
            "Entrypoint": null,
            "OnBuild": null,
            "Labels": {}
        },
        "container": "19ee1cd90c07eb7b3c359aaec3706e269a871064cca47801122444cef51c5038",
        "container_config": {
            "Hostname": "9ac68176ac52",
            "Domainname": "",
            "User": "",
            "AttachStdin": false,
            "AttachStdout": false,
            "AttachStderr": false,
            "Tty": false,
            "OpenStdin": false,
            "StdinOnce": false,
            "Env": ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],
            "Cmd": ["/bin/sh", "-c", "#(nop) ", "CMD [\"/bin/sh\"]"],
            "ArgsEscaped": true,
            "Image": "sha256:a96393421091145abdc0ce8f02691166ed0fe7f769b4dfc7f700b4b11d4a80df",
            "Volumes": null,
            "WorkingDir": "",
            "Entrypoint": null,
            "OnBuild": null,
            "Labels": {}
        },
        "created": "2017-05-25T23:33:22.029729271Z",
        "docker_version": "17.03.1-ce",
        "history": [{
            "created": "2017-05-25T23:33:21.294948657Z",
            "created_by": "/bin/sh -c #(nop) ADD file:ce33aabbc5f370e58ebe911e081ce093e3df18d689c2d5a5d092c77973f62a54 in / "
        }, {
            "created": "2017-05-25T23:33:22.029729271Z",
            "created_by": "/bin/sh -c #(nop)  CMD [\"/bin/sh\"]",
            "empty_layer": true
        }],
        "os": "linux",
        "rootfs": {
            "type": "layers",
            "diff_ids": ["sha256:3fb66f713c9fa9debcdaa58bb9858bd04c17350d9614b7a250ec0ee527319e59"]
        }
    },
    "image_uuid": "af538a6a-5ca3-04cc-fd2e-9c0064fe5a63",
    "manifest_str": "{\n   \"schemaVersion\": 2,\n   \"mediaType\": \"application/vnd.docker.distribution.manifest.v2+json\",\n   \"config\": {\n      \"mediaType\": \"application/vnd.docker.container.image.v1+json\",\n      \"size\": 1522,\n      \"digest\": \"sha256:a41a7446062d197dd4b21b38122dcc7b2399deb0750c4110925a7dd37c80f118\"\n   },\n   \"layers\": [\n      {\n         \"mediaType\": \"application/vnd.docker.image.rootfs.diff.tar.gzip\",\n         \"size\": 1990101,\n         \"digest\": \"sha256:2aecc7e1714b6fad58d13aedb0639011b37b86f743ba7b6a52d82bd03014b78e\"\n      }\n   ]\n}",
    "manifest_digest": "sha256:0b94d1d1b5eb130dd0253374552445b39470653fb1a1ec2d81490948876e462c",
    "parent": "",
    "owner_uuid": "f64c0e9c-bb71-42e7-a95b-091d1282ca0f",
    "size": 1990101,
    "dockerImageVersion": "2.2"
}
```

# Appendix 2: A walkthrough of digests examples

Here is walkthrough pulling alpine:latest from Docker Hub, tagging it,
pushing it to a private Docker Hub repo, `docker inspect`ing it, and comparing
those to raw Docker Hub Registry API responses to illustrate the Docker
Registry API v2 schema 2 *manifest* and *config* for images.

Some terminology for the new "schema 2" (a.k.a. v2.2) world:

- A *docker image* is made up of a "config" and one or more (allows zero?)
  "layers". Unlike in earlier Docker, an image's intermediate layers are
  not `docker run`nable images. For some level of backward compat, synthetic
  image configs are created for those intermediate layers by the Docker Engine
  as needed.
- A *image manifest* is used to describe a Docker image for pushing to and
  pulling from a Docker Registry. It is a JSON object that refers to the
  "config" and "layers" by content digest. Those content digests are used to
  download the config and layers from the registry for a "docker pull".
  The digest of the manifest content is called the *manifest digest* here. There
  is no specified normalized form -- the exact content returned by the registry
  is used. The manifest format is [specified
  here](https://github.com/docker/distribution/blob/master/docs/spec/manifest-v2-2.md).
- A Docker *image config* is a JSON object that describes the image, e.g.
  the architecture, os, container "Cmd", history, and importantly the content
  digests of its layers (uncompressed). This *somewhat* duplicates the
  layer content digests in the "manifest" (but may differ because they are
  the digest of uncompressed content). However, because the config includes
  in-order layer content digests, the digest of the config JSON (the *config
  digest*) is a unique content-based identifier for the image. This is
  the *docker image id*.
- A Docker *image layer* is, typically, a compressed Docker "rootfs diff" tar.
  Its content-type is defined in the image manifest.

When identifying an image, the "config digest" is often referred to as the
image "id" and the "manifest digest" is often referred to as just the *digest*.


## docker pull

```
ubuntu@3334dcb4-0dc2-4ebd-b3e5-62a74de4db9b:~$ docker pull alpine:latest
latest: Pulling from library/alpine
627beaf3eaaf: Pull complete
Digest: sha256:58e1a1bb75db1b5a24a462dd5e2915277ea06438c3f105138f97eb53149673c4
Status: Downloaded newer image for alpine:latest
```

- `alpine:latest` is a "RepoTag".
- `sha256:58e1a1bb75db1b5a24a462dd5e2915277ea06438c3f105138f97eb53149673c4` is
  the *manifest* digest.
- `627beaf3eaaf` is the prefix of the Alpine image's only layer's digest.

We can see these values in the raw Docker Registry API manifest for this image
(note that Docker likes to use *3-space* indentation for the manifests):

```
[node-docker-registry-client/examples/v2]$ node getManifest.js -s2 alpine:latest
# response headers
{
    "content-length": "528",
    "content-type": "application/vnd.docker.distribution.manifest.v2+json",
    "docker-content-digest": "sha256:58e1a1bb75db1b5a24a462dd5e2915277ea06438c3f105138f97eb53149673c4",
    "docker-distribution-api-version": "registry/2.0",
    "etag": "\"sha256:58e1a1bb75db1b5a24a462dd5e2915277ea06438c3f105138f97eb53149673c4\"",
    "date": "Thu, 13 Apr 2017 22:43:29 GMT",
    "strict-transport-security": "max-age=31536000",
    "x-request-received": 1492123408835,
    "x-request-processing-time": 498
}
# manifest
{
   "schemaVersion": 2,
   "mediaType": "application/vnd.docker.distribution.manifest.v2+json",
   "config": {
      "mediaType": "application/vnd.docker.container.image.v1+json",
      "size": 1278,
      "digest": "sha256:4a415e3663882fbc554ee830889c68a33b3585503892cc718a4698e91ef2a526"
   },
   "layers": [
      {
         "mediaType": "application/vnd.docker.image.rootfs.diff.tar.gzip",
         "size": 1905270,
         "digest": "sha256:627beaf3eaaff1c0bc3311d60fb933c17ad04fe377e1043d9593646d8ae3bfe1"
      }
   ]
}
```

## docker images

We can list the pulled image:

```

ubuntu@3334dcb4-0dc2-4ebd-b3e5-62a74de4db9b:~$ docker images
REPOSITORY                   TAG                 IMAGE ID            CREATED             SIZE
alpine                       latest              4a415e366388        5 weeks ago         3.987 MB
```

and with the digest:

```
ubuntu@3334dcb4-0dc2-4ebd-b3e5-62a74de4db9b:~$ docker images --digests
REPOSITORY                   TAG                 DIGEST                                                                    IMAGE ID            CREATED             SIZE
alpine                       latest              sha256:58e1a1bb75db1b5a24a462dd5e2915277ea06438c3f105138f97eb53149673c4   4a415e366388        5 weeks ago         3.987 MB
```

That "DIGEST" is the *manifest digest*.

Where does that "IMAGE ID" come from? As discussed in the terminology above,
that is the image "config digest", which we can see in `docker inspect`
output.


## docker inspect

```
ubuntu@3334dcb4-0dc2-4ebd-b3e5-62a74de4db9b:~$ docker inspect sha256:4a415e3663882fbc55
[
    {
        "Id": "sha256:4a415e3663882fbc554ee830889c68a33b3585503892cc718a4698e91ef2a526",
        "RepoTags": [
            "alpine:latest"
        ],
        "RepoDigests": [
            "alpine@sha256:58e1a1bb75db1b5a24a462dd5e2915277ea06438c3f105138f97eb53149673c4"
        ],
        "Parent": "",
        ...
        "RootFS": {
            "Type": "layers",
            "Layers": [
                "sha256:23b9c7b43573dd164619ad59e9d51eda4095926729f59d5f22803bcbe9ab24c2"
            ]
        }
    }
]
```

This inspect output format is *mostly* a massaged form of the image "config",
which we can see from the raw Registry API response:

```
$ node downloadBlob.js alpine@sha256:4a415e3663882fbc554ee830889c68a33b3585503892cc718a4698e91ef2a526
Repo: docker.io/alpine
Downloading blob to "4a415e366388.blob".
...

$ cat 4a415e366388.blob | json
{
  ...
  "history": [
    {
      "created": "2017-03-03T20:32:37.723773456Z",
      "created_by": "/bin/sh -c #(nop) ADD file:730030a984f5f0c5dc9b15ab61da161082b5c0f6e112a9c921b42321140c3927 in / "
    }
  ],
  "rootfs": {
    "type": "layers",
    "diff_ids": [
      "sha256:23b9c7b43573dd164619ad59e9d51eda4095926729f59d5f22803bcbe9ab24c2"
    ]
  }
}
```

In the inspect output:

- "Id" is the "config digest"
- "RepoDigests" is the "$repo@$digest" (*manifest digest*) form that you can
  use with `docker pull ...`. Currently it just has one entry.


Forms that the Docker Engine supports to identify the image:

```
docker inspect 4a415e366388             # docker id or a unique prefix of it
docker inspect sha256:4a415e366388      # ... with the digest algorithm
docker inspect alpine:latest            # repo:tag
# The complete "repo@digest" (this is the *manifest digest*):
docker inspect alpine@sha256:58e1a1bb75db1b5a24a462dd5e2915277ea06438c3f105138f97eb53149673c4
```


## docker push

We can tag this image for a different repo and push that:

```
ubuntu@3334dcb4-0dc2-4ebd-b3e5-62a74de4db9b:~$ docker tag 4a415e3663882fbc5 trentm/foo:mybartag

ubuntu@3334dcb4-0dc2-4ebd-b3e5-62a74de4db9b:~$ docker push trentm/foo:mybartag
The push refers to a repository [docker.io/trentm/foo]
23b9c7b43573: Pushed
mybartag: digest: sha256:58e1a1bb75db1b5a24a462dd5e2915277ea06438c3f105138f97eb53149673c4 size: 528
```

- `digest: sha256:58e1a1bb75db1b5a24a462dd5e2915277ea06438c3f105138f97eb53149673c4`
  is the *manifest digest* again. Here the Docker Engine just reused the
  exact manifest content that was received in the earlier "docker pull",
  hence the same digest.
- `23b9c7b43573` is the *uncompressed* layer digest. After an image is pulled,
  it is the uncompressed digest that is the identifier for the layer content.
  This keeps its independent of the compression algorithm. IIUC, the Docker
  Engine would be free to use a different compression for the pull
  (and hence have to change the content-type in the manifest for that layer).

If we now look at `docker inspect` we can see our added tag and repo digest:

```
ubuntu@3334dcb4-0dc2-4ebd-b3e5-62a74de4db9b:~$ docker inspect 4a415e3663882fbc55
[
    {
        "Id": "sha256:4a415e3663882fbc554ee830889c68a33b3585503892cc718a4698e91ef2a526",
        "RepoTags": [
            "alpine:latest",
            "trentm/foo:mybartag"
        ],
        "RepoDigests": [
            "alpine@sha256:58e1a1bb75db1b5a24a462dd5e2915277ea06438c3f105138f97eb53149673c4",
            "trentm/foo@sha256:58e1a1bb75db1b5a24a462dd5e2915277ea06438c3f105138f97eb53149673c4"
        ],
        "Parent": "",
...

ubuntu@3334dcb4-0dc2-4ebd-b3e5-62a74de4db9b:~$ docker images
REPOSITORY                   TAG                 IMAGE ID            CREATED             SIZE
alpine                       latest              4a415e366388        5 weeks ago         3.987 MB
trentm/foo                   mybartag            4a415e366388        5 weeks ago         3.987 MB

ubuntu@3334dcb4-0dc2-4ebd-b3e5-62a74de4db9b:~$ docker images --digests
REPOSITORY                   TAG                 DIGEST                                                                    IMAGE ID            CREATED             SIZE
alpine                       latest              sha256:58e1a1bb75db1b5a24a462dd5e2915277ea06438c3f105138f97eb53149673c4   4a415e366388        5 weeks ago         3.987 MB
trentm/foo                   mybartag            sha256:58e1a1bb75db1b5a24a462dd5e2915277ea06438c3f105138f97eb53149673c4   4a415e366388        5 weeks ago         3.987 MB
```
