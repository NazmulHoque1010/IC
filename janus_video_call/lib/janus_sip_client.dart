import 'dart:async';
import 'dart:convert';
import 'dart:io';

// ignore_for_file: avoid_print

/// Signature for SIP plugin events forwarded to the UI.
///
/// [event] is the SIP plugin event name ("incomingcall", "accepted",
/// "hangup", ...) or "error" for plugin errors.
typedef SipEventHandler = Future<void> Function(
  String event,
  Map<String, dynamic> data,
  Map<String, dynamic>? jsep,
);

class JanusException implements Exception {
  JanusException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Minimal Janus WebSocket client for the SIP plugin.
///
/// One instance = one Janus session + one SIP plugin handle.
class JanusSipClient {
  JanusSipClient({required this.onSipEvent, required this.onConnectionLost});

  final SipEventHandler onSipEvent;
  final void Function(String reason) onConnectionLost;

  WebSocket? _socket;
  StreamSubscription<dynamic>? _subscription;
  Timer? _keepAlive;

  int? _sessionId;
  int? _handleId;

  final Map<String, Completer<Map<String, dynamic>>> _pending = {};
  Completer<void>? _registerCompleter;
  Future<void> _eventChain = Future<void>.value();
  int _counter = 0;
  bool _closed = false;

  // ---------------------------------------------------------------------------
  // Connection
  // ---------------------------------------------------------------------------

  /// Opens the WebSocket, creates a Janus session and attaches the SIP plugin.
  Future<void> connect(String url) async {
    print('JANUS: connecting to $url');

    final socket = await WebSocket.connect(
      url,
      protocols: ['janus-protocol'],
    ).timeout(const Duration(seconds: 10));

    socket.pingInterval = const Duration(seconds: 20);
    _socket = socket;

    _subscription = socket.listen(
      _onData,
      onError: (Object error) => print('JANUS: WebSocket error: $error'),
      onDone: () => _lost('Janus WebSocket closed.'),
      cancelOnError: false,
    );

    final created = await _send({'janus': 'create'}, withSession: false);
    _sessionId = (created['data'] as Map)['id'] as int;

    _keepAlive = Timer.periodic(
      const Duration(seconds: 25),
      (_) => _fire({'janus': 'keepalive'}),
    );

    final attached = await _send({
      'janus': 'attach',
      'plugin': 'janus.plugin.sip',
    });
    _handleId = (attached['data'] as Map)['id'] as int;

    print('JANUS: session=$_sessionId handle=$_handleId');
  }

  /// Destroys the Janus session and closes the WebSocket.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;

    _fire({'janus': 'destroy'});
    await _cleanup('Client closed.');
  }

  // ---------------------------------------------------------------------------
  // SIP plugin requests
  // ---------------------------------------------------------------------------

  /// Registers [extension] with the SIP server at [sipHost]:[sipPort]
  /// and waits for "registered" or "registration_failed".
  Future<void> register({
    required String extension,
    required String password,
    required String sipHost,
    required int sipPort,
  }) async {
    final completer = Completer<void>();
    completer.future.ignore();
    _registerCompleter = completer;

    try {
      await _send(
        {
          'janus': 'message',
          'body': {
            'request': 'register',
            'username': 'sip:$extension@$sipHost',
            'authuser': extension,
            'display_name': extension,
            'secret': password,
            'proxy': 'sip:$sipHost:$sipPort',
          },
        },
        withHandle: true,
      );

      await completer.future.timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw JanusException('No registration answer within 15 seconds.');
    } finally {
      _registerCompleter = null;
    }
  }

  Future<void> call({
    required String uri,
    required Map<String, dynamic> jsep,
  }) async {
    await _send(
      {
        'janus': 'message',
        'body': {'request': 'call', 'uri': uri},
        'jsep': jsep,
      },
      withHandle: true,
      timeout: const Duration(seconds: 15),
    );
  }

  Future<void> accept(Map<String, dynamic> jsep) async {
    await _send(
      {
        'janus': 'message',
        'body': {'request': 'accept'},
        'jsep': jsep,
      },
      withHandle: true,
      timeout: const Duration(seconds: 15),
    );
  }

  Future<void> decline() async {
    await _send(
      {
        'janus': 'message',
        'body': {'request': 'decline'},
      },
      withHandle: true,
    );
  }

  Future<void> hangup() async {
    await _send(
      {
        'janus': 'message',
        'body': {'request': 'hangup'},
      },
      withHandle: true,
    );
  }

  /// Sends one local ICE candidate to Janus (trickle ICE).
  void trickle(Map<String, dynamic> candidate) {
    _fire({'janus': 'trickle', 'candidate': candidate}, withHandle: true);
  }

  // ---------------------------------------------------------------------------
  // Transport helpers
  // ---------------------------------------------------------------------------

  String _nextTransaction() {
    _counter++;
    return '${DateTime.now().microsecondsSinceEpoch}-$_counter';
  }

  /// Sends a request and waits for its success / ack / error reply.
  Future<Map<String, dynamic>> _send(
    Map<String, dynamic> payload, {
    bool withSession = true,
    bool withHandle = false,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final socket = _socket;
    if (socket == null) {
      throw JanusException('Not connected to Janus.');
    }

    final transaction = _nextTransaction();
    final message = <String, dynamic>{...payload, 'transaction': transaction};

    if (withSession) message['session_id'] = _sessionId;
    if (withHandle) message['handle_id'] = _handleId;

    final completer = Completer<Map<String, dynamic>>();
    _pending[transaction] = completer;

    final body = payload['body'];
    print('JANUS -> ${payload['janus']} '
        '${body is Map ? body['request'] ?? '' : ''}');

    socket.add(jsonEncode(message));

    try {
      final response = await completer.future.timeout(timeout);

      if (response['janus'] == 'error') {
        final error = response['error'];
        final code = error is Map ? error['code'] : '';
        final reason = error is Map ? error['reason'] : error;
        throw JanusException('Janus error $code: $reason');
      }

      return response;
    } on TimeoutException {
      _pending.remove(transaction);
      throw JanusException(
        'Janus did not answer "${payload['janus']}" in time.',
      );
    }
  }

  /// Sends a message without waiting for a reply.
  void _fire(Map<String, dynamic> payload, {bool withHandle = false}) {
    final socket = _socket;
    final sessionId = _sessionId;
    if (socket == null || sessionId == null) return;
    if (withHandle && _handleId == null) return;

    final message = <String, dynamic>{
      ...payload,
      'transaction': _nextTransaction(),
      'session_id': sessionId,
    };
    if (withHandle) message['handle_id'] = _handleId;

    try {
      socket.add(jsonEncode(message));
    } catch (error) {
      print('JANUS: send failed: $error');
    }
  }

  void _onData(dynamic data) {
    if (data is! String) return;

    print('JANUS <- $data');

    Map<String, dynamic> message;
    try {
      message = jsonDecode(data) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    final type = message['janus'];
    final transaction = message['transaction'];

    if (transaction is String &&
        (type == 'success' || type == 'error' || type == 'ack')) {
      final pending = _pending.remove(transaction);
      if (pending != null && !pending.isCompleted) {
        pending.complete(message);
        return;
      }
    }

    if (type == 'timeout') {
      _lost('Janus session timed out.');
      return;
    }

    if (type != 'event') return;

    // Handle events one at a time, in order.
    _eventChain = _eventChain
        .then((_) => _handleEvent(message))
        .catchError((Object error, StackTrace stackTrace) {
      print('EVENT HANDLER ERROR: $error\n$stackTrace');
    });
  }

  Future<void> _handleEvent(Map<String, dynamic> message) async {
    final pluginData = message['plugindata'];
    if (pluginData is! Map) return;

    final rawData = pluginData['data'];
    if (rawData is! Map) return;
    final data = Map<String, dynamic>.from(rawData);

    final rawJsep = message['jsep'];
    final jsep = rawJsep is Map ? Map<String, dynamic>.from(rawJsep) : null;

    final registration = _registerCompleter;

    if (data['error'] != null) {
      final text =
          'SIP plugin error ${data['error_code'] ?? ''}: ${data['error']}';
      if (registration != null && !registration.isCompleted) {
        registration.completeError(JanusException(text));
        return;
      }
      await onSipEvent('error', {'reason': text}, null);
      return;
    }

    final rawResult = data['result'];
    if (rawResult is! Map) return;
    final result = Map<String, dynamic>.from(rawResult);
    final event = result['event']?.toString() ?? '';

    print('SIP event: $event');

    if (registration != null && !registration.isCompleted) {
      if (event == 'registered') {
        registration.complete();
        return;
      }
      if (event == 'registration_failed') {
        registration.completeError(JanusException(
          'Registration failed: ${result['code']} ${result['reason']}',
        ));
        return;
      }
    }

    await onSipEvent(event, result, jsep);
  }

  void _lost(String reason) {
    if (_closed) return;
    _closed = true;
    print('JANUS: connection lost: $reason');
    unawaited(_cleanup(reason));
    onConnectionLost(reason);
  }

  Future<void> _cleanup(String reason) async {
    _keepAlive?.cancel();
    _keepAlive = null;

    for (final pending in _pending.values) {
      if (!pending.isCompleted) {
        pending.completeError(JanusException(reason));
      }
    }
    _pending.clear();

    final registration = _registerCompleter;
    if (registration != null && !registration.isCompleted) {
      registration.completeError(JanusException(reason));
    }

    final subscription = _subscription;
    final socket = _socket;
    _subscription = null;
    _socket = null;

    try {
      await subscription?.cancel();
    } catch (_) {}
    try {
      await socket?.close();
    } catch (_) {}
  }
}
