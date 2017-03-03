---
authors: Elijah Zupancic <elijah.zupancic@joyent.com>, Wyatt Preul <wyatt.preul@joyent.com>
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

This document describes the proposed design and implementation of a client-side encryption mechanism for Manta, similar to the functionality provided by Amazon S3's Java, .NET, and Ruby SDKs.

In [section 1](#1-design-discussion), we discuss the proposed design for this feature in detail: first outlining the changes needed to implement client-side encryption in a general sense, then reviewing design constraints and requirements for implementing such a feature in Manta, and finally, reasoning through each piece of the proposal. If you are interested in the motivation behind client-side encryption in Manta, you should read this section.

In [section 2](#2-java-manta-sdk-client-side-encryption-design-and-implementation), we provide a detailed summary of the design of the JDK implementation.

In [section 3](#3-nodejs-sdk-design-and-implementation), we provide a comprehensive overview of the design of the Node.js implementation.

## Terms

| Term           | Definition                                                  |
| -------------- | ----------------------------------------------------------- |
| Plaintext      | [Unencrypted data](https://en.wikipedia.org/wiki/Plaintext) |
| Ciphertext     | [Encrypted data](https://en.wikipedia.org/wiki/Ciphertext) |
| Authentication | [Cryptographic authentication](https://en.wikipedia.org/wiki/Message_authentication) - such as [MAC](https://en.wikipedia.org/wiki/Message_authentication_code) or [AE](https://en.wikipedia.org/wiki/Authenticated_encryption) |
| Metadata       | [Refers to metadata about objects stored in Manta](https://apidocs.joyent.com/manta/api.html#PutMetadata) |

## 1. Design Discussion

### Client-side Encryption Description

Encryption used in object stores with an HTTP API such as Swift, S3, and Manta typically fall under one of two types of implementations:
client-side and server-side. Client-side encryption performs all of the encryption and decryption operations entirely in the client SDK with no encryption-specific operations being executed on the object store server. This implies that key management is entirely handled by the client. Server-side encryption typically handles key management, encryption and decryption entirely using the object store's server logic on behalf of the client. This RFD will be focused solely on client-side encryption.

Conceptually, client-side encryption's primary use case is when you do not trust the provider of your object-store. Security is guaranteed
because the client has full control over encryption algorithms, keys, and authentication. Additionally, when server-side encryption is not
available in an object store, client-side encryption can be used to provide similar functionality to server-side encryption provided that
the user is willing to relax requirements such as authentication. This can make sense when the provider of the object-store is not viewed
as a potential adversary and is a trusted party.

From a design perspective, the implementation of client-side encryption in Manta loosely resembles the Java S3 SDK implementation. Like the
S3 implementation, we use the JVM's support for encryption facilities to do encryption, we support fully client-managed private keys, we
support loosening strict checking of ciphertext authentication so we can do more operations (such as HTTP range requests), we support
multi-part uploads and encrypting streams.

### Desired Client-side Encryption Functionality

In order for an object store client SDK to provide encryption and decryption as a seamless part of its API, there needs to be support for
the following operations and constraints:

 * Client-side encryption can be selectively enabled or disabled.
 * Streamable operations can be encrypted or decrypted without changing the API from non-encrypted operations.
 * Retryable operations are not affected by enabling encryption.
 * Encryption algorithms supporting O(1) additional memory per operation are supported.
 * HTTP range requests of ciphertext can be decrypted.
 * Objects uploaded through the multipart upload interface can be encrypted and decrypted.
 * The schemes for client-side encryption should be compatible between all supported client SDKs. Objects encrypted using one SDK can be seamlessly decrypted with other SDKs that support client-side encryption.
 * The encryption key formats are compatible between all supported SDKs.
 * Users of the SDK can select cipher and strength of encryption algorithm used.
 * Functionality to allow for encrypted metadata is provided.
 * Standardized headers are set that inform Manta that a given object is encrypted.

### Unsupported Operations

Due to the inherent limitations of client-side encryption, some operations will not be supported. The list of operations not supported is as
follows:

 * Manta jobs cannot be supported with client-side encrypted objects. Clients can, of course, upload the keys to Manta themselves and import them into jobs as assets if they need to, but there will be no first class support for such operations.
 * Decryption via signed links will not natively be supported by Manta server-side operations. A client could still download a signed link and decrypt it themselves.
 * Decryption of objects contained in the public directory will not be natively supported by Manta server-side operations.
 * If using a [Authenticated Encryption with Associated Data (AEAD) cipher](https://en.wikipedia.org/wiki/Authenticated_encryption), authentication will not be possible when making HTTP range requests.
 * Range requests for either CBC or AEAD algorithms won't decrypt the stored ciphertext.

### HTTP Headers Used with Client-side Encryption

The following headers must be treated from an API perspective as "metadata" (`m-*` parameters) and thus will be supported without changes to Manta server-side code.

#### `m-encrypt-type`
To give the maintainers of Manta and client SDKs more options when implementing future functionality, we should create a new HTTP metadata
header that is supported in Manta outside of user-supplied metadata. This header would be used to mark a given objects as being encrypted
using client-side encryption. One example of how this header could be useful is if we wanted to implement gzip compression in the future,
ciphertext does not compress well and we would be able to selectively disable compression for encrypted files. Another example is that it
could be used as a basis for identifying files that would be candidates for a future migration to server-side encryption.
Clients must read this header and if present identify the file as encrypted client side. The client must check its support for the
encryption type. If the type is unrecognized, the client must error informing the implementor of the problem. Then, the client must
check its support for client-side encryption at the version specified. If the version is unsupported, the client must error informing
the implementor of the problem.

The format of the header value must be `$type/$version`

```
m-encrypt-type: client/1
```

#### `m-encrypt-key-id`
To provide an audit trail to the consumers of client-side encryption, we set a header indicating the ID of the key used to encrypt the
object. This would assist users in debugging cases where files have been encrypted using multiple keys and could allow the client to
support multiple encryption keys in the future. This value must contain only US-ASCII printable characters with no whitespace
(ASCII characters 33-126). If the key specified in the client configuration does not comply with the acceptable characters, an
error must be thrown notifying the implementor. If the header returned by the server contains invalid characters, the client
attempts to handle it gracefully in whatever way makes the most sense within the client's language or framework.

```
m-encrypt-key-id: tps-key
```

#### `m-encrypt-iv`
In order to make sure that the same ciphertext is not generated each time the same file is encrypted, we use an
[initialization vector (IV)](https://en.wikipedia.org/wiki/Initialization_vector). This IV is stored in Manta as header metadata
using base64 encoding.   
```
m-encrypt-iv: TWFrZSBEVHJhY2UgZ3JlYXQgYWdhaW4K=
```

#### `m-encrypt-hmac-type`
A cryptographic checksum of the ciphertext is stored as the last N bytes of the data blob when not using an authenticated algorithm.
This header contains the HMAC type as a string. If the HMAC type is known then the total size of the HMAC can be determined.
Thus, the client will know how many bytes from the end of the file are the actual ciphertext. The HMAC must be
signed by the same key as the ciphertext is signed by and the HMAC must not have a salt added.

*If a AEAD cipher is being used this header is not stored and the m-encrypt-aead-tag-length header is used instead.*

The HMACs below must be supported and are identified with the following strings. The identifiers must be able to
be read in a case-insensitive manner, but the implementor must make every effort to write the strings with the
case as presented below:

| Identifier | Algorithm | HMAC Size in Bytes |
|------------|-----------|--------------------|
| HmacMD5    | MD5       | 16                 |
| HmacSHA1   | SHA1      | 20                 |
| HmacSHA256 | SHA256    | 32                 |
| HmacSHA512 | SHA512    | 64                 |


```
m-encrypt-hmac-type: HmacSHA256
```

#### `m-encrypt-aead-tag-length`
AEAD ciphers append a tag at the end of the cipher text that allows validation that the ciphertext is unaltered. The value of the header
will be the size of the AEAD tag in bytes.

*This header is only used when storing ciphertext written via a AEAD cipher.*

```
m-encrypt-aead-tag-length: 16
```

#### `m-encrypt-cipher`
In order to allow differing clients to easily select the correct encryption algorithm, we set a header indicating the type of cipher used to
encrypt the object. The value of this header must be in the form of `cipher/mode/padding state`. Clients must support reading this value
in a case-insensitive manner, but clients must make every effort to write the value in the original case. Clients will read this value and
look up the implementation details for the cipher based on the header's value. In the section called [Supported Ciphers](#supported-ciphers),
the details of how each one of these ciphers is implemented is specified. Each client will need to implement the ciphers as per the
specification section. If the client doesn't support the cipher returned from this header, it must explicitly error and inform the
implementor of the problem.

```
m-encrypt-cipher: AES256/CTR/NoPadding
```

#### `m-encrypt-plaintext-content-length`
For a plethora of use cases it is valuable for the client to be able to be aware of the decrypted file's size. This is an optional
header that can be omitted when streaming in chunked mode when the plaintext content length is not known until the file has finished
sending. The value of this header is the total number of bytes of the plaintext content represented as an integer.

```
m-encrypt-plaintext-content-length: 1048576
```

#### `m-encrypt-metadata`
Like the free form `m-*` metadata headers, we support free form encrypted metadata. The value of this header is ciphertext encoded in base64.
Metadata stored in plaintext is written in the form of HTTP headers delimited by new lines. The value of this header must be limited to a
maximum of 4k bytes as base64 ciphertext. The cipher used to encrypt metadata must be the same as specified in the `m-encrypt-cipher` header.

```
m-encrypt-metadata: 2q2GrKPPcil6iaXXSImSn38cp+AVSZeQGaEp0+Wz+IWsYcC3B312cg7L5JI0HRK7Dvcurtsy7ccu=
```

#### `m-encrypt-metadata-iv`
Like `m-encrypt-iv` we store the IV for the ciphertext for the HTTP header `m-encrypt-metadata`.

```
m-encrypt-metadata-iv: MDEyMzQ1Njc4OTAxMjQ1Cg
```

#### `m-encrypt-metadata-hmac`
A cryptographic checksum of the ciphertext for the encrypted headers is stored in this header so that ciphertext can be authenticated.
This prevents classes of attacks that involve tricky changes to the ciphertext binary file. This header must not be used for AEAD ciphers.
The [hash-based message authentication (HMAC)](https://en.wikipedia.org/wiki/Hash-based_message_authentication_code) value must use the
same algorithm as specified in the `m-encrypt-hmac-type` header. The value of the HMAC must be stored in base64 encoding.

```
m-encrypt-metadata-hmac: YTk0ODkwNGYyZjBmNDc5YjhmODE5NzY5NGIzMDE4NGIwZDJlZDFjMWNkMmExZWMwZmI4NWQyOTlhMTkyYTQ0NyAgLQo=
```

#### `m-encrypt-metadata-aead-tag-length`
Like `m-encrypt-aead-tag-length` we store the AEAD tag length in bytes for the HTTP header `m-encrypt-metadata` so that we can verify the
authenticity of the header ciphertext. Note: This header is not used for non-AEAD ciphers.

```
m-encrypt-metadata-aead-tag-length: 16
```

### Supported Ciphers

We've identified the ciphers in the table below as the best candidates for streamable encryption. SDKs implementing client-side
encryption must make their best effort to support all of these ciphers.

| Name / Identifier       | Block Size Bytes | IV Length Bytes | Tag Length Bytes | Max Plaintext Size Bytes | AEAD  |
|-------------------------|------------------|-----------------|------------------|--------------------------|-------|
| AES128/GCM/NoPadding    | 16               | 16              | 16               | 68719476704              | true  |
| AES192/GCM/NoPadding    | 16               | 16              | 16               | 68719476704              | true  |
| AES256/GCM/NoPadding    | 16               | 16              | 16               | 68719476704              | true  |
| AES128/CTR/NoPadding    | 16               | 16              | N/A              | unlimited                | false |
| AES192/CTR/NoPadding    | 16               | 16              | N/A              | unlimited                | false |
| AES256/CTR/NoPadding    | 16               | 16              | N/A              | unlimited                | false |
| AES128/CBC/PKCS5Padding | 16               | 16              | N/A              | unlimited                | false |
| AES192/CBC/PKCS5Padding | 16               | 16              | N/A              | unlimited                | false |
| AES256/CBC/PKCS5Padding | 16               | 16              | N/A              | unlimited                | false |

### Cryptographic Authentication Modes

Depending on the threat model determined by the consumer of the client SDK, different modes of authentication of the ciphertext would be
desirable. If the consumer trusts the object store provider, then enabling a mode that skips authentication when it prevents an operation
from operating efficiently makes sense. One example of an operation that would not work in an authenticated mode would be random reads
(e.g. HTTP range requests). With security in mind, the client SDK must operate by default in a fully authenticated mode unless explicitly
disabled. Thus, consumers of SDKs supporting client-side encryption would be able to choose between one of two modes:

 * `MandatoryAuthentication` (default)
 * `OptionalAuthentication`

We only provide two modes unlike S3 which provides three modes (`EncryptionOnly`, `AuthenticatedEncryption`, and `StrictAuthenticatedEncryption`). `EncryptionOnly` mode in S3 does not authenticate ciphertext at all, `AuthenticatedEncryption` authenticates ciphertext when it is possible with the operation being performed and `StrictAuthenticatedEncryption` always authenticates and will cause an exception to be thrown if the operation can't be performed with authentication.   

### Authentication with AEAD Ciphers

If a AEAD cipher is used, we allow the AEAD algorithm's implementation to perform authentication of the ciphertext. Sometimes, this will
take extra care to do in client implementations because it involves reading the entire stream before it is authenticated. Thus, random
reads will not be authenticated and must only be done in `OptionalAuthentication` mode.

Additionally, AEAD ciphers allow for *associated data* / *additional data* to be stored. However, in this implementation associated data
must not be stored. The only data stored outside of the actual cipher text must be the [authentication tag](https://tools.ietf.org/html/rfc5116#section-5.1).
The authentication tag must also be appended to the end of the ciphertext in binary form.

### Authentication with Non-AEAD Ciphers

If a non-AEAD cipher is used, we calculate a HMAC value of the IV and ciphertext and append the HMAC in binary form to the
end of the binary ciphertext (file) uploaded to Manta. We append to the end of the blob in order to avoid having to add it has a
HTTP header as part of a separate operation. This allows us to do a PUT as a single operation.
All HMACs are signed with the same secret key being used for encryption and are not salted.

Essentially, generation of the HMAC is done in the following steps:

1. Choose the HMAC algorithm and associated secret key.
2. Update HMAC value with IV associated with ciphertext.
3. Update HMAC value with ciphertext.
4. Calculate the HMAC digest in binary and write it to the end of the binary blob after the ciphertext.


### Key Management

Initially, there will be no support server-side for key management. All key management will need to be done by the implementer of the SDK.
The default key format and location will be standardized across all implementations of Manta client-side encryption in their respective SDKs.

S3 provides a Key Management Service (KMS), and the design of any similar service is beyond the scope of this RFD.


### Key Format

Secret keys must be stored and read in the ASN.1 encoding of a public key, encoded according to the ASN.1 type `SubjectPublicKeyInfo`.
The `SubjectPublicKeyInfo` syntax is defined in the [X509 standard as follows](https://tools.ietf.org/html/rfc5280#section-4.1):

```
 SubjectPublicKeyInfo ::= SEQUENCE {
   algorithm AlgorithmIdentifier,
   subjectPublicKey BIT STRING }
```

### Metadata Support

Encrypted metadata will be supported by serializing to a key value data structure that is compatible with [RFC 2616](https://www.w3.org/Protocols/rfc2616/rfc2616-sec14.html).
This data structure is as follows:

```
e-key_1: value_1
e-key_2: value_2
e-key_3: value_3
```

All text must be encoded in US-ASCII using only printable characters (between codepoints 32 and 126 inclusive). Keys must be prefixed with the
string "e-" and must not contain spaces. Values may contain a semi-colon and spaces. Unlike RFC 2616 HTTP headers, keys cannot be duplicated.
Furthermore, values are handled as-is and there will be no value sub-field parsing required in the implementation.

Encrypted metadata not beginning with the prefix "e-" must result in an error.

The plaintext data structure described above will be encrypted and converted to base64 encoding. This will be stored as metadata on the
object via the HTTP header `m-encrypt-metadata`.

SDK implementations must store `Content-Type` headers in the encrypted metadata coded with the key `e-content-type`. If possible, the
`e-content-type` value can be read and passed on to the consumer of the SDK as the original `Content-Type` header in order to preserve
the same abstraction between encrypted usage and unencrypted usage.

### Content-Type

Encrypted files must be stored with a `Content-Type` header value of `application/octet-stream`.

### Content-Length

SDKs may overwrite the value of `Content-Length` returned from the client API with the value of `m-encrypt-plaintext-content-length`.

### Future considerations

Ideally, our client-side encryption implementation must be designed such that when we build server-side encryption support customers can
seamlessly migrate between schemes. This can be possible if we have consistent headers/metadata for identifying ciphers, MAC, IV and key ids.

### Limitations

***Your data on Manta with client-side encryption is only as strong as the security of your instances that host the encryption keys.***

Encryption is only as secure as your keys. Since client-side encryption does not handle any form of key management, a large part of security is left up to the implementer of the SDK. For example, if you are running an application that uses the SDK in the same datacenter as Manta and storing your keys in one of your instances, you effectively have the same level of security as not having any encryption if you do not trust the operators of the data center. The only benefit encryption would provide would be an assurance that the data stored was unavailable when the Manta hard disks were disposed of.

In contrast to the scenario above, if your keys were protected by an [HSM](https://en.wikipedia.org/wiki/Hardware_security_module) in a secure datacenter (that you trust) that is separate from Manta (which you don't trust), the benefits of client-side encryption would be realized because your keys could have a different threat profile than Manta itself.

## 2. Java Manta SDK Client-side Encryption Design and Implementation

Client-side encryption within the Java Manta SDK must be implemented as an optional operation that wraps streams going to and from Manta.
Client-side encryption will be enabled using configuration, and from an API consumer's perspective, there will not be a change in the API.
When operations are not supported by the encryption settings, then appropriate exceptions must be thrown indicating the conflict between
the setting and the operation. An example of this would be an attempt to use a HTTP range operation when `MandatoryAuthentication` is enabled. Furthermore, care will need to be taken to allow for operations that are retriable to continue to be retriable - such as sending [File](https://docs.oracle.com/javase/8/docs/api/java/io/File.html) objects.   

### Cipher Selection and Library Support

The JVM implementation of client-side encryption relies on the encryption algorithms and ciphers as provided as part of the running JVM's implementation of the Java Cryptography Extension (JCE)](https://en.wikipedia.org/wiki/Java_Cryptography_Extension). Thus, users of client-side encryption are assumed to trust the security of the JCE implementation in the JVM that they choose to run.

In the Oracle JDK, there is limited default support for strong encryption algorithms. To enable stronger encryption, you must download and install the [Java Cryptography Extension (JCE) Unlimited Strength Jurisdiction Policy Files](http://www.oracle.com/technetwork/java/javase/downloads/jce8-download-2133166.html). This isn't an issue with the OpenJDK. Also, strong encryption algorithms are supported using the [JCE API](https://en.wikipedia.org/wiki/Java_Cryptography_Extension) by [The Legion of the Bouncy Castle](http://www.bouncycastle.org/java.html) project.

We will also support algorithms supplied by Bouncy Castle and the Java runtime via the [JCE API](http://docs.oracle.com/javase/8/docs/technotes/guides/security/crypto/CryptoSpec.html). The Java Manta SDK currently bundles Bouncy Castle dependencies because they are used when doing [authentication via HTTP signed requests](https://github.com/joyent/java-http-signature).

### Configuration

All settings related to client-side encryption will be defined as part of the Java Manta SDK's
[ConfigContext](https://github.com/joyent/java-manta/blob/master/java-manta-client/src/main/java/com/joyent/manta/config/ConfigContext.java)
interface. This allows for the Java Manta SDK to be easily integrated into other libraries'
configuration systems. The following configuration settings will be added to the Java Manta SDK:

```java
    /**
     * @return true when client-side encryption is enabled.
     */
    Boolean isClientEncryptionEnabled();

    /**
     * @return true when downloading unencrypted files is allowed in encryption mode
     */
    Boolean permitUnencryptedDownloads();

    /**
     * @return specifies if we are in strict ciphertext authentication mode or not
     */
    EncryptionAuthenticationMode getEncryptionAuthenticationMode();

    /**
     * A plain-text identifier for the encryption key used. It doesn't contain
     * whitespace and is encoded in US-ASCII. The value of this setting has
     * no current functional impact.
     *
     * @return the unique identifier of the key used for encryption
     */
    String getEncryptionKeyId();

    /**
     * Gets the algorithm name in the format of <code>cipher/mode/padding state</code>.
     *
     * @return the name of the algorithm used to encrypt and decrypt
     */
    String getEncryptionAlgorithm();

    /**
     * @return path to the private encryption key on the filesystem (can't be used if private key bytes is not null)
     */
    String getEncryptionPrivateKeyPath();

    /**
     * @return private encryption key data (can't be used if private key path is not null)
     */
    byte[] getEncryptionPrivateKeyBytes();
```

### Headers

The additional headers specifying in [HTTP Headers Used with Client-side Encryption](HTTP-Headers-Used-with-Client-side-Encryption) would be added as properties of the
[`com.joyent.manta.http.MantaHttpHeaders`](https://github.com/joyent/java-manta/blob/master/java-manta-client/src/main/java/com/joyent/manta/http/MantaHttpHeaders.java) class.
These properties would be set without intervention from the implementer of the SDK in
the specific implementation of [`com.joyent.manta.http.HttpHelper`](https://github.com/joyent/java-manta/blob/master/java-manta-client/src/main/java/com/joyent/manta/http/HttpHelper.java) by the uploading logic.

### Thread-safety

All operations within the Java Manta SDK *should* be currently thread-safe. Any client-encryption implementation will need to also be thread-safe because consumers of the SDK are assuming thread safety.

### Stream Support

In order to encrypt Java streams, it is desirable to create a wrapping stream that allows for setting an encryption algorithm and multipart settings. This approach is similar to how the S3 SDK handles encrypting streams in the `com.amazonaws.services.s3.internal.crypto.CipherLiteInputStream` class. Using a wrapping stream allows the implementer of the SDK to provide their own streams in the same way for encrypted operations as unencrypted operations. Moreover, it allows us to easily control specific multipart behaviors and the opening and closing of potentially thread-unsafe resources used for encryption.   

### File Support

Currently, when we send a file to Manta via the SDK, we create an instance of `org.apache.http.entity.FileEntity` that has a reference to the `java.io.File` instance passed to its constructor. This allows the put operation to Manta to be retriable. When we add client-side encryption support, we will need to encrypt the file on the filesystem and write it to a temporary file and then reference that (the temporary file) when creating a new `FileContent` instance. This will preserve the retryability settings so that it behaves in the same manner as the unencrypted API call.

### HTTP Range / Random Read Support

Authenticating ciphertext and decrypting random sections of ciphertext can't be done as one operation without reading the entirety of the ciphertext. This mode of operation is inefficient when a consumer of an object store wants to read randomly from an object that is stored using client-side encryption because it would require them to download the entire object and authenticate it before decrypting the random section. Thus, we will only allow HTTP range requests to be performed when `EncryptionAuthenticationMode` is set to `Optional`. In those cases, the server-side content-md5 could still be compared to a record that the client keeps for additional security. However, it would not be bulletproof because the server could still send differing binary data to the client for the range and that binary data could not be authenticated. In the end, this mode of operation requires trusting the provider.

When reading randomly from a remote object in ciphertext, the byte range of the plaintext object does not match the byte range of the cipher text object. Any implementation would need to provide a cipher-aware translation of byte-ranges. Moreover, some ciphers do not support random reads at all. In those cases, we want to throw an exception to inform the implementer that the operation is not possible.

In the S3 SDK, range requests are supported by finding the cipher's lower and upper block bounds and adjusting the range accordingly. An example of this operation can be found in `com.amazonaws.services.s3.internal.crypto.S3CryptoModuleBase`. We will likewise need to do a similar operation. Furthermore, we will need to rewrite the range header when it is specified in [`com.joyent.manta.client.HttpHelper`](https://github.com/joyent/java-manta/blob/master/java-manta-client/src/main/java/com/joyent/manta/http/HttpHelper.java) and client-side encryption is enabled.  

#### Random Operation Support with [`MantaSeekableByteChannel`](https://github.com/joyent/java-manta/blob/master/java-manta-client/src/main/java/com/joyent/manta/client/MantaSeekableByteChannel.java)

We will need to refactor [`MantaSeekableByteChannel`](https://github.com/joyent/java-manta/blob/master/java-manta-client/src/main/java/com/joyent/manta/client/MantaSeekableByteChannel.java) so that it uses the methods provided in [`com.joyent.manta.client.HttpHelper`](https://github.com/joyent/java-manta/blob/master/java-manta-client/src/main/java/com/joyent/manta/http/HttpHelper.java) to do ranged `GET` operations so that we do not have to duplicate our ciphertext range translation code.  

### Multipart Support

See [RFD 65](https://github.com/joyent/rfd/blob/master/rfd/0065/README.md) for general information on multipart upload (MPU).

The Manta MPU allows parts to be uploaded concurrently and in any order.  To avoid significant cryptographic complexity
(requiring a block cipher mode of operation that can safely be used in parallel), the SDK constraints multipart uploads
with client side encryption to be done in serial and in order. (The S3 SDK imposes the same constraint.)

In general the SDK will:
 * Calculate the relevant metadata (ie `m-encrypt-key-id`), including any encrypted metadata
 * Create a new MPU with the metadata
 * Upload parts (including final padding and HMAC if needed) until complete
 * Commit

If the content length is known ahead of time (the upload is a local file and not an unbound stream),
then `m-encrypt-plaintext-content-length` is among the metadata set when the MPU is created.
Otherwise this optional header is omitted.

### Metadata Support

Encrypted metadata will be settable via the `MantaMetadata` class by setting metadata keys that are prefixed with `e-`.

### Failure Handling

A number of new `RuntimeException` classes will need to be created that map to the different encryption failure modes. These classes will
represent states such as invalid keys, invalid ciphertext and ciphertext authentication failures.

Furthermore, the SDK should be smart enough to handle downloads when an object is not encrypted and the `PermitUnencryptedDownloads`
flag is set to `true`.

The following new classes will be added to support client-side encryption:

```java
class MantaEncryptionException extends MantaException
class MantaClientEncryptionException extends MantaEncryptionException
class MantaClientEncryptionCiphertextAuthenticationException extends MantaClientEncryptionException
```

#### Key Failures

Private key format failures should be detected upon startup of the SDK and cause an exception to be thrown. This allows for the early
alerting to implementers of the SDK of any problems in their key configuration.

#### Decryption Failures

Failures due to problems decoding the ciphertext will be pushed up the stack from the underlying JCE implementation. We need to be
careful to preserve such exceptions and to wrap them with our own exception types that provide additional context that allows for
ease in debugging.

## 3. Node.js SDK Design and Implementation

### Assumptions

- Key management is beyond the scope of this work. Therefore, this solution should not depend on a particular key management choice.
- There shouldn't be any server-side changes needed to make this solution work.
- Files uploaded and encrypted using the Node.js Manta client should support being decrypted/verified using other clients (Java).
- The Manta SDK for Node.js lowercases the header keys, therefore, assume that the `m-*` headers are all lowercase


### Limitations

- GCM is the only supported authentication encryption cipher supported by Node.js: https://nodejs.org/api/crypto.html#crypto_cipher_setaad_buffer
- The `chattr` Manta SDK function will not auto-encrypt metadata headers set on the `m-encrypt-metadata` header location
- The `info` Manta SDK function will not auto-decrypt metadata headers

### Prototype

A working prototype that is built on top of the existing Manta SDK for Node.js is available at https://cr.joyent.us/#/c/1110/


### API

The Manta client will support setting default values for the various encryption options. This will allow for client instances to be created for specific cipher algorithms and for specific key storage locations.

#### `get(path, options, callback)`

Update the existing `get` function with support for retrieving encrypted objects, validating their integrity, and passing the decrypted version to the developer. The `options` object will be updated to expect a property named `getKey` that will be a function that will be executed to get the secret key used to encrypt the object stored at `path`. `getKey` is only required when retrieving an encrypted object.

##### Potential Failures to Consider

Below are possible scenarios/failures to consider

1. `m-encrypt-type` doesn't exist or doesn't have the value `'client/VERSION'`, in which case the object is assumed not to be encrypted, and the usual processing of the file occurs, without decryption. In the event that the version isn't supported by the client, it should not try to decrypt the file and should return the encrypted form of the file.
1. `m-encrypt-cipher` is set to an algorithm that isn't supported by Node.js, in which case an error should be returned in the callback
1. `m-encrypt-key-id` isn't found by the `getKey` function or an error is returned on the callback. In this scenario, the error will be forwarded to the callback function.
1. `getKey` doesn't exist and `m-encrypt-type` is set to `'client'`, this will result in an error being passed to the callback.
1. Required header information is missing from the object stored in Manta. This results in an error passed to the callback.
1. The stored HMAC doesn't match the calculated HMAC of the IV + decrypted object. This results in an error passed to the callback.

##### Logical Workflow

Below are the steps that will take place inside of `get` when encountering an encrypted object

1. Detect if an object is encrypted by checking if the `m-encrypt-type` header is set to `'client/VERSION'` Initially, this will be `client/1`
1. Validate the required encryption headers are stored with the object
1. Retrieve the secret key using the `m-encrypt-key-id` value and `getKey` function passed to the option object
1. Decrypt the object using the `m-encrypt-iv`, the key retrieved from `getKey()` and the cipher specified in `m-encrypt-cipher`
1. Calculate the HMAC using the specified algorithm with the key from getKey() using the IV + decrypted object
1. Verify that the calculated HMAC matches the stored value
1. Verify that the object byte size matches the stored `m-encrypt-original-content-length`
1. Decrypt and validate any encrypted metadata headers
1. Pass the decrypted object to the callback function as a stream and the response object decorated with the decrypted metadata headers

##### Usage example

```js
'use strict';

const Fs = require('fs');
const Manta = require('manta');
const Vault = require('node-vault');

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

const client = Manta.createClient({
    sign: Manta.privateKeySigner({
        key: Fs.readFileSync(process.env.HOME + '/.ssh/id_rsa', 'utf8'),
        keyId: process.env.MANTA_KEY_ID,
        user: process.env.MANTA_USER
    }),
    user: process.env.MANTA_USER,
    url: process.env.MANTA_URL,
    encrypt: {
        getKey
    }
});


client.get('~~/stor/encrypted', (err, stream, res) => {
  if (err) {
    console.error(err);
    process.exit(1);
  }

  stream.pipe(process.stdout);
  console.log('\n');
});
```

#### `put(path, input, options, callback)`

Upload an object to Manta and optionally encrypt it using the cipher details provided. When encryption occurs, additional `m-*` headers will be saved along with the object.


##### Logical Workflow

Below are the steps that should take place when encrypting an object.

1. Check that encryption should take place
1. Assert that all required options are present for encryption: `key`, `keyId`, `cipher`. `cipher` should use the alg/width/padding structure
1. Assert that the provided `cipher` algorithm is valid and supported by the platform
1. Generate an Initialization Vector (IV)
1. Create a HMAC instance using the `key` and specified `hmacType`.
1. Calculate the HMAC using the IV and input stream
1. Calculate the cipher from the input stream and IV
1. Set the `m-encrypt-type` header to `'client/VERSION'`
1. Set the `m-encrypt-key-id` header sent to Manta using the `options.keyId`
1. Set the `m-encrypt-iv` header to the IV value encoded as base64
1. Set the `m-encrypt-cipher` header to the `options.cipher`
1. Set the `e-content-type` header and update the request HTTP header for `Content-Type` to `application/octet-stream`
1. Append the HMAC digest to the stream being uploaded
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
const options = {
  encrypt: {
    key: 'FFFFFFFBD96783C6C91E2222',
    keyId: 'dev/test',
    cipher: 'AES256/CTR/NoPadding',
    hmacType: 'HmacSHA256'
  },
  headers: {
    'e-key': 'secret'
  }
};

client.put('~~/stor/encrypted', file, options, (err, res) => {
  if (err) {
    console.error(err);
    process.exit(1);
  }
});
```
