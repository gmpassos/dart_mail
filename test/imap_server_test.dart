import 'dart:io';

import 'package:dart_mail/imap_server.dart';
import 'package:test/test.dart';

import 'basic_client.dart';
import 'localhost_cert.dart';
import 'logging.dart';

void main() {
  safeZone().runGuarded(_runTets);
}

void _runTets() {
  logToConsole();

  final localhostSecurityContext = loadLocalhostSecurityContext();

  late IMAPServer server;
  late MapAuthProvider authProvider;
  late InMemoryMailboxStore mailboxStore;

  setUp(() async {
    authProvider = MapAuthProvider({'alice@example.com': 'password123'});
    mailboxStore = InMemoryMailboxStore(authProvider);

    server = IMAPServer(
      hostname: 'localhost',
      securityContext: localhostSecurityContext,
      mailboxStore: mailboxStore,
      authProvider: authProvider,
      imapPort: 1143,
      imapsPort: 1993,
    );

    await server.start();
  });

  tearDown(() async {
    await server.close();
  });

  test('IMAP greeting and CAPABILITY', () async {
    final socket = await Socket.connect('127.0.0.1', 1143);
    final client = BasicClient(socket);

    await client.expectLine((l) => l.any((e) => e.contains('IMAP4rev1 Ready')));

    client.send('a1 CAPABILITY');

    await client.expectLine((l) => l.any((e) => e.contains('* CAPABILITY')));
    await client.expectLine(
      (l) => l.any((e) => e.contains('CAPABILITY completed')),
    );

    client.close();
  });

  test('LOGIN requires STARTTLS on IMAP', () async {
    final socket = await Socket.connect('127.0.0.1', 1143);
    final client = BasicClient(socket);

    await client.expectLine((l) => l.any((e) => e.contains('Ready')));

    client.send('a1 LOGIN alice@example.com password123');

    await client.expectLine(
      (l) => l.any((e) => e.contains('STARTTLS required')),
    );

    client.close();
  });

  test('STARTTLS then LOGIN succeeds', () async {
    final socket = await Socket.connect('127.0.0.1', 1143);
    final client = BasicClient(socket);

    await client.expectLine((l) => l.any((e) => e.contains('Ready')));

    client.send('a1 STARTTLS');
    await client.expectLine(
      (l) => l.any((e) => e.contains('Begin TLS negotiation')),
    );

    await client.startTLS();

    client.send('a2 LOGIN alice@example.com password123');
    await client.expectLine((l) => l.any((e) => e.contains('LOGIN completed')));

    client.send('a1 LOGOUT');

    await client.expectLine((l) => l.any((e) => e.contains('BYE')));
    await client.expectLine(
      (l) => l.any((e) => e.contains('LOGOUT completed')),
    );

    client.close();
  });

  test('IMAPS LOGIN, SELECT, UID SEARCH', () async {
    final socket = await SecureSocket.connect(
      '127.0.0.1',
      1993,
      onBadCertificate: (_) => true,
    );
    final client = BasicClient(socket);

    await client.expectLine((l) => l.any((e) => e.contains('Ready')));

    client.send('a1 LOGIN alice@example.com password123');
    await client.expectLine((l) => l.any((e) => e.contains('LOGIN completed')));

    client.send('a2 SELECT INBOX');
    await client.expectLine((l) => l.any((e) => e.contains('EXISTS')));
    await client.expectLine(
      (l) => l.any((e) => e.contains('SELECT completed')),
    );

    client.send('a3 UID SEARCH ALL');
    await client.expectLine((l) => l.any((e) => e.contains('* SEARCH')));
    await client.expectLine(
      (l) => l.any((e) => e.contains('SEARCH completed')),
    );

    client.close();
  });

  test('LOGOUT closes connection', () async {
    final socket = await Socket.connect('127.0.0.1', 1143);
    final client = BasicClient(socket);

    await client.expectLine((l) => l.any((e) => e.contains('Ready')));

    client.send('a1 LOGOUT');

    await client.expectLine((l) => l.any((e) => e.contains('BYE')));
    await client.expectLine(
      (l) => l.any((e) => e.contains('LOGOUT completed')),
    );

    client.close();
  });
}
