import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

/// Peer option: the MAC address of the peer's network adapter.
const kPeerOptionWakeMac = 'wake-mac';

/// Peer option: where the peer's network can be reached from the internet,
/// `host` or `host:port`, for a router that forwards the port to the peer.
const kPeerOptionWakeAddress = 'wake-address';

/// The port magic packets go to unless the address names another one.
const kWakeDefaultPort = 9;

/// Parses `aa:bb:cc:dd:ee:ff`, `aa-bb-cc-dd-ee-ff` or `aabbccddeeff`.
List<int>? parseMac(String s) {
  final hex = s.trim().replaceAll(RegExp(r'[:\-. ]'), '');
  if (!RegExp(r'^[0-9a-fA-F]{12}$').hasMatch(hex)) return null;
  final mac = [
    for (var i = 0; i < 12; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16)
  ];
  // All zeros or a multicast address cannot be a network adapter.
  if (mac.every((b) => b == 0) || mac[0] & 1 == 1) return null;
  return mac;
}

String formatMac(List<int> mac) =>
    mac.map((b) => b.toRadixString(16).padLeft(2, '0')).join(':');

/// Six 0xFF bytes and the MAC sixteen times.
Uint8List magicPacket(List<int> mac) => Uint8List.fromList([
      for (var i = 0; i < 6; i++) 0xFF,
      for (var i = 0; i < 16; i++) ...mac,
    ]);

/// Parses `host`, `host:port`, `[v6]:port` or a bare IPv6 address.
({String host, int port})? parseWakeAddress(String s) {
  s = s.trim();
  if (s.isEmpty) return null;
  int? port;
  String host;
  final bracket = RegExp(r'^\[([^\]]+)\](?::(\d+))?$').firstMatch(s);
  if (bracket != null) {
    host = bracket[1]!;
    if (bracket[2] != null) port = int.tryParse(bracket[2]!);
  } else if (':'.allMatches(s).length == 1) {
    final i = s.indexOf(':');
    host = s.substring(0, i);
    port = int.tryParse(s.substring(i + 1));
    if (port == null) return null;
  } else {
    host = s;
  }
  if (host.isEmpty || host.contains(RegExp(r'[\s/]'))) return null;
  port ??= kWakeDefaultPort;
  if (port < 1 || port > 65535) return null;
  return (host: host, port: port);
}

/// Whether [ip] is an IPv4 address the internet cannot reach: private,
/// carrier-grade NAT (shared by many customers), loopback or link-local.
bool isUnreachableIPv4(String ip) {
  final parts = ip.split('.').map(int.tryParse).toList();
  if (parts.length != 4 || parts.any((p) => p == null || p < 0 || p > 255)) {
    return true;
  }
  final a = parts[0]!, b = parts[1]!;
  return a == 0 ||
      a == 10 ||
      a == 127 ||
      (a == 100 && b >= 64 && b <= 127) ||
      (a == 169 && b == 254) ||
      (a == 172 && b >= 16 && b <= 31) ||
      (a == 192 && b == 168);
}

/// The MAC addresses LAN discovery recorded for peer [id], from RustDesk's
/// `<app>_lan_peers.toml`.
List<String> macsFromLanPeers(String toml, String id) {
  final macs = <String>[];
  String? peer;
  var inIpMac = false;
  final keyValue = RegExp(r'^\s*"?([^"=]+?)"?\s*=\s*"([^"]*)"\s*$');
  for (final line in const LineSplitter().convert(toml)) {
    final t = line.trim();
    if (t == '[[peers]]') {
      peer = null;
      inIpMac = false;
    } else if (t.startsWith('[')) {
      inIpMac = t == '[peers.ip_mac]';
    } else {
      final m = keyValue.firstMatch(t);
      if (m == null) continue;
      if (!inIpMac && m[1] == 'id') {
        peer = m[2];
      } else if (inIpMac && peer == id) {
        final mac = parseMac(m[2]!);
        if (mac != null && !macs.contains(formatMac(mac))) {
          macs.add(formatMac(mac));
        }
      }
    }
  }
  return macs;
}

/// Sends magic packets for [mac] to the local network and, when given, to
/// [address] (see [parseWakeAddress]). Returns how many targets got them.
Future<int> sendWake(List<int> mac, {String? address}) async {
  final packet = magicPacket(mac);
  final targets = <(InternetAddress, int)>[
    (InternetAddress('255.255.255.255'), kWakeDefaultPort),
    (InternetAddress('255.255.255.255'), 7),
  ];
  final remote = address == null ? null : parseWakeAddress(address);
  if (remote != null) {
    try {
      for (final ip in await InternetAddress.lookup(remote.host)
          .timeout(const Duration(seconds: 5))) {
        targets.add((ip, remote.port));
      }
    } catch (e) {
      debugPrint('Wake: cannot resolve ${remote.host}: $e');
    }
  }
  RawDatagramSocket? v4, v6;
  try {
    v4 = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0)
      ..broadcastEnabled = true;
    if (targets.any((t) => t.$1.type == InternetAddressType.IPv6)) {
      v6 = await RawDatagramSocket.bind(InternetAddress.anyIPv6, 0);
    }
    var reached = 0;
    for (final (ip, port) in targets) {
      final socket = ip.type == InternetAddressType.IPv6 ? v6 : v4;
      var sent = false;
      // UDP may drop one; the adapter only needs one.
      for (var i = 0; i < 3; i++) {
        try {
          sent |= (socket?.send(packet, ip, port) ?? 0) > 0;
        } catch (e) {
          debugPrint('Wake: sending to $ip:$port failed: $e');
        }
      }
      if (sent) reached++;
    }
    return reached;
  } finally {
    v4?.close();
    v6?.close();
  }
}

/// The `LOCATION` header of an SSDP response.
String? ssdpLocation(String response) {
  for (final line in const LineSplitter().convert(response)) {
    final i = line.indexOf(':');
    if (i > 0 && line.substring(0, i).trim().toLowerCase() == 'location') {
      return line.substring(i + 1).trim();
    }
  }
  return null;
}

/// The control URL of the WAN connection service in an Internet Gateway
/// Device description at [location], and that service's type.
({Uri url, String type})? wanControlUrl(String xml, Uri location) {
  final base = RegExp(r'<URLBase>\s*([^<]+?)\s*</URLBase>').firstMatch(xml);
  final baseUri = base != null ? Uri.tryParse(base[1]!) ?? location : location;
  final service = RegExp(r'<service>(.*?)</service>', dotAll: true);
  for (final m in service.allMatches(xml)) {
    final body = m[1]!;
    final type = RegExp(r'<serviceType>\s*([^<]+?)\s*</serviceType>')
        .firstMatch(body)?[1];
    if (type == null ||
        !(type.startsWith('urn:schemas-upnp-org:service:WANIPConnection:') ||
            type.startsWith(
                'urn:schemas-upnp-org:service:WANPPPConnection:'))) {
      continue;
    }
    final control =
        RegExp(r'<controlURL>\s*([^<]+?)\s*</controlURL>').firstMatch(body)?[1];
    if (control == null) continue;
    return (url: baseUri.resolve(control), type: type);
  }
  return null;
}

/// `NewExternalIPAddress` of a GetExternalIPAddress SOAP response.
String? externalIpFromSoap(String xml) =>
    RegExp(r'<NewExternalIPAddress>\s*([^<]*?)\s*</NewExternalIPAddress>')
        .firstMatch(xml)?[1];

/// Asks the router (UPnP Internet Gateway Device) for the public IPv4 address
/// of this network. Null when no router answers.
Future<String?> routerPublicIp(
    {Duration timeout = const Duration(seconds: 3)}) async {
  final locations = <String>{};
  final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  try {
    final group = InternetAddress('239.255.255.250');
    for (final st in const [
      'urn:schemas-upnp-org:device:InternetGatewayDevice:1',
      'urn:schemas-upnp-org:service:WANIPConnection:1',
      'urn:schemas-upnp-org:device:InternetGatewayDevice:2',
    ]) {
      socket.send(
          utf8.encode('M-SEARCH * HTTP/1.1\r\n'
              'HOST: 239.255.255.250:1900\r\n'
              'MAN: "ssdp:discover"\r\n'
              'MX: 2\r\n'
              'ST: $st\r\n\r\n'),
          group,
          1900);
    }
    final done = Completer<void>();
    final timer = Timer(timeout, () {
      if (!done.isCompleted) done.complete();
    });
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final d = socket.receive();
      if (d == null) return;
      final location = ssdpLocation(utf8.decode(d.data, allowMalformed: true));
      if (location != null) locations.add(location);
    });
    await done.future;
    timer.cancel();
  } finally {
    socket.close();
  }
  final http = HttpClient()..connectionTimeout = timeout;
  try {
    for (final location in locations) {
      try {
        final uri = Uri.parse(location);
        final desc = await (await http.getUrl(uri)).close().timeout(timeout);
        final wan = wanControlUrl(
            await desc.transform(utf8.decoder).join().timeout(timeout), uri);
        if (wan == null) continue;
        final req = await http.postUrl(wan.url);
        req.headers
          ..set('Content-Type', 'text/xml; charset="utf-8"')
          ..set('SOAPAction', '"${wan.type}#GetExternalIPAddress"');
        req.write('<?xml version="1.0"?>'
            '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
            's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
            '<s:Body><u:GetExternalIPAddress xmlns:u="${wan.type}"/></s:Body>'
            '</s:Envelope>');
        final res = await req.close().timeout(timeout);
        final ip = externalIpFromSoap(
            await res.transform(utf8.decoder).join().timeout(timeout));
        if (ip != null && ip.isNotEmpty) return ip;
      } catch (e) {
        debugPrint('Wake: router at $location did not answer: $e');
      }
    }
  } finally {
    http.close(force: true);
  }
  return null;
}
