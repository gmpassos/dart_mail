import 'dart:io';

import 'package:dart_mail/dns_resolver.dart';
import 'package:dns_client/dns_client.dart';
import 'package:test/test.dart';

void main() {
  group('MXRecord', () {
    test('compareTo sorts by preference (ascending)', () {
      final a = MXRecord(10, InternetAddress.loopbackIPv4);
      final b = MXRecord(5, InternetAddress.loopbackIPv4);

      final list = [a, b]..sort();

      expect(list.first.preference, 5);
    });

    test('equality and hashCode work correctly', () {
      final a = MXRecord(10, InternetAddress.loopbackIPv4);
      final b = MXRecord(10, InternetAddress.loopbackIPv4);
      final c = MXRecord(20, InternetAddress.loopbackIPv4);

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a == c, isFalse);
    });

    test('toString is stable', () {
      final r = MXRecord(10, InternetAddress.loopbackIPv4);
      expect(r.toString(), contains('MXRecord(10)'));
    });
  });

  group('SimpleDNSResolver', () {
    test('resolves A/AAAA records with preference 0', () async {
      final resolver = SimpleDNSResolver();

      final records = await resolver.resolveMX('localhost');

      expect(records, isNotEmpty);
      expect(records.every((r) => r.preference == 0), isTrue);
    });
  });

  group('DNSOverHttpsResolver', () {
    group('_FakeDnsOverHttps', () {
      test(
        'parses MX records, resolves hostnames, and sorts by priority',
        () async {
          final fakeClient = _FakeDnsOverHttps([
            Answer('example.com', RRType.MX.value, 60, '20 localhost.'),
            Answer('example.com', RRType.MX.value, 60, '10 localhost.'),
          ]);

          final resolver = DNSOverHttpsResolver(fakeClient);

          final records = await resolver.resolveMX('example.com');

          expect(records.length, greaterThanOrEqualTo(2));
          expect(records.first.preference, 10);
          expect(records.last.preference, 20);
          expect(records.every((r) => r.address.isLoopback), isTrue);
        },
      );

      test('ignores malformed MX records safely', () async {
        final fakeClient = _FakeDnsOverHttps([
          Answer('example.com', RRType.MX.value, 60, 'invalid'),
        ]);

        final resolver = DNSOverHttpsResolver(fakeClient);
        final records = await resolver.resolveMX('example.com');

        expect(records, isEmpty);
      });
    });

    group('DnsOverHttps.google', () {
      test('google.com (MX)', () async {
        var googleClient = DnsOverHttps.google();
        final resolver = DNSOverHttpsResolver(googleClient);

        final records = await resolver.resolveMX('google.com');

        expect(records.length, greaterThanOrEqualTo(2));
        expect(records.first.preference, inInclusiveRange(0, 20));
        expect(records.every((r) => r.address.isLoopback), isFalse);
      });

      test('gmail.com (MX)', () async {
        var googleClient = DnsOverHttps.google();
        final resolver = DNSOverHttpsResolver(googleClient);

        final records = await resolver.resolveMX('gmail.com');

        expect(records.length, greaterThanOrEqualTo(2));
        expect(records.first.preference, inInclusiveRange(0, 20));
        expect(records.last.preference, inInclusiveRange(20, 50));
        expect(records.every((r) => r.address.isLoopback), isFalse);
      });
    });
  });
}

class _FakeDnsOverHttps extends DnsOverHttps {
  final List<Answer> answers;

  _FakeDnsOverHttps(this.answers) : super('https://fake-dns/');

  @override
  Future<DnsRecord> lookupHttpsByRRType(String name, RRType type) async {
    return DnsRecord(
      0,
      false,
      false,
      false,
      false,
      false,
      null,
      answers.toList(),
      null,
    );
  }
}
