import 'package:xml/xml.dart';

import 'dart:convert';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../dav_errors.dart';
import '../dav_provider_profile.dart';
import '../http/dav_http_transport.dart';
import '../http/dav_transfer.dart';
import '../xml/dav_xml.dart';
import '../xml/dav_stream_parser.dart';

typedef DavCredentialProvider = Future<DavBasicCredential> Function();

String davText(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');
String davPropertyXml(DavPropertyName property) =>
    '<p:' +
    property.localName +
    ' xmlns:p="' +
    davText(property.namespaceUri ?? '') +
    '"/>';

final class DavCollection {
  const DavCollection({
    required this.uri,
    required this.displayName,
    required this.privileges,
    required this.reports,
    required this.properties,
  });
  final Uri uri;
  final String displayName;
  final Set<DavPropertyName> privileges, reports;
  final DavMultistatusResponse properties;
  bool hasPrivilege(String name) =>
      privileges.contains(DavPropertyName(davNamespace, name)) ||
      privileges.contains(const DavPropertyName(davNamespace, 'all'));
  bool get canRead => hasPrivilege('read');
  bool get canCreate => hasPrivilege('bind') || hasPrivilege('write');
  bool get canUpdate => hasPrivilege('write-content') || hasPrivilege('write');
  bool get canDelete => hasPrivilege('unbind') || hasPrivilege('write');
  bool get canRename =>
      hasPrivilege('write-properties') || hasPrivilege('write');
  bool get supportsSync =>
      reports.contains(const DavPropertyName(davNamespace, 'sync-collection'));
}

final class DavDiscoveryResult {
  const DavDiscoveryResult({
    required this.principal,
    required this.homeSets,
    required this.collections,
    required this.homeProperties,
    required this.methods,
    required this.features,
  });
  final Uri principal;
  final List<Uri> homeSets;
  final List<DavCollection> collections;
  final Map<Uri, DavMultistatusResponse> homeProperties;
  final Set<String> methods, features;
}

final class DavObject {
  const DavObject({
    required this.uri,
    required this.etag,
    required this.data,
    this.complete = true,
    this.contentType,
  });
  final Uri uri;
  final String etag, data;
  final bool complete;
  final String? contentType;
}

final class DavSyncResult {
  const DavSyncResult({
    required this.changed,
    required this.deleted,
    required this.syncToken,
    required this.truncated,
  });
  final Map<Uri, String> changed;
  final Set<Uri> deleted;
  final String syncToken;
  final bool truncated;
}

/// Generic resource/property/sync mechanics. No persistence or domain mapping.
final class DavResourceClient {
  DavResourceClient({
    required this.transport,
    required this.credentialProvider,
    required this.authority,
    required this.accountId,
    this.profile = const DavProviderProfile(),
    this.parser = const DavXmlParser(),
    this.streaming,
  });
  final DavHttpTransport transport;
  final DavCredentialProvider credentialProvider;
  final Uri authority;
  final String accountId;
  final DavProviderProfile profile;
  final DavXmlParser parser;
  final DavTransferClient? streaming;
  final _uuid = const Uuid();

  Future<DavBasicCredential> _credential(DavCancellationToken? token) async {
    token?.throwIfCancelled();
    final pending = credentialProvider();
    if (token == null) return pending;
    return Future.any([
      pending,
      token.whenCancelled.then<DavBasicCredential>((_) {
        token.throwIfCancelled();
        throw StateError('Cancelled authorization');
      }),
    ]);
  }

  Future<DavResponse> request(
    String method,
    Uri uri, {
    String? xml,
    List<int>? bytes,
    Map<String, String> headers = const {},
    bool discovery = false,
    DavCancellationToken? cancellation,
  }) async {
    final credential = await _credential(cancellation);
    cancellation?.throwIfCancelled();
    final response = await transport.send(
      DavRequest(
        method: method,
        uri: uri,
        accountId: accountId,
        collectionId: uri.path,
        correlationId: _uuid.v7(),
        headers: {
          if (xml != null) 'content-type': 'application/xml; charset=utf-8',
          ...headers,
        },
        bodyBytes: xml == null
            ? bytes == null
                  ? null
                  : Uint8List.fromList(bytes)
            : Uint8List.fromList(utf8.encode(xml)),
        retryClass:
            const {
              'GET',
              'HEAD',
              'PROPFIND',
              'REPORT',
              'OPTIONS',
            }.contains(method)
            ? DavRetryClass.safeRead
            : DavRetryClass.never,
        redirectPolicy: discovery
            ? DavRedirectPolicy.discovery
            : DavRedirectPolicy.none,
      ),
      credential: credential,
      cancellationToken: cancellation,
    );
    return response;
  }

  Future<DavMultistatus> propfind(
    Uri uri,
    Iterable<DavPropertyName> properties, {
    int depth = 0,
    bool discovery = false,
    DavCancellationToken? cancellation,
  }) async {
    if (depth != 0 && depth != 1) throw ArgumentError('Depth must be 0 or 1');
    final body =
        '<d:propfind xmlns:d="DAV:"><d:prop>' +
        properties.map(davPropertyXml).join() +
        '</d:prop></d:propfind>';
    if (streaming != null && !discovery)
      return _streamMultistatus('PROPFIND', uri, body, {
        'depth': '$depth',
      }, cancellation);
    final response = await request(
      'PROPFIND',
      uri,
      headers: {'depth': '$depth'},
      discovery: discovery,
      xml:
          '<d:propfind xmlns:d="DAV:"><d:prop>' +
          properties.map(davPropertyXml).join() +
          '</d:prop></d:propfind>',
      cancellation: cancellation,
    );
    requireStatus(response, {207});
    final parsed = parser.parseMultistatus(response.bodyBytes);
    return DavMultistatus(
      responses: parsed.responses,
      syncToken: parsed.syncToken,
      errorConditions: parsed.errorConditions,
      requestUri: response.requestUri,
    );
  }

  Future<DavMultistatus> report(
    Uri uri,
    String body, {
    DavCancellationToken? cancellation,
  }) async {
    if (streaming != null)
      return _streamMultistatus('REPORT', uri, body, const {
        'depth': '0',
      }, cancellation);
    final response = await request(
      'REPORT',
      uri,
      headers: const {'depth': '0'},
      xml: body,
      cancellation: cancellation,
    );
    _requireReportStatus(response);
    final parsed = parser.parseMultistatus(response.bodyBytes);
    return DavMultistatus(
      responses: parsed.responses,
      syncToken: parsed.syncToken,
      errorConditions: parsed.errorConditions,
      requestUri: response.requestUri,
    );
  }

  Future<DavDiscoveryResult> discover({
    required Uri entryUri,
    required String namespace,
    required String homeProperty,
    required String collectionType,
    required List<DavPropertyName> extraProperties,
    DavCancellationToken? cancellation,
  }) async {
    final base = [
      const DavPropertyName(davNamespace, 'current-user-principal'),
      const DavPropertyName(davNamespace, 'resourcetype'),
      const DavPropertyName(davNamespace, 'displayname'),
      const DavPropertyName(davNamespace, 'current-user-privilege-set'),
      const DavPropertyName(davNamespace, 'supported-report-set'),
      DavPropertyName(namespace, homeProperty),
      ...extraProperties,
    ];
    var firstUri = entryUri;
    DavMultistatus first;
    try {
      first = await propfind(
        firstUri,
        base,
        discovery: true,
        cancellation: cancellation,
      );
    } on DavException catch (error) {
      if (error.statusCode != 404) rethrow;
      // A caller-supplied DAV service URL is the RFC discovery fallback.
      firstUri = authority;
      first = await propfind(
        firstUri,
        base,
        discovery: true,
        cancellation: cancellation,
      );
    }
    firstUri = first.requestUri ?? firstUri;
    if (first.responses.isEmpty)
      throw const FormatException('Discovery omitted principal');
    final firstResponse = first.responses.first;
    final principalHref = _hrefs(
      firstResponse.successfulProperty(davNamespace, 'current-user-principal'),
    ).firstOrNull;
    final principal = principalHref == null
        ? firstUri
        : resolve(principalHref, firstUri);
    final principalResult = principal == firstUri
        ? first
        : await propfind(
            principal,
            base,
            discovery: true,
            cancellation: cancellation,
          );
    final principalBase = principalResult.requestUri ?? principal;
    final homes = <Uri>{};
    for (final response in [...first.responses, ...principalResult.responses]) {
      for (final href in _hrefs(
        response.successfulProperty(namespace, homeProperty),
      )) {
        homes.add(
          resolve(href, response == firstResponse ? firstUri : principalBase),
        );
      }
    }
    // An explicit address-book/calendar URL is also a valid connection entry.
    final collections = <Uri, DavCollection>{};
    for (final entry in first.responses) {
      if (_contains(
        entry.successfulProperty(davNamespace, 'resourcetype'),
        namespace,
        collectionType,
      )) {
        final collection = _collection(entry, resolve(entry.href, firstUri));
        collections[collection.uri] = collection;
      }
    }
    final homeProperties = <Uri, DavMultistatusResponse>{};
    for (final home in homes) {
      cancellation?.throwIfCancelled();
      final result = await propfind(
        home,
        base,
        depth: 1,
        cancellation: cancellation,
      );
      if (result.responses.length > 512)
        throw const FormatException('Too many DAV sources');
      for (final entry in result.responses) {
        final uri = resolve(entry.href, home);
        if (uri.path == home.path) homeProperties[home] = entry;
        if (_contains(
          entry.successfulProperty(davNamespace, 'resourcetype'),
          namespace,
          collectionType,
        )) {
          collections[uri] = _collection(entry, uri);
        }
      }
    }
    if (homes.isEmpty && collections.isEmpty)
      throw const DavException(
        kind: DavErrorKind.protocol,
        code: 'DavHomeSetMissing',
        safeMessage: 'No supported DAV home set was discovered.',
      );
    final options = await request(
      'OPTIONS',
      principal,
      cancellation: cancellation,
    );
    requireStatus(options, {200, 204});
    return DavDiscoveryResult(
      principal: principal,
      homeSets: homes.toList(),
      collections: collections.values.toList(),
      homeProperties: homeProperties,
      methods: (options.headers['allow'] ?? '')
          .split(',')
          .map((s) => s.trim().toUpperCase())
          .where((s) => s.isNotEmpty)
          .toSet(),
      features: (options.headers['dav'] ?? '')
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toSet(),
    );
  }

  Future<DavObject> get(Uri uri, {DavCancellationToken? cancellation}) async {
    final response = await request('GET', uri, cancellation: cancellation);
    requireStatus(response, {200});
    final etag = response.etag;
    if (etag == null || etag.isEmpty)
      throw const FormatException('Resource omitted ETag');
    return DavObject(
      uri: response.requestUri,
      etag: etag,
      data: response.bodyText,
      contentType: response.headers['content-type'],
    );
  }

  Future<DavObject> put(
    Uri uri,
    String fullData, {
    required String contentType,
    String? etag,
    bool create = false,
    DavCancellationToken? cancellation,
  }) async {
    if (!create && (etag == null || etag.isEmpty))
      throw ArgumentError('An ETag is required');
    final response = await request(
      'PUT',
      uri,
      bytes: utf8.encode(fullData),
      headers: {
        'content-type': contentType,
        if (create) 'if-none-match': '*' else 'if-match': etag!,
      },
      cancellation: cancellation,
    );
    requireStatus(response, {200, 201, 204}, mutation: true);
    // The representation may be normalized by the server; fetch confirmed data.
    try {
      return await get(uri, cancellation: cancellation);
    } catch (_) {
      throw const DavException(
        kind: DavErrorKind.unknownOutcome,
        code: 'DavWriteConfirmationUnavailable',
        safeMessage: 'The write needs reconciliation.',
      );
    }
  }

  Future<void> delete(
    Uri uri, {
    required String etag,
    DavCancellationToken? cancellation,
  }) async {
    if (etag.isEmpty) throw ArgumentError('An ETag is required');
    final response = await request(
      'DELETE',
      uri,
      headers: {'if-match': etag},
      cancellation: cancellation,
    );
    requireStatus(response, {200, 204}, mutation: true);
  }

  Future<Map<Uri, String>> enumerateEtags(
    Uri collection, {
    DavCancellationToken? cancellation,
  }) async {
    final result = await propfind(
      collection,
      [
        const DavPropertyName(davNamespace, 'getetag'),
        const DavPropertyName(davNamespace, 'resourcetype'),
      ],
      depth: 1,
      cancellation: cancellation,
    );
    final inventory = <Uri, String>{};
    for (final response in result.responses) {
      final uri = resolve(response.href, collection);
      if (uri.path == collection.path) continue;
      requireMember(collection, uri);
      final etag = response
          .successfulProperty(davNamespace, 'getetag')
          ?.text
          .trim();
      if (response.isMissing) continue;
      if (etag == null || etag.isEmpty)
        throw const FormatException('Inventory omitted ETag');
      inventory[uri] = etag;
    }
    return inventory;
  }

  Future<DavSyncResult> syncCollection(
    Uri collection,
    String token, {
    int maximumResults = 1000,
    DavCancellationToken? cancellation,
  }) async {
    if (maximumResults < 1 || maximumResults > 20000)
      throw RangeError.value(maximumResults);
    String body({required bool includeLimit}) =>
        '<d:sync-collection xmlns:d="DAV:"><d:sync-token>' +
        davText(token) +
        '</d:sync-token><d:sync-level>1</d:sync-level>' +
        (includeLimit
            ? '<d:limit><d:nresults>$maximumResults</d:nresults></d:limit>'
            : '') +
        '<d:prop><d:getetag/></d:prop></d:sync-collection>';
    late final DavMultistatus result;
    try {
      result = await report(
        collection,
        body(includeLimit: true),
        cancellation: cancellation,
      );
    } on DavException catch (error) {
      if (error.code != 'DavSyncLimitRejected') rethrow;
      // RFC 6578 section 3.7: this failed request returned no changes or
      // replacement token. Remove only its optional server-side limit, once.
      // The same transport and XML parser still enforce all local bounds.
      cancellation?.throwIfCancelled();
      result = await report(
        collection,
        body(includeLimit: false),
        cancellation: cancellation,
      );
    }
    if (result.hasCondition(davNamespace, 'valid-sync-token'))
      throw const DavException(
        kind: DavErrorKind.invalidSyncToken,
        code: 'DavSyncTokenInvalid',
        safeMessage: 'Collection cursor expired.',
      );
    if (result.syncToken == null)
      throw const FormatException('Sync response omitted token');
    final changed = <Uri, String>{}, deleted = <Uri>{};
    var truncated = false;
    for (final entry in result.responses) {
      final uri = resolve(entry.href, collection);
      if (entry.statusCode == 507 ||
          entry.propstats.any((p) => p.statusCode == 507)) {
        // Section 3.6 truncation is a response for the request URI, not an
        // arbitrary member failure. Its returned token represents this page.
        if (uri != collection || entry.statusCode != 507)
          throw const DavException(
            kind: DavErrorKind.protocol,
            code: 'DavSyncResourceFailed',
            safeMessage: 'A collection change could not be synchronized.',
            statusCode: 507,
          );
        truncated = true;
        continue;
      }
      if (uri.path == collection.path) continue;
      requireMember(collection, uri);
      if (entry.isMissing) {
        deleted.add(uri);
        continue;
      }
      final etag = entry.successfulProperty(davNamespace, 'getetag')?.text;
      if (etag == null) throw const FormatException('Sync change omitted ETag');
      changed[uri] = etag;
    }
    return DavSyncResult(
      changed: changed,
      deleted: deleted,
      syncToken: result.syncToken!,
      truncated: truncated,
    );
  }

  Future<DavMultistatus> _streamMultistatus(
    String method,
    Uri uri,
    String xml,
    Map<String, String> headers,
    DavCancellationToken? cancellation,
  ) async {
    final token = cancellation ?? DavCancellationToken();
    token.throwIfCancelled();
    final credential = await _credential(token);
    token.throwIfCancelled();
    final response = await streaming!.openRead(
      uri,
      method: method,
      bodyBytes: utf8.encode(xml),
      headers: {'content-type': 'application/xml; charset=utf-8', ...headers},
      credential: credential,
      cancellation: token,
    );
    try {
      if (response.statusCode == 207) {
        final parsed = await parseDavMultistatusStream(
          response.body,
          cancellation: token,
          maximumEntries: 100000,
          maximumElements: 1000000,
        );
        return DavMultistatus(
          responses: parsed.responses,
          syncToken: parsed.syncToken,
          errorConditions: parsed.errorConditions,
          requestUri: response.requestUri,
        );
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.body) {
        if (bytes.length + chunk.length > 65536)
          throw const FormatException('DAV error body limit');
        bytes.add(chunk);
      }
      final body = bytes.takeBytes();
      final errorResponse = DavResponse(
        statusCode: response.statusCode,
        headers: response.headers,
        bodyBytes: body,
        requestUri: response.requestUri,
        correlationId: _uuid.v7(),
      );
      if (method == 'REPORT')
        _requireReportStatus(errorResponse);
      else
        requireStatus(errorResponse, {207});
      throw StateError('Unreachable DAV status');
    } finally {
      await response.close();
    }
  }

  void _requireReportStatus(DavResponse response) {
    if (const {403, 409, 507}.contains(response.statusCode)) {
      Set<DavPropertyName> conditions = const {};
      try {
        conditions = parser.parseDavError(
          response.bodyBytes,
          correlationId: response.correlationId,
        );
      } on DavException catch (error) {
        // Invalid XML cannot establish a DAV condition. Preserve the HTTP
        // failure classification, but never suppress a local resource limit.
        if (error.kind != DavErrorKind.malformedXml &&
            error.kind != DavErrorKind.malformedStatus)
          rethrow;
      }
      if (const {403, 409}.contains(response.statusCode) &&
          conditions.contains(
            const DavPropertyName(davNamespace, 'valid-sync-token'),
          ))
        throw DavException(
          kind: DavErrorKind.invalidSyncToken,
          code: 'DavSyncTokenInvalid',
          safeMessage: 'The collection cursor expired.',
          statusCode: response.statusCode,
          correlationId: response.correlationId,
        );
      if (response.statusCode == 507 &&
          conditions.contains(
            const DavPropertyName(
              davNamespace,
              'number-of-matches-within-limits',
            ),
          ))
        throw DavException(
          kind: DavErrorKind.limitExceeded,
          code: 'DavSyncLimitRejected',
          safeMessage:
              'The server could not honor the collection result limit.',
          statusCode: response.statusCode,
          correlationId: response.correlationId,
        );
    }
    requireStatus(response, {207});
  }

  Uri resolve(String href, Uri responseUri) => resolveDavHref(
    href: href,
    responseRequestUri: responseUri,
    profile: profile,
    accountAuthority: authority,
  );
  void requireMember(Uri collection, Uri member) {
    final prefix = collection.path.endsWith('/')
        ? collection.path
        : collection.path + '/';
    if (!sameDavOrigin(collection, member) ||
        member.hasQuery ||
        member.hasFragment ||
        member.userInfo.isNotEmpty ||
        member.pathSegments.any(
          (segment) =>
              segment == '.' || segment == '..' || segment.contains(r'\'),
        ) ||
        !member.path.startsWith(prefix) ||
        member.path.length == prefix.length ||
        member.path.substring(prefix.length).contains('/')) {
      throw const DavException(
        kind: DavErrorKind.redirectRejected,
        code: 'DavMemberOutsideCollection',
        safeMessage: 'DAV returned an unrelated resource.',
      );
    }
  }

  void requireStatus(
    DavResponse response,
    Set<int> allowed, {
    bool mutation = false,
  }) {
    if (allowed.contains(response.statusCode)) return;
    final code = response.statusCode;
    throw DavException(
      kind: switch (code) {
        401 => DavErrorKind.authentication,
        403 => DavErrorKind.authorization,
        404 => DavErrorKind.notFound,
        409 => DavErrorKind.conflict,
        412 => DavErrorKind.preconditionFailed,
        429 => DavErrorKind.rateLimited,
        >= 500 => mutation ? DavErrorKind.unknownOutcome : DavErrorKind.server,
        _ => DavErrorKind.protocol,
      },
      code: 'DavHttp$code',
      safeMessage: 'The DAV operation was rejected.',
      statusCode: code,
      correlationId: response.correlationId,
      retryAfter: parseDavRetryAfter(response.headers['retry-after']),
    );
  }

  Iterable<String> _hrefs(DavProperty? property) =>
      property?.element.descendantElements
          .where(
            (e) =>
                e.name.namespaceUri == davNamespace && e.name.local == 'href',
          )
          .map((e) => e.innerText.trim()) ??
      [];
  bool _contains(DavProperty? property, String namespace, String name) =>
      property?.element.descendantElements.any(
        (e) => e.name.namespaceUri == namespace && e.name.local == name,
      ) ??
      false;
  DavCollection collectionFromProperties(
    DavMultistatusResponse entry,
    Uri uri,
  ) => _collection(entry, uri);
  DavCollection _collection(DavMultistatusResponse entry, Uri uri) {
    Set<DavPropertyName> names(String container, String wrapper) =>
        entry
            .successfulProperty(davNamespace, container)
            ?.element
            .descendantElements
            .where(
              (e) =>
                  e.name.namespaceUri == davNamespace &&
                  e.name.local == wrapper,
            )
            .expand(
              (e) => e.childElements.map(
                (c) => DavPropertyName(c.name.namespaceUri, c.name.local),
              ),
            )
            .toSet() ??
        {};
    return DavCollection(
      uri: uri,
      displayName:
          entry.successfulProperty(davNamespace, 'displayname')?.text ??
          uri.path,
      privileges: names('current-user-privilege-set', 'privilege'),
      reports: names('supported-report-set', 'report'),
      properties: entry,
    );
  }
}
