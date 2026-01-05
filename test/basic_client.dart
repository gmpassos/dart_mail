import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

class BasicClient {
  Socket _socket;
  StreamSubscription? _subscription;

  final List<String> lines = [];
  Completer<String>? _waitingLine;

  BasicClient(this._socket) {
    _bind(_socket);
  }

  void _bind(Socket socket) {
    _subscription = utf8.decoder
        .bind(socket)
        .transform(const LineSplitter())
        .listen(_onLine);
  }

  void _onLine(String line) {
    lines.add(line);
    _notifyLine(line);
  }

  void send(String line) {
    _socket.write('$line\r\n');
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
    _socket.destroy();
  }
}
