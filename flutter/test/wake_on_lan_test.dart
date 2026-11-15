import 'package:flutter_hbb/models/wake_on_lan.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('MAC addresses parse in the usual notations', () {
    const mac = [0x00, 0x1a, 0x2b, 0x3c, 0x4d, 0x5e];
    expect(parseMac('00:1a:2b:3c:4d:5e'), mac);
    expect(parseMac('00-1A-2B-3C-4D-5E'), mac);
    expect(parseMac(' 001a2b3c4d5e '), mac);
    expect(parseMac('001a.2b3c.4d5e'), mac);
    expect(formatMac(mac), '00:1a:2b:3c:4d:5e');
  });

  test('impossible MAC addresses are refused', () {
    expect(parseMac(''), isNull);
    expect(parseMac('00:1a:2b:3c:4d'), isNull);
    expect(parseMac('00:1a:2b:3c:4d:5g'), isNull);
    expect(parseMac('00:00:00:00:00:00'), isNull);
    expect(parseMac('01:00:5e:00:00:01'), isNull);
  });

  test('a magic packet is six 0xFF and the MAC sixteen times', () {
    const mac = [0x02, 0x11, 0x22, 0x33, 0x44, 0x55];
    final p = magicPacket(mac);
    expect(p.length, 102);
    expect(p.sublist(0, 6), List.filled(6, 0xFF));
    for (var i = 0; i < 16; i++) {
      expect(p.sublist(6 + i * 6, 12 + i * 6), mac);
    }
  });

  test('wake addresses take a port only when given', () {
    expect(parseWakeAddress('home.example.net'),
        (host: 'home.example.net', port: kWakeDefaultPort));
    expect(parseWakeAddress('203.0.113.7:4009'),
        (host: '203.0.113.7', port: 4009));
    expect(parseWakeAddress('[2001:db8::1]:9'), (host: '2001:db8::1', port: 9));
    expect(parseWakeAddress('2001:db8::1'),
        (host: '2001:db8::1', port: kWakeDefaultPort));
    expect(parseWakeAddress(''), isNull);
    expect(parseWakeAddress('host:abc'), isNull);
    expect(parseWakeAddress('host:70000'), isNull);
    expect(parseWakeAddress('http://host'), isNull);
  });

  test('private and shared IPv4 addresses are not reachable', () {
    for (final ip in [
      '10.0.0.1',
      '172.16.5.4',
      '192.168.1.1',
      '100.64.0.1',
      '100.127.255.254',
      '169.254.1.1',
      '127.0.0.1',
      'nonsense',
    ]) {
      expect(isUnreachableIPv4(ip), isTrue, reason: ip);
    }
    for (final ip in ['203.0.113.7', '100.63.0.1', '172.32.0.1', '8.8.8.8']) {
      expect(isUnreachableIPv4(ip), isFalse, reason: ip);
    }
  });

  test('LAN discovery MACs are read for the right peer', () {
    const toml = '''
[[peers]]
id = "111"
username = "a"
hostname = "pc-a"
platform = "Windows"
online = false

[peers.ip_mac]
"192.168.1.10" = "aa:bb:cc:dd:ee:01"

[[peers]]
id = "222"
hostname = "pc-b"

[peers.ip_mac]
"192.168.1.20" = "aa:bb:cc:dd:ee:02"
"10.0.0.20" = "AA-BB-CC-DD-EE-03"
"10.0.0.21" = ""
''';
    expect(macsFromLanPeers(toml, '111'), ['aa:bb:cc:dd:ee:01']);
    expect(macsFromLanPeers(toml, '222'),
        ['aa:bb:cc:dd:ee:02', 'aa:bb:cc:dd:ee:03']);
    expect(macsFromLanPeers(toml, '333'), isEmpty);
  });

  test('the router description yields the WAN control URL', () {
    const xml = '''
<root><device><serviceList>
<service><serviceType>urn:schemas-upnp-org:service:Layer3Forwarding:1</serviceType>
<controlURL>/ctl/L3F</controlURL></service>
</serviceList><deviceList><device><serviceList>
<service>
  <serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>
  <controlURL>/ctl/IPConn</controlURL>
</service>
</serviceList></device></deviceList></device></root>''';
    final wan =
        wanControlUrl(xml, Uri.parse('http://192.168.1.1:5000/rootDesc.xml'));
    expect(wan?.url.toString(), 'http://192.168.1.1:5000/ctl/IPConn');
    expect(wan?.type, 'urn:schemas-upnp-org:service:WANIPConnection:1');
    expect(
        wanControlUrl(
                '<root><URLBase>http://10.0.0.1:49000/</URLBase>'
                '<service><serviceType>urn:schemas-upnp-org:service:WANPPPConnection:1'
                '</serviceType><controlURL>upnp/control/wanpppconn1</controlURL>'
                '</service></root>',
                Uri.parse('http://10.0.0.1:49000/igd.xml'))
            ?.url
            .toString(),
        'http://10.0.0.1:49000/upnp/control/wanpppconn1');
    expect(wanControlUrl('<root/>', Uri.parse('http://x/')), isNull);
  });

  test('SSDP and SOAP answers are read', () {
    expect(
        ssdpLocation('HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=120\r\n'
            'Location: http://192.168.1.1:5000/rootDesc.xml\r\nST: x\r\n\r\n'),
        'http://192.168.1.1:5000/rootDesc.xml');
    expect(ssdpLocation('HTTP/1.1 200 OK\r\n\r\n'), isNull);
    expect(
        externalIpFromSoap(
            '<s:Envelope><s:Body><u:GetExternalIPAddressResponse>'
            '<NewExternalIPAddress>203.0.113.7</NewExternalIPAddress>'
            '</u:GetExternalIPAddressResponse></s:Body></s:Envelope>'),
        '203.0.113.7');
  });
}
