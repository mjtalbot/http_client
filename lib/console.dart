import 'dart:async';
import 'dart:io' as io;

import 'http_client.dart';
import 'src/headers.dart' show wrapHeaders;

export 'http_client.dart';

/// HTTP Client in console (server) environment.
class ConsoleClient implements Client {
  final io.HttpClient _delegate;
  final Headers _headers;

  ConsoleClient._(this._delegate, this._headers);

  /// HTTP Client in console (server) environment.
  ///
  /// Set [proxy] for static http proxy, or [proxyFn] for dynamic http proxy.
  /// Return format should be e.g. ""PROXY host:port; PROXY host2:port2; DIRECT"
  factory ConsoleClient({
    String proxy,
    String Function(Uri uri) proxyFn,

    /* Headers | Map */
    dynamic headers,

    /// The idle timeout of non-active persistent (keep-alive) connections.
    Duration idleTimeout,

    /// the maximum number of live connections, to a single host.
    int maxConnectionsPerHost,

    /// Whether the body of a response will be automatically uncompressed.
    bool autoUncompress,

    /// The default value of the `User-Agent` header for all requests.
    /// Set to empty string to disable setting the User-Agent header automatically.
    String userAgent,

    /// Whether to silently ignore bad certificates.
    /// Use it only on known servers with demo/expired SSL certs.
    bool ignoreBadCertificates,
  }) {
    ignoreBadCertificates ??= false;
    final delegate = io.HttpClient();
    if (proxy != null) {
      delegate.findProxy = (uri) => proxy;
    } else if (proxyFn != null) {
      delegate.findProxy = proxyFn;
    }
    if (idleTimeout != null) {
      delegate.idleTimeout = idleTimeout;
    }
    if (maxConnectionsPerHost != null) {
      delegate.maxConnectionsPerHost = maxConnectionsPerHost;
    }
    if (autoUncompress != null) {
      delegate.autoUncompress = autoUncompress;
    }
    if (userAgent != null) {
      delegate.userAgent = userAgent.isEmpty ? null : userAgent;
    }
    if (ignoreBadCertificates) {
      delegate.badCertificateCallback = (cert, host, port) => true;
    }
    return ConsoleClient._(delegate, wrapHeaders(headers, clone: true));
  }

  @override
  Future<Response> send(Request request) {
    if (request.timeout != null && request.timeout > Duration.zero) {
      return _send(request).timeout(request.timeout);
    } else {
      return _send(request);
    }
  }

  Future<Response> _send(Request request) async {
    final rq = await _delegate.openUrl(request.method, request.uri);
    final appliedHeaders = <String>{};

    void applyHeader(Headers headers, String key) {
      final values = headers[key];
      if (values == null || values.isEmpty) return;
      appliedHeaders.add(key.toLowerCase());
      if (values.length == 1) {
        rq.headers.set(key, values.single);
      } else {
        rq.headers.set(key, values);
      }
    }

    void applyContentLength(int length) {
      if (appliedHeaders.contains('content-length')) return;
      rq.headers.set('Content-Length', length.toString());
    }

    request?.headers?.keys?.forEach((key) {
      applyHeader(request.headers, key);
    });
    _headers?.keys?.forEach((key) {
      if (appliedHeaders.contains(key)) return;
      applyHeader(_headers, key);
    });

    if (request.persistentConnection != null) {
      rq.persistentConnection = request.persistentConnection;
    }
    if (request.followRedirects != null) {
      rq.followRedirects = request.followRedirects;
    }
    if (request.maxRedirects != null) {
      rq.maxRedirects = request.maxRedirects;
    }

    // sending body
    final body = request.body;
    if (body is List<int>) {
      applyContentLength(body.length);
      rq.add(body);
      await rq.close();
    } else if (body is StreamFn) {
      final stream = await body();
      await stream.pipe(rq);
    } else if (body is Stream<List<int>>) {
      await body.pipe(rq);
    } else if (body is io.File) {
      applyContentLength(await body.length());
      await body.openRead().cast<List<int>>().pipe(rq);
    } else if (body == null) {
      await rq.close();
    } else {
      throw ArgumentError('Unknown request body: ${request.body}');
    }

    final rs = await rq.done;
    await rq.close();
    final headers = Headers();
    rs.headers.forEach((String key, List<String> values) {
      headers.add(key, values);
    });

    return Response(
      rs.statusCode,
      rs.reasonPhrase,
      headers,
      rs,
      redirects: rs?.redirects
          ?.map((ri) => RedirectInfo(ri.statusCode, ri.method, ri.location))
          ?.toList(),
      requestAddress: rq?.connectionInfo?.remoteAddress?.address,
      responseAddress: rs?.connectionInfo?.remoteAddress?.address,
    );
  }

  @override
  Future close({bool force = false}) async {
    _delegate.close(force: force);
  }
}
