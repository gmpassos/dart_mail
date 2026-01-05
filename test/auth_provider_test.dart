import 'package:dart_mail/auth_provider.dart';
import 'package:test/test.dart';

import 'logging.dart';

void main() {
  logToConsole();

  group('MapAuthProvider', () {
    final auth = MapAuthProvider({
      'alice@example.com': 'pass123',
      'bob@example.com': 'secret',
    });

    test('hasUser returns true for existing user', () {
      expect(auth.hasUser('alice@example.com'), isTrue);
    });

    test('hasUser returns false for non-existing user', () {
      expect(auth.hasUser('charlie@example.com'), isFalse);
    });

    test('validate returns true for correct password', () {
      expect(auth.validate('bob@example.com', 'secret'), isTrue);
    });

    test('validate returns false for wrong password', () {
      expect(auth.validate('bob@example.com', 'wrong'), isFalse);
    });

    test('existingUsers filters correctly', () {
      final users = auth.existingUsers([
        'alice@example.com',
        'bob@example.com',
        'charlie@example.com',
      ]);
      expect(users, ['alice@example.com', 'bob@example.com']);
    });
  });
}
