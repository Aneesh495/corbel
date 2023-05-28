import 'dart:convert';
import 'dart:io';

/// Route handler callback taking request, response, and matched path parameters.
typedef RouteHandler = Future<void> Function(
  HttpRequest request,
  HttpResponse response,
  Map<String, String> params,
);

class _RouteEntry {
  final String method;
  final List<String> segments;
  final RouteHandler handler;

  _RouteEntry(this.method, this.segments, this.handler);
}

/// High-performance HTTP request router matching parameterized REST endpoints.
class CorbelRouter {
  final List<_RouteEntry> _routes = [];

  void addRoute(String method, String path, RouteHandler handler) {
    final cleanPath = path.startsWith('/') ? path.substring(1) : path;
    final segments = cleanPath.isEmpty ? <String>[] : cleanPath.split('/');
    _routes.add(_RouteEntry(method.toUpperCase(), segments, handler));
  }

  void get(String path, RouteHandler handler) => addRoute('GET', path, handler);
  void post(String path, RouteHandler handler) => addRoute('POST', path, handler);
  void put(String path, RouteHandler handler) => addRoute('PUT', path, handler);
  void delete(String path, RouteHandler handler) => addRoute('DELETE', path, handler);

  /// Dispatches incoming [request] to matching route handler.
  Future<void> handle(HttpRequest request) async {
    final method = request.method.toUpperCase();
    final uriPath = request.uri.path;
    final cleanPath = uriPath.startsWith('/') ? uriPath.substring(1) : uriPath;
    final reqSegments = cleanPath.isEmpty ? <String>[] : cleanPath.split('/');

    for (final route in _routes) {
      if (route.method != method) continue;
      if (route.segments.length != reqSegments.length) continue;

      final params = <String, String>{};
      var matches = true;

      for (var i = 0; i < route.segments.length; i++) {
        final patternSeg = route.segments[i];
        final actualSeg = reqSegments[i];

        if (patternSeg.startsWith(':')) {
          final paramName = patternSeg.substring(1);
          params[paramName] = Uri.decodeComponent(actualSeg);
        } else if (patternSeg != actualSeg) {
          matches = false;
          break;
        }
      }

      if (matches) {
        try {
          await route.handler(request, request.response, params);
        } catch (err, stack) {
          _sendJson(
            request.response,
            HttpStatus.internalServerError,
            {
              'error': err.toString(),
              'stack': stack.toString(),
            },
          );
        }
        return;
      }
    }

    _sendJson(
      request.response,
      HttpStatus.notFound,
      {'error': 'Route not found: ${request.method} $uriPath'},
    );
  }

  static void _sendJson(HttpResponse response, int statusCode, Map<String, dynamic> body) {
    final jsonStr = jsonEncode(body);
    response.statusCode = statusCode;
    response.headers.contentType = ContentType.json;
    response.write(jsonStr);
    response.close();
  }
}
