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
        .timeout(const Duration(seconds: 10));

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
        .timeout(const Duration(seconds: 10));

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
        .timeout(const Duration(seconds: 30));

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
    setState(() {
      _isRegistering = true;
      _status = 'Creating Janus session...';
      _isRegistered = false;
    });

    try {
      final sessionResponse = await _createJanusSession();
      final sessionId = sessionResponse['data']['id'] as int;
      _sessionId = sessionId;

      setState(() {
        _status = 'Attaching SIP plugin...';
      });

      final handleResponse = await _attachSipPlugin(sessionId: sessionId);
      final handleId = handleResponse['data']['id'] as int;
      _handleId = handleId;

      setState(() {
        _status = 'Sending SIP register request...';
      });

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
          .timeout(const Duration(seconds: 10));

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
          'Janus rejected register request: ${registerData['error']}',
        );
      }

      setState(() {
        _status = 'Waiting for registration event...';
      });

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

        await Future<void>.delayed(const Duration(seconds: 1));
      }

      if (registrationEvent == 'registered') {
        setState(() {
          _isRegistered = true;
          _status =
              'Registered as ${_usernameController.text.trim()}. '
              'You can now call any extension or receive calls.';
        });

        _startEventLoop();
      } else {
        setState(() {
          _isRegistered = false;
          _status =
              'Registration not confirmed. Final event: $registrationEvent';
        });
      }
    } on TimeoutException {
      setState(() {
        _isRegistered = false;
        _status = 'Registration timed out waiting for Janus.';
      });
    } catch (error) {
      setState(() {
        _isRegistered = false;
        _status = 'Registration failed: $error';
      });
    } finally {
      setState(() {
        _isRegistering = false;
      });
    }
  }

  Future<void> _ensureMicrophoneAndPeerConnection() async {
    if (_peerConnection != null && _localStream != null) {
      return;
    }

    setState(() {
      _status = 'Requesting microphone...';
    });

    final stream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': false,
    });

    _localStream = stream;

    final audioTracks = stream.getAudioTracks();

    print('Microphone tracks found: ${audioTracks.length}');

    if (audioTracks.isEmpty) {
      throw Exception('No microphone audio track was returned');
    }

    setState(() {
      _status = 'Creating WebRTC PeerConnection...';
    });

    final peerConnection = await createPeerConnection({
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
    });

    _peerConnection = peerConnection;

    peerConnection.onIceCandidate = (candidate) {
      if (candidate != null) {
        _sendIceCandidate(candidate);
      }
    };

    peerConnection.onConnectionState = (state) {
      print('PeerConnection state: $state');

      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        setState(() {
          _status = 'Call connected. Audio should be active.';
        });
      } else if (state ==
          RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        setState(() {
          _status = 'Call failed: WebRTC connection failed.';
        });
      }
    };

    for (final track in stream.getTracks()) {
      await peerConnection.addTrack(track, stream);
    }
  }

  Future<void> _startCall() async {
    final destination = _destinationSipUser;

    if (!_isRegistered) {
      setState(() {
        _status = 'Register before calling.';
      });
      return;
    }

    if (destination.isEmpty) {
      setState(() {
        _status = 'Enter a destination extension.';
      });
      return;
    }

    if (_isCalling || _isInCall) {
      return;
    }

    setState(() {
      _isCalling = true;
      _status = 'Preparing microphone and WebRTC...';
    });

    try {
      await _ensureMicrophoneAndPeerConnection();

      final peerConnection = _peerConnection!;

      setState(() {
        _status = 'Creating SDP offer...';
      });

      final offer = await peerConnection.createOffer({
        'offerToReceiveAudio': 1,
        'offerToReceiveVideo': 0,
      });

      await peerConnection.setLocalDescription(offer);

      final localDescription = await peerConnection.getLocalDescription();

      setState(() {
        _status = 'Sending SIP INVITE through Janus...';
      });

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
                'type': localDescription?.type,
                'sdp': localDescription?.sdp,
              },
            }),
          )
          .timeout(const Duration(seconds: 10));

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

      setState(() {
        _isCalling = false;
        _isInCall = true;
        _status = 'Calling $destination...';
      });
    } catch (error) {
      print('Call failed: $error');

      setState(() {
        _isCalling = false;
        _isInCall = false;
        _status = 'Call failed: $error';
      });

      await _hangup();
    }
  }

  void _startEventLoop() {
    if (_eventLoopRunning) {
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

        // Caller cancelled while the incoming-call dialog is still open.
        if (event == 'hangup' && _incomingCallVisible) {
          _dismissIncomingDialogBecauseCallerHungUp();
          continue;
        }

        if (event == 'hangup' && !_isInCall && !_isCalling) {
          print('DEBUG: Ignoring stale hangup event.');
          continue;
        }

        final jsep = eventData['jsep'] as Map<String, dynamic>?;

        if (event == 'incomingcall') {
          final callerUri = resultData['username'] as String? ?? '';

          final callerExtension = _extractExtension(callerUri);

          // Do not await: the loop must keep polling so it can see a
          // hangup event while the dialog is still open.
          unawaited(
            _handleIncomingCall(
              jsep,
              callerExtension,
            ),
          );
        } else if (event == 'calling') {
          setState(() {
            _status = 'Calling $_destinationSipUser...';
          });
        } else if (event == 'progress') {
          if (jsep != null) {
            await _applyRemoteAnswer(jsep);
          }

          setState(() {
            _status = 'Call progressing. Applying audio answer...';
          });
        } else if (event == 'ringing') {
          setState(() {
            _status = 'Ringing $_destinationSipUser...';
          });
        } else if (event == 'accepted') {
          if (jsep != null) {
            await _applyRemoteAnswer(jsep);
          }

          setState(() {
            _status = 'Call accepted.';
          });
        } else if (event == 'hangup') {
          await _handleRemoteHangup();
        }
      } catch (error) {
        print('Error while handling Janus SIP event: $error');

        if (!_isRegistered) {
          break;
        }

        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }

    _eventLoopRunning = false;
  }

  String _extractExtension(String sipUri) {
    // Example input: sip:1000@192.168.97.53:5070
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
    if (_incomingCallVisible || _isInCall) {
      await _declineIncomingCall();
      return;
    }

    _incomingCallVisible = true;
    _incomingCancelledByCaller = false;

    final shouldAccept = await _showIncomingCallDialog(
      callerExtension,
    );

    _incomingCallVisible = false;
    _incomingDialogContext = null;

    if (_incomingCancelledByCaller) {
      _incomingCancelledByCaller = false;

      if (mounted) {
        setState(() {
          _status =
              'Missed call from extension: $callerExtension (caller cancelled).';
        });
      }

      return;
    }

    if (!shouldAccept) {
      await _declineIncomingCall();
      return;
    }

    try {
      if (jsep == null) {
        throw Exception('Incoming call has no SDP offer');
      }

      setState(() {
        _isInCall = true;
        _status = 'Accepting incoming call...';
      });

      await _ensureMicrophoneAndPeerConnection();

      final peerConnection = _peerConnection!;

      final offerType = jsep['type'] as String?;
      final offerSdp = jsep['sdp'] as String?;

      if (offerType == null || offerSdp == null) {
        throw Exception('Incoming call SDP is invalid');
      }

      await peerConnection.setRemoteDescription(
        RTCSessionDescription(offerSdp, offerType),
      );

      setState(() {
        _status = 'Creating call answer...';
      });

      final answer = await peerConnection.createAnswer({
        'offerToReceiveAudio': 1,
        'offerToReceiveVideo': 0,
      });

      await peerConnection.setLocalDescription(answer);

      final localDescription = await peerConnection.getLocalDescription();

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
                'type': localDescription?.type,
                'sdp': localDescription?.sdp,
              },
            }),
          )
          .timeout(const Duration(seconds: 10));

      print('DEBUG: Accept status: ${response.statusCode}');
      print('DEBUG: Accept body: ${response.body}');

      if (response.statusCode != 200) {
        throw Exception(
          'Failed to accept incoming call: HTTP ${response.statusCode}',
        );
      }

      setState(() {
        _status = 'Incoming call accepted.';
      });
    } catch (error) {
      print('Failed to handle incoming call: $error');

      setState(() {
        _isInCall = false;
        _status = 'Incoming call failed: $error';
      });

      await _hangup();
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

      setState(() {
        _status = 'Incoming call rejected.';
      });
    } catch (error) {
      print('Failed to decline incoming call: $error');
    }
  }

  Future<void> _applyRemoteAnswer(
    Map<String, dynamic> jsep,
  ) async {
    final peerConnection = _peerConnection;

    if (peerConnection == null) {
      return;
    }

    final type = jsep['type'] as String?;
    final sdp = jsep['sdp'] as String?;

    if (type == null || sdp == null) {
      print('Janus sent no usable SDP answer');
      return;
    }

    await peerConnection.setRemoteDescription(
      RTCSessionDescription(sdp, type),
    );

    setState(() {
      _status = 'Remote SDP applied. Audio negotiation complete.';
    });
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
    } catch (error) {
      print('Failed to send ICE candidate: $error');
    }
  }

  Future<void> _handleRemoteHangup() async {
    if (_processingRemoteHangup) {
      return;
    }

    _processingRemoteHangup = true;
    _isInCall = false;

    await _disposeWebRtc();

    if (mounted) {
      setState(() {
        _isCalling = false;
        _isInCall = false;
        _status = 'Call ended. Ready for another call.';
      });
    }

    _processingRemoteHangup = false;
  }

  Future<void> _hangup() async {
    if (_processingRemoteHangup) {
      return;
    }

    _isInCall = false;

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
      } catch (error) {
        print('Hangup request failed: $error');
      }
    }

    await _disposeWebRtc();

    if (mounted) {
      setState(() {
        _isCalling = false;
        _isInCall = false;
        _status = 'Call ended. Ready for another call.';
      });
    }
  }

  Future<void> _disposeWebRtc() async {
    try {
      await _localStream?.dispose();
      await _peerConnection?.close();
    } catch (_) {
      // Ignore cleanup errors.
    }

    _localStream = null;
    _peerConnection = null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Janus SIP Demo'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _janusIpController,
              decoration: const InputDecoration(
                labelText: 'Janus IP',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _janusPortController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Janus HTTP port',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _sipServerController,
              decoration: const InputDecoration(
                labelText: 'SIP server IP',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _sipPortController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'SIP server port',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _usernameController,
              decoration: const InputDecoration(
                labelText: 'SIP username',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _passwordController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'SIP password',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 24),
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
              TextField(
                controller: _destinationController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Destination extension',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
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
                      onPressed: (_isInCall || _isCalling)
                          ? _hangup
                          : null,
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
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Status',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(_status),
                    const SizedBox(height: 8),
                    Text('Janus session ID: ${_sessionId ?? 'none'}'),
                    Text('SIP handle ID: ${_handleId ?? 'none'}'),
                    Text(
                      'Registered: ${_isRegistered ? 'yes' : 'no'}',
                    ),
                    Text(
                      'In call: ${_isInCall ? 'yes' : 'no'}',
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}