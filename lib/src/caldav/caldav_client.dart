import '../http/dav_http_transport.dart';
import '../dav_errors.dart';
import '../protocol/dav_resource_client.dart';
import '../xml/dav_xml.dart';

/// CalDAV protocol only: calendar/task interpretation stays in its application.
final class CalDavClient {
  const CalDavClient(this.resources);
  final DavResourceClient resources;

  /// Calendar collection creation protocol extracted from BusyMax's actual
  /// MKCALENDAR path. Naming, scheduling, persistence and uncertain-outcome
  /// reconciliation stay with the caller; this method never retries.
  Future<void> createCalendar(
    Uri home,
    Uri target, {
    required String displayName,
    Set<String> components = const {'VEVENT'},
    DavCancellationToken? cancellation,
  }) async {
    final root = home.path.endsWith('/') ? home.path : home.path + '/';
    if (target.origin != home.origin ||
        !target.path.startsWith(root) ||
        !target.path.endsWith('/') ||
        target.path == root ||
        target.path
            .substring(root.length, target.path.length - 1)
            .contains('/') ||
        target.pathSegments.any(
          (segment) =>
              segment == '.' || segment == '..' || segment.contains(r'\'),
        ) ||
        target.hasQuery ||
        target.hasFragment ||
        target.userInfo.isNotEmpty ||
        displayName.trim().isEmpty ||
        components.isEmpty ||
        components.difference(const {'VEVENT', 'VTODO', 'VJOURNAL'}).isNotEmpty)
      throw ArgumentError('Invalid calendar collection request');
    final response = await resources.request(
      'MKCALENDAR',
      target,
      cancellation: cancellation,
      xml:
          '<c:mkcalendar xmlns:d="DAV:" xmlns:c="' +
          caldavNamespace +
          '"><d:set><d:prop><d:displayname>' +
          davText(displayName.trim()) +
          '</d:displayname><c:supported-calendar-component-set>' +
          components
              .map((component) => '<c:comp name="' + component + '"/>')
              .join() +
          '</c:supported-calendar-component-set></d:prop></d:set></c:mkcalendar>',
    );
    resources.requireStatus(response, {201}, mutation: true);
  }

  Future<DavDiscoveryResult> discover({
    Uri? entryUri,
    DavCancellationToken? cancellation,
  }) => resources.discover(
    entryUri: entryUri ?? resources.authority.resolve('/.well-known/caldav'),
    namespace: caldavNamespace,
    homeProperty: 'calendar-home-set',
    collectionType: 'calendar',
    extraProperties: const [
      DavPropertyName(caldavNamespace, 'supported-calendar-component-set'),
      DavPropertyName(caldavNamespace, 'supported-calendar-data'),
      DavPropertyName(caldavNamespace, 'calendar-description'),
      DavPropertyName(caldavNamespace, 'max-resource-size'),
      DavPropertyName(caldavNamespace, 'schedule-inbox-URL'),
      DavPropertyName(caldavNamespace, 'schedule-outbox-URL'),
    ],
    cancellation: cancellation,
  );
  Future<List<DavObject>> query(
    Uri calendar, {
    String component = 'VEVENT',
    DateTime? start,
    DateTime? end,
    DavCancellationToken? cancellation,
  }) async {
    if (!const {'VEVENT', 'VTODO', 'VJOURNAL'}.contains(component))
      throw ArgumentError('Unsupported component');
    if ((start == null) != (end == null) ||
        (start != null && !start.isBefore(end!))) {
      throw ArgumentError('Invalid time range');
    }
    final range = start == null
        ? ''
        : '<c:time-range start="' +
              _time(start) +
              '" end="' +
              _time(end!) +
              '"/>';
    final result = await resources.report(
      calendar,
      '<c:calendar-query xmlns:d="DAV:" xmlns:c="' +
          caldavNamespace +
          '"><d:prop><d:getetag/>' +
          '<c:calendar-data/></d:prop><c:filter><c:comp-filter name="VCALENDAR"><c:comp-filter name="' +
          component +
          '">' +
          range +
          '</c:comp-filter></c:comp-filter></c:filter></c:calendar-query>',
      cancellation: cancellation,
    );
    return _objects(calendar, result);
  }

  Future<List<DavObject>> multiget(
    Uri calendar,
    Iterable<Uri> members, {
    DavCancellationToken? cancellation,
  }) async {
    final list = members.toList();
    if (list.length > 1000) throw RangeError('Multiget batch limit');
    for (final member in list) {
      resources.requireMember(calendar, member);
    }
    final result = await resources.report(
      calendar,
      '<c:calendar-multiget xmlns:d="DAV:" xmlns:c="' +
          caldavNamespace +
          '"><d:prop><d:getetag/><c:calendar-data/></d:prop>' +
          list
              .map((uri) => '<d:href>' + davText(uri.path) + '</d:href>')
              .join() +
          '</c:calendar-multiget>',
      cancellation: cancellation,
    );
    return _objects(calendar, result);
  }

  Future<DavObject> put(
    Uri uri,
    String fullIcalendar, {
    String? etag,
    bool create = false,
    DavCancellationToken? cancellation,
  }) => resources.put(
    uri,
    fullIcalendar,
    contentType: 'text/calendar; charset=utf-8',
    etag: etag,
    create: create,
    cancellation: cancellation,
  );
  Future<void> delete(
    Uri uri, {
    required String etag,
    DavCancellationToken? cancellation,
  }) => resources.delete(uri, etag: etag, cancellation: cancellation);
  Future<DavSyncResult> syncCollection(
    Uri uri,
    String token, {
    DavCancellationToken? cancellation,
  }) => resources.syncCollection(uri, token, cancellation: cancellation);
  List<DavObject> _objects(Uri calendar, DavMultistatus result) {
    if (result.hasCondition(davNamespace, 'number-of-matches-within-limits') ||
        result.responses.any((entry) => entry.statusCode == 507)) {
      throw const DavException(
        kind: DavErrorKind.limitExceeded,
        code: 'CalDavQueryTruncated',
        safeMessage: 'The calendar report was truncated.',
      );
    }
    final objects = <DavObject>[];
    for (final entry in result.responses) {
      final uri = resources.resolve(entry.href, calendar);
      resources.requireMember(calendar, uri);
      if (entry.isMissing) continue;
      final data = entry.successfulProperty(caldavNamespace, 'calendar-data');
      final etag = entry.successfulProperty(davNamespace, 'getetag');
      if (data == null || etag == null)
        throw const FormatException('Incomplete calendar response');
      objects.add(
        DavObject(
          uri: uri,
          etag: etag.text,
          data: data.text,
          contentType: 'text/calendar',
        ),
      );
    }
    return objects;
  }

  String _time(DateTime time) =>
      time
          .toUtc()
          .toIso8601String()
          .replaceAll('-', '')
          .replaceAll(':', '')
          .split('.')
          .first +
      'Z';
}
