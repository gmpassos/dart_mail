import 'dart:io';

import 'package:dart_mail/dns_resolver.dart';
import 'package:dart_mail/email_delivery_client.dart';
import 'package:dart_mail/imap_server.dart';
import 'package:dart_mail/smtp_server.dart';

void main() async {
  // In-memory users and credentials (demo / development / tests only)
  final authProvider = MapAuthProvider({
    'alice@example.com': 'password123',
    'bob@example.com': 'secret',
  });

  // Central mailbox storage:
  // - SMTP writes incoming messages
  // - IMAP exposes stored messages to clients
  final mailboxStore = InMemoryMailboxStore(authProvider);

  // DNS-over-HTTPS resolver used to fetch MX records
  // (replace or customize for production environments)
  final dnsResolver = DNSOverHttpsResolver.google();

  // SMTP delivery client used to relay emails to external domains
  final emailDeliveryClient = SMTPEmailDeliveryClient(
    hostname: 'localhost',
    dnsResolver: dnsResolver,
  );

  // TLS configuration for SMTP, IMAP, and IMAPS
  // Supports self-signed certificates for local testing
  final securityContext = SecurityContext()
    ..useCertificateChain('certs/localhost.pem')
    ..usePrivateKey('certs/localhost.key');

  // SMTP server:
  // - Accepts authenticated mail
  // - Stores local messages
  // - Relays remote messages using MX lookup
  final smtpServer = SMTPServer(
    hostname: '0.0.0.0',
    port: 2525,
    securityContext: securityContext,
    authProvider: authProvider,
    mailboxStore: mailboxStore,
    dnsResolver: dnsResolver,
    emailDeliveryClient: emailDeliveryClient,
  );

  // IMAP server:
  // - Plain IMAP with STARTTLS
  // - Encrypted IMAPS
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

  print('SMTP server listening on port 2525');
  print('IMAP server listening on port 1143 (STARTTLS)');
  print('IMAPS server listening on port 1993');

  // Handle Ctrl+C for clean shutdown
  ProcessSignal.sigint.watch().listen((_) async {
    await smtpServer.close();
    await imapServer.close();
    exit(0);
  });
}
