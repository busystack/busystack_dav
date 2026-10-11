import 'dart:convert';

import 'package:busystack_dav/carddav.dart';
import 'package:busystack_dav/caldav.dart';

Future<void> main() async {
  const xml =
      '<d:multistatus xmlns:d="DAV:"><d:response><d:href>/books/one.vcf</d:href><d:propstat><d:prop><d:getetag>"one"</d:getetag></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>';
  final entries = await parseDavMultistatusStream(
    Stream.value(utf8.encode(xml)),
    cancellation: DavCancellationToken(),
  );
  print(entries.responses.length);
  // These distinct public protocol types are used by application-owned clients.
  print([CardDavClient, CalDavClient]);
}
