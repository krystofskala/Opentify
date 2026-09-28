import 'dart:convert';

import 'package:http/http.dart' as http;

/// Vyhozeno pro každou non-2xx odpověď — nese status kód a syrové tělo, aby
/// ho volající mohl zobrazit nebo se podle kódu rozhodnout (404 -> "nenalezeno"
/// stav v UI, ne obecná chybová hláška).
class ApiException implements Exception {
  ApiException({required this.statusCode, required this.body});

  final int statusCode;
  final String body;

  @override
  String toString() => 'ApiException($statusCode): $body';
}

/// Tenký HTTP wrapper nad `docs/openapi.yaml` — base URL + dev auth hlavičky
/// na jednom místě, JSON (de)serializaci řeší až repository vrstva
/// (CatalogRepository apod.), tenhle klient zůstává obecný.
class ApiClient {
  ApiClient({
    required this.baseUrl,
    required this.userId,
    required this.deviceId,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final String baseUrl;
  final String userId;
  final String deviceId;
  final http.Client _http;

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'X-User-Id': userId,
        'X-Device-Id': deviceId,
      };

  Uri _uri(String path, Map<String, String>? query) {
    final clean = query?.map((k, v) => MapEntry(k, v));
    return Uri.parse('$baseUrl$path').replace(
      queryParameters: (clean == null || clean.isEmpty) ? null : clean,
    );
  }

  Future<Map<String, dynamic>> getJson(String path, {Map<String, String>? query}) async {
    final response = await _http.get(_uri(path, query), headers: _headers);
    return _decode(response) as Map<String, dynamic>;
  }

  Future<List<dynamic>> getJsonList(String path, {Map<String, String>? query}) async {
    final response = await _http.get(_uri(path, query), headers: _headers);
    return _decode(response) as List<dynamic>;
  }

  Future<Map<String, dynamic>> postJson(String path, {Object? body}) async {
    final response = await _http.post(
      _uri(path, null),
      headers: _headers,
      body: body == null ? null : jsonEncode(body),
    );
    return _decode(response) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> patchJson(String path, {Object? body}) async {
    final response = await _http.patch(
      _uri(path, null),
      headers: _headers,
      body: body == null ? null : jsonEncode(body),
    );
    return _decode(response) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>?> deleteJson(String path) async {
    final response = await _http.delete(_uri(path, null), headers: _headers);
    return _decode(response) as Map<String, dynamic>?;
  }

  /// Upload souboru (multipart/form-data) — `http.MultipartRequest` si sám
  /// nastaví `Content-Type` s boundary, takže mu do hlaviček nesmí přijít
  /// pevné `application/json` z `_headers`.
  Future<Map<String, dynamic>> postMultipart(
    String path, {
    required String fieldName,
    required List<int> bytes,
    required String filename,
  }) async {
    final request = http.MultipartRequest('POST', _uri(path, null));
    request.headers.addAll(Map<String, String>.from(_headers)..remove('Content-Type'));
    request.files.add(http.MultipartFile.fromBytes(fieldName, bytes, filename: filename));
    final streamed = await _http.send(request);
    final response = await http.Response.fromStream(streamed);
    return _decode(response) as Map<String, dynamic>;
  }

  dynamic _decode(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(statusCode: response.statusCode, body: response.body);
    }
    if (response.body.isEmpty) return null;
    return jsonDecode(utf8.decode(response.bodyBytes));
  }

  void close() => _http.close();
}
