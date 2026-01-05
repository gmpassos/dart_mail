import 'dart:async';
import 'dart:io';

import 'package:dart_mail/mailbox_store.dart';
import 'package:test/test.dart';

import 'logging.dart';

void main() {
  logToConsole();

  group('InMemoryMailboxStore', () {
    late InMemoryMailboxStore store;

    setUp(() {
      final authProvider = MapAuthProvider({
        'alice@example.com': 'pass123',
        'bob@example.com': 'secret',
      });
      store = InMemoryMailboxStore(authProvider);
    });

    test('store emails in memory', () async {
      final recipients = ['alice@example.com', 'bob@example.com'];
      final result = store.store(
        from: 'noreply@example.com',
        to: recipients,
        body: 'Hello World',
      );

      expect(result, containsAll(recipients));
      expect(store.countMessagesUIDs('alice@example.com'), 1);
      expect(store.countMessagesUIDs('bob@example.com'), 1);
    });

    test('listMessagesUIDs returns UIDs in order', () async {
      store.store(
        from: 'noreply@example.com',
        to: ['alice@example.com'],
        body: 'First',
      );
      store.store(
        from: 'noreply@example.com',
        to: ['alice@example.com'],
        body: 'Second',
      );

      final uids = store.listMessagesUIDs('alice@example.com');
      expect(uids.length, 2);
      expect(uids, ['0', '1']);
    });

    test('countMessagesUIDs returns 0 for empty mailbox', () {
      expect(store.countMessagesUIDs('unknown@example.com'), 0);
    });

    test('getMessage returns correct message by UID', () async {
      store.store(
        from: 'noreply@example.com',
        to: ['alice@example.com'],
        body: 'Test Message',
      );

      final uid = '0';
      final message = store.getMessage('alice@example.com', uid);
      expect(message, 'Test Message');
    });

    test('getMessage returns null for invalid UID', () async {
      store.store(
        from: 'noreply@example.com',
        to: ['alice@example.com'],
        body: 'Hello',
      );

      expect(store.getMessage('alice@example.com', '99'), isNull);
      expect(store.getMessage('alice@example.com', '-1'), isNull);
      expect(store.getMessage('alice@example.com', 'abc'), isNull);
      expect(store.getMessage('unknown@example.com', '0'), isNull);
    });

    test('storing multiple emails appends correctly', () async {
      store.store(
        from: 'noreply@example.com',
        to: ['bob@example.com'],
        body: 'Msg1',
      );
      store.store(
        from: 'noreply@example.com',
        to: ['bob@example.com'],
        body: 'Msg2',
      );

      expect(store.countMessagesUIDs('bob@example.com'), 2);
      expect(store.getMessage('bob@example.com', '0'), 'Msg1');
      expect(store.getMessage('bob@example.com', '1'), 'Msg2');
    });
  });

  group('FileSystemMailboxStore', () {
    late Directory tmpDir;
    late FileSystemMailboxStore store;
    late MapAuthProvider auth;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync();
      auth = MapAuthProvider({
        'alice@example.com': 'pass123',
        'bob@example.com': 'secret',
      });
      store = FileSystemMailboxStore(tmpDir, auth);
    });

    tearDown(() {
      tmpDir.deleteSync(recursive: true);
    });

    test('resolveMailboxDirectoryName normalizes names', () {
      var (userDir: userDir, domainDir: domainDir) = store
          .resolveMailboxDirectoryPath('Álice+test@domain.com');
      expect(userDir, equals('alice'));
      expect(domainDir, equals('domain.com'));
    });

    test('store writes emails to mailbox directories', () async {
      final recipients = ['alice@example.com', 'bob@example.com'];
      final result = await store.store(
        from: 'noreply@example.com',
        to: recipients,
        body: 'Hello World',
      );

      expect(result, containsAll(recipients));

      for (var mailbox in recipients) {
        final dir = store.resolveMailboxDirectory(mailbox);
        expect(dir.existsSync(), isTrue);

        final files = dir.listSync().whereType<File>().toList();
        expect(files, isNotEmpty);

        final content = files.first.readAsStringSync();
        expect(content, contains('Hello World'));
        expect(content, contains('From: noreply@example.com'));
      }
    });

    test('countMessagesUIDs returns correct count', () async {
      await store.store(
        from: 'noreply@example.com',
        to: ['alice@example.com'],
        body: 'Msg 1',
      );

      await store.store(
        from: 'noreply@example.com',
        to: ['alice@example.com'],
        body: 'Msg 2',
      );

      expect(await store.countMessagesUIDs('alice@example.com'), 2);
    });

    test('listMessagesUIDs returns UIDs sorted', () async {
      await store.store(
        from: 'noreply@example.com',
        to: ['alice@example.com'],
        body: 'First',
      );
      await Future.delayed(Duration(milliseconds: 5));
      await store.store(
        from: 'noreply@example.com',
        to: ['alice@example.com'],
        body: 'Second',
      );

      final uids = await store.listMessagesUIDs('alice@example.com');
      expect(uids.length, 2);
      expect(int.parse(uids[0]), lessThan(int.parse(uids[1])));
    });
  });
}
