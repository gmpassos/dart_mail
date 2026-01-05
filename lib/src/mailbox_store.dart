import 'dart:async';
import 'dart:io';

import 'package:diacritic/diacritic.dart';
import 'package:logging/logging.dart' as logging;
import 'package:path/path.dart' as path;

import 'auth_provider.dart';

/// Mail storage abstraction
abstract class MailboxStore {
  final AuthProvider authProvider;

  MailboxStore(this.authProvider);

  FutureOr<List<String>> resolveMailboxes(List<String> recipients) =>
      authProvider.existingUsers(recipients);

  FutureOr<List<String>> store({
    required String from,
    required List<String> to,
    required String body,
  });

  FutureOr<List<String>> listMessagesUIDs(String mailbox);

  FutureOr<int> countMessagesUIDs(String mailbox);

  FutureOr<String?> getMessage(String mailbox, String uid);
}

/// In-Memory mailbox store for client handler tests
class InMemoryMailboxStore extends MailboxStore {
  final Map<String, List<String>> _store;

  InMemoryMailboxStore(super.authProvider, {Map<String, List<String>>? store})
    : _store = (store ?? {}).map((k, v) => MapEntry(k, v.toList()));

  @override
  List<String> store({
    required String from,
    required List<String> to,
    required String body,
  }) {
    var deliveredTo = <String>[];

    for (var mailbox in to) {
      if (!authProvider.hasUser(mailbox)) {
        continue;
      }

      _store.putIfAbsent(mailbox, () => []);
      _store[mailbox]!.add(body);

      deliveredTo.add(mailbox);
    }

    return deliveredTo;
  }

  @override
  int countMessagesUIDs(String mailbox) {
    return _store[mailbox]?.length ?? 0;
  }

  @override
  List<String> listMessagesUIDs(String mailbox) {
    final messages = _store[mailbox];
    if (messages == null) return [];
    // Use simple numeric UIDs
    return List.generate(messages.length, (i) => i.toString());
  }

  /// Optional helper to get message content by UID
  @override
  String? getMessage(String mailbox, String uid) {
    final messages = _store[mailbox];
    if (messages == null) return null;
    final index = int.tryParse(uid);
    if (index == null || index < 0 || index >= messages.length) return null;
    return messages[index];
  }
}

/// Simple filesystem mailbox store
class FileSystemMailboxStore extends MailboxStore {
  static final _log = logging.Logger('FileSystemMailboxStore');

  final Directory rootDir;

  FileSystemMailboxStore(this.rootDir, super.authProvider) {
    if (!rootDir.existsSync()) {
      throw ArgumentError(
        "Mailbox root directory does NOT exists: ${rootDir.path}",
      );
    }
  }

  ({String userDir, String? domainDir}) resolveMailboxDirectoryPath(
    String mailbox,
  ) {
    var parts = mailbox.split('@');

    var username = parts[0];
    var domain = parts.length > 1 ? parts[1] : null;

    var userDir = removeDiacritics(username).trim().toLowerCase();

    // ignore dots:
    userDir = userDir.replaceAll(RegExp(r'\.'), '');

    // ignore anything after + in username:
    userDir = userDir.replaceAll(RegExp(r'\+.*'), '');

    // remove non-word characters:
    userDir = userDir.replaceAll(RegExp(r'\W'), '_');

    String? domainDir;
    if (domain != null) {
      domainDir = removeDiacritics(domain).trim().toLowerCase();
      domainDir = domainDir.replaceAll(RegExp(r'[^\w.]'), '_');
      domainDir = domainDir.replaceAll(RegExp(r'^\.+'), '');
      if (domainDir.isEmpty) {
        domainDir = null;
      }
    }

    return (userDir: userDir, domainDir: domainDir);
  }

  Directory resolveMailboxDirectory(String mailbox) {
    var (userDir: userDir, domainDir: domainDir) = resolveMailboxDirectoryPath(
      mailbox,
    );

    if (domainDir != null) {
      return Directory(path.join(rootDir.path, domainDir, userDir));
    } else {
      return Directory(path.join(rootDir.path, userDir));
    }
  }

  @override
  List<String> resolveMailboxes(List<String> recipients) {
    return super.resolveMailboxes(recipients) as List<String>;
  }

  int _storeCount = 0;

  @override
  Future<List<String>> store({
    required String from,
    required List<String> to,
    required String body,
  }) async {
    var mailboxes = resolveMailboxes(to);
    if (mailboxes.isEmpty) return [];

    var deliveredTo = <String>[];

    for (var mailbox in mailboxes) {
      if (!authProvider.hasUser(mailbox)) {
        continue;
      }

      var mailboxDir = resolveMailboxDirectory(mailbox);

      await mailboxDir.create(recursive: true);

      var storeID = (++_storeCount) % 1000;
      var storeIDStr = '$storeID'.padLeft(3, '0');

      var mailFile = File(
        path.join(
          mailboxDir.path,
          '${DateTime.now().millisecondsSinceEpoch}$storeIDStr.eml',
        ),
      );

      await mailFile.writeAsString('From: $from\nTo: ${to.join(', ')}\n$body');

      deliveredTo.add(mailbox);

      _log.info(
        "Stored e-mail from `$from` to `${to.join(', ')}` at: ${mailFile.path}",
      );
    }

    return deliveredTo;
  }

  /// Returns a list of message UIDs (filenames without extension) for the given mailbox.
  @override
  Future<List<String>> listMessagesUIDs(String mailbox) async {
    final files = await _listMessagesFiles(mailbox);

    // Sort by timestamp extracted from filename
    files.sort((a, b) {
      final aName = path.basenameWithoutExtension(a.path);
      final bName = path.basenameWithoutExtension(b.path);
      final aTime = int.tryParse(aName) ?? 0;
      final bTime = int.tryParse(bName) ?? 0;
      return aTime.compareTo(bTime);
    });

    var uids = files.map((f) => path.basenameWithoutExtension(f.path)).toList();
    return uids;
  }

  Future<List<File>> _listMessagesFiles(String mailbox) async {
    var mailboxDir = resolveMailboxDirectory(mailbox);
    final list = await mailboxDir.list().toList();

    var files = list
        .whereType<File>()
        .where((f) => f.path.endsWith('.eml'))
        .toList();

    return files;
  }

  @override
  Future<int> countMessagesUIDs(String mailbox) async {
    final list = await _listMessagesFiles(mailbox);

    final files = list
        .whereType<File>()
        .where((f) => f.path.endsWith('.eml'))
        .toList();

    return files.length;
  }

  /// Returns the message body by UID (filename without extension)
  @override
  Future<String?> getMessage(String mailbox, String uid) async {
    final mailboxDir = resolveMailboxDirectory(mailbox);
    if (!(await mailboxDir.exists())) return null;

    final file = File(path.join(mailboxDir.path, '$uid.eml'));
    if (!(await file.exists())) return null;

    return file.readAsString();
  }
}
