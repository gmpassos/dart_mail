import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:logging/logging.dart' as logging;

import 'dns_resolver.dart';

/// Interface for sending emails to remote servers.
abstract class EmailDeliveryClient {
  /// Sends an email from [from] to [recipients] at the given [domain].
  ///
  /// [body] is the full email content including headers.
  /// If [useTls] is true, attempts to use STARTTLS when supported.
  /// Returns true if the email was accepted by the remote server.
  Future<bool> sendEmail({
    required String domain,
    required String from,
    required List<String> recipients,
    required String body,
    bool useTls,
  });

  /// Gracefully shuts down the client, releasing any resources.
  Future<void> close();
}

/// SMTP implementation of [EmailDeliveryClient] using raw sockets.
class SMTPEmailDeliveryClient implements EmailDeliveryClient {
  static final _log = logging.Logger('SMTPEmailDeliveryClient');

  final String hostname;
  final DNSResolver dnsResolver;

  final int mxServerPort;
  Duration connectTimeout;

  SMTPEmailDeliveryClient({
    required this.hostname,
    required this.dnsResolver,
    this.mxServerPort = 25,
    this.connectTimeout = const Duration(seconds: 30),
  });

  @override
  Future<bool> sendEmail({
    required String domain,
    required String from,
    required List<String> recipients,
    required String body,
    bool useTls = true,
  }) async {
    // No recipients to deliver to (nothing to send):
    if (recipients.isEmpty) {
      return false;
    }

    try {
      // Resolve MX records
      var mxRecords = await dnsResolver.resolveMX(domain);
      if (mxRecords.isEmpty) {
        _log.severe(
          "No MX record for `$domain`! Can't deliver e-mail> from: $from ; to: $recipients",
        );
        return false;
      }

      var mxServer = selectMXServerAddress(mxRecords);

      Socket socket = await connectToMXServer(mxServer);

      final handler = _SocketHandler(
        hostname: hostname,
        socket: socket,
        from: from,
        recipients: recipients,
        body: body,
        useTls: useTls,
      );

      return handler.result;
    } catch (e, s) {
      _log.severe(
        "Error sending e-mail from `$from` to `${recipients.join(', ')}`",
        e,
        s,
      );
      return false;
    }
  }

  Future<Socket> connectToMXServer(InternetAddress mxServer) async {
    var socket = await Socket.connect(
      mxServer,
      mxServerPort,
      timeout: connectTimeout,
    );
    return socket;
  }

  InternetAddress selectMXServerAddress(List<MXRecord> mxRecords) {
    if (mxRecords.isEmpty) {
      throw ArgumentError('MX records list cannot be empty');
    }

    mxRecords.sort();

    // Find the lowest preference value
    final lowestPref = mxRecords.first.preference;

    // Filter MX records with the lowest preference
    final bestServers = mxRecords
        .where((r) => r.preference == lowestPref)
        .toList();

    // Randomly select one for load balancing
    final selected = bestServers[Random().nextInt(bestServers.length)];

    return selected.address;
  }

  @override
  Future<void> close() async {}
}

class _SocketHandler {
  final String hostname;
  final bool useTls;

  final String from;
  final List<String> recipients;
  final String body;

  _SocketHandler({
    required this.hostname,
    required this.socket,
    required this.from,
    required this.recipients,
    required this.body,
    this.useTls = true,
  }) {
    _listen();
  }

  final Completer<bool> _completer = Completer<bool>();

  Future<bool> get result => _completer.future;

  final List<String> _allLines = [];
  bool _tlsUpgraded = false;
  bool _dataSent = false;
  int _recipientIndex = 0;
  bool _receivedGreeting = false;
  bool _ehloComplete = false;

  Socket socket;
  late StreamSubscription _subscription;

  void _listen() {
    _subscription = utf8.decoder
        .bind(socket)
        .transform(const LineSplitter())
        .listen(_onLine, onDone: _onDone, onError: _onError);
  }

  final List<String> _serverCapabilities = [];

  void _onLine(String line) async {
    line = line.trim();
    _allLines.add(line);

    if (line.startsWith('220')) {
      if (!_receivedGreeting) {
        _receivedGreeting = true;
        _sendLine('EHLO $hostname');
      } else if (!_tlsUpgraded && useTls) {
        // STARTTLS ready
        _subscription.pause();
        socket = await SecureSocket.secure(
          socket,
          onBadCertificate: (c) => true,
        );
        _listen();
        _tlsUpgraded = true;
        _ehloComplete = false; // EHLO again after TLS
        _serverCapabilities.clear();
        _sendLine('EHLO $hostname');
      }
    } else if (line.startsWith('250')) {
      // EHLO response lines end with space, not dash
      if (!_ehloComplete) {
        if (line.startsWith('250-')) {
          _serverCapabilities.add(line);
        } else {
          _ehloComplete = true;

          var allowStartTLS = _serverCapabilities.any(
            (l) => l.contains('STARTTLS'),
          );

          // If server supports STARTTLS and requested, upgrade
          if (allowStartTLS && !_tlsUpgraded && useTls) {
            _sendLine('STARTTLS');
          } else {
            _sendLine('MAIL FROM:<$from>');
          }
        }
        return; // wait until EHLO complete
      }

      // After MAIL FROM
      if (!_dataSent && _recipientIndex < recipients.length) {
        _sendLine('RCPT TO:<${recipients[_recipientIndex]}>');
        _recipientIndex++;
      } else if (!_dataSent && _recipientIndex >= recipients.length) {
        _sendLine('DATA');
        _dataSent = true;
      } else if (_dataSent) {
        _sendLine('QUIT');
      }
    } else if (line.startsWith('354')) {
      // DATA accepted
      _sendLine(body.replaceAll('\n', '\r\n'));
      _sendLine('.');
    } else if (line.startsWith('221')) {
      _complete(true);
      socket.destroy();
    }
  }

  void _sendLine(String line) {
    socket.write('$line\r\n');
  }

  void _onDone() => _complete(false);

  void _onError(Object e, StackTrace s) {
    if (!_completer.isCompleted) _completer.completeError(e, s);
  }

  void _complete(bool success) {
    if (!_completer.isCompleted) _completer.complete(success);
  }

  Future<void> dispose() async {
    await _subscription.cancel();
    socket.destroy();
  }
}
