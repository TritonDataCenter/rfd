---
authors: Elijah Zupancic <elijah.zupancic@joyent.com>
state: draft
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2016 Joyent Inc.
-->

# RFD 71 Manta Client-side Encryption

## Introduction

This document will describe the proposed design and implementation of a client-side encryption mechanism for Manta, similar to the functionality provided by Amazon S3's Java, .NET, and Ruby SDKs.

In section 1, we discuss the proposed design for this feature in detail: first outlining the changes needed to implement client-side encryption in a general sense, then reviewing design constraints and requirements for implementing such a feature in Manta, and finally, reasoning through each piece of the design. If you are interested in the motivation behind client-side encryption in Manta, you should read this section.

In section 2, we provide a detailed summary of the design of the JDK implementation.

In section 3, we provide a detailed summary of the design of the node.js implementation.

## Terms

| Term           | Definition                                                  |
| -------------- | ----------------------------------------------------------- |
| Plaintext      | [Unencrypted data](https://en.wikipedia.org/wiki/Plaintext) |
| Ciphertext     | [Encrypted data](https://en.wikipedia.org/wiki/Ciphertext) |
| Authentication | [Cryptographic authentication](https://en.wikipedia.org/wiki/Message_authentication) - such as [MAC](https://en.wikipedia.org/wiki/Message_authentication_code) or [AE](https://en.wikipedia.org/wiki/Authenticated_encryption) |
| Metadata       | Refers to metadata about objects stored in Manta |

## 1. Design Discussion

### Client-side Encryption Description

Encryption used in object stores with an HTTP API such as Swift, S3, and Manta typically fall under one of two types of implementations: client-side and server-side. Client-side encryption performs all of the encryption and decryption operations entirely in the client SDK with no encryption-specific operations being executed on the object store server. This implies that key management is entirely handled by the client. Server-side encryption typically handles key management, encryption and decryption entirely using the object store's server logic on behalf of the client. This RFD will be focused solely on client-side encryption.

Conceptually, client-side encryption's primary use case is when you do not trust the provider of your object-store. Security is ensured because the client has full control over encryption algorithms, keys and authentication. Additionally, when server-side encryption is not available on an object store, client-side encryption can be used to provide similar functionality to server-side encryption provided that the user is willing to relax requirements such as authentication. This can make sense when the provider of the object-store is not viewed as a potential adversary and is a trusted party.
  
From a design perspective the implementation of client-side encryption in Manta loosely resembles the Java S3 SDK implementation. Like the S3 implementation, we use the JVM's support for encryption facilities to do encryption, we support fully client-managed private keys, we support loosening strict checking of ciphertext authentication so we can do more operations (such as HTTP range requests), we support multi-part uploads and encrypting streams.

### Desired Client-side Encryption Functionality

In order for an object store client SDK to provide encryption and decryption as a seamless part of its API, there needs to be support for the following operations and constraints:

 * Client-side encryption can be selectively enabled or disabled.
 * Streamable operations can be encrypted or decrypted without changing the API from non-encrypted operations.
 * Retryable operations are not affected by enabling encryption.
 * Encryption algorithms supporting O(1) additional memory per operation are supported. 
 * HTTP range requests of ciphertext can be decrypted.
 * Objects uploaded through the multipart upload interface can be encrypted and decrypted.
 * The schemes for client-side encryption should be compatible between all supported client SDKs. Objects encrypted using one SDK can be seamlessly decrypted with other SDKs that support client-side encryption.
 * The encryption key file formats are compatible between all supported SDKs.
 * The encryption key default file paths and environment variables are compatible between all supported SDKs.
 * Users of the SDK can select cipher and strength of encryption algorithm used.
 * Functionality to allow for encrypted metadata is provided.
 * Standardized headers are set that inform Manta that a given object is encrypted.

### Unsupported Operations

Due to the inherent limitations of client-side encryption, some operations will not be supported. The list of operations not supported is as follows:

 * Manta jobs cannot be supported with client-side encrypted objects. Clients can of course upload the keys to Manta themselves and import them into jobs as assets if they need to, but there will be no first class support for such operations.
 * Decryption via signed links will not natively be supported by Manta server-side operations. A client could still download a signed link and decrypt it themself.
 * Decryption of objects contained in the public directory will not be natively supported by Manta server-side operations. 
 * If using a [Authenticated Encryption with Associated Data (AEAD) cipher](https://en.wikipedia.org/wiki/Authenticated_encryption), authentication will not be possible when doing HTTP range requests.

### HTTP Headers Used with Client-side Encryption

The following headers will be added to manta as natively supported headers like `Durability-Level` and not treated from an API perspective as "metadata" (`m-*` parameter). The rational behind this is that it is enforcing the contract for consistent behavior between client-side encryption implementations across SDKs.

#### `m-encrypt-support`
In order to give the maintainers of Manta and client SDKs more options when implementing future functionality, we should create a new HTTP metadata header that is supported in Manta outside of user-supplied metadata. This header would be used to mark a given objects as being encrypted using client-side encryption. One example of how this header could be useful is if we wanted to implement gzip compression in the future, ciphertext does not compress well and we would be able to selectively disable compression for encrypted files. Another example is that it could be used as a basis for a identifying files that would be candidates for a future migration to server-side encryption.

```
m-encrypt-support: client
```

#### `m-encrypt-key-id`
To provide an audit trail to the consumers of client-side encryption, we set a header indicating the ID of the key used to encrypt the object. This would assist users in debugging cases where files have been encrypted using multiple keys and could allow the client to support multiple encryption keys in the future.

```
m-encrypt-key-id: XXXXXXXXX
```

#### `m-encrypt-iv`
In order to make sure that the same ciphertext is not generated each time the same file is encrypted, we use an [initialization vector (IV)](https://en.wikipedia.org/wiki/Initialization_vector). This IV is stored in Manta as header metadata in base64 encoding.   
```
m-encrypt-iv: TWFrZSBEVHJhY2UgZ3JlYXQgYWdhaW4K
```

#### m-encrypt-mac
A cryptographic checksum of the ciphertext is stored in this header so that ciphertext can be authenticated. This prevents classes of attacks that involve tricky changes to the ciphertext binary file. When using AEAD ciphers, it will contain the authentication data (AD) instead of [hash-based message authentication (HMAC)](https://en.wikipedia.org/wiki/Hash-based_message_authentication_code) data. The value of the header will be stored in base64 encoding.
```
m-encrypt-mac: XXXXXXXXX

```

#### `m-encrypt-cipher`
In order to allow differing clients to easily select the correct encryption algorithm, we set a header indicating the type of cipher used to encrypt the object. This header is in the form of `cipher/width/mode`.

```
m-encrypt-cipher: aes/256/cbc
```

#### `m-encrypt-original-content-length`
For a plethora of use cases it is valuable for the client to be able to be aware of the unencrypted file's size. We store that in bytes.
```
m-encrypt-original-content-length: 1048576

```

#### `m-encrypt-metadata`
Like the free form `m-*` metadata headers, we support free form encrypted metadata. The value of this header is ciphertext encoded in base64. Metadata stored in plaintext is written as JSON. The value of this header will be limited to a maximum of 4k bytes as base64 ciphertext. 
```
m-encrypt-metadata: XXXXXXXXX

```

#### `m-encrypt-metadata-iv`
Like `m-encrypt-iv` we store the IV for the ciphertext for the HTTP header `m-encrypt-metadata`. 
```
m-encrypt-metadata-iv: TWFrZSBEVHJhY2UgZ3JlYXQgYWdhaW4K

```

#### `m-encrypt-metadata-mac`
Like `m-encrypt-mac` we store the MAC in base64 for the ciphertext for the HTTP header `m-encrypt-metadata` so that we can verify the authenticity of the header ciphertext.
```
m-encrypt-metadata-mac: XXXXXXXXX

```

#### `m-encrypt-metadata-cipher`
Like `m-encrypt-cipher` we store the cipher for the ciphertext for the HTTP header `m-encrypt-metadata` so that our client can easily choose the right algorithm for decryption.
```
m-encrypt-metadata-cipher: aes/256/cbc
```

```
The following headers are stored by S3, but aren't addressed above:

TODO: Find out if we need to store cipher and/or key padding settings.
TODO: Find out if we need to store AEAD tag length.
```

### Cryptographic Authentication Modes

Depending on the threat model determined by the consumer of the client SDK, different modes of authentication of the ciphertext would be desirable. If the consumer trusts the object store provider, then enabling a mode that skips authentication when it prevents an operation from operating efficiently makes sense. One example of an operation that would not work in an authenticated mode would be random reads (e.g. HTTP range requests). With a security in mind, the client SDK will operate by default in a fully authenticated mode unless explicitly disabled. Thus, consumers of SDKs supporting client-side encryption would be able to choose between one of two modes:

 * `MandatoryObjectAuthentication` (default)
 * `OptionalObjectAuthentication`
 
We only provide two modes unlike S3 which provides three modes (`EncryptionOnly`, `AuthenticatedEncryption`, and `StrictAuthenticatedEncryption`). `EncryptionOnly` mode in S3 does not authenticate ciphertext at all, `AuthenticatedEncryption` authenticates ciphertext when it is possible with the operation being performed and `StrictAuthenticatedEncryption` always authenticates and will cause an exception to be thrown if the operation can't be performed with authentication.   

### Key Management

Initially, there will be no support server-side for key management. All key management will need to be done by the implementer of the SDK. The default key format and location will be standardized across all implementations of Manta client-side encryption in their respective SDKs.

S3 provides a Key Management Service (KMS) and the design of any equivalent service is beyond the scope of this RFD. 

```
TODO: Define the default location for encryption keys.
TODO: Define the default portable format for encryption keys.

```

### Metadata Support

Encrypted metadata will be supported by serializing to a JSON data structure that will be encrypted and converted to base64 encoding. This will be stored as metadata on the object via the HTTP header `m-encrypt-headers`. 

### Future considerations

Ideally, our client-side encryption implementation will be designed such that when we build server-side encryption support customers can seamlessly migrate between schemes. This can be possible if we have consistent headers/metadata for identifying ciphers, MAC, IV and key ids. 

## 2. Java Manta SDK Client-side Encryption Design and Implementation

Client-side encryption within the Java Manta SDK will be implemented as an optional operation that wraps streams going to and from Manta. Client-side encryption will be enabled using configuration and from an API consumer's perspective there will not be a change in the API. When operations are not supported by the encryption settings, then appropriate exceptions will be thrown indicating the conflict between the setting and the operation. An example of this would be an attempt to use a HTTP range operation when `MandatoryObjectAuthentication` is enabled. Furthermore, care will need to be taken to allow for operations that are retryable to continue to be retryable - such as sending [File](https://docs.oracle.com/javase/8/docs/api/java/io/File.html) objects.   

### Cipher Selection and Library Support

The JVM implementation of client-side encryption relies on the encryption algorithms and ciphers as provided as part of the running JVM's implementation of the Java Cryptography Extension (JCE)](https://en.wikipedia.org/wiki/Java_Cryptography_Extension). Thus, users of client-side encryption are assumed to trust the security of the JCE implementation in the JVM that they choose to run.

In the Oracle JDK there is limited default support for strong encryption algorithms. In order to enable stronger encryption, you must download and install the [Java Cryptography Extension (JCE) Unlimited Strength Jurisdiction Policy Files](http://www.oracle.com/technetwork/java/javase/downloads/jce8-download-2133166.html). This isn't an issue with the OpenJDK. Also, strong encryption algorithms are supported using the [JCE API](https://en.wikipedia.org/wiki/Java_Cryptography_Extension) by [The Legion of the Bouncy Castle](http://www.bouncycastle.org/java.html) project.

We will also support algorithms supplied by Bouncy Castle and the Java runtime via the [JCE API](http://docs.oracle.com/javase/8/docs/technotes/guides/security/crypto/CryptoSpec.html). The Java Manta SDK currently bundles Bouncy Castle dependencies because they are used when doing [authentication via HTTP signed requests](https://github.com/joyent/java-http-signature).

We've identified the following ciphers as the best candidates for streamable encryption:

```
TODO: Alex Wilson - please add reccomendations from JCE and BouncyCastle. Please note if they are compatible with OpenSSL.

```

### Configuration

All settings related to client-side encryption will be defined as part of the Java Manta SDK's [ConfigContext](https://github.com/joyent/java-manta/blob/master/java-manta-client/src/main/java/com/joyent/manta/config/ConfigContext.java) interface. This allows for the Java Manta SDK to be easily integrated into other libraries' configuration systems.
  
```
TODO: Explicitly define the configuration parameters needed for client-side encryption.
TODO: Do we want to support multiple keys?

We will need:
ClientSideEncryptionEnabled: true | false (default)
PermitUnencryptedDownloads: true | false (true)
EncryptionAuthenticationMode: Optional | Mandatory (default)
EncryptionPrivateKeyPath or EncryptionPrivateKeyBytes (one or the other need to be selected)

```

### Headers

The additional headers specifying in [HTTP Headers Used with Client-side Encryption](HTTP-Headers-Used-with-Client-side-Encryption) would be added as properties of the [`com.joyent.manta.client.MantaHttpHeaders`](https://github.com/joyent/java-manta/blob/master/java-manta-client/src/main/java/com/joyent/manta/client/MantaHttpHeaders.java) class. These properites would be set without intervention from the implementer of the SDK in the relevant section of [`com.joyent.manta.client.HttpHelper`](https://github.com/joyent/java-manta/blob/master/java-manta-client/src/main/java/com/joyent/manta/client/HttpHelper.java) by the uploading logic. For `Manta-Encrypt-Original-Content-Length` when streaming we will need to wrap the plaintext stream in a [`org.apache.commons.io.CountingInputStream`](https://commons.apache.org/proper/commons-io/javadocs/api-2.5/org/apache/commons/io/input/CountingInputStream.html) in order to calculate the content length.  

### Thread-safety

All operations within the Java Manta SDK *should* be currently thread-safe. Any client-encryption implementation will need to also be thread-safe because consumers of the SDK are assuming thread safety. 

### Streamable Checksums

There has been an [open feature request](https://github.com/joyent/java-manta/issues/95) for some time to calculate MD5s when putting objects to Manta. This feature would need to be implemented to allow for authentication of ciphertext. The S3 SDK does it with their own class `com.amazonaws.services.s3.internal.MD5DigestCalculatingInputStream`. However, the JVM runtime provides a class ([`java.security.DigestInputStream`](https://docs.oracle.com/javase/8/docs/api/java/security/DigestInputStream.html)) that does equivalent functionality and it should be investigated as a first option.

### Stream Support

In order to encrypt Java streams, it is desirable to create a wrapping stream that allows for setting an encryption algorithm and multipart settings. This approach is similar to how the S3 SDK handles encrypting streams in the `com.amazonaws.services.s3.internal.crypto.CipherLiteInputStream` class. Using a wrapping stream allows the implementer of the SDK to use provide their own streams in the same way for encrypted operations as unencrypted operations. Moreover, it allows us to easily control specific multipart behaviors and the opening and closing of potentially thread-unsafe resources used for encryption.   

### File Support

Currently, when we send a file to Manta via the SDK, we create an instance of `com.google.api.client.http.FileContent` that has a reference to the `java.io.File` instance passed to its constructor. This allows the put operation to Manta to be retryable. When we add client-side encryption support, we will need to encrypt the file on the filesystem and write it to a temporary file and then reference that (the temporary file) when creating a new `FileContent` instance. This will preserve the retryability settings so that it behaves in the same manner as the unencrypted API call. 

### HTTP Range / Random Read Support

Authenticating ciphertext and decrypting random sections of ciphertext can't be done as one operation without reading the entirety of the ciphertext. This mode of operation is inefficient when a consumer of an object store wants to read randomly from an object that is stored using client-side encryption because it would require them to download the entire object and authenticate it before decrypting the random section. Thus, we will only allow HTTP range requests to be performed when `EncryptionAuthenticationMode` is set to `Optional`. In those cases, the server-side content-md5 could still be compared to a record that the client keeps for additional security. However, it would not be bulletproof because the server could still send differing binary data to the client for the range and that binary data could not be authenticated. In the end, this mode of operation requires trusting the provider.
   
When reading randomly from an remote object in ciphertext, the byte range of the plaintext object does not match the byte range of the cipher text object. Any implementation would need to provide a cipher-aware translation of byte-ranges. Moreover, some ciphers do not support random reads at all. In those cases, we want to throw an exception to inform the implementer that the operation is not possible.

In the S3 SDK, range requests are supported by finding the cipher's lower and upper block bounds and adjusting the range accordingly. An example of this operation can be found in `com.amazonaws.services.s3.internal.crypto.S3CryptoModuleBase`. We will likewise need to do a similar operation. Furthermore, we will need to rewrite the range header when it is specified in [`com.joyent.manta.client.HttpHelper`](https://github.com/joyent/java-manta/blob/master/java-manta-client/src/main/java/com/joyent/manta/client/HttpHelper.java) and client-side encryption is enabled.  

#### Random Operation Support with [`MantaSeekableByteChannel`](https://github.com/joyent/java-manta/blob/master/java-manta-client/src/main/java/com/joyent/manta/client/MantaSeekableByteChannel.java)

We will need to refactor [`MantaSeekableByteChannel`](https://github.com/joyent/java-manta/blob/master/java-manta-client/src/main/java/com/joyent/manta/client/MantaSeekableByteChannel.java) so that it uses the methods provided in [`com.joyent.manta.client.HttpHelper`](https://github.com/joyent/java-manta/blob/master/java-manta-client/src/main/java/com/joyent/manta/client/HttpHelper.java) to do ranged `GET` operations so that we do not have to duplicate our ciphertext range translation code.  

### Multipart Support

```
TODO: Figure out how to encrypt each MPU part in isolation so that they can be assembled by the server into a single decryptable unit. S3 is able to do multipart uploads in strict mode, so it is entirely possible using the encryption algoritims provided in the JCE.
```

### Metadata Support

A new class will be created called `EncryptedMantaMetadata`. This class will support the `Map<K, V>` interface because the backing format for metadata will be JSON. This should allow the implementers of the SDK define their own structure for free form Metadata.  

A new property called `encryptedMetadata` of the type `com.joyent.manta.client.EncryptedMantaMetadata` would be added to the [`com.joyent.manta.client.MantaHttpHeaders`](https://github.com/joyent/java-manta/blob/master/java-manta-client/src/main/java/com/joyent/manta/client/MantaHttpHeaders.java) class. Inside the [`com.joyent.manta.client.HttpHelper`](https://github.com/joyent/java-manta/blob/master/java-manta-client/src/main/java/com/joyent/manta/client/HttpHelper.java) class we would serialize the `EncryptedMantaMetadata` instance to JSON, encrypt it, base64 it and write it (metadata ciphertext), the MAC and the IV as HTTP headers. Likewise for reading headers, we would reverse the operations and write the value back to the a method that would allow the consumer to define their own generic types upon read. 

### Failure Handling

A number of new `RuntimeException` classes will need to be created that map to the different encryption failure modes. These classes will represent states such as invalid keys, invalid ciphertext and ciphertext authentication failures.
  
Furthermore, the SDK should be smart enough to handle unencrypted downloads when an object is unencrypted and the `PermitUnencryptedDownloads` flag is set to `true`.  

#### Key Failures

Private key format failures should be detected upon startup of the SDK and cause an exception to be thrown. This allows for the early alerting to implementers of the SDK of any problems in their key configuration.

#### Decryption Failures

Failures due to problems decoding the ciphertext will be pushed up the stack from the underlying JCE implementation. We need to be careful to preserve such exceptions and to wrap them with our own exception types that provide additional context that allows for ease in debugging.

## 3. Node.js SDK Design and Implementation

### Assumptions

- Key management is beyond the scope of this work. Therefore, this solution should not depend on a particular key management choice.
- There shouldn't be any server-side changes needed to make this solution work.
- Files uploaded and encrypted using the Node.js manta client should support being decrypted/verified using other clients (Java).
- The manta SDK for Node.js lowercases the header keys, therefore, assume that the `m-*` are all lowercase


### Limitations

- GCM is the only supported authentication encryption cipher supported by Node.js: https://nodejs.org/api/crypto.html#crypto_cipher_setaad_buffer


### API

#### `get(path, options, callback)`

Retrieve an encrypted object stored at `path` inside Manta and decrypt it. The `options` object expects a property named `getKey` that will be a function that will be executed to get the secret key used to encrypt the object stored at `path`. Below are possible scenarios to consider:

1. `m-encrypt-support` doesn't exist or doesn't have the value `'client'`, in which case the object is assumed not to be encrypted and the normal processing of the file occurs, without decryption
1. `m-encrypt-cipher` is set to an algorithm that isn't supported by Node.js, in which case an error should be returned in the callback
1. `m-encrypt-key-id` isn't found by the `getKey` function or an error is returned on the callback. In this scenario the error will be forwarded to the callback function.
1. `getKey` doesn't exist and `m-encrypt-support` is set to `'client'`, this will result in an error being passed on the callback.
1. Required header information is missing from the object stored in Manta. This results in an error passed to the callback.
1. `m-encrypt-mac` doesn't match the calculated HMAC of the encrypted object. This results in an error passed to the callback.


##### Usage example

```js
'use strict';

const Fs = require('fs');
const Manta = require('manta');
const Vault = require('node-vault');

const client = Manta.createClient({
    sign: Manta.privateKeySigner({
        key: Fs.readFileSync(process.env.HOME + '/.ssh/id_rsa', 'utf8'),
        keyId: process.env.MANTA_KEY_ID,
        user: process.env.MANTA_USER
    }),
    user: process.env.MANTA_USER,
    url: process.env.MANTA_URL
});

const vault = Vault({
  token: '1234'
});

const getKey = function (keyId, callback) {
  vault.read('secret/' + keyId).then((result) => {
    callback(null, result);
  }).catch((err) => {
    callback(err);
  });
};


client.get('~~/stor/encrypted', { getKey }, (err, stream) => {
  if (err) {
    console.error(err);
    process.exit(1);
  }

  stream.pipe(process.stdout);
  console.log('\n');
});
```

#### `put(path, input, options, callback)`

Upload an object to Manta and optionally encrypt it using the cipher details provided. When encryption occurs, additional `m-*` headers will be saved along with the object. Below are the steps that should take place when encrypting an object.

1. Check that encryption should take place
1. Assert that all required options are present for encryption: `key`, `keyId`, `cipher`. `cipher` should use the alg/width/mode structure
1. Assert that the provided `cipher` algorithm is valid and supported by the platform
1. Generate an Initialization Vector (IV)
1. Calculate the cipher from the input stream and IV
1. Calculate the HMAC using the calculated cipher and `key`, this should use 'sha256' or we should save the configured HMAC algorithm in a separate header
1. Set the `m-encrypt-support` header to `'client'`
1. Set the `m-encrypt-key-id` header sent to Manta using the `options.keyId`
1. Set the `m-encrypt-iv` header to the IV value encoded as base64
1. Set the `m-encrypt-cipher` header to the `options.cipher`
1. Set the `m-encrypt-mac` header to the HMAC calculated value encoded as base64
1. Calculate the cipher for the `metadata` using similar steps when the metadata also needs to be encrypted

##### Usage example

```js
'use strict';

const Fs = require('fs');
const Manta = require('manta');

const client = Manta.createClient({
    sign: Manta.privateKeySigner({
        key: Fs.readFileSync(process.env.HOME + '/.ssh/id_rsa', 'utf8'),
        keyId: process.env.MANTA_KEY_ID,
        user: process.env.MANTA_USER
    }),
    user: process.env.MANTA_USER,
    url: process.env.MANTA_URL
});

const file = Fs.createReadStream(__dirname + '/README.md');
const keyId = 'dev/test';
const key = 'FFFFFFFBD96783C6C91E2222';
const cipher = 'aes/192/cbc';

client.put('~~/stor/encrypted', file, { key, keyId, cipher }, (err, res) => {
  if (err) {
    console.error(err);
    process.exit(1);
  }
});
```

#### `info(path, options, callback)`

Retrieve metadata and headers for an object stored in Manta. When metadata is encrypted, info should decrypt and validate the integrity of the stored data, providing a decrypted form of the metadata.

The `headers` will be checked and if `m-encrypt-support` is set to `'client'` and if there is a `m-encrypt-metadata` header, then info should decrypt the value of `m-encrypt-metadata` using the information in other headers, perform an integrity check using the `m-encrypt-metadata-mac` value, then set the decrypted metadata on `m-encrypt-metadata-decypted`.


#### `chattr(path, options, callback)`

The change attribute function will also need to be updated to support setting metadata headers with encrypted values.
