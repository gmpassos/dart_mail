import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:logging/logging.dart' as logging;

import 'auth_provider.dart';
import 'dns_resolver.dart';
import 'email_delivery_client.dart';
import 'mailbox_store.dart';

final _log = logging.Logger('SMTPServer');

/// Pure Dart SMTP Server.
class SMTPServer {
  final int port;
  final String hostname;
  final SecurityContext securityContext;
  final AuthProvider authProvider;
  final MailboxStore mailboxStore;
  final EmailDeliveryClient emailDeliveryClient;

  SMTPServer({
    this.port = 25,
    required this.hostname,
    required this.securityContext,
    required this.authProvider,
    required this.mailboxStore,
    DNSResolver? dnsResolver,
    EmailDeliveryClient? emailDeliveryClient,
  }) : emailDeliveryClient =
           emailDeliveryClient ??
           SMTPEmailDeliveryClient(
             hostname: hostname,
             dnsResolver: dnsResolver ?? DNSOverHttpsResolver.google(),
           );

  ServerSocket? _server;

  Future<void> start() async {
    final ServerSocket server = _server = await ServerSocket.bind(
      InternetAddress.anyIPv4,
      port,
    );

    _log.info("SMTP Server listening on port: $port");

    server.listen(_onAccept);
  }

  void _onAccept(Socket socket) {
    var clientHandler = _SMTPClientHandler(
      serverPort: port,
      socket: socket,
      hostname: hostname,
      securityContext: securityContext,
      authProvider: authProvider,
      mailBoxStore: mailboxStore,
      emailDeliveryClient: emailDeliveryClient,
    );

    _log.info(
      "SMTP Server[$port] accepted Socket: ${clientHandler.remoteAddress.address}:${clientHandler.remotePort}",
    );

    clientHandler.handle();
  }

  Future<void> close() async => await _server?.close();
}

class _SMTPClientHandler {
  final int serverPort;

  Socket socket;
  bool _closed = false;
  Object? _error;

  final String hostname;
  final SecurityContext securityContext;
  final AuthProvider authProvider;
  final MailboxStore mailBoxStore;
  final EmailDeliveryClient emailDeliveryClient;

  bool tls = false;
  bool auth = false;
  String? authUser;

  String? mailFrom;
  bool? mailFromLocalAccount;

  final rcpt = <String>[];
  final data = StringBuffer();
  bool inData = false;

  StreamSubscription? subscription;
  late void Function(String) send;

  late final InternetAddress remoteAddress;
  late final int remotePort;

  _SMTPClientHandler({
    required this.serverPort,
    required this.socket,
    required this.hostname,
    required this.securityContext,
    required this.authProvider,
    required this.mailBoxStore,
    required this.emailDeliveryClient,
  }) {
    try {
      remoteAddress = socket.remoteAddress;
      remotePort = socket.remotePort;
    } catch (_) {}
  }

  String get info =>
      'SMTP[$serverPort]-Client[${remoteAddress.address}:$remotePort]';

  Future<void> handle() async {
    socket.write('220 $hostname ESMTP Ready\r\n');
    _bind(socket, false);
  }

  final List<String> _allLines = [];

  void _onLine(final String line) async {
    if (_closed) return;

    _allLines.add(line);

    // Read DATA lines:
    if (inData) {
      if (line == '.') {
        inData = false;
        await onReceiveEmail(from: mailFrom!, to: rcpt, body: data.toString());
        data.clear();
        send('250 OK');
      } else {
        data.writeln(line);
      }
      return;
    }

    // HELO
    if (line.startsWith('EHLO') || line.startsWith('HELO')) {
      send('250-$hostname');
      if (!tls) send('250-STARTTLS');
      send('250-AUTH LOGIN PLAIN');
      send('250 OK');
    }
    // STARTTLS
    else if (line == 'STARTTLS') {
      if (tls) {
        send('503 TLS already active');
        return;
      }
      send('220 Ready to start TLS');
      await _startTLS();
    }
    // QUIT
    else if (line == 'QUIT') {
      send('221 Bye');
      await socket.flush();
      Future.delayed(Duration(milliseconds: 10));
      _close();
    }
    // AUTH LOGIN
    else if (line.startsWith('AUTH LOGIN')) {
      if (!tls) {
        send('538 Encryption required');
        return;
      }
      send('334 VXNlcm5hbWU6');
    }
    // DATA:
    else if (line == 'DATA') {
      send('354 End with <CRLF>.<CRLF>');
      inData = true;
    }
    // AUTH: user
    else if (!auth && authUser == null && _isB64(line)) {
      final user = utf8.decode(base64.decode(line));
      if (!authProvider.hasUser(user)) {
        send('535 Auth failed');
        return;
      }
      authUser = user;
      send('334 UGFzc3dvcmQ6');
    }
    // AUTH: pass
    else if (authUser != null && !auth) {
      final pass = utf8.decode(base64.decode(line));
      if (authProvider.validate(authUser!, pass)) {
        auth = true;
        send('235 Auth OK');
        _log.info("$info User authenticated: $authUser");
      } else {
        send('535 Auth failed');
        _log.warning("$info User authenticated failed: $authUser");
      }
    }
    // AUTH PLAIN
    else if (line.startsWith('AUTH PLAIN')) {
      if (!tls) {
        send('538 Encryption required');
        return;
      }
      final p = utf8
          .decode(base64.decode(line.split(' ').last))
          .split('\u0000');
      if (authProvider.validate(p[1], p[2])) {
        auth = true;
        send('235 Auth OK');
        _log.info("$info User authenticated: $authUser");
      } else {
        send('535 Auth failed');
        _log.warning("$info User authenticated failed: $authUser");
      }
    } else if (line.startsWith('MAIL FROM:')) {
      mailFrom = _addr(line);
      mailFromLocalAccount = authProvider.hasUser(mailFrom!);

      // If it's a mensagem from a local account, should be authenticated:
      if (!auth && mailFromLocalAccount!) {
        send('530 Authentication required');
        return;
      }

      send('250 OK');
    }
    // RCPT TO
    else if (line.startsWith('RCPT TO:')) {
      final addr = _addr(line);

      // check if recipient exists:
      if (!authProvider.hasUser(addr)) {
        // If it's an external recipient, mail from should be local and authenticated:
        if (!auth || !(mailFromLocalAccount ?? false)) {
          send('530 Authentication required');
          return;
        }

        send('550 5.1.1 User unknown');
        rcpt.add(addr);
        return;
      }

      rcpt.add(addr);
      send('250 OK');
    }
    // NOT IMPLEMENTED:
    else {
      send('502 Not implemented');
    }
  }

  Future<void> _startTLS() async {
    _log.info("$info Upgrading to TLS...");
    subscription?.pause();
    final secure = await SecureSocket.secureServer(socket, securityContext);
    socket = secure;
    tls = true;
    _bind(secure, true);
    _log.info("$info Started TLS!");
  }

  void _bind(Socket socket, bool sec) {
    subscription = utf8.decoder
        .bind(socket)
        .transform(const LineSplitter()) // split by line
        .listen(_onLine, onDone: _onDone, onError: _onError);

    send = (v) {
      if (_closed) return;

      try {
        socket.write('$v\r\n');
      } catch (e) {
        _error ??= e;
      }
    };
  }

  void _onDone() {
    _closed = true;
  }

  void _onError(Object error, StackTrace stackTrace) {
    _closed = true;
    _error ??= error;
    _log.severe("Socker error> $error", error, stackTrace);
  }

  void _close() {
    _closed = true;
    subscription?.cancel();
    subscription = null;
    socket.destroy();
  }

  Future<void> onReceiveEmail({
    required String from,
    required List<String> to,
    required String body,
  }) async {
    final fromLocal = authProvider.hasUser(from);
    final localRecipients = authProvider.existingUsers(to);

    // Reject mail sent by a local address when:
    // - there are no local recipients AND
    // - the sender is not authenticated as the MAIL FROM user.
    // This prevents unauthenticated local users from using the server as a relay.
    if (fromLocal && localRecipients.isEmpty && (!auth || from != authUser)) {
      _log.warning(
        "$info Aborted e-mail, not authenticated> authUser: $authUser ; from: $from ; to: $to ; local: $localRecipients",
      );
      return;
    }

    _log.info(
      "$info Received e-mail> authUser: $authUser ; from: $from ; to: $to ; local: $localRecipients",
    );

    // Store the message for local recipients.
    // `mailBoxStore.store` persists only local mailboxes
    // and safely ignores any external addresses.
    if (localRecipients.isNotEmpty) {
      var deliveredTo = await mailBoxStore.store(
        from: from,
        to: to,
        body: body,
      );

      _log.info(
        "$info Stored e-mail> authUser: $authUser ; from: $from ; to: $to ; deliveredTo: $deliveredTo",
      );
    }

    // Relay mail only if:
    // - the sender is a local user
    // - the session is authenticated
    // - the authenticated user matches MAIL FROM
    //
    // `relayEmail` internally sends only to external recipients.
    if (fromLocal && auth && from == authUser) {
      final hasExternalRecipients = localRecipients.length < to.length;
      if (hasExternalRecipients) {
        var deliveredTo = await relayEmail(from: from, to: to, body: body);

        _log.info(
          "$info Relayed e-mail> authUser: $authUser ; from: $from ; to: $to ; deliveredTo: $deliveredTo",
        );
      }
    }
  }

  Future<List<String>> relayEmail({
    required String from,
    required List<String> to,
    required String body,
  }) async {
    var rcptByDomain = to.groupListsBy((e) => e.parseDomain);

    var deliveredTo = <String>[];

    for (var e in rcptByDomain.entries) {
      var domain = e.key;
      var recipients = e.value;
      if (domain == null) continue;

      var localRecipients = authProvider.existingUsers(recipients);
      var externalRecipients = recipients
          .whereNot((a) => localRecipients.contains(a))
          .toList();

      if (externalRecipients.isNotEmpty) {
        await emailDeliveryClient.sendEmail(
          domain: domain,
          from: from,
          recipients: externalRecipients,
          body: body,
        );

        deliveredTo.addAll(externalRecipients);
      }
    }

    return deliveredTo;
  }

  bool _isB64(String s) {
    try {
      base64.decode(s);
      return true;
    } catch (_) {
      return false;
    }
  }

  String _addr(String l) => l.substring(l.indexOf('<') + 1, l.indexOf('>'));
}

extension on String {
  String? get parseDomain {
    var idx = indexOf('@');
    if (idx < 0) return null;
    var domain = substring(idx + 1);
    return domain;
  }
}
