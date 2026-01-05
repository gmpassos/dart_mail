# dart_mail

[![pub package](https://img.shields.io/pub/v/dart_mail.svg?logo=dart\&logoColor=00b9fc)](https://pub.dev/packages/dart_mail)
[![Null Safety](https://img.shields.io/badge/null-safety-brightgreen)](https://dart.dev/null-safety)
[![GitHub Tag](https://img.shields.io/github/v/tag/gmpassos/dart_mail?logo=git\&logoColor=white)](https://github.com/gmpassos/dart_mail/releases)
[![Last Commit](https://img.shields.io/github/last-commit/gmpassos/dart_mail?logo=github\&logoColor=white)](https://github.com/gmpassos/dart_mail/commits/main)
[![License](https://img.shields.io/github/license/gmpassos/dart_mail?logo=open-source-initiative\&logoColor=green)](https://github.com/gmpassos/dart_mail/blob/main/LICENSE)

`dart_mail` is a **pure Dart email stack** implementing **SMTP, IMAP, DNS MX resolution, and email delivery**.

It allows you to **build a complete mail server or mail-enabled application** using Dart only — no external mail services required.

---

## Overview

`dart_mail` provides:

* 📤 SMTP server for receiving and relaying email
* 📥 IMAP server for mailbox access
* 🌐 DNS MX resolution for remote delivery
* 🗂️ Pluggable mailbox storage
* 🔐 Authentication abstraction
* 🔁 SMTP relay client for outbound delivery

Designed for **servers, self-hosted solutions, testing environments, and embedded email infrastructure**.

Add this note section to the README (fits best after **Overview** or **Requirements**):

---

## Cross-Platform

`dart_mail` runs on **any operating system supported by Dart**:

* Linux
* macOS
* Windows
* Docker
* Cloud runtimes

It has **no dependency on Linux-specific architectures or system services**, unlike traditional SMTP/IMAP servers (Postfix, Exim, Dovecot, Sendmail).

This makes `dart_mail` ideal for:

* Cross-platform development
* Local testing on macOS or Windows
* Containerized and embedded deployments
* Environments where installing or managing system mail servers is not desirable

All networking, TLS, DNS resolution, and protocol handling are implemented **entirely in Dart**.

---

## Features

* ✉️ Fully functional **SMTP server**

    * Authentication
    * Local delivery
    * Remote relay via MX lookup
* 📬 **IMAP & IMAPS servers**

    * STARTTLS and TLS support
* 🌍 **DNS-over-HTTPS MX resolution**
* 🔐 Pluggable authentication providers
* 🗄️ Swappable mailbox storage backends
* 🧪 Ideal for development, testing, and self-hosted setups
* ⚡ 100% Dart, no native dependencies

---

## Minimal Example

A complete **SMTP + IMAP** server using in-memory storage:

```dart
import 'dart:io';

import 'package:dart_mail/dns_resolver.dart';
import 'package:dart_mail/email_delivery_client.dart';
import 'package:dart_mail/imap_server.dart';
import 'package:dart_mail/smtp_server.dart';

void main() async {
  // Simple in-memory authentication
  final authProvider = MapAuthProvider({
    'alice@example.com': 'password123',
    'bob@example.com': 'secret',
  });

  // Shared mailbox storage
  final mailboxStore = InMemoryMailboxStore(authProvider);

  // DNS resolver for MX lookups
  final dnsResolver = DNSOverHttpsResolver.google();

  // SMTP client for relaying external emails
  final emailDeliveryClient = SMTPEmailDeliveryClient(
    hostname: 'localhost',
    dnsResolver: dnsResolver,
  );

  // TLS configuration
  final securityContext = SecurityContext()
    ..useCertificateChain('certs/localhost.pem')
    ..usePrivateKey('certs/localhost.key');

  // Start SMTP server
  final smtpServer = SMTPServer(
    hostname: '0.0.0.0',
    port: 2525,
    securityContext: securityContext,
    authProvider: authProvider,
    mailboxStore: mailboxStore,
    dnsResolver: dnsResolver,
    emailDeliveryClient: emailDeliveryClient,
  );

  // Start IMAP / IMAPS server
  final imapServer = IMAPServer(
    hostname: '0.0.0.0',
    mailboxStore: mailboxStore,
    authProvider: authProvider,
    securityContext: securityContext,
    imapPort: 1143,
    imapsPort: 1993,
  );

  await smtpServer.start();
  await imapServer.start();

  print('SMTP: 2525');
  print('IMAP: 1143 (STARTTLS)');
  print('IMAPS: 1993');

  // Graceful shutdown
  ProcessSignal.sigint.watch().listen((_) async {
    await smtpServer.close();
    await imapServer.close();
    exit(0);
  });
}
```

---

## Architecture

```
SMTP Client
   │
   ▼
SMTP Server ──► MailboxStore ◄── IMAP Server
   │
   └──► SMTP Relay ──► Remote MX Server
```

* **SMTP** writes messages
* **IMAP** reads messages
* **MailboxStore** is the shared persistence layer
* **SMTP relay** delivers messages to external domains

---

## Use Cases

* Self-hosted mail servers
* Local development mail infrastructure
* Integration tests (email-heavy systems)
* Custom email gateways
* Embedded mail services in Dart backends

---

## Requirements

* Dart 3.9+
* TLS certificates (self-signed supported)
* Open network ports for SMTP / IMAP

---

## Issues & Feature Requests

Please report issues and request features via the
[issue tracker][tracker].

[tracker]: https://github.com/gmpassos/dart_mail/issues

---

## Author

Graciliano M. Passos: [gmpassos@GitHub][github].

[github]: https://github.com/gmpassos

---

## License

Dart free & open-source [license](https://github.com/dart-lang/stagehand/blob/master/LICENSE).
