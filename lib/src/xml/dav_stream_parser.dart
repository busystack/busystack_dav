// Event-by-event multistatus parsing adapted from BusyFiles (Apache-2.0).
import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';

import 'package:xml/xml_events.dart';

import '../http/dav_http_transport.dart';
import 'dav_xml.dart';

/// Nothing is returned until the entire document validates. A caller must not
/// advance a cursor or delete unseen members on an incomplete response.
Future<DavMultistatus> parseDavMultistatusStream(
  Stream<List<int>> source, {
  required DavCancellationToken cancellation,
  int maximumBytes = 32 * 1024 * 1024,
  int maximumEntries = 20000,
  int maximumEntryBytes = 4 * 1024 * 1024,
  int maximumDepth = 64,
  int maximumElements = 200000,
}) async {
  var received = 0, depth = 0, count = 0, entryBytes = 0, elements = 0;
  Stream<List<int>> bounded() async* {
    final iterator = StreamIterator(source);
    final aborted = Completer<bool>();
    final subscription = cancellation.cancellations.listen((_) {
      if (!aborted.isCompleted) aborted.complete(false);
    });
    try {
      cancellation.throwIfCancelled();
      while (await Future.any([
        iterator.moveNext().timeout(const Duration(seconds: 60)),
        aborted.future,
      ])) {
        cancellation.throwIfCancelled();
        final chunk = iterator.current;
        received += chunk.length;
        if (received > maximumBytes)
          throw const FormatException('DAV stream byte limit');
        yield chunk;
      }
      cancellation.throwIfCancelled();
    } finally {
      await subscription.cancel();
      await iterator.cancel();
      if (!aborted.isCompleted) aborted.complete(false);
    }
  }

  final encoder = XmlEventEncoder();
  XmlStartElementEvent? root;
  List<XmlEvent>? entry;
  final metadata = <XmlEvent>[];
  var metadataBytes = 0;
  final responses = <DavMultistatusResponse>[];
  await for (final events
      in bounded()
          .transform(utf8.decoder)
          .toXmlEvents(
            validateDocument: true,
            validateNamespace: true,
            validateNesting: true,
            withNamespace: true,
          )) {
    cancellation.throwIfCancelled();
    for (final event in events) {
      if (event is XmlDoctypeEvent)
        throw const FormatException('DAV DOCTYPE forbidden');
      if (event is XmlStartElementEvent) {
        elements++;
        if (elements > maximumElements)
          throw const FormatException('DAV element limit');
        if (depth == 0) {
          if (root != null ||
              event.localName != 'multistatus' ||
              event.namespaceUri != davNamespace) {
            throw const FormatException('Expected DAV multistatus');
          }
          root = event;
          if (utf8.encode(encoder.convert([event])).length > 16384)
            throw const FormatException('DAV root limit');
        } else if (depth == 1 &&
            event.localName == 'response' &&
            event.namespaceUri == davNamespace) {
          if (++count > maximumEntries)
            throw const FormatException('DAV entry limit');
          entry = [];
          entryBytes = 0;
        }
        if (entry != null) {
          entry.add(event);
          entryBytes += utf8.encode(encoder.convert([event])).length;
        } else if (depth > 0) {
          metadata.add(event);
          metadataBytes += utf8.encode(encoder.convert([event])).length;
        }
        if (!event.isSelfClosing) depth++;
        if (depth > maximumDepth)
          throw const FormatException('DAV depth limit');
      } else if (event is XmlEndElementEvent) {
        if (entry != null) {
          entry.add(event);
          entryBytes += utf8.encode(encoder.convert([event])).length;
        } else if (depth > 1) {
          metadata.add(event);
          metadataBytes += utf8.encode(encoder.convert([event])).length;
        }
        depth--;
      } else if (entry != null) {
        entry.add(event);
        entryBytes += utf8.encode(encoder.convert([event])).length;
      } else if (depth > 0) {
        metadata.add(event);
        metadataBytes += utf8.encode(encoder.convert([event])).length;
      }
      if (entryBytes > maximumEntryBytes || metadataBytes > 65536)
        throw const FormatException('DAV property limit');
      if (entry != null &&
          depth == 1 &&
          (event is XmlEndElementEvent ||
              event is XmlStartElementEvent && event.isSelfClosing)) {
        final xml =
            encoder.convert([root!]) +
            encoder.convert(entry) +
            '</' +
            root.name +
            '>';
        final parsed = DavXmlParser(
          limits: DavXmlLimits(
            maximumBytes: maximumEntryBytes + 16384,
            maximumTextBytes: maximumEntryBytes,
          ),
        ).parseMultistatus(Uint8List.fromList(utf8.encode(xml)));
        responses.addAll(parsed.responses);
        entry = null;
        entryBytes = 0;
      }
    }
  }
  if (root == null || depth != 0 || entry != null)
    throw const FormatException('Incomplete DAV stream');
  final tail =
      encoder.convert([root]) +
      encoder.convert(metadata) +
      '</' +
      root.name +
      '>';
  final parsed = const DavXmlParser().parseMultistatus(
    Uint8List.fromList(utf8.encode(tail)),
  );
  return DavMultistatus(
    responses: List.unmodifiable(responses),
    syncToken: parsed.syncToken,
    errorConditions: parsed.errorConditions,
  );
}
