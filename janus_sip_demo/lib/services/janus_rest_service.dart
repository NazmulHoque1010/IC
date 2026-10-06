import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class JanusRestService {
  JanusRestService({required this.serverUrl, http.Client? client})
    : _client = client ?? http.Client();

  final String serverUrl;
  final http.Client _client;

  int? _sessionId;
  int? _handleId;
  bool _disposed = false;

  int? get sessionId => _sessionId;
  int? get handleId => _handleId;

  Future<JanusSessionResult> createSessionAndAttachSip() async {
    _ensureNotDisposed();

    if (_sessionId != null && _handleId != null) {
      return JanusSessionResult(sessionId: _sessionId!, handleId: _handleId!);
    }

    final sessionResponse = await _post(serverUrl, <String, dynamic>{
      'janus': 'create',
      'transaction': _transactionId('create'),
    });

    _throwIfJanusError(sessionResponse);
    _expectSuccess(sessionResponse, 'creating a Janus session');

    _sessionId = _readId(sessionResponse['data'], 'id');

    final handleResponse = await _post(
      '$serverUrl/$_sessionId',
      <String, dynamic>{
        'janus': 'attach',
        'plugin': 'janus.plugin.sip',
        'transaction': _transactionId('attach'),
      },
    );

    _throwIfJanusError(handleResponse);
    _expectSuccess(handleResponse, 'attaching the SIP plugin');

    _handleId = _readId(handleResponse['data'], 'id');

    return JanusSessionResult(sessionId: _sessionId!, handleId: _handleId!);
  }

  Future<JanusSipRegistrationResult> registerSip({
    required String extension,
    required String password,
    required String sipServer,
    required String displayName,
  }) async {
    _ensureNotDisposed();

    final session = await createSessionAndAttachSip();
    final normalizedServer = _normalizeSipServer(sipServer);
    final domain = _sipDomain(normalizedServer);
    final normalizedExtension = extension.trim();

    final registerResponse = await _post(
      '$serverUrl/${session.sessionId}/${session.handleId}',
      <String, dynamic>{
        'janus': 'message',
        'transaction': _transactionId('register'),
        'body': <String, dynamic>{
          'request': 'register',
          'username': 'sip:$normalizedExtension@$domain',
          'authuser': normalizedExtension,
          'secret': password,
          'proxy': normalizedServer,
          'display_name': displayName,
        },
      },
    );

    _throwIfJanusError(registerResponse);

    if (registerResponse['janus'] != 'ack' &&
        registerResponse['janus'] != 'success') {
      throw JanusApiException(
        'Unexpected response while requesting SIP registration: '
        '${registerResponse['janus']}',
      );
    }

    final event = await _waitForSipRegistrationEvent();

    return JanusSipRegistrationResult(
      sessionId: session.sessionId,
      handleId: session.handleId,
      event: event,
    );
  }

  Future<JanusSipEvent> _waitForSipRegistrationEvent() async {
    final sessionId = _requireSessionId();
    final handleId = _requireHandleId();
    final deadline = DateTime.now().add(const Duration(seconds: 15));

    while (DateTime.now().isBefore(deadline)) {
      final response = await _get(
        '$serverUrl/$sessionId?rid=${DateTime.now().millisecondsSinceEpoch}&maxev=1',
      );

      _throwIfJanusError(response);

      if (response['janus'] == 'keepalive') {
        continue;
      }

      if (response['janus'] != 'event') {
        continue;
      }

      final sender = response['sender'];
      if (sender is! num || sender.toInt() != handleId) {
        continue;
      }

      final pluginData = response['plugindata'];
      if (pluginData is! Map<String, dynamic>) {
        continue;
      }

      if (pluginData['plugin'] != 'janus.plugin.sip') {
        continue;
      }

      final data = pluginData['data'];
      if (data is! Map<String, dynamic> || data['sip'] != 'event') {
        continue;
      }

      final result = data['result'];
      if (result is! Map<String, dynamic>) {
        continue;
      }

      final event = result['event']?.toString();

      if (event == 'registered') {
        return JanusSipEvent.registered(
          username: result['username']?.toString() ?? '',
        );
      }

      if (event == 'registration_failed') {
        return JanusSipEvent.failed(
          code: result['code']?.toString() ?? 'unknown',
          reason: result['reason']?.toString() ?? 'Unknown SIP error',
        );
      }
    }

    throw JanusApiException(
      'Timed out waiting for a SIP registration event from Janus.',
    );
  }

  Future<Map<String, dynamic>> _post(
    String url,
    Map<String, dynamic> body,
  ) async {
    final response = await _client
        .post(
          Uri.parse(url),
          headers: const <String, String>{'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 10));

    return _decodeHttpResponse(response);
  }

  Future<Map<String, dynamic>> _get(String url) async {
    final response = await _client
        .get(Uri.parse(url))
        .timeout(const Duration(seconds: 20));

    return _decodeHttpResponse(response);
  }

  Map<String, dynamic> _decodeHttpResponse(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw JanusApiException(
        'HTTP ${response.statusCode} from Janus: ${response.body}',
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw JanusApiException('Janus returned invalid JSON.');
    }

    return decoded;
  }

  String _normalizeSipServer(String value) {
    var server = value.trim();

    if (!server.startsWith('sip:') && !server.startsWith('sips:')) {
      server = 'sip:$server';
    }

    return server;
  }

  String _sipDomain(String sipServer) {
    var domain = sipServer
        .replaceFirst(RegExp(r'^sips?:'), '')
        .replaceFirst(RegExp(r';.*$'), '');

    final colonIndex = domain.lastIndexOf(':');
    if (colonIndex > -1) {
      domain = domain.substring(0, colonIndex);
    }

    if (domain.isEmpty) {
      throw JanusApiException('Could not derive a SIP domain from SIP server.');
    }

    return domain;
  }

  int _requireSessionId() {
    final value = _sessionId;
    if (value == null) {
      throw JanusApiException('Janus session has not been created.');
    }
    return value;
  }

  int _requireHandleId() {
    final value = _handleId;
    if (value == null) {
      throw JanusApiException('Janus SIP handle has not been created.');
    }
    return value;
  }

  int _readId(dynamic data, String key) {
    if (data is! Map<String, dynamic> || data[key] is! num) {
      throw JanusApiException('Janus response is missing data.$key.');
    }

    return (data[key] as num).toInt();
  }

  void _expectSuccess(Map<String, dynamic> response, String action) {
    if (response['janus'] != 'success') {
      throw JanusApiException(
        'Unexpected response while $action: ${response['janus']}',
      );
    }
  }

  void _throwIfJanusError(Map<String, dynamic> response) {
    if (response['janus'] != 'error') {
      return;
    }

    final error = response['error'];
    if (error is Map<String, dynamic>) {
      throw JanusApiException(
        'Janus error ${error['code']}: ${error['reason']}',
      );
    }

    throw JanusApiException('Janus returned an unknown error.');
  }

  String _transactionId(String action) {
    return '$action-${DateTime.now().microsecondsSinceEpoch}';
  }

  void _ensureNotDisposed() {
    if (_disposed) {
      throw JanusApiException('This Janus service has already been disposed.');
    }
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }

    _disposed = true;
    final sessionId = _sessionId;

    if (sessionId != null) {
      try {
        await _post('$serverUrl/$sessionId', <String, dynamic>{
          'janus': 'destroy',
          'transaction': _transactionId('destroy'),
        });
      } catch (_) {
        // Best-effort cleanup only.
      }
    }

    _client.close();
  }
}

class JanusSessionResult {
  const JanusSessionResult({required this.sessionId, required this.handleId});

  final int sessionId;
  final int handleId;
}

class JanusSipRegistrationResult {
  const JanusSipRegistrationResult({
    required this.sessionId,
    required this.handleId,
    required this.event,
  });

  final int sessionId;
  final int handleId;
  final JanusSipEvent event;
}

class JanusSipEvent {
  const JanusSipEvent._({
    required this.isRegistered,
    required this.username,
    this.code,
    this.reason,
  });

  const JanusSipEvent.registered({required String username})
    : this._(isRegistered: true, username: username);

  const JanusSipEvent.failed({required String code, required String reason})
    : this._(isRegistered: false, username: '', code: code, reason: reason);

  final bool isRegistered;
  final String username;
  final String? code;
  final String? reason;
}

class JanusApiException implements Exception {
  JanusApiException(this.message);

  final String message;

  @override
  String toString() => message;
}
