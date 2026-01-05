import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart' as logging;

import 'auth_provider.dart';
import 'mailbox_store.dart';

final _log = logging.Logger('IMAPServer');

class IMAPServer {
  final String hostname;
  final SecurityContext securityContext;
  final MailboxStore mailboxStore;
  final SMTPAuthProvider authProvider;

  final int imapsPort;
  final int imapPort;

  IMAPServer({
    required this.hostname,
    required this.securityContext,
    required this.mailboxStore,
    required this.authProvider,
    this.imapsPort = 993,
    this.imapPort = 143,
  });

  SecureServerSocket? _secureServer;
  ServerSocket? _server;

  Future<void> start() async {
    // IMAPS 993 (implicit TLS)
    var secureServer = _secureServer = await SecureServerSocket.bind(
      InternetAddress.anyIPv4,
      imapsPort,
      securityContext,
    );

    _log.info('IMAPS Server listening on port: $imapsPort');

    secureServer.listen((socket) {
      _IMAPClientHandler(
        serverPort: imapsPort,
        socket: socket,
        hostname: hostname,
        mailboxStore: mailboxStore,
        authProvider: authProvider,
        securityContext: securityContext,
        imaps: true,
      ).handle();
    });

    // IMAP 143 (plaintext + STARTTLS)
    var server = _server = await ServerSocket.bind(
      InternetAddress.anyIPv4,
      imapPort,
    );

    _log.info('IMAP Server listening on port: $imapPort');

    server.listen((socket) {
      _IMAPClientHandler(
        serverPort: imapPort,
        socket: socket,
        hostname: hostname,
        mailboxStore: mailboxStore,
        authProvider: authProvider,
        securityContext: securityContext,
        imaps: false,
      ).handle();
    });
  }

  Future<void> close() async {
    await _secureServer?.close();
    await _server?.close();
  }
}

class _IMAPClientHandler {
  final int serverPort;
  Socket socket;
  final String hostname;
  final MailboxStore mailboxStore;
  final SMTPAuthProvider authProvider;
  final SecurityContext securityContext;
  final bool imaps;

  late bool tls;

  bool authenticated = false;
  String? user;

  StreamSubscription? subscription;
  late void Function(String) send;
  Object? error;

  late final InternetAddress remoteAddress;
  late final int remotePort;

  _IMAPClientHandler({
    required this.serverPort,
    required this.socket,
    required this.hostname,
    required this.mailboxStore,
    required this.authProvider,
    required this.securityContext,
    required this.imaps,
  }) {
    tls = imaps;

    try {
      remoteAddress = socket.remoteAddress;
      remotePort = socket.remotePort;
    } catch (_) {}
  }

  String get info =>
      '${imaps ? 'IMAPS' : 'IMAP'}[$serverPort]-Client[${remoteAddress.address}:$remotePort]';

  Future<void> handle() async {
    socket.write('* OK [$hostname] IMAP4rev1 Ready\r\n');
    _bind(socket);
  }

  final List<String> _allLines = [];

  void _onLine(String line) async {
    _allLines.add(line);

    final parts = line.split(' ');
    final tag = parts.first;
    final cmd = parts.length > 1 ? parts[1].toUpperCase() : '';

    // STARTTLS support
    if (cmd == 'STARTTLS' && !tls) {
      if (tls) {
        // Fail: client requested STARTTLS but connection is already secure
        send('$tag BAD TLS already active');
        return;
      }

      send('$tag OK Begin TLS negotiation');
      await _startTLS();
      return;
    }

    switch (cmd) {
      case 'LOGIN':
        {
          final username = parts[2];
          final password = parts[3];
          if (!tls) {
            send('$tag NO STARTTLS required before login');
            break;
          }
          if (authProvider.validate(username, password)) {
            authenticated = true;
            user = username;
            send('$tag OK LOGIN completed');
            _log.info("$info User logged: $username");
          } else {
            send('$tag NO LOGIN failed');
            _log.warning("$info Login failed: $username");
          }
          break;
        }

      case 'CAPABILITY':
        {
          send('* CAPABILITY IMAP4rev1 UIDPLUS STARTTLS');
          send('$tag OK CAPABILITY completed');
          break;
        }

      case 'LIST':
        {
          send('* LIST (\\HasNoChildren) "/" INBOX');
          send('$tag OK LIST completed');
          break;
        }

      case 'SELECT':
        {
          if (!_checkAuth(tag)) break;
          final messagesCount = await mailboxStore.countMessagesUIDs(user!);
          send('* $messagesCount EXISTS');
          send('* FLAGS (\\Seen)');
          send('$tag OK [READ-WRITE] SELECT completed');
          break;
        }

      case 'UID':
        {
          if (!_checkAuth(tag)) break;
          final sub = parts[2].toUpperCase();

          if (sub == 'SEARCH') {
            final messages = await mailboxStore.listMessagesUIDs(user!);
            final ids = List.generate(messages.length, (i) => i + 1).join(' ');
            send('* SEARCH $ids');
            send('$tag OK SEARCH completed');
          }

          if (sub == 'FETCH') {
            final messages = await mailboxStore.listMessagesUIDs(user!);
            for (var i = 0; i < messages.length; i++) {
              final msg = messages[i];
              send('* ${i + 1} FETCH (UID ${i + 1} RFC822 {${msg.length}}');
              socket.write(msg);
              send(')');
            }
            send('$tag OK FETCH completed');
          }
          break;
        }

      case 'LOGOUT':
        {
          send('* BYE Logging out');
          send('$tag OK LOGOUT completed');
          socket.close();
          _log.info("$info Logout: $user");
          return;
        }

      default:
        {
          send('$tag BAD Unsupported command');
        }
    }
  }

  bool _checkAuth(String tag) {
    if (!authenticated) {
      send('$tag NO AUTHENTICATIONFAILED Authentication required');
      return false;
    }
    return true;
  }

  Future<void> _startTLS() async {
    _log.info("$info Upgrading to TLS...");
    subscription?.pause();
    final secure = await SecureSocket.secureServer(socket, securityContext);
    socket = secure;
    tls = true;
    _bind(secure);
    _log.info("$info Started TLS!");
  }

  void _bind(Socket socket) {
    subscription = utf8.decoder
        .bind(socket)
        .transform(const LineSplitter())
        .listen(_onLine);

    send = (v) {
      socket.write('$v\r\n');
      try {
        socket.write('$v\r\n');
      } catch (e) {
        error = e;
      }
    };
  }
}
