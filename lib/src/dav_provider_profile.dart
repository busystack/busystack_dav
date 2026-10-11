import 'dav_errors.dart';

/// A credentials boundary, independent of provider account classes.
final class DavProviderProfile {
  const DavProviderProfile({
    this.additionalTrustedOrigins = const {},
    this.credentialScope = DavCredentialScope.origin,
    this.allowInsecureLoopback = false,
  });
  const DavProviderProfile.nextcloud({this.allowInsecureLoopback = false})
    : additionalTrustedOrigins = const {},
      credentialScope = DavCredentialScope.installation;
  const DavProviderProfile.iCloudCalDav()
    : additionalTrustedOrigins = const {},
      credentialScope = DavCredentialScope.iCloudCalDav,
      allowInsecureLoopback = false;
  final Set<Uri> additionalTrustedOrigins;
  final DavCredentialScope credentialScope;
  final bool allowInsecureLoopback;
  bool isTrustedCredentialDestination(
    Uri destination, {
    required Uri accountAuthority,
  }) {
    final insecureLoopback =
        allowInsecureLoopback &&
        accountAuthority.scheme == 'http' &&
        destination.scheme == 'http' &&
        _isLoopback(accountAuthority.host) &&
        _isLoopback(destination.host);
    if ((destination.scheme != 'https' && !insecureLoopback) ||
        destination.userInfo.isNotEmpty ||
        destination.fragment.isNotEmpty ||
        destination.host.isEmpty)
      return false;
    if (credentialScope == DavCredentialScope.iCloudCalDav) {
      bool approved(Uri uri) =>
          uri.scheme == 'https' &&
          uri.port == 443 &&
          (uri.host == 'caldav.icloud.com' ||
              RegExp(r'^p[0-9]+-caldav[.]icloud[.]com$').hasMatch(uri.host));
      return approved(accountAuthority) && approved(destination);
    }
    if (credentialScope == DavCredentialScope.installation) {
      if (!sameDavOrigin(accountAuthority, destination)) return false;
      final base = accountAuthority.path.replaceFirst(RegExp(r'/+$'), '');
      return base.isEmpty ||
          destination.path == base ||
          destination.path.startsWith(base + '/') ||
          (!destination.hasQuery &&
              const {
                '/.well-known/caldav',
                '/.well-known/carddav',
              }.contains(destination.path));
    }
    return sameDavOrigin(accountAuthority, destination) ||
        additionalTrustedOrigins.any(
          (origin) => sameDavOrigin(origin, destination),
        );
  }
}

bool _isLoopback(String host) {
  final normalized = host.toLowerCase();
  return normalized == 'localhost' ||
      normalized == '127.0.0.1' ||
      normalized == '::1';
}

enum DavCredentialScope { origin, installation, iCloudCalDav }

bool sameDavOrigin(Uri first, Uri second) =>
    first.scheme.toLowerCase() == second.scheme.toLowerCase() &&
    first.host.toLowerCase() == second.host.toLowerCase() &&
    first.port == second.port;

Uri resolveDavHref({
  required String href,
  required Uri responseRequestUri,
  required DavProviderProfile profile,
  required Uri accountAuthority,
  String? correlationId,
}) {
  final source = href.trim();
  Uri? resolved;
  try {
    resolved = responseRequestUri.resolve(source);
  } catch (_) {
    /* reject below */
  }
  if (source.isEmpty ||
      source.contains(r'\') ||
      resolved == null ||
      resolved.hasFragment ||
      resolved.hasQuery ||
      !profile.isTrustedCredentialDestination(
        resolved,
        accountAuthority: accountAuthority,
      )) {
    throw DavException(
      kind: DavErrorKind.redirectRejected,
      code: 'DavHrefDestinationRejected',
      safeMessage: 'Unsafe DAV resource reference.',
      correlationId: correlationId,
    );
  }
  return resolved;
}

/// Uri.path retains escaped reserved octets; never decode an opaque resource ID.
String normalizedDavHrefKey(Uri uri) {
  if (!uri.path.startsWith('/'))
    throw ArgumentError('Absolute DAV path required');
  return uri.path;
}
