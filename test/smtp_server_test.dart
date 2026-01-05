import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_mail/smtp_server.dart';
import 'package:dart_mail/src/dns_resolver.dart';
import 'package:dart_mail/src/email_delivery_client.dart';
import 'package:mailer/mailer.dart';
import 'package:mailer/smtp_server.dart';
import 'package:test/test.dart';

import 'basic_client.dart';
import 'localhost_cert.dart';
import 'logging.dart';

void main() async {
  logToConsole();

  final localhostSecurityContext = loadLocalhostSecurityContext();

  final otherMXPort = 2025; // use high port to avoid permission issues
  final SMTPServer otherMXServer;
  final InMemoryMailboxStore otherMailboxStore;
  {
    var authProvider = MapAuthProvider({'bob@example2.com': 'password123'});
    otherMailboxStore = InMemoryMailboxStore(authProvider);
    var dnsResolver = _LocalDNSResolver();

    // Create server without TLS for testing
    otherMXServer = SMTPServer(
      port: otherMXPort,
      hostname: 'localhost',
      securityContext: localhostSecurityContext,
      authProvider: authProvider,
      mailboxStore: otherMailboxStore,
      dnsResolver: dnsResolver,
    );

    await otherMXServer.start();
  }

  group('SMTPServer integration test + relay (basic client)', () {
    late InMemoryMailboxStore mailboxStore;
    late MapAuthProvider authProvider;
    late DNSResolver dnsResolver;
    late EmailDeliveryClient emailDeliveryClient;
    late SMTPServer server;
    late int port;

    setUp(() async {
      port = 2525; // use high port to avoid permission issues
      authProvider = MapAuthProvider({'alice@example.com': 'password123'});
      mailboxStore = InMemoryMailboxStore(authProvider);
      dnsResolver = _LocalDNSResolver();
      emailDeliveryClient = SMTPEmailDeliveryClient(
        hostname: 'localhost',
        dnsResolver: dnsResolver,
        mxServerPort: otherMXPort,
      );

      // Create server without TLS for testing
      server = SMTPServer(
        port: port,
        hostname: 'localhost',
        securityContext: localhostSecurityContext,
        authProvider: authProvider,
        mailboxStore: mailboxStore,
        dnsResolver: dnsResolver,
        emailDeliveryClient: emailDeliveryClient,
      );

      await server.start();

      // Wait a moment for server to start
      await Future.delayed(Duration(milliseconds: 50));
    });

    tearDown(() async {
      await server.close();
    });

    test('send email via SMTPServer', () async {
      final socket = await Socket.connect('localhost', port);
      final client = BasicClient(socket);

      await client.expectLine(
        (l) => l.join('\n').contains('220 localhost ESMTP Ready'),
      );

      client.send('EHLO client');
      await client.expectLine((l) => l.join('\n').contains('\n250 OK'));

      client.send('STARTTLS');
      await client.expectLine(
        (l) => l.join('\n').contains('\n220 Ready to start TLS'),
      );

      await client.startTLS();

      client.send('EHLO client');
      await client.expectLine(
        (l) => l
            .join('\n')
            .contains(
              '250-localhost\n'
              '250-AUTH LOGIN PLAIN\n'
              '250 OK',
            ),
      );

      client.send('AUTH LOGIN');
      client.send(base64.encode(utf8.encode('alice@example.com')));
      client.send(base64.encode(utf8.encode('password123')));

      await client.expectLine((l) => l.join('\n').contains('\n235 Auth OK'));

      client.send('MAIL FROM:<alice@example.com>');
      client.send('RCPT TO:<bob@example2.com>');
      client.send('DATA');

      await client.expectLine(
        (l) => l.join('\n').contains('\n354 End with <CRLF>.<CRLF>'),
      );

      client.send('Hello world via SMTPServer!');
      client.send('.');

      await client.expectLine(
        (l) => l.join('\n').contains('\n250 OK'),
        const Duration(seconds: 45),
      );

      client.send('QUIT');
      await Future.delayed(const Duration(milliseconds: 100));
      client.close();

      expect(otherMailboxStore.countMessagesUIDs('bob@example2.com'), 1);
      final message = otherMailboxStore.getMessage('bob@example2.com', '0');
      expect(message, contains('Hello world via SMTPServer!'));

      expect(client.lines.any((l) => l.contains('220')), isTrue);
      expect(client.lines.any((l) => l.contains('235 Auth OK')), isTrue);
      expect(client.lines.any((l) => l.contains('250 OK')), isTrue);
      expect(
        client.lines.any((l) => l.contains('354 End with <CRLF>.<CRLF>')),
        isTrue,
      );
      expect(client.lines.last.contains('221 Bye'), isTrue);
    });
  });

  group('SMTPServer integration test (mailer client)', () {
    late InMemoryMailboxStore mailboxStore;
    late MapAuthProvider authProvider;
    late DNSResolver dnsResolver;
    late EmailDeliveryClient emailDeliveryClient;
    late SMTPServer server;
    late int port;

    setUp(() async {
      port = 2526; // high port
      authProvider = MapAuthProvider({
        'alice@example.com': 'password123',
        'bob@example.com': 'secret',
      });
      mailboxStore = InMemoryMailboxStore(authProvider);
      dnsResolver = _LocalDNSResolver();
      emailDeliveryClient = SMTPEmailDeliveryClient(
        hostname: 'localhost',
        dnsResolver: dnsResolver,
        mxServerPort: otherMXPort,
      );

      server = SMTPServer(
        port: port,
        hostname: 'localhost',
        securityContext: localhostSecurityContext,
        authProvider: authProvider,
        mailboxStore: mailboxStore,
        dnsResolver: dnsResolver,
        emailDeliveryClient: emailDeliveryClient,
      );

      // Start server
      await server.start();
      await Future.delayed(Duration(milliseconds: 100));
    });

    tearDown(() async {
      await server.close();
    });

    test('send email via mailer package', () async {
      // Configure mailer SMTP server
      final smtpServer = SmtpServer(
        'localhost',
        port: port,
        ssl: false,
        ignoreBadCertificate: true,
        username: 'alice@example.com',
        password: 'password123',
      );

      // Compose message
      final message = Message()
        ..from = Address('alice@example.com', 'Alice')
        ..recipients.add('bob@example.com')
        ..subject = 'Test Email'
        ..text = 'Hello Bob via mailer!';

      // Send email
      final sendReport = await send(message, smtpServer);

      // Check that message is stored in memory
      expect(mailboxStore.countMessagesUIDs('bob@example.com'), 1);
      final stored = mailboxStore.getMessage('bob@example.com', '0');
      expect(stored, contains('SGVsbG8gQm9iIHZpYSBtYWlsZXIhDQo='));

      // Check that send report shows success
      expect(sendReport, isNotNull);
    });
  });
}

/// Forces any MX resolution to localhost:
class _LocalDNSResolver extends DNSResolver {
  @override
  Future<List<MXRecord>> resolveMX(String domain) async {
    return [MXRecord(0, InternetAddress.loopbackIPv4)];
  }
}
