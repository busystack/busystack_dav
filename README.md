# busystack_dav

Pure Dart DAV transport and protocol operations. Public libraries are `busystack_dav.dart`, `carddav.dart`, `caldav.dart` and `nextcloud.dart`. Implementation is private under `lib/src`. There are no Flutter, account-storage, file-node, calendar-projection or contacts-persistence dependencies.

`DavHttpTransport` supplies bounded resource requests, conditional headers, cancellation, limits and safe error information. `DavResourceClient` supplies principal/home/collection discovery, validated href membership, properties, enumeration, conditional resources and RFC 6578 collection synchronization. Discovery follows its explicit bounded redirect policy; operational requests do not redirect. Credentials only follow normalized, explicitly trusted destinations. The Nextcloud profile additionally restricts credentials to the installation path and exact standard well-known discovery endpoints.

`CardDavClient` implements address-book discovery, advertised privileges and supported vCard versions, full/selected-property address data, address-book query/multiget and conditional resource operations. Address-book creation is negotiated through extended MKCOL and parent privileges. `CalDavClient` separately implements calendar-home-set discovery, supported components, calendar query/multiget, conditional calendar objects and collection sync. Calendar storage/scheduling and address-object interpretation remain outside this package.

`DavXmlParser` bounds small-resource XML. `parseDavMultistatusStream` parses events incrementally with independent byte, entry, property, depth and element limits, rejecting DTD/entities and incomplete/truncated responses. It returns a validated complete result; callers must not commit cursors from partial XML.

`DavTransferClient.download`, `openRead` and `upload` preserve streaming/backpressure without a whole-file body limit. `openRead` exposes response metadata and a single-consumption body suitable for incremental PROPFIND, REPORT and Nextcloud file `SEARCH` decoding. Call `close` if abandoning the body. Request and response metadata have independent bounds. No transfer automatically retries an uncertain mutation. Native cancellation uses the independently copied terminating-client mechanism; standard TLS validation remains enabled.

`NextcloudLoginFlowV2` provides only protocol mechanics: trusted launch/poll destinations, bounded polling, cancellation and returned server/loginName/appPassword. Applications own browser presentation, secure credential storage and account coordination. Nextcloud contacts subsequently use proper CardDAV discovery.

```
dart pub get --enforce-lockfile
dart format --output=none --set-exit-if-changed lib test example
dart analyze
dart test
dart run example/main.dart
```

Requires Dart 3.13.4; XML is 7.0.1. Copied BusyMax XML 6.6.1 behavior was ported inside this package; donor resolutions were not changed. See BusyCards' donor map, regression tests and streaming measurements. BusyFiles file-specific IDs, checksums, permissions, chunking, OCS/share/trash/version operations remain in BusyFiles. Existing apps have not adopted these APIs in Milestone 1.

The reproducible local source release contains all four new sibling targets. Future publication can use exact hosted versions of this same package without adding packages; nothing is published here. Apache-2.0, with donor attribution in NOTICE.


Transport adapters may implement `DavRequestNotDispatchedException` only when
an enforcement boundary proves that no HTTP bytes were transmitted. The
transport preserves such failures without retry or unknown-mutation wrapping.
`DavException` is extensible so applications can retain typed review details.
Unproven write failures still require remote reconciliation. Nextcloud Login
Flow endpoints and canonical handoffs remain inside the configured installation.
