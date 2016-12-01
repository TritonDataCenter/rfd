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

## 1. Design Discussion

### Client-side Encryption Description

Encryption used in object stores with an HTTP API such as Swift, S3, and Manta typically fall under one of two types of implementations: client-side and server-side. Client-side encryption performs all of the encryption and decryption operations entirely in the client SDK with no encryption-specific operations being executed on the object store server. This implies that key management is entirely handled by the client.ciphertext Server-side encryption typically handles key management, encryption and decryption entirely using the object store's server logic on behalf of the client. This RFD will be focused solely on client-side encryption.

Conceptually, client-side encryption's primary use case is when you do not trust the provider of your object-store. Security is ensured because the client has full control over encryption algorithms, keys and authentication. When server-side encryption is not available on an object store, client-side encryption can be used to provide similar functionality by relaxing requirements such as ciphertext authentication and thereby supporting random reads from streamable ciphers. This can make sense when the provider of the object-store is not viewed as a potential adversary and is a trusted party.  

### Desired Client-side Encryption Functionality

In order for an object store client SDK to provide encryption and decryption as a seamless part of its API, there needs to be support for the following operations and constraints:

 * Client-side encryption can be selectively enabled or disabled.
 * Streamable operations can be encrypted or decrypted without changing the API from non-encrypted operations.
 * Retryable operations are not affected by enabling encryption.
 * Encryption is memory efficient.
 * HTTP range requests of ciphertext can be decrypted.
 * Multipart uploads can be encrypted and decrypted.
 * Client-side encryption implementation is compatible between all client SDKs.
 * Users of the SDK can select cipher and strength of encryption algorithm used.
 * Metadata is optionally encrypted.
 * Manta jobs can be supplied encryption credentials and operate normally.
 * Standardize headers to inform Manta that the object is encrypted.

### Unsupported Operations

Due to the inherent limitations of client-side encryption, some operations will not be supported. The list of operations not supported is as follows:

 * Decryption via signed links will not be supported.
 * Objects contained in the public directory will not be automatically decrypted unless accessed via a client SDK that supports client-side encryption.
 * If using a [Authenticated Encryption with Associated Data (AEAD) cipher](https://en.wikipedia.org/wiki/Authenticated_encryption), authentication will not be possible when doing HTTP range requests.

### HTTP Headers Used with Client-side Encryption

#### `Manta-Encrypt-Support`
In order to give the maintainers of Manta and client SDKs more options when implementing future functionality, we should create a new HTTP metadata header that is supported in Manta outside of user-supplied metadata. This header would be used to mark a given objects as being encrypted using client-side encryption. One example of how this header could be useful is if we wanted to implement gzip compression in the future, ciphertext doesn't compress well and we would be able to selectively disable compression for encrypted files.

```
Manta-Encrypt-Support: client
```

#### `Manta-Encrypt-Key-Id`
To provide an audit trail to the consumers of client-side encryption, we set a header indicating the id of the key used to encrypt the object. This would assist users in debugging cases where files have been encrypted using multiple keys and could allow the client to support multiple encryption keys in the future.

```
Manta-Encrypt-Key-Id: XXXXXXXXX
```

#### `Manta-Encrypt-IV`
In order to make sure that the same ciphertext is not generated each time the same file is encrypted, we use an [initialization vector (IV)](https://en.wikipedia.org/wiki/Initialization_vector). This IV is stored in Manta as convenience so that this value is easily available when decrypting.   
```
Manta-Encrypt-IV: XXXXXXXXX
```

#### Manta-Encrypt-MAC
A cryptographic checksum of the ciphertext is stored in this header so that ciphertext can be authenticated. This prevents classes of attacks that involve tricky changes to the ciphertext binary file. When using AEAD ciphers, it will contain the authentication data (AD) instead of [hash-based message authentication (HMAC)](https://en.wikipedia.org/wiki/Hash-based_message_authentication_code) data. The value of the header will be stored in base64 encoding.
```
Manta-Encrypt-MAC: XXXXXXXXX

```

#### `Manta-Encrypt-Cipher`
In order to allow differing clients to easily select the correct encryption algorithm, we set a header indicating the type of cipher used to encrypt the object. This header is in the form of `cipher-width-mode`.

```
Manta-Encrypt-Cipher: aes-256-cbc
```

#### `Manta-Encrypt-Plaintext-Content-Length`
For a plethora of use cases it is valuable for the client to be able to be aware of the unencrypted file's size. We store that in bytes.
```
Manta-Encrypt-Plaintext-Content-Length: 1048576

```

#### `Manta-Encrypt-Metadata`
Like the free form `m-*` metadata headers, we support free form encrypted metadata. The value of this header is ciphertext encoded in base64. Metadata stored in plaintext is written as JSON. The value of this header will be limited to a maximum of 4k bytes as base64 ciphertext. 
```
Manta-Encrypt-Metadata: XXXXXXXXX

```

#### `Manta-Encrypt-Metadata-IV`
Like `Manta-Encrypt-IV` we store the IV for the ciphertext for the HTTP header `Manta-Encrypt-Metadata`. 
```
Manta-Encrypt-Metadata-IV: XXXXXXXXX

```

#### `Manta-Encrypt-Metadata-MAC`
Like `Manta-Encrypt-MAC` we store the MAC in base64 for the ciphertext for the HTTP header `Manta-Encrypt-Metadata` so that we can verify the authenticity of the header ciphertext.
```
Manta-Encrypt-Metadata-MAC: XXXXXXXXX

```

#### `Manta-Encrypt-Metadata-Cipher`
Like `Manta-Encrypt-Cipher` we store the cipher for the ciphertext for the HTTP header `Manta-Encrypt-Metadata` so that our client can easily choose the right algorithm for decryption.
```
Manta-Encrypt-Metadata-Cipher: aes-256-cbc
```

### Metadata Support

Encrypted metadata will be supported by serializing to a JSON data structure that will be encrypted and converted to base64 encoding. This will be stored as metadata on the object via the HTTP header `Manta-Encrypt-Headers`. 

### Manta Job Support

### Future considerations

## 2. JDK SDK Design and Implementation

### Cipher Selection and Library Support

`TODO: research how the OpenJDK handles strong encryption algorithms.`

In the Oracle JDK there is limited default support for strong encryption algorithms. In order to enable stronger encryption, you must download and install the [Java Cryptography Extension (JCE) Unlimited Strength Jurisdiction Policy Files](http://www.oracle.com/technetwork/java/javase/downloads/jce8-download-2133166.html). Strong encryption algorithms are also supported using the [JCE API](https://en.wikipedia.org/wiki/Java_Cryptography_Extension) by [The Legion of the Bouncy Castle](http://www.bouncycastle.org/java.html) project.

Ideally, we should support algorithms supplied by Bouncy Castle and the Java runtime via the [JCE API](http://docs.oracle.com/javase/8/docs/technotes/guides/security/crypto/CryptoSpec.html). The Java Manta SDK currently bundles Bouncy Castle dependencies because they are used when doing [authentication via HTTP signed requests](https://github.com/joyent/java-http-signature).

We've identified the following ciphers as the best candidates for streamable encryption:

```
TODO: Alex Wilso - please add reccomendations from JCE and BouncyCastle. Please note if they are compatible with OpenSSL.

```

### Key Management

### Configuration

#### Enabling Unauthenticated Range Requests

### Stream Support

### File Support

### Range Support

#### Random Operation Support with [MantaSeekableByteChannel](https://github.com/joyent/java-manta/blob/master/java-manta-client/src/main/java/com/joyent/manta/client/MantaSeekableByteChannel.java)

### Multipart Support

### Metadata Support

### Failure Handling

#### Key Failures

#### Decryption Failures

## 3. Node.js SDK Design and Implementation
