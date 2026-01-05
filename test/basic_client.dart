import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart' as logging;
import 'package:test/test.dart';

final _log = logging.Logger('test/BasicClient');

class BasicClient {
  Socket _socket;
  StreamSubscription? _subscription;
  bool _closed = false;
  Object? _error;

  final List<String> lines = [];
  Completer<String>? _waitingLine;

  InternetAddress? _remoteAddress;
  int? _remotePort;

  BasicClient(this._socket) {
    try {
      _remoteAddress = _socket.remoteAddress;
      _remotePort = _socket.remotePort;
    } catch (_) {}
    _bind(_socket);
  }

  String get info => 'BasicClient[$_remoteAddress:$_remotePort]';

  void _bind(Socket socket) {
    _subscription = utf8.decoder
        .bind(socket)
        .transform(const LineSplitter())
        .listen(_onLine, onDone: _onDone, onError: _onError);
  }

  void _onLine(String line) {
    lines.add(line);
    _notifyLine(line);
  }

  void _onDone() {
    _closed = true;
  }

  void _onError(Object error, StackTrace stackTrace) {
    _closed = true;
    _error ??= error;
    _log.severe("Socket error> $error", error, stackTrace);
  }

  void send(String line) {
    if (_closed) {
      _log.warning(
        "$info Attempting to write on closed socket",
        null,
        StackTrace.current,
      );
      return;
    }

    try {
      _socket.write('$line\r\n');
    } catch (e, s) {
      _log.severe("$info Error writing to socket!", e, s);
    }
  }

  void _notifyLine(String line) {
    final waiter = _waitingLine;
    _waitingLine = null;
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete(line);
    }
  }

  Future<bool> _waitLine(
    bool Function(List<String> lines) matcher, [
    Duration timeout = const Duration(seconds: 3),
  ]) async {
    final start = DateTime.now();

    while (true) {
      if (matcher(lines)) return true;

      final elapsed = DateTime.now().difference(start);
      final remaining = timeout - elapsed;
      if (remaining.inMilliseconds <= 0) return false;

      _waitingLine = Completer();
      await _waitingLine!.future.timeout(remaining, onTimeout: () => '');
    }
  }

  Future<void> expectLine(
    bool Function(List<String> lines) matcher, [
    Duration timeout = const Duration(seconds: 3),
  ]) async {
    final ok = await _waitLine(matcher, timeout);
    expect(ok, isTrue, reason: 'Expected line not found:\n${lines.join('\n')}');
  }

  Future<void> startTLS() async {
    _subscription?.pause();

    _socket = await SecureSocket.secure(_socket, onBadCertificate: (_) => true);

    _bind(_socket);
  }

  void close() {
    _closed = true;
    _socket.destroy();
  }
}
