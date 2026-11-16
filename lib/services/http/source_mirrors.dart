import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http_interceptor/http_interceptor.dart';
import 'package:path_provider/path_provider.dart';

/// A user-configured domain mirror: any request whose host is [fromHost] is
/// transparently redirected to [toOrigin] ("scheme://host[:port]"), keeping
/// the path, query and fragment. Sources on sites that rotate domains (for
/// example Kagane) keep working by pointing a dead or unreachable host at a
/// live mirror.
class SourceMirror {
  const SourceMirror({required this.fromHost, required this.toOrigin});

  /// The host to redirect, lowercase, no scheme and no path (for example
  /// "kagane.to").
  final String fromHost;

  /// The origin requests are redirected to, for example "https://kagane.moe".
  final String toOrigin;

  Map<String, dynamic> toJson() => {'from': fromHost, 'to': toOrigin};
}

/// Device-local store of [SourceMirror]s, persisted as a JSON file. Mirrors
/// are a property of this device's network, so they are deliberately kept out
/// of the synced settings.
class SourceMirrorStore {
  SourceMirrorStore._();

  static List<SourceMirror> mirrors = [];

  static Map<String, String> _index = {};

  static const _fileName = 'source_mirrors.json';

  /// The mirrors as they go on the wire to the extension server.
  static Map<String, String> wireMap() => {
    for (final m in mirrors) m.fromHost: m.toOrigin,
  };

  static void _reindex() {
    _index = {
      for (final m in mirrors)
        if (m.fromHost.isNotEmpty && m.toOrigin.isNotEmpty) m.fromHost: m.toOrigin,
    };
  }

  /// The origin [url] is redirected to, or null when no mirror matches.
  static Uri? targetFor(Uri url) {
    final host = url.host;
    final origin =
        _index[host] ?? _index[host.replaceFirst(RegExp(r'^www\.'), '')] ??
        _index['www.$host'];
    if (origin == null) return null;
    return Uri.tryParse(origin);
  }

  /// [url] rewritten to its mirror, preserving query, fragment and userInfo.
  /// A target without an explicit port lets the scheme pick the default, so
  /// an original URL that carried an odd port does not drag it along.
  static Uri rewrite(Uri url) {
    final target = targetFor(url);
    if (target == null || !target.hasScheme || target.host.isEmpty) {
      return url;
    }
    final explicitPort =
        target.port != (target.scheme == 'https' ? 443 : 80);
    return Uri(
      scheme: target.scheme,
      userInfo: url.userInfo,
      host: target.host,
      port: explicitPort ? target.port : 0,
      path: url.path,
      query: url.hasQuery ? url.query : null,
      fragment: url.fragment,
    );
  }

  /// Adds or replaces the mirror for [fromHost]. Returns the normalized
  /// mirror, or null when either side is invalid.
  static SourceMirror? upsert(String fromHost, String toOrigin) {
    final host = normalizeHost(fromHost);
    final origin = normalizeOrigin(toOrigin);
    if (host == null || origin == null) return null;
    mirrors
      ..removeWhere((m) => m.fromHost == host)
      ..add(SourceMirror(fromHost: host, toOrigin: origin));
    _reindex();
    return SourceMirror(fromHost: host, toOrigin: origin);
  }

  static bool remove(String fromHost) {
    final host = normalizeHost(fromHost) ?? fromHost.trim().toLowerCase();
    final removed = mirrors.removeWhere((m) => m.fromHost == host);
    _reindex();
    return removed > 0;
  }

  /// "kagane.to", "https://kagane.to/" and "KAGANE.TO" all mean "kagane.to".
  static String? normalizeHost(String value) {
    var host = value.trim();
    if (host.isEmpty) return null;
    final asUrl = Uri.tryParse(host);
    if (host.contains('://') && asUrl != null && asUrl.host.isNotEmpty) {
      host = asUrl.host;
    }
    host = host.toLowerCase();
    if (host.startsWith('www.')) host = host.substring(4);
    if (!RegExp(r'^[a-z0-9.-]+$').hasMatch(host) || !host.contains('.')) {
      return null;
    }
    return host;
  }

  /// "kagane.moe" means "https://kagane.moe"; a full origin may carry an
  /// explicit port. Returns null when the result is not a usable origin.
  static String? normalizeOrigin(String value) {
    var origin = value.trim();
    if (origin.isEmpty) return null;
    if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(origin)) {
      origin = 'https://$origin';
    }
    final parsed = Uri.tryParse(origin);
    if (parsed == null || !parsed.hasScheme || parsed.host.isEmpty) {
      return null;
    }
    if (parsed.scheme != 'http' && parsed.scheme != 'https') return null;
    final validHost = normalizeHost(parsed.host);
    if (validHost == null) return null;
    final explicitPort =
        parsed.port != (parsed.scheme == 'https' ? 443 : 80);
    return Uri(
      scheme: parsed.scheme,
      host: parsed.host,
      port: explicitPort ? parsed.port : 0,
    ).toString();
  }

  static Future<void> load() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_fileName');
      if (!await file.exists()) return;
      final data = jsonDecode(await file.readAsString());
      final list = data is Map ? data['mirrors'] : null;
      if (list is List) {
        mirrors = [
          for (final entry in list)
            if (entry is Map &&
                entry['from'] != null &&
                entry['to'] != null)
              SourceMirror(
                fromHost: entry['from'].toString(),
                toOrigin: entry['to'].toString(),
              ),
        ];
      }
    } catch (_) {
      mirrors = [];
    }
    _reindex();
  }

  static Future<void> save() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_fileName');
      await file.writeAsString(
        jsonEncode({
          'mirrors': [for (final m in mirrors) m.toJson()],
        }),
      );
    } catch (_) {}
  }
}

/// Applies [SourceMirrorStore] to every request this app's own clients make:
/// JavaScript, Dart and Aidoku sources, trackers and image downloads. Mihon
/// APK extensions fetch inside the extension server, so those are covered by
/// the server-side mirror set pushed through /setHostMirrors instead.
class MirrorInterceptor extends InterceptorContract {
  @override
  Future<BaseRequest> interceptRequest({required BaseRequest request}) async {
    try {
      if (SourceMirrorStore.targetFor(request.url) == null) return request;
      final newUrl = SourceMirrorStore.rewrite(request.url);
      if (request is http.Request) {
        final mirrored =
            http.Request(request.method, newUrl)
              ..followRedirects = request.followRedirects
              ..maxRedirects = request.maxRedirects
              ..persistentConnection = request.persistentConnection;
        mirrored.headers.addAll(request.headers);
        mirrored.bodyBytes = request.bodyBytes;
        return mirrored;
      }
      if (request is http.MultipartRequest) {
        final mirrored =
            http.MultipartRequest(request.method, newUrl)
              ..followRedirects = request.followRedirects
              ..maxRedirects = request.maxRedirects
              ..persistentConnection = request.persistentConnection;
        mirrored.headers.addAll(request.headers);
        mirrored.fields.addAll(request.fields);
        mirrored.files.addAll(request.files);
        return mirrored;
      }
      // Streamed uploads cannot be replayed safely; leave them untouched.
      return request;
    } catch (_) {
      return request;
    }
  }

  @override
  Future<BaseResponse> interceptResponse({
    required BaseResponse response,
  }) async {
    return response;
  }
}
