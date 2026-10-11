import 'package:xml/xml.dart';

import '../dav_errors.dart';
import '../http/dav_http_transport.dart';
import '../protocol/dav_resource_client.dart';
import '../xml/dav_xml.dart';

const carddavNamespace = 'urn:ietf:params:xml:ns:carddav';

final class CardDavAddressBook {
  const CardDavAddressBook(this.collection);
  final DavCollection collection;
  Set<String> get vcardVersions {
    final advertised = collection.properties.successfulProperty(
      carddavNamespace,
      'supported-address-data',
    );
    if (advertised == null) return const {'3.0'};
    return advertised.element.descendantElements
        .where(
          (element) =>
              element.name.namespaceUri == carddavNamespace &&
              element.name.local == 'address-data-type' &&
              element.getAttribute('content-type') == 'text/vcard',
        )
        .map((element) => element.getAttribute('version') ?? '3.0')
        .toSet();
  }

  int? get maximumResourceBytes => int.tryParse(
    collection.properties
            .successfulProperty(carddavNamespace, 'max-resource-size')
            ?.text ??
        '',
  );
}

/// CardDAV protocol, separate from all calendar concepts and persistence.
final class CardDavClient {
  const CardDavClient(this.resources);
  final DavResourceClient resources;

  Future<DavDiscoveryResult> discover({
    Uri? entryUri,
    DavCancellationToken? cancellation,
  }) => resources.discover(
    entryUri: entryUri ?? resources.authority.resolve('/.well-known/carddav'),
    namespace: carddavNamespace,
    homeProperty: 'addressbook-home-set',
    collectionType: 'addressbook',
    extraProperties: const [
      DavPropertyName(carddavNamespace, 'supported-address-data'),
      DavPropertyName(carddavNamespace, 'max-resource-size'),
      DavPropertyName(carddavNamespace, 'addressbook-description'),
    ],
    cancellation: cancellation,
  );

  Future<List<DavObject>> query(
    Uri addressBook, {
    String? text,
    String property = 'FN',
    List<String>? selectedProperties,
    String version = '3.0',
    DavCancellationToken? cancellation,
  }) async {
    if (!RegExp(r'^[A-Z][A-Z0-9-]*$').hasMatch(property))
      throw ArgumentError('Invalid vCard property');
    final filter = text == null
        ? '<c:filter/>'
        : '<c:filter><c:prop-filter name="' +
              davText(property) +
              '"><c:text-match collation="i;unicode-casemap" match-type="contains">' +
              davText(text) +
              '</c:text-match></c:prop-filter></c:filter>';
    final result = await resources.report(
      addressBook,
      '<c:addressbook-query xmlns:d="DAV:" xmlns:c="' +
          carddavNamespace +
          '">' +
          _props(selectedProperties, version) +
          filter +
          '</c:addressbook-query>',
      cancellation: cancellation,
    );
    if (result.hasCondition(davNamespace, 'number-of-matches-within-limits') ||
        result.responses.any((e) => e.statusCode == 507)) {
      throw const DavException(
        kind: DavErrorKind.limitExceeded,
        code: 'CardDavQueryTruncated',
        safeMessage: 'The address-book query was truncated.',
      );
    }
    return _objects(addressBook, result, complete: selectedProperties == null);
  }

  Future<List<DavObject>> multiget(
    Uri addressBook,
    Iterable<Uri> members, {
    List<String>? selectedProperties,
    String version = '3.0',
    DavCancellationToken? cancellation,
  }) async {
    final list = members.toList();
    if (list.length > 1000) throw RangeError('Multiget batch limit');
    for (final member in list) {
      resources.requireMember(addressBook, member);
    }
    final result = await resources.report(
      addressBook,
      '<c:addressbook-multiget xmlns:d="DAV:" xmlns:c="' +
          carddavNamespace +
          '">' +
          _props(selectedProperties, version) +
          list
              .map((uri) => '<d:href>' + davText(uri.path) + '</d:href>')
              .join() +
          '</c:addressbook-multiget>',
      cancellation: cancellation,
    );
    return _objects(addressBook, result, complete: selectedProperties == null);
  }

  Future<DavObject> get(Uri uri, {DavCancellationToken? cancellation}) =>
      resources.get(uri, cancellation: cancellation);
  Future<DavObject> put(
    Uri uri,
    String fullVcard, {
    String? etag,
    bool create = false,
    DavCancellationToken? cancellation,
  }) => resources.put(
    uri,
    fullVcard,
    contentType: 'text/vcard; charset=utf-8',
    etag: etag,
    create: create,
    cancellation: cancellation,
  );
  Future<void> delete(
    Uri uri, {
    required String etag,
    DavCancellationToken? cancellation,
  }) => resources.delete(uri, etag: etag, cancellation: cancellation);

  Future<void> createAddressBook(
    Uri destination,
    String name, {
    String? description,
    DavCancellationToken? cancellation,
  }) async {
    final response = await resources.request(
      'MKCOL',
      destination,
      xml:
          '<d:mkcol xmlns:d="DAV:" xmlns:c="' +
          carddavNamespace +
          '"><d:set><d:prop><d:resourcetype><d:collection/><c:addressbook/></d:resourcetype><d:displayname>' +
          davText(name) +
          '</d:displayname>' +
          (description == null
              ? ''
              : '<c:addressbook-description>' +
                    davText(description) +
                    '</c:addressbook-description>') +
          '</d:prop></d:set></d:mkcol>',
      cancellation: cancellation,
    );
    resources.requireStatus(response, {201}, mutation: true);
  }

  Future<void> renameAddressBook(
    Uri uri,
    String name, {
    DavCancellationToken? cancellation,
  }) async {
    final response = await resources.request(
      'PROPPATCH',
      uri,
      xml:
          '<d:propertyupdate xmlns:d="DAV:"><d:set><d:prop><d:displayname>' +
          davText(name) +
          '</d:displayname></d:prop></d:set></d:propertyupdate>',
      cancellation: cancellation,
    );
    resources.requireStatus(response, {207}, mutation: true);
    final result = resources.parser.parseMultistatus(response.bodyBytes);
    if (result.responses.any((e) => e.propstats.any((p) => !p.isSuccessful))) {
      throw const DavException(
        kind: DavErrorKind.authorization,
        code: 'CardDavPropertyRejected',
        safeMessage: 'The address-book property was not changed.',
      );
    }
  }

  Future<void> deleteAddressBook(
    Uri uri, {
    DavCancellationToken? cancellation,
  }) async {
    final response = await resources.request(
      'DELETE',
      uri,
      cancellation: cancellation,
    );
    resources.requireStatus(response, {200, 204}, mutation: true);
  }

  String _props(List<String>? selected, String version) {
    if (!const {'3.0', '4.0'}.contains(version))
      throw ArgumentError('Unsupported vCard version');
    for (final name in selected ?? <String>[]) {
      if (!RegExp(r'^[A-Z][A-Z0-9-]*$').hasMatch(name))
        throw ArgumentError('Invalid vCard property');
    }
    return '<d:prop><d:getetag/><c:address-data content-type="text/vcard" version="' +
        version +
        '">' +
        (selected?.map((name) => '<c:prop name="' + name + '"/>').join() ??
            '') +
        '</c:address-data></d:prop>';
  }

  List<DavObject> _objects(
    Uri collection,
    DavMultistatus result, {
    required bool complete,
  }) {
    final objects = <DavObject>[];
    for (final entry in result.responses) {
      final uri = resources.resolve(entry.href, collection);
      resources.requireMember(collection, uri);
      if (entry.isMissing) continue;
      final data = entry.successfulProperty(carddavNamespace, 'address-data');
      final etag = entry.successfulProperty(davNamespace, 'getetag');
      if (data == null || etag == null)
        throw const FormatException('Incomplete address-object response');
      objects.add(
        DavObject(
          uri: uri,
          data: data.text,
          etag: etag.text,
          complete: complete,
          contentType: 'text/vcard',
        ),
      );
    }
    return objects;
  }
}
