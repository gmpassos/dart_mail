import 'dart:io';

import 'package:dns_client/dns_client.dart';
import 'package:logging/logging.dart' as logging;

/// Represents an MX record with its priority and resolved IP address.
class MXRecord implements Comparable<MXRecord> {
  final int preference;
  final InternetAddress address;

  MXRecord(this.preference, this.address);

  @override
  int compareTo(MXRecord other) => preference.compareTo(other.preference);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MXRecord &&
          runtimeType == other.runtimeType &&
          preference == other.preference &&
          address == other.address;

  @override
  int get hashCode => Object.hash(preference, address);

  @override
  String toString() => 'MXRecord($preference)@$address';
}

/// Abstract interface for DNS resolution
abstract class DNSResolver {
  /// Resolves MX records for a domain, returning both preference and address.
  Future<List<MXRecord>> resolveMX(String domain);
}

/// Default implementation using Google DNS-over-HTTPS
class DNSOverHttpsResolver implements DNSResolver {
  static final _log = logging.Logger('DNSOverHttpsResolver');

  final DnsOverHttps client;

  DNSOverHttpsResolver(this.client);

  DNSOverHttpsResolver.google() : this(DnsOverHttps.google());

  @override
  Future<List<MXRecord>> resolveMX(String domain) async {
    // Get full MX DNS records
    final record = await client.lookupHttpsByRRType(domain, RRType.MX);

    final answers = record.answer ?? [];

    final mxRecords = <MXRecord>[];

    for (var answer in answers) {
      if (answer.type == RRType.MX.value) {
        // MX data format: "priority mailserver"
        // Example: "10 mail.example.com."
        final parts = answer.data.split(' ');
        if (parts.length >= 2) {
          final preference = int.tryParse(parts[0]) ?? 0;
          final hostname = parts[1].replaceAll(RegExp(r'\.$'), '');

          if (hostname.isNotEmpty) {
            try {
              // Resolve the MX hostname to an IP
              final addresses = await InternetAddress.lookup(hostname);
              for (var addr in addresses) {
                mxRecords.add(MXRecord(preference, addr));
              }
            } catch (e, s) {
              _log.severe(
                "Error calling: `InternetAddress.lookup('$hostname')`",
                e,
                s,
              );
            }
          }
        }
      }
    }

    // Sort by preference (lowest first)
    mxRecords.sort();

    return mxRecords;
  }
}

/// Fallback resolver using simple A/AAAA lookup (no MX priority)
class SimpleDNSResolver implements DNSResolver {
  @override
  Future<List<MXRecord>> resolveMX(String domain) async {
    final addresses = await InternetAddress.lookup(domain);
    return addresses.map((addr) => MXRecord(0, addr)).toList();
  }
}
