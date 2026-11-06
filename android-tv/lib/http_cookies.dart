import 'dart:io';

Map<String, String> cookieValues(String header) {
  final values = <String, String>{};
  for (final part in header.split(';')) {
    final split = part.indexOf('=');
    if (split > 0) {
      values[part.substring(0, split).trim()] = part
          .substring(split + 1)
          .trim();
    }
  }
  return values;
}

String mergeCookies(Iterable<String> headers) {
  final values = <String, String>{};
  for (final header in headers) {
    values.addAll(cookieValues(header));
  }
  return values.entries.map((e) => '${e.key}=${e.value}').join('; ');
}

class _StoredCookie {
  final Cookie cookie;
  final bool hostOnly;
  final DateTime? expires;
  _StoredCookie(this.cookie, this.hostOnly, this.expires);
  bool get expired => expires != null && !expires!.isAfter(DateTime.now());
}

/// Each plugin and each login transaction owns a separate cookie jar.
class PluginCookieJar {
  final List<_StoredCookie> _cookies = [];

  void receive(Cookie cookie, Uri uri) {
    final hostOnly = cookie.domain == null;
    final domain = (cookie.domain ?? uri.host)
        .replaceFirst(RegExp(r'^\.'), '')
        .toLowerCase();
    if (uri.host != domain && !uri.host.endsWith('.$domain')) return;
    if (domain != uri.host && !domain.contains('.')) return;
    cookie.domain = domain;
    if (cookie.path == null || !cookie.path!.startsWith('/')) {
      final slash = uri.path.lastIndexOf('/');
      cookie.path = slash <= 0 ? '/' : uri.path.substring(0, slash);
    }
    _cookies.removeWhere(
      (c) =>
          c.cookie.name == cookie.name &&
          c.cookie.domain == domain &&
          c.cookie.path == cookie.path,
    );
    final expires = cookie.maxAge == null
        ? cookie.expires
        : DateTime.now().add(Duration(seconds: cookie.maxAge!));
    final stored = _StoredCookie(cookie, hostOnly, expires);
    if (!stored.expired) _cookies.add(stored);
  }

  void seed(String name, String value, String domain) {
    receive(
      Cookie(name, value)
        ..domain = domain
        ..path = '/'
        ..secure = true,
      Uri.https(domain.replaceFirst(RegExp(r'^\.'), ''), '/'),
    );
  }

  String header(Uri uri) {
    _cookies.removeWhere((c) => c.expired);
    final matching =
        _cookies.where((stored) {
          final cookie = stored.cookie;
          final domain = cookie.domain!;
          final path = cookie.path!;
          final domainMatches =
              uri.host == domain ||
              (!stored.hostOnly && uri.host.endsWith('.$domain'));
          final pathMatches =
              uri.path == path ||
              (uri.path.startsWith(path) &&
                  (path.endsWith('/') ||
                      uri.path.substring(path.length).startsWith('/')));
          return domainMatches &&
              pathMatches &&
              (!cookie.secure || uri.scheme == 'https');
        }).toList()..sort(
          (a, b) => b.cookie.path!.length.compareTo(a.cookie.path!.length),
        );
    // The more specific path takes precedence when a server sets duplicate names.
    final values = <String, String>{};
    for (final c in matching) {
      values.putIfAbsent(c.cookie.name, () => c.cookie.value);
    }
    return values.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  String exportCredentials(bool Function(Uri) allowed) => mergeCookies(
    _cookies
        .where((c) => !c.expired && allowed(Uri.https(c.cookie.domain!, '/')))
        .map((c) => '${c.cookie.name}=${c.cookie.value}'),
  );
}
