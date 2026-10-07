import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;

// Temporary development-only lint suppression.
// Replace print() with a logging package before production use.
// ignore_for_file: avoid_print, unnecessary_string_interpolations

void main() {
  runApp(const JanusSipDemoApp());
}

class JanusSipDemoApp extends StatelessWidget {
  const JanusSipDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Janus SIP Demo',
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
  final TextEditingController _janusPortController = TextEditingController();
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
  bool _eventLoopRunning = false;
  bool _processingRemoteHangup = false;

  int? _sessionId;
  int? _handleId;

  MediaStream? _localStream;
  RTCPeerConnection? _peerConnection;

  String get _janusBaseUrl {
    final ip = _janusIpController.text.trim();
    final port = _janusPortController.text.trim();
    return 'http://$ip:$port/janus';
  }

  String get _sipServer {
    return _sipServerController.text.trim();
  }

  int get _sipServerPort {
    return int.tryParse(_sipPortController.text.trim()) ?? 5060;
  }

  String get _destinationSipUser {
    return _destinationController.text.trim();
  }

  @override
  void dispose() {
    _janusIpController.dispose();
    _janusPortController.dispose();
    _sipServerController.dispose();
    _sipPortController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _destinationController.dispose();
    _disposeWebRtc();
    super.dispose();
  }

  void _setStatus(String message) {
    print('STATUS: $message');

    if (!mounted) {
      return;
    }

    setState(() {
      _status = message;
    });
  }

  String _randomTransaction() {
    return DateTime.now().microsecondsSinceEpoch.toString();
  }

  String get _janusEventUrl {
    final sessionId = _sessionId;

    if (sessionId == null) {
      throw Exception('No active Janus session');
    }

    return '$_janusBaseUrl/$sessionId';
  }

  Future<Map<String, dynamic>> _createJanusSession() async {
    final response = await http
        .post(
          Uri.parse(_janusBaseUrl),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'janus': 'create',
            'transaction': _randomTransaction(),
          }),
        )
        .timeout(const Duration(seconds: 15));

    print('DEBUG: Create session status: ${response.statusCode}');
    print('DEBUG: Create session body: ${response.body}');

    if (response.statusCode != 200) {
      throw Exception(
        'Failed to create Janus session: HTTP ${response.statusCode}',
      );
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;

    if (data['janus'] != 'success') {
      throw Exception('Janus session creation failed: ${data['error']}');
    }

    return data;
  }

  Future<Map<String, dynamic>> _attachSipPlugin({
    required int sessionId,
  }) async {
    final response = await http
        .post(
          Uri.parse('$_janusBaseUrl/$sessionId'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'janus': 'attach',
            'plugin': 'janus.plugin.sip',
            'transaction': _randomTransaction(),
          }),
        )
        .timeout(const Duration(seconds: 15));

    print('DEBUG: Attach plugin status: ${response.statusCode}');
    print('DEBUG: Attach plugin body: ${response.body}');

    if (response.statusCode != 200) {
      throw Exception(
        'Failed to attach SIP plugin: HTTP ${response.statusCode}',
      );
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;

    if (data['janus'] != 'success') {
      throw Exception('SIP plugin attach failed: ${data['error']}');
    }

    return data;
  }

  Future<Map<String, dynamic>> _getNextEvent() async {
    final response = await http
        .get(
          Uri.parse('$_janusEventUrl?maxev=1'),
        )
        .timeout(const Duration(seconds: 65));

    print('DEBUG: Event status: ${response.statusCode}');
    print('DEBUG: Event body: ${response.body}');

    if (response.statusCode != 200) {
      throw Exception(
        'Failed to read Janus event: HTTP ${response.statusCode}',
      );
    }

    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<void> _registerWithJanus() async {
    if (_isRegistering) {
      return;
    }

    setState(() {
      _isRegistering = true;
      _isRegistered = false;
      _isCalling = false;
      _isInCall = false;
      _sessionId = null;
      _handleId = null;
      _status = 'Creating Janus session...';
    });

    try {
      await _disposeWebRtc();

      final sessionResponse = await _createJanusSession();
      final sessionId = sessionResponse['data']['id'] as int;
      _sessionId = sessionId;

      _setStatus('Attaching SIP plugin...');

      final handleResponse = await _attachSipPlugin(sessionId: sessionId);
      final handleId = handleResponse['data']['id'] as int;
      _handleId = handleId;

      _setStatus('Sending SIP registration request...');

      final registerResponse = await http
          .post(
            Uri.parse('$_janusBaseUrl/$sessionId/$handleId'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'janus': 'message',
              'transaction': _randomTransaction(),
              'body': {
                'request': 'register',
                'username':
                    'sip:${_usernameController.text.trim()}@$_sipServer',
                'authuser': _usernameController.text.trim(),
                'display_name': 'Flutter SIP Client',
                'secret': _passwordController.text,
                'proxy': 'sip:$_sipServer:$_sipServerPort',
              },
            }),
          )
          .timeout(const Duration(seconds: 15));

      print('DEBUG: Register status: ${registerResponse.statusCode}');
      print('DEBUG: Register body: ${registerResponse.body}');

      if (registerResponse.statusCode != 200) {
        throw Exception(
          'Register request failed: HTTP ${registerResponse.statusCode}',
        );
      }

      final registerData =
          jsonDecode(registerResponse.body) as Map<String, dynamic>;

      if (registerData['janus'] != 'ack' &&
          registerData['janus'] != 'success') {
        throw Exception(
          'Janus rejected registration: ${registerData['error']}',
        );
      }

      _setStatus('Waiting for registration confirmation...');

      String? registrationEvent;

      for (int attempt = 0; attempt < 10; attempt++) {
        final eventData = await _getNextEvent();

        final pluginData =
            eventData['plugindata']?['data'] as Map<String, dynamic>?;

        final resultData =
            pluginData?['result'] as Map<String, dynamic>?;

        registrationEvent = resultData?['event'] as String?;

        print('DEBUG: Registration event: $registrationEvent');

        if (registrationEvent == 'registered' ||
            registrationEvent == 'registration_failed') {
          break;
        }
      }

      if (registrationEvent == 'registered') {
        if (!mounted) {
          return;
        }

        setState(() {
          _isRegistered = true;
          _status =
              'Registered as ${_usernameController.text.trim()}. '
              'Ready to call or receive calls.';
        });

        _startEventLoop();
      } else {
        _setStatus(
          'Registration was not confirmed. Final event: '
          '${registrationEvent ?? 'none'}',
        );
      }
    } on TimeoutException {
      _setStatus('Registration timed out waiting for Janus.');
    } catch (error, stackTrace) {
      print('REGISTER ERROR: $error');
      print(stackTrace);
      _setStatus('Registration failed: $error');
    } finally {
      if (mounted) {
        setState(() {
          _isRegistering = false;
        });
      }
    }
  }

  Future<void> _ensureMicrophoneAndPeerConnection() async {
    if (_peerConnection != null && _localStream != null) {
      return;
    }

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
        'DEBUG: mic track '
        'id=${track.id}, '
        'kind=${track.kind}, '
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
        unawaited(_sendIceCandidate(candidate));
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
        'DEBUG: RTP sender '
        'track=${sender.track?.kind}, '
        'enabled=${sender.track?.enabled}',
      );
    }
  }

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

    if (_isCalling || _isInCall) {
      return;
    }

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

      final response = await http
          .post(
            Uri.parse('$_janusBaseUrl/$_sessionId/$_handleId'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'janus': 'message',
              'transaction': _randomTransaction(),
              'body': {
                'request': 'call',
                'uri': 'sip:$destination@$_sipServer:$_sipServerPort',
              },
              'jsep': {
                'type': localDescription.type,
                'sdp': localDescription.sdp,
              },
            }),
          )
          .timeout(const Duration(seconds: 15));

      print('DEBUG: Call status: ${response.statusCode}');
      print('DEBUG: Call body: ${response.body}');

      if (response.statusCode != 200) {
        throw Exception(
          'Janus call request failed: HTTP ${response.statusCode}',
        );
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (data['janus'] != 'ack' && data['janus'] != 'success') {
        throw Exception('Janus rejected call request: ${data['error']}');
      }

      if (!mounted) {
        return;
      }

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

  void _startEventLoop() {
    if (_eventLoopRunning || !_isRegistered) {
      return;
    }

    _eventLoopRunning = true;
    unawaited(_eventLoop());
  }

  Future<void> _eventLoop() async {
    while (_isRegistered) {
      try {
        final eventData = await _getNextEvent();

        final pluginData =
            eventData['plugindata']?['data'] as Map<String, dynamic>?;

        if (pluginData == null) {
          continue;
        }

        final resultData = pluginData['result'] as Map<String, dynamic>?;

        if (resultData == null) {
          continue;
        }

        final event = resultData['event'] as String?;

        print('DEBUG: SIP event: $event');
        print(
          'DEBUG: SIP event data: '
          '${const JsonEncoder.withIndent('  ').convert(resultData)}',
        );

        if (event == 'hangup' && _incomingCallVisible) {
          _dismissIncomingDialogBecauseCallerHungUp();
          continue;
        }

        if (event == 'incomingcall') {
          final jsep = eventData['jsep'] as Map<String, dynamic>?;
          final callerUri = resultData['username'] as String? ?? '';
          final callerExtension = _extractExtension(callerUri);

          unawaited(
            _handleIncomingCall(jsep, callerExtension),
          );
          continue;
        }

        if (event == 'calling') {
          if (mounted) {
            setState(() {
              _isCalling = true;
              _isInCall = false;
              _status = 'Calling $_destinationSipUser...';
            });
          }
          continue;
        }

        final jsep = eventData['jsep'] as Map<String, dynamic>?;

        if (event == 'proceeding') {
          if (jsep != null) {
            await _applyRemoteAnswer(jsep);
          }

          if (mounted) {
            setState(() {
              _isCalling = true;
              _isInCall = false;
              _status = 'Call proceeding. Waiting for answer...';
            });
          }
          continue;
        }

        if (event == 'progress') {
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
          continue;
        }

        if (event == 'ringing') {
          if (mounted) {
            setState(() {
              _isCalling = true;
              _isInCall = false;
              _status = 'Ringing $_destinationSipUser...';
            });
          }
          continue;
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
          continue;
        }

        if (event == 'hangup') {
          await _handleRemoteHangup(resultData);
        }
      } on TimeoutException {
        // Normal behavior for a Janus REST long-poll when there are no events.
        // Immediately create the next long-poll request.
        continue;
      } catch (error, stackTrace) {
        print('EVENT LOOP ERROR: $error');
        print(stackTrace);

        if (!_isRegistered) {
          break;
        }

        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }

    _eventLoopRunning = false;
  }

  String _extractExtension(String sipUri) {
    final match = RegExp(r'sip:([^@]+)@').firstMatch(sipUri);
    return match?.group(1) ?? 'Unknown';
  }

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
        'Missed call from extension: $callerExtension '
        '(caller cancelled).',
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

      final response = await http
          .post(
            Uri.parse('$_janusBaseUrl/$_sessionId/$_handleId'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'janus': 'message',
              'transaction': _randomTransaction(),
              'body': {
                'request': 'accept',
              },
              'jsep': {
                'type': localDescription.type,
                'sdp': localDescription.sdp,
              },
            }),
          )
          .timeout(const Duration(seconds: 15));

      print('DEBUG: Accept status: ${response.statusCode}');
      print('DEBUG: Accept body: ${response.body}');

      if (response.statusCode != 200) {
        throw Exception(
          'Failed to accept incoming call: HTTP ${response.statusCode}',
        );
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (data['janus'] != 'ack' && data['janus'] != 'success') {
        throw Exception('Janus rejected call accept: ${data['error']}');
      }

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

  Future<bool> _showIncomingCallDialog(
    String callerExtension,
  ) async {
    if (!mounted) {
      return false;
    }

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
              onPressed: () {
                Navigator.of(dialogContext).pop(false);
              },
              child: const Text('Reject'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.of(dialogContext).pop(true);
              },
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
      final response = await http.post(
        Uri.parse('$_janusBaseUrl/$_sessionId/$_handleId'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'janus': 'message',
          'transaction': _randomTransaction(),
          'body': {
            'request': 'decline',
          },
        }),
      );

      print('DEBUG: Decline status: ${response.statusCode}');
      print('DEBUG: Decline body: ${response.body}');

      _setStatus('Incoming call rejected.');
    } catch (error, stackTrace) {
      print('DECLINE ERROR: $error');
      print(stackTrace);
      _setStatus('Could not reject incoming call: $error');
    }
  }

  Future<void> _applyRemoteAnswer(
    Map<String, dynamic> jsep,
  ) async {
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

  Future<void> _sendIceCandidate(RTCIceCandidate candidate) async {
    try {
      final sessionId = _sessionId;
      final handleId = _handleId;

      if (sessionId == null || handleId == null) {
        return;
      }

      final response = await http.post(
        Uri.parse('$_janusBaseUrl/$sessionId/$handleId'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'janus': 'trickle',
          'transaction': _randomTransaction(),
          'candidate': {
            'candidate': candidate.candidate,
            'sdpMid': candidate.sdpMid,
            'sdpMLineIndex': candidate.sdpMLineIndex,
          },
        }),
      );

      print(
        'DEBUG: ICE candidate sent: '
        '${candidate.candidate} '
        'HTTP ${response.statusCode}',
      );
    } catch (error, stackTrace) {
      print('ICE CANDIDATE ERROR: $error');
      print(stackTrace);
    }
  }

  Future<void> _handleRemoteHangup(
    Map<String, dynamic> resultData,
  ) async {
    if (_processingRemoteHangup) {
      return;
    }

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
    if (_processingRemoteHangup) {
      return;
    }

    final sessionId = _sessionId;
    final handleId = _handleId;

    if (sessionId != null && handleId != null) {
      try {
        final response = await http.post(
          Uri.parse('$_janusBaseUrl/$sessionId/$handleId'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'janus': 'message',
            'transaction': _randomTransaction(),
            'body': {
              'request': 'hangup',
            },
          }),
        );

        print('DEBUG: Hangup status: ${response.statusCode}');
        print('DEBUG: Hangup body: ${response.body}');
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
        title: const Text('Janus SIP Demo'),
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
                label: 'Janus HTTP port',
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
                        'Janus session ID: ${_sessionId ?? 'none'}',
                      ),
                      SelectableText(
                        'SIP handle ID: ${_handleId ?? 'none'}',
                      ),
                      SelectableText(
                        'Registered: ${_isRegistered ? 'yes' : 'no'}',
                      ),
                      SelectableText(
                        'In call: ${_isInCall ? 'yes' : 'no'}',
                      ),
                      SelectableText(
                        'Calling: ${_isCalling ? 'yes' : 'no'}',
                      ),
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