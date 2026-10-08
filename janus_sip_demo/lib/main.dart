import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

// ignore_for_file: avoid_print, unnecessary_string_interpolations

void main() {
  runApp(const JanusSipDemoApp());
}

class JanusSipDemoApp extends StatelessWidget {
  const JanusSipDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Janus SIP Demo (WebSocket)',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const MyHomePage(),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  final TextEditingController _janusIpController = TextEditingController();
  final TextEditingController _janusPortController =
      TextEditingController(text: '8188');
  final TextEditingController _sipServerController = TextEditingController();
  final TextEditingController _sipPortController = TextEditingController();
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _destinationController = TextEditingController();

  String _status = 'Enter connection details and register.';
  bool _isRegistering = false;
  bool _isRegistered = false;

  bool _isCalling = false;
  bool _isInCall = false;
  bool _incomingCallVisible = false;
  bool _incomingCancelledByCaller = false;
  BuildContext? _incomingDialogContext;
  bool _processingRemoteHangup = false;

  int? _sessionId;
  int? _handleId;

  WebSocket? _socket;
  StreamSubscription<dynamic>? _socketSub;
  Timer? _keepAliveTimer;

  final Map<String, Completer<Map<String, dynamic>>> _pending = {};
  Completer<String>? _registrationCompleter;
  Future<void> _eventChain = Future<void>.value();
  int _transactionCounter = 0;

  MediaStream? _localStream;
  RTCPeerConnection? _peerConnection;

  String get _janusWsUrl {
    final ip = _janusIpController.text.trim();
    final port = _janusPortController.text.trim();
    return 'ws://$ip:$port';
  }

  String get _sipServer => _sipServerController.text.trim();

  int get _sipServerPort =>
      int.tryParse(_sipPortController.text.trim()) ?? 5060;

  String get _destinationSipUser => _destinationController.text.trim();

  @override
  void dispose() {
    _keepAliveTimer?.cancel();

    _janusIpController.dispose();
    _janusPortController.dispose();
    _sipServerController.dispose();
    _sipPortController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _destinationController.dispose();

    unawaited(_closeWebSocket());
    unawaited(_disposeWebRtc());

    super.dispose();
  }

  void _setStatus(String message) {
    print('STATUS: $message');

    if (!mounted) return;

    setState(() {
      _status = message;
    });
  }

  String _randomTransaction() {
    _transactionCounter++;
    return '${DateTime.now().microsecondsSinceEpoch}-$_transactionCounter';
  }

  // ---------------------------------------------------------------------------
  // WebSocket transport
  // ---------------------------------------------------------------------------

  Future<void> _connectWebSocket() async {
    await _closeWebSocket();

    final url = _janusWsUrl;

    _setStatus('Connecting to Janus WebSocket $url ...');

    final socket = await WebSocket.connect(
      url,
      protocols: ['janus-protocol'],
    ).timeout(const Duration(seconds: 10));

    socket.pingInterval = const Duration(seconds: 20);

    print('DEBUG: WebSocket connected. Subprotocol: ${socket.protocol}');

    _socket = socket;

    _socketSub = socket.listen(
      _onSocketData,
      onError: (Object error) {
        print('DEBUG: WebSocket error: $error');
      },
      onDone: () => _onSocketDone(socket),
      cancelOnError: false,
    );
  }

  Future<void> _closeWebSocket() async {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;

    final subscription = _socketSub;
    final socket = _socket;

    _socketSub = null;
    _socket = null;

    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(Exception('WebSocket closed'));
      }
    }

    _pending.clear();

    try {
      await subscription?.cancel();
    } catch (_) {}

    try {
      await socket?.close();
    } catch (_) {}
  }

  void _onSocketDone(WebSocket socket) {
    if (!identical(socket, _socket)) {
      return;
    }

    _handleConnectionLost(
      'Janus WebSocket closed '
      '(code ${socket.closeCode}, reason ${socket.closeReason}).',
    );
  }

  void _handleConnectionLost(String reason) {
    print('CONNECTION LOST: $reason');

    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;

    _socketSub?.cancel();
    _socketSub = null;
    _socket = null;

    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(Exception(reason));
      }
    }

    _pending.clear();

    final registration = _registrationCompleter;
    if (registration != null && !registration.isCompleted) {
      registration.completeError(Exception(reason));
    }

    unawaited(_disposeWebRtc());

    if (!mounted) return;

    setState(() {
      _isRegistered = false;
      _isCalling = false;
      _isInCall = false;
      _status = '$reason Register again.';
    });
  }

  void _onSocketData(dynamic data) {
    if (data is! String) {
      print('DEBUG: Ignoring non-text WebSocket frame');
      return;
    }

    print('DEBUG: WS <- $data');

    Map<String, dynamic> message;

    try {
      message = jsonDecode(data) as Map<String, dynamic>;
    } catch (error) {
      print('DEBUG: Invalid JSON from Janus: $error');
      return;
    }

    final type = message['janus'] as String?;
    final transaction = message['transaction'] as String?;

    if (transaction != null &&
        (type == 'success' || type == 'error' || type == 'ack')) {
      final pending = _pending.remove(transaction);

      if (pending != null && !pending.isCompleted) {
        pending.complete(message);
        return;
      }
    }

    _eventChain = _eventChain
        .then((_) => _handleJanusMessage(message))
        .catchError((Object error, StackTrace stackTrace) {
      print('EVENT HANDLER ERROR: $error');
      print(stackTrace);
    });
  }

  Future<Map<String, dynamic>> _request(
    Map<String, dynamic> payload, {
    bool needSession = true,
    bool needHandle = false,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final socket = _socket;

    if (socket == null) {
      throw Exception('Janus WebSocket is not connected');
    }

    final transaction = _randomTransaction();

    final message = <String, dynamic>{
      ...payload,
      'transaction': transaction,
    };

    if (needSession) {
      final sessionId = _sessionId;

      if (sessionId == null) {
        throw Exception('No Janus session');
      }

      message['session_id'] = sessionId;
    }

    if (needHandle) {
      final handleId = _handleId;

      if (handleId == null) {
        throw Exception('No SIP plugin handle');
      }

      message['handle_id'] = handleId;
    }

    final completer = Completer<Map<String, dynamic>>();
    _pending[transaction] = completer;

    final bodyRequest = (message['body'] is Map)
        ? (message['body'] as Map)['request']
        : '';

    print('DEBUG: WS -> ${message['janus']} $bodyRequest');

    socket.add(jsonEncode(message));

    try {
      final response = await completer.future.timeout(timeout);

      if (response['janus'] == 'error') {
        final error = response['error'];
        final code = error is Map ? error['code'] : '';
        final reason = error is Map ? error['reason'] : error;

        throw Exception('Janus error $code: $reason');
      }

      return response;
    } on TimeoutException {
      _pending.remove(transaction);

      throw Exception(
        'Janus did not answer "${payload['janus']}" within '
        '${timeout.inSeconds}s',
      );
    }
  }

  void _sendNoWait(
    Map<String, dynamic> payload, {
    bool needHandle = false,
  }) {
    final socket = _socket;
    final sessionId = _sessionId;

    if (socket == null || sessionId == null) return;

    final message = <String, dynamic>{
      ...payload,
      'transaction': _randomTransaction(),
      'session_id': sessionId,
    };

    if (needHandle) {
      final handleId = _handleId;

      if (handleId == null) return;

      message['handle_id'] = handleId;
    }

    socket.add(jsonEncode(message));
  }

  void _startKeepAlive() {
    _keepAliveTimer?.cancel();

    _keepAliveTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      print('DEBUG: sending Janus keepalive');
      _sendNoWait({'janus': 'keepalive'});
    });
  }

  // ---------------------------------------------------------------------------
  // SIP registration
  // ---------------------------------------------------------------------------

  Future<void> _registerWithJanus() async {
    if (_isRegistering) return;

    setState(() {
      _isRegistering = true;
      _isRegistered = false;
      _isCalling = false;
      _isInCall = false;
      _status = 'Connecting...';
    });

    try {
      await _disposeWebRtc();
      await _closeWebSocket();

      _sessionId = null;
      _handleId = null;

      await _connectWebSocket();

      _setStatus('Creating Janus session...');

      final created = await _request(
        {'janus': 'create'},
        needSession: false,
      );

      _sessionId = created['data']['id'] as int;

      _startKeepAlive();

      _setStatus('Attaching SIP plugin...');

      final attached = await _request({
        'janus': 'attach',
        'plugin': 'janus.plugin.sip',
      });

      _handleId = attached['data']['id'] as int;

      final registration = Completer<String>();
      registration.future.ignore();
      _registrationCompleter = registration;

      _setStatus('Sending SIP registration request...');

      await _request(
        {
          'janus': 'message',
          'body': {
            'request': 'register',
            'username':
                'sip:${_usernameController.text.trim()}@$_sipServer',
            'authuser': _usernameController.text.trim(),
            'display_name': 'Flutter SIP Client',
            'secret': _passwordController.text,
            'proxy': 'sip:$_sipServer:$_sipServerPort',
          },
        },
        needHandle: true,
      );

      _setStatus('Waiting for registration confirmation...');

      final outcome = await registration.future.timeout(
        const Duration(seconds: 15),
      );

      if (outcome == 'registered') {
        if (!mounted) return;

        setState(() {
          _isRegistered = true;
          _status = 'Registered as ${_usernameController.text.trim()} '
              'over WebSocket. Ready to call or receive calls.';
        });
      } else {
        _setStatus('Registration was not confirmed: $outcome');
        await _closeWebSocket();
      }
    } on TimeoutException {
      _setStatus('Registration timed out waiting for Janus.');
      await _closeWebSocket();
    } catch (error, stackTrace) {
      print('REGISTER ERROR: $error');
      print(stackTrace);

      _setStatus('Registration failed: $error');
      await _closeWebSocket();
    } finally {
      _registrationCompleter = null;

      if (mounted) {
        setState(() {
          _isRegistering = false;
        });
      }
    }
  }

  // ---------------------------------------------------------------------------
  // WebRTC
  // ---------------------------------------------------------------------------

  Future<void> _ensureMicrophoneAndPeerConnection() async {
    if (_peerConnection != null && _localStream != null) return;

    _setStatus('Requesting microphone permission...');

    final stream = await navigator.mediaDevices.getUserMedia({
      'audio': {
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
      },
      'video': false,
    });

    _localStream = stream;

    final audioTracks = stream.getAudioTracks();

    print('DEBUG: Microphone tracks found: ${audioTracks.length}');

    for (final track in audioTracks) {
      print(
        'DEBUG: mic track id=${track.id}, kind=${track.kind}, '
        'enabled=${track.enabled}',
      );
    }

    if (audioTracks.isEmpty) {
      throw Exception('No microphone audio track was returned.');
    }

    _setStatus('Creating WebRTC PeerConnection...');

    final peerConnection = await createPeerConnection({
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
      'sdpSemantics': 'unified-plan',
    });

    _peerConnection = peerConnection;

    peerConnection.onIceCandidate = (candidate) {
      if (candidate != null) {
        _sendIceCandidate(candidate);
      }
    };

    peerConnection.onConnectionState = (state) {
      print('DEBUG: PeerConnection state: $state');

      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _setStatus('WebRTC connected. Audio should be active.');
      } else if (state ==
          RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _setStatus('Call failed: WebRTC connection failed.');
      } else if (state ==
          RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        _setStatus('WebRTC disconnected. Waiting for call status...');
      }
    };

    peerConnection.onIceConnectionState = (state) {
      print('DEBUG: ICE connection state: $state');
    };

    for (final track in stream.getTracks()) {
      await peerConnection.addTrack(track, stream);
    }

    final senders = await peerConnection.getSenders();

    for (final sender in senders) {
      print(
        'DEBUG: RTP sender track=${sender.track?.kind}, '
        'enabled=${sender.track?.enabled}',
      );
    }
  }

  void _sendIceCandidate(RTCIceCandidate candidate) {
    _sendNoWait(
      {
        'janus': 'trickle',
        'candidate': {
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        },
      },
      needHandle: true,
    );

    print('DEBUG: ICE candidate sent: ${candidate.candidate}');
  }

  Future<void> _applyRemoteAnswer(Map<String, dynamic> jsep) async {
    final peerConnection = _peerConnection;

    if (peerConnection == null) {
      _setStatus('Remote SDP arrived, but no WebRTC PeerConnection exists.');
      return;
    }

    final type = jsep['type'] as String?;
    final sdp = jsep['sdp'] as String?;

    if (type == null || sdp == null) {
      _setStatus('Janus sent no usable SDP answer.');
      return;
    }

    await peerConnection.setRemoteDescription(
      RTCSessionDescription(sdp, type),
    );

    _setStatus('Remote SDP applied. Establishing audio...');
  }

  Future<void> _disposeWebRtc() async {
    try {
      await _localStream?.dispose();
      await _peerConnection?.close();
    } catch (error) {
      print('WebRTC cleanup warning: $error');
    }

    _localStream = null;
    _peerConnection = null;
  }

  // ---------------------------------------------------------------------------
  // Outgoing call
  // ---------------------------------------------------------------------------

  Future<void> _startCall() async {
    final destination = _destinationSipUser;

    if (!_isRegistered) {
      _setStatus('Register before calling.');
      return;
    }

    if (destination.isEmpty) {
      _setStatus('Enter a destination extension.');
      return;
    }

    if (_isCalling || _isInCall) return;

    setState(() {
      _isCalling = true;
      _isInCall = false;
      _status = 'Preparing microphone and WebRTC...';
    });

    try {
      await _disposeWebRtc();
      await _ensureMicrophoneAndPeerConnection();

      final peerConnection = _peerConnection!;

      _setStatus('Creating SDP offer...');

      final offer = await peerConnection.createOffer({
        'offerToReceiveAudio': 1,
        'offerToReceiveVideo': 0,
      });

      await peerConnection.setLocalDescription(offer);

      final localDescription = await peerConnection.getLocalDescription();

      if (localDescription?.sdp == null || localDescription!.sdp!.isEmpty) {
        throw Exception('WebRTC created an empty SDP offer.');
      }

      _setStatus('Sending SIP INVITE through Janus...');

      await _request(
        {
          'janus': 'message',
          'body': {
            'request': 'call',
            'uri': 'sip:$destination@$_sipServer:$_sipServerPort',
          },
          'jsep': {
            'type': localDescription.type,
            'sdp': localDescription.sdp,
          },
        },
        needHandle: true,
        timeout: const Duration(seconds: 15),
      );

      if (!mounted) return;

      setState(() {
        _isCalling = true;
        _isInCall = false;
        _status = 'INVITE sent. Waiting for the destination to ring...';
      });
    } catch (error, stackTrace) {
      print('CALL ERROR: $error');
      print(stackTrace);

      await _disposeWebRtc();

      if (mounted) {
        setState(() {
          _isCalling = false;
          _isInCall = false;
          _status = 'Call failed: $error';
        });
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Incoming Janus events
  // ---------------------------------------------------------------------------

  Future<void> _handleJanusMessage(Map<String, dynamic> message) async {
    final type = message['janus'] as String?;

    if (type == 'timeout') {
      unawaited(_closeWebSocket());
      _handleConnectionLost('Janus session timed out.');
      return;
    }

    if (type != 'event') {
      return;
    }

    final pluginData = message['plugindata'];

    if (pluginData is! Map) return;

    final data = pluginData['data'];

    if (data is! Map) return;

    final pluginError = data['error'];

    if (pluginError != null) {
      final text = 'SIP plugin error ${data['error_code'] ?? ''}: '
          '$pluginError';

      print('PLUGIN ERROR: $text');

      final registration = _registrationCompleter;

      if (registration != null && !registration.isCompleted) {
        registration.completeError(Exception(text));
        return;
      }

      await _disposeWebRtc();

      if (mounted) {
        setState(() {
          _isCalling = false;
          _isInCall = false;
          _status = text;
        });
      }

      return;
    }

    final result = data['result'];

    if (result is! Map) return;

    final resultData = Map<String, dynamic>.from(result);
    final event = resultData['event'] as String?;

    final jsepRaw = message['jsep'];
    final jsep =
        jsepRaw is Map ? Map<String, dynamic>.from(jsepRaw) : null;

    print('DEBUG: SIP event: $event');

    if (event == 'registering') {
      _setStatus('SIP registering...');
      return;
    }

    if (event == 'registered' || event == 'registration_failed') {
      final registration = _registrationCompleter;

      if (registration != null && !registration.isCompleted) {
        registration.complete(event!);
      } else if (event == 'registration_failed') {
        if (mounted) {
          setState(() {
            _isRegistered = false;
            _status = 'SIP registration failed: '
                '${resultData['code']} ${resultData['reason']}';
          });
        }
      }

      return;
    }

    if (event == 'hangup' && _incomingCallVisible) {
      _dismissIncomingDialogBecauseCallerHungUp();
      return;
    }

    if (event == 'incomingcall') {
      final callerUri = resultData['username'] as String? ?? '';
      final callerExtension = _extractExtension(callerUri);

      unawaited(_handleIncomingCall(jsep, callerExtension));
      return;
    }

    if (event == 'calling') {
      if (mounted) {
        setState(() {
          _isCalling = true;
          _isInCall = false;
          _status = 'Calling $_destinationSipUser...';
        });
      }

      return;
    }

    if (event == 'proceeding' || event == 'progress') {
      if (jsep != null) {
        await _applyRemoteAnswer(jsep);
      }

      if (mounted) {
        setState(() {
          _isCalling = true;
          _isInCall = false;
          _status = 'Call progressing. Waiting for answer...';
        });
      }

      return;
    }

    if (event == 'ringing') {
      if (mounted) {
        setState(() {
          _isCalling = true;
          _isInCall = false;
          _status = 'Ringing $_destinationSipUser...';
        });
      }

      return;
    }

    if (event == 'accepted') {
      if (jsep != null) {
        await _applyRemoteAnswer(jsep);
      }

      if (mounted) {
        setState(() {
          _isCalling = false;
          _isInCall = true;
          _status = 'Call accepted. Connecting audio...';
        });
      }

      return;
    }

    if (event == 'hangup') {
      await _handleRemoteHangup(resultData);
    }
  }

  String _extractExtension(String sipUri) {
    final match = RegExp(r'sip:([^@]+)@').firstMatch(sipUri);
    return match?.group(1) ?? 'Unknown';
  }

  // ---------------------------------------------------------------------------
  // Incoming call
  // ---------------------------------------------------------------------------

  void _dismissIncomingDialogBecauseCallerHungUp() {
    print('DEBUG: Caller hung up before the call was answered.');

    _incomingCancelledByCaller = true;

    final dialogContext = _incomingDialogContext;

    if (dialogContext != null && dialogContext.mounted) {
      Navigator.of(dialogContext).pop(false);
    }
  }

  Future<void> _handleIncomingCall(
    Map<String, dynamic>? jsep,
    String callerExtension,
  ) async {
    if (_incomingCallVisible || _isInCall || _isCalling) {
      await _declineIncomingCall();
      return;
    }

    _incomingCallVisible = true;
    _incomingCancelledByCaller = false;

    final shouldAccept = await _showIncomingCallDialog(callerExtension);

    _incomingCallVisible = false;
    _incomingDialogContext = null;

    if (_incomingCancelledByCaller) {
      _incomingCancelledByCaller = false;

      _setStatus(
        'Missed call from extension: $callerExtension (caller cancelled).',
      );

      return;
    }

    if (!shouldAccept) {
      await _declineIncomingCall();
      return;
    }

    try {
      if (jsep == null) {
        throw Exception('Incoming call has no SDP offer.');
      }

      setState(() {
        _isCalling = true;
        _isInCall = false;
        _status = 'Accepting incoming call...';
      });

      await _disposeWebRtc();
      await _ensureMicrophoneAndPeerConnection();

      final peerConnection = _peerConnection!;

      final offerType = jsep['type'] as String?;
      final offerSdp = jsep['sdp'] as String?;

      if (offerType == null || offerSdp == null) {
        throw Exception('Incoming call SDP is invalid.');
      }

      await peerConnection.setRemoteDescription(
        RTCSessionDescription(offerSdp, offerType),
      );

      _setStatus('Creating call answer...');

      final answer = await peerConnection.createAnswer({
        'offerToReceiveAudio': 1,
        'offerToReceiveVideo': 0,
      });

      await peerConnection.setLocalDescription(answer);

      final localDescription = await peerConnection.getLocalDescription();

      if (localDescription?.sdp == null || localDescription!.sdp!.isEmpty) {
        throw Exception('WebRTC created an empty SDP answer.');
      }

      _setStatus('Sending call acceptance to Janus...');

      await _request(
        {
          'janus': 'message',
          'body': {'request': 'accept'},
          'jsep': {
            'type': localDescription.type,
            'sdp': localDescription.sdp,
          },
        },
        needHandle: true,
        timeout: const Duration(seconds: 15),
      );

      if (mounted) {
        setState(() {
          _isCalling = true;
          _isInCall = false;
          _status = 'Acceptance sent. Waiting for call confirmation...';
        });
      }
    } catch (error, stackTrace) {
      print('INCOMING CALL ERROR: $error');
      print(stackTrace);

      await _disposeWebRtc();

      if (mounted) {
        setState(() {
          _isInCall = false;
          _isCalling = false;
          _status = 'Incoming call failed: $error';
        });
      }
    }
  }

  Future<bool> _showIncomingCallDialog(String callerExtension) async {
    if (!mounted) return false;

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        _incomingDialogContext = dialogContext;

        return AlertDialog(
          title: const Text('Incoming Call'),
          content: Text(
            'Incoming call from extension: $callerExtension\n\n'
            'Do you want to accept this call?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Reject'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Accept'),
            ),
          ],
        );
      },
    );

    return result ?? false;
  }

  Future<void> _declineIncomingCall() async {
    try {
      await _request(
        {
          'janus': 'message',
          'body': {'request': 'decline'},
        },
        needHandle: true,
      );

      _setStatus('Incoming call rejected.');
    } catch (error, stackTrace) {
      print('DECLINE ERROR: $error');
      print(stackTrace);

      _setStatus('Could not reject incoming call: $error');
    }
  }

  // ---------------------------------------------------------------------------
  // Hang up
  // ---------------------------------------------------------------------------

  Future<void> _handleRemoteHangup(Map<String, dynamic> resultData) async {
    if (_processingRemoteHangup) return;

    _processingRemoteHangup = true;

    final code = resultData['code'];
    final reason = resultData['reason'];

    print('DEBUG: Remote hangup. Code: $code, reason: $reason');

    await _disposeWebRtc();

    if (mounted) {
      setState(() {
        _isCalling = false;
        _isInCall = false;
        _status = 'Call ended — code: ${code ?? 'unknown'}, '
            'reason: ${reason ?? 'unknown'}.';
      });
    }

    _processingRemoteHangup = false;
  }

  Future<void> _hangup() async {
    if (_processingRemoteHangup) return;

    if (_socket != null && _handleId != null) {
      try {
        await _request(
          {
            'janus': 'message',
            'body': {'request': 'hangup'},
          },
          needHandle: true,
        );
      } catch (error, stackTrace) {
        print('HANGUP ERROR: $error');
        print(stackTrace);
      }
    }

    await _disposeWebRtc();

    if (mounted) {
      setState(() {
        _isCalling = false;
        _isInCall = false;
        _status = 'Call ended locally. Ready for another call.';
      });
    }
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  Widget _buildInput({
    required TextEditingController controller,
    required String label,
    TextInputType? keyboardType,
    bool obscureText = false,
  }) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      obscureText: obscureText,
      textInputAction: TextInputAction.next,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).viewPadding.bottom;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Janus SIP Demo (WebSocket)'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 24 + bottomPadding),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildInput(
                controller: _janusIpController,
                label: 'Janus IP',
                keyboardType: TextInputType.url,
              ),
              const SizedBox(height: 12),
              _buildInput(
                controller: _janusPortController,
                label: 'Janus WebSocket port (default 8188)',
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 12),
              _buildInput(
                controller: _sipServerController,
                label: 'SIP server IP',
                keyboardType: TextInputType.url,
              ),
              const SizedBox(height: 12),
              _buildInput(
                controller: _sipPortController,
                label: 'SIP server port',
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 12),
              _buildInput(
                controller: _usernameController,
                label: 'SIP username',
                keyboardType: TextInputType.text,
              ),
              const SizedBox(height: 12),
              _buildInput(
                controller: _passwordController,
                label: 'SIP password',
                obscureText: true,
                keyboardType: TextInputType.visiblePassword,
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: _isRegistering ? null : _registerWithJanus,
                child: _isRegistering
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Register with Janus'),
              ),
              if (_isRegistered) ...[
                const SizedBox(height: 24),
                const Divider(),
                const SizedBox(height: 8),
                Text(
                  'Call controls',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                _buildInput(
                  controller: _destinationController,
                  label: 'Destination extension',
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        onPressed:
                            (!_isCalling && !_isInCall) ? _startCall : null,
                        child: _isCalling
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('Call'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: (_isInCall || _isCalling) ? _hangup : null,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red,
                          foregroundColor: Colors.white,
                        ),
                        child: const Text('Hang up'),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 24),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Status',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      SelectableText(_status),
                      const SizedBox(height: 12),
                      const Divider(),
                      const SizedBox(height: 8),
                      SelectableText(
                        'Transport: WebSocket '
                        '(${_socket != null ? 'connected' : 'disconnected'})',
                      ),
                      SelectableText(
                        'Janus session ID: ${_sessionId ?? 'none'}',
                      ),
                      SelectableText('SIP handle ID: ${_handleId ?? 'none'}'),
                      SelectableText(
                        'Registered: ${_isRegistered ? 'yes' : 'no'}',
                      ),
                      SelectableText('In call: ${_isInCall ? 'yes' : 'no'}'),
                      SelectableText('Calling: ${_isCalling ? 'yes' : 'no'}'),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}