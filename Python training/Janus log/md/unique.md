2026-08-21T00:04:09.517782+0600 janus-test sudo[3273]: [WSS-0x7f4f8c021090] Destroying WebSocket client
2026-08-21T00:01:58.806083+0600 janus-test sudo[3273]: Creating new session: 4653754810525284; 0x7f4fdc002fd0
2026-08-21T00:04:09.412947+0600 janus-test sudo[3273]: Destroying session 7280510213952357; 0x7f4fdc007420
2026-08-21T00:01:58.865002+0600 janus-test sudo[3273]: Creating new handle in session 4653754810525284: 193865524489355; 0x7f4fdc002fd0 0x7f4fdc00af70
2026-08-21T00:04:10.247324+0600 janus-test sudo[3273]: [1005146296845126] Handle and related resources freed; 0x7f4fdc009410 0x7f4fdc007420
2026-08-21T00:01:59.243685+0600 janus-test sudo[3273]: [193865524489355] Creating ICE agent (ICE Lite mode, controlled)
2026-08-21T00:04:09.246227+0600 janus-test sudo[3273]: [1005146296845126] WebRTC resources freed; 0x7f4fdc009410 0x7f4fdc007420
2026-08-21T00:04:09.237666+0600 janus-test sudo[3273]: [janus.plugin.sip-0x7f4f8c00d1f0] No WebRTC media anymore
2026-08-21T00:04:09.352176+0600 janus-test sudo[3273]: Detaching handle from JANUS SIP plugin; 0x7f4fdc009410 0x7f4f8c00d1f0 0x7f4fdc009410 0x7f4fdc00ba30
2026-08-21T00:01:58.895100+0600 janus-test sudo[3273]: sres: /etc/resolv.conf: unknown option
2026-08-21T00:02:04.476630+0600 janus-test sudo[3273]: [193865524489355] The DTLS handshake has been completed
2026-08-21T00:02:04.476630+0600 janus-test sudo[3273]: [janus.plugin.sip-0x7f4f8c01ac80] WebRTC media is now available
2026-08-21T00:02:06.088405+0600 janus-test sudo[3273]: [WARN] [SIP-09638009771] Got a 'Connection refused' on the audio RTCP socket, closing it
2026-08-21T00:06:05.896370+0600 janus-test sudo[3273]: [WARN] [3066738104914293] Failed to add some remote candidates (added 0, expected 1)
2026-08-21T00:04:09.290603+0600 janus-test sudo[3273]: [ERR] [plugins/janus_sip.c:janus_sip_handler:4675] Wrong state (not established/inviting/progress? status=idle)
2026-08-21T09:04:53.232486+0600 janus-test sudo[3273]: [WARN] [3303864204570178] Didn't receive audio for more than 1 second(s)...
2026-08-21T11:19:32.748738+0600 janus-test sudo[3273]: Detaching handle from JANUS VideoCall plugin; 0x7f4fdc009410 0x7f4f8c004410 0x7f4fdc009410 0x7f4fdc005400
2026-08-21T08:20:05.647775+0600 janus-test sudo[3273]: [ERR] [janus.c:janus_process_incoming_request:1194] Couldn't find any session 1046645067417167...
2026-08-26T00:21:18.828275+0600 janus-test sudo[3273]: [WARN] [8806047911697935]     Missing valid SRTP session (packet arrived too early?), skipping...
2026-08-21T08:19:04.347563+0600 janus-test sudo[3273]: [WARN] [8317872731069396] ICE failed for component 1 in stream 1, but we're still waiting for some info so we don't care... (trickle pending, answer received, alert not set)
2026-08-21T10:58:09.241665+0600 janus-test sudo[3273]: Timeout expired for session 2079873307108201...
2026-08-21T11:19:32.749311+0600 janus-test sudo[3273]: [janus.plugin.videocall-0x7f4f8c004410] No WebRTC media anymore
2026-08-21T11:19:32.682344+0600 janus-test sudo[3273]: [WARN] No call to hangup
2026-08-22T11:03:34.805447+0600 janus-test sudo[3273]: [janus.plugin.videocall-0x7f4fdc00b0c0] WebRTC media is now available
2026-08-21T08:42:10.052861+0600 janus-test sudo[3273]: [7132740125023079] Negotiation update, checking what changed...
2026-08-21T08:18:50.711427+0600 janus-test sudo[3273]: [WARN] [8317872731069396] No stream, queueing this trickle as it got here before the SDP...
2026-08-21T08:42:10.052861+0600 janus-test sudo[3273]: [7132740125023079] ICE restart detected
2026-08-21T08:42:10.052861+0600 janus-test sudo[3273]: [7132740125023079] Restarting ICE...
2026-08-21T19:31:28.687436+0600 janus-test sudo[3273]: [ERR] [janus.c:janus_process_incoming_request:1204] Couldn't find any handle 7018284164926532 in session 3407017201928467...
2026-08-27T17:56:18.932311+0600 janus-test sudo[3273]: [ERR] [plugins/janus_videocall.c:janus_videocall_handler:1158] Username '8801875738699' already taken
2026-08-21T03:53:02.101544+0600 janus-test sudo[3273]: [ERR] [transports/janus_http.c:janus_http_admin_handler:1882] Invalid url /
2026-08-21T08:18:59.329564+0600 janus-test sudo[3273]: [WARN] [8317872731069396] ICE failed for component 1 in stream 1, but let's give it some time... (trickle pending, answer received, alert not set)
2026-08-21T19:30:58.706551+0600 janus-test sudo[3273]: [ERR] [plugins/janus_sip.c:janus_sip_handler:4214] Wrong state (not in a call? status=idle)
2026-08-23T09:46:58.864039+0600 janus-test sudo[3273]: [ERR] [ice.c:janus_ice_cb_nice_recv:3102] [7688846018440918]     SRTCP unprotect error: srtp_err_status_replay_fail (len=70-->70)
2026-08-22T09:56:20.127048+0600 janus-test sudo[3273]: [ERR] [ice.c:janus_ice_check_failed:2089] [3029585454042204] ICE failed for component 1 in stream 1...
2026-08-22T21:51:22.952340+0600 janus-test sudo[3273]: nta_outgoing_tcancel: trying to cancel cancelled request
2026-08-21T08:41:05.180434+0600 janus-test sudo[3273]: [WARN] [858555534162008] Agent already exists?
2026-08-21T08:41:05.181519+0600 janus-test sudo[3273]: [ERR] [janus.c:janus_process_incoming_request:1542] Error setting ICE locally
2026-08-22T01:21:07.766290+0600 janus-test sudo[3273]: [317807942333703] Audio SSRC (#0) on mline #0 changed: 551641741 --> 400342977
2026-08-22T01:21:07.766290+0600 janus-test sudo[3273]: [ERR] [plugins/janus_sip.c:janus_sip_handler:3635] Wrong state (already in a call? status=incall)
2026-09-17T11:54:03.964013+0600 janus-test sudo[698]: [ERR] [plugins/janus_videocall.c:janus_videocall_handler:1151] Already registered (8801875738699)
2026-08-21T11:18:50.453255+0600 janus-test sudo[3273]: [ERR] [janus.c:janus_process_incoming_request:1553] Unexpected ANSWER (did we offer?)
2026-08-29T12:00:20.673664+0600 janus-test sudo[3273]: [2014828099611442] Updating existing session
2026-08-25T20:21:45.896737+0600 janus-test sudo[3273]: [ERR] [janus.c:janus_process_incoming_request:1899] [7260116756288161] Received a trickle, but still cleaning a previous session
2026-09-02T10:45:06.931529+0600 janus-test sudo[3273]: [ERR] [plugins/janus_videocall.c:janus_videocall_handler:1180] Register a username first
2026-09-17T11:28:17.502707+0600 janus-test sudo[698]: [ERR] [plugins/janus_videocall.c:janus_videocall_handler:1158] Username 's1' already taken
2026-08-22T11:55:00.722376+0600 janus-test sudo[3273]: [ERR] [transports/janus_http.c:janus_http_admin_handler:1882] Invalid url /favicon.ico
2026-09-02T09:54:16.858640+0600 janus-test sudo[3273]: [ERR] [plugins/janus_videocall.c:janus_videocall_handler:1228] Username '4567' doesn't exist
2026-09-02T10:44:47.916656+0600 janus-test sudo[3273]: [ERR] [plugins/janus_videocall.c:janus_videocall_handler:1158] Username 'efgh' already taken
2026-08-23T11:09:12.208723+0600 janus-test sudo[3273]: [ERR] [dtls.c:janus_dtls_retry:1115] [1025862469666943] DTLS taking too much time for component 1 in stream 1...
2026-08-27T11:21:37.399485+0600 janus-test sudo[3273]: [ERR] [ice.c:janus_plugin_session_is_alive:802] Invalid plugin session (0x7f4f8c013ba0)
2026-09-02T11:31:04.118340+0600 janus-test sudo[3273]: [ERR] [plugins/janus_videocall.c:janus_videocall_handler:1158] Username '1133' already taken
2026-08-23T20:30:32.989405+0600 janus-test sudo[3273]: [ERR] [plugins/janus_sip.c:janus_sip_allocate_local_ports:6967] Bind failed for audio RTP (port 52224), error (Address already in use), trying a different one...
2026-08-25T20:21:45.898467+0600 janus-test sudo[3273]: [ERR] [plugins/janus_sip.c:janus_sip_handler:4214] Wrong state (not in a call? status=closing)
2026-09-02T11:52:22.463703+0600 janus-test sudo[3273]: [ERR] [transports/janus_http.c:janus_http_admin_handler:1882] Invalid url /robots.txt
2026-09-02T11:52:22.839989+0600 janus-test sudo[3273]: [ERR] [transports/janus_http.c:janus_http_admin_handler:1882] Invalid url /sitemap.xml
2026-09-02T11:52:23.974267+0600 janus-test sudo[3273]: [ERR] [transports/janus_http.c:janus_http_admin_handler:1882] Invalid url stager
2026-09-02T11:52:24.349984+0600 janus-test sudo[3273]: [ERR] [transports/janus_http.c:janus_http_admin_handler:1882] Invalid url stager64
2026-09-02T12:06:07.232364+0600 janus-test sudo[3273]: [WARN] [3641343846957469] Didn't receive video for more than 1 second(s)...
2026-09-01T16:43:39.241905+0600 janus-test sudo[3273]: Detaching handle from JANUS VideoRoom plugin; 0x7f4fdc015440 0x7f4f8c030910 0x7f4fdc015440 0x7f4fdc0310a0
2026-09-01T16:47:32.396293+0600 janus-test sudo[3273]: [janus.plugin.videocall-0x7f4f8c0135d0] Data channel available
2026-09-02T10:44:25.701833+0600 janus-test sudo[3273]: [ERR] [plugins/janus_videocall.c:janus_videocall_handler:1188] Already in a call
2026-09-13T23:37:57.309732+0600 janus-test sudo[698]: ---------------------------------------------------
2026-09-16T15:25:21.860093+0600 janus-test sudo[698]: [ERR] [plugins/janus_videocall.c:janus_videocall_handler:1228] Username '8801875738699' doesn't exist
2026-08-23T00:40:22.900218+0600 janus-test sudo[3273]: [ERR] [plugins/janus_sip.c:janus_sip_handler:3629] Wrong state (not registered)
2026-08-24T23:16:04.471552+0600 janus-test sudo[3273]: [ERR] [transports/janus_http.c:janus_http_admin_handler:1919] Too many components...
2026-08-26T11:33:45.861697+0600 janus-test sudo[3273]: [WARN] [4237638458786406] ICE failed for component 1 in stream 1, but let's give it some time... (trickle pending, answer pending, alert not set)
2026-08-29T23:23:33.318196+0600 janus-test sudo[3273]: [ERR] [plugins/janus_sip.c:janus_sip_handler:2936] No session associated with this handle...
2026-08-30T14:21:20.681027+0600 janus-test sudo[3273]: [WARN] [7113285224097781] Alert already triggered, clearing up...
2026-09-02T10:29:58.652715+0600 janus-test sudo[3273]: [ERR] [plugins/janus_videocall.c:janus_videocall_handler:1228] Username 'abcd' doesn't exist
2026-09-02T11:52:23.218595+0600 janus-test sudo[3273]: [ERR] [transports/janus_http.c:janus_http_admin_handler:1882] Invalid url /F7sl
2026-09-02T11:52:23.595328+0600 janus-test sudo[3273]: [ERR] [transports/janus_http.c:janus_http_admin_handler:1882] Invalid url /nWKM
2026-09-03T15:43:27.536715+0600 janus-test sudo[3273]: [ERR] [transports/janus_http.c:janus_http_admin_handler:1882] Invalid url http://api.ipify.org/
2026-09-08T16:02:55.330991+0600 janus-test sudo[3273]: [ERR] [transports/janus_http.c:janus_http_admin_handler:1882] Invalid url /mcp
2026-09-08T16:02:55.339519+0600 janus-test sudo[3273]: [ERR] [transports/janus_http.c:janus_http_admin_handler:1882] Invalid url /api/mcp
2026-09-10T04:33:32.368830+0600 janus-test sudo[3273]: [rtp-sample] New video stream! (#1, ssrc=825307441, index 0)
2026-09-10T22:12:13.011154+0600 janus-test sudo[3273]: [ERR] [plugins/janus_sip.c:janus_sip_handler:4675] Wrong state (not established/inviting/progress? status=closing)
2026-09-12T21:31:41.833668+0600 janus-test sudo[3273]: [ERR] [plugins/janus_sip.c:janus_sip_handler:2979] Already registered (09638009866)
2026-09-13T11:56:43.950543+0600 janus-test sudo[3273]: [WARN] [SIP-09638917803] Unsupported SRTP profile AEAD_AES_256_GCM_8
2026-09-13T23:36:11.513271+0600 janus-test systemd[1]: Stopping Janus WebRTC Server...
2026-09-13T23:36:11.526177+0600 janus-test sudo[3273]: Stopping server, please wait...
2026-09-13T23:36:11.531779+0600 janus-test sudo[3273]: Ending sessions timeout watchdog...
2026-09-13T23:36:11.531779+0600 janus-test sudo[3273]: Sessions watchdog stopped
2026-09-13T23:36:11.531779+0600 janus-test sudo[3273]: Closing transport plugins:
2026-09-13T23:36:11.531779+0600 janus-test sudo[3273]: Stopping webserver(s)...
2026-09-13T23:36:11.531779+0600 janus-test sudo[3273]: In a hurry? I'm trying to free resources cleanly, here!
2026-09-13T23:36:11.531779+0600 janus-test sudo[3273]: JANUS REST (HTTP/HTTPS) transport plugin destroyed!
2026-09-13T23:36:11.534377+0600 janus-test sudo[3273]: WebSockets thread ended
2026-09-13T23:36:11.539339+0600 janus-test sudo[3273]: JANUS WebSockets transport plugin destroyed!
2026-09-13T23:36:11.539339+0600 janus-test sudo[3273]: Ending requests thread...
2026-09-13T23:36:11.539339+0600 janus-test sudo[3273]: Leaving Janus requests handler thread
2026-09-13T23:36:11.539339+0600 janus-test sudo[3273]: Destroying sessions...
2026-09-13T23:36:11.539339+0600 janus-test sudo[3273]: Freeing crypto resources...
2026-09-13T23:36:11.539339+0600 janus-test sudo[3273]: De-initializing SCTP...
2026-09-13T23:36:11.573423+0600 janus-test sudo[3273]: Closing plugins:
2026-09-13T23:36:11.573423+0600 janus-test sudo[3273]: JANUS AudioBridge plugin destroyed!
2026-09-13T23:36:11.573423+0600 janus-test sudo[3273]: JANUS Record&Play plugin destroyed!
2026-09-13T23:36:11.575428+0600 janus-test sudo[3273]: JANUS VideoRoom plugin destroyed!
2026-09-13T23:36:11.576049+0600 janus-test sudo[3273]: JANUS TextRoom plugin destroyed!
2026-09-13T23:36:11.577458+0600 janus-test sudo[3273]: JANUS NoSIP plugin destroyed!
2026-09-13T23:36:11.579139+0600 janus-test sudo[3273]: JANUS SIP plugin destroyed!
2026-09-13T23:36:11.580113+0600 janus-test sudo[3273]: JANUS VideoCall plugin destroyed!
2026-09-13T23:36:11.580897+0600 janus-test sudo[3273]: JANUS EchoTest plugin destroyed!
2026-09-13T23:36:11.587580+0600 janus-test sudo[3273]: JANUS Streaming plugin destroyed!
2026-09-13T23:36:11.587580+0600 janus-test sudo[3273]: Closing event handlers:
2026-09-13T23:36:11.587580+0600 janus-test sudo[3273]: Bye!
2026-09-13T23:36:11.610602+0600 janus-test sudo[3272]: pam_unix(sudo:session): session closed for user root
2026-09-13T23:36:11.618600+0600 janus-test systemd[1]: janus.service: Deactivated successfully.
2026-09-13T23:36:11.619360+0600 janus-test systemd[1]: Stopped Janus WebRTC Server.
2026-09-13T23:36:11.620870+0600 janus-test systemd[1]: janus.service: Consumed 21h 10min 46.405s CPU time.
2026-09-13T23:37:56.943184+0600 janus-test systemd[1]: Started Janus WebRTC Server.
2026-09-13T23:37:57.139215+0600 janus-test sudo[641]:     root : PWD=/ ; USER=root ; COMMAND=/opt/janus/bin/janus
2026-09-13T23:37:57.146355+0600 janus-test sudo[641]: pam_unix(sudo:session): session opened for user root(uid=0) by (uid=0)
2026-09-13T23:37:57.309732+0600 janus-test sudo[698]: Janus version: 1302 (1.3.2)
2026-09-13T23:37:57.309732+0600 janus-test sudo[698]: Janus commit: 2c6564d75eccb1c46f503a5fd0334929239fa5fb
2026-09-13T23:37:57.309732+0600 janus-test sudo[698]: Compiled on:  Sun Mar 23 15:15:08 UTC 2025
2026-09-13T23:37:57.309732+0600 janus-test sudo[698]: Logger plugins folder: /opt/janus/lib/janus/loggers
2026-09-13T23:37:57.309732+0600 janus-test sudo[698]: [WARN]         Couldn't access logger plugins folder...
2026-09-13T23:37:57.309732+0600 janus-test sudo[698]:   Starting Meetecho Janus (WebRTC Server) v1.3.2
2026-09-13T23:37:57.309732+0600 janus-test sudo[698]: Checking command line arguments...
2026-09-13T23:37:57.309732+0600 janus-test sudo[698]: Debug/log level is 4
2026-09-13T23:37:57.309732+0600 janus-test sudo[698]: Debug/log timestamps are disabled
2026-09-13T23:37:57.309732+0600 janus-test sudo[698]: Debug/log colors are enabled
2026-09-13T23:37:57.309732+0600 janus-test sudo[698]: Adding 'vmnet' to the ICE ignore list...
2026-09-13T23:37:57.309732+0600 janus-test sudo[698]: Using 10.0.0.14 as local IP...
2026-09-13T23:37:57.309732+0600 janus-test sudo[698]: Token based authentication disabled
2026-09-13T23:37:57.309732+0600 janus-test sudo[698]: Initializing recorder code
2026-09-13T23:37:57.309732+0600 janus-test sudo[698]: Using nat_1_1_mapping for public IP: 103.209.43.47
2026-09-13T23:37:57.309732+0600 janus-test sudo[698]: Initializing ICE stuff (Lite mode, ICE-TCP candidates disabled, half-trickle, IPv6 support disabled)
2026-09-13T23:37:57.326028+0600 janus-test sudo[698]: TURN REST API backend: (disabled)
2026-09-13T23:37:57.326028+0600 janus-test sudo[698]: Crypto: OpenSSL >= 1.1.0
2026-09-13T23:37:57.326028+0600 janus-test sudo[698]: No cert/key specified, autogenerating some...
2026-09-13T23:37:57.333887+0600 janus-test sudo[698]: Fingerprint of our certificate: 38:83:6D:12:A6:13:A3:FC:40:27:0C:E2:6C:34:5C:ED:71:2D:2D:75:83:B0:E1:41:B9:DE:FB:09:C5:6B:A9:1B
2026-09-13T23:37:57.333887+0600 janus-test sudo[698]: [WARN] DTLS timeout set to 500 ms, but not using BoringSSL: ignoring
2026-09-13T23:37:57.355250+0600 janus-test sudo[698]: Event handlers support disabled
2026-09-13T23:37:57.355250+0600 janus-test sudo[698]: Sessions watchdog started
2026-09-13T23:37:57.355701+0600 janus-test sudo[698]: Plugins folder: /opt/janus/lib/janus/plugins
2026-09-13T23:37:57.355701+0600 janus-test sudo[698]: Joining Janus requests handler thread
2026-09-13T23:37:57.356183+0600 janus-test sudo[698]: Loading plugin 'libjanus_echotest.so'...
2026-09-13T23:37:57.369185+0600 janus-test sudo[698]: JANUS EchoTest plugin initialized!
2026-09-13T23:37:57.369650+0600 janus-test sudo[698]: Loading plugin 'libjanus_videoroom.so'...
2026-09-13T23:37:57.377651+0600 janus-test sudo[698]: JANUS VideoRoom plugin initialized!
2026-09-13T23:37:57.377651+0600 janus-test sudo[698]: Loading plugin 'libjanus_textroom.so'...
2026-09-13T23:37:57.387106+0600 janus-test sudo[698]: JANUS TextRoom plugin initialized!
2026-09-13T23:37:57.387106+0600 janus-test sudo[698]: Loading plugin 'libjanus_recordplay.so'...
2026-09-13T23:37:57.403455+0600 janus-test sudo[698]: JANUS Record&Play plugin initialized!
2026-09-13T23:37:57.403455+0600 janus-test sudo[698]: Loading plugin 'libjanus_audiobridge.so'...
2026-09-13T23:37:57.426379+0600 janus-test sudo[698]: [WARN] Denoising via RNNoise NOT supported
2026-09-13T23:37:57.426379+0600 janus-test sudo[698]: JANUS AudioBridge plugin initialized!
2026-09-13T23:37:57.426379+0600 janus-test sudo[698]: Loading plugin 'libjanus_videocall.so'...
2026-09-13T23:37:57.436144+0600 janus-test sudo[698]: JANUS VideoCall plugin initialized!
2026-09-13T23:37:57.436144+0600 janus-test sudo[698]: Loading plugin 'libjanus_nosip.so'...
2026-09-13T23:37:57.442693+0600 janus-test sudo[698]: JANUS NoSIP plugin initialized!
2026-09-13T23:37:57.443055+0600 janus-test sudo[698]: Loading plugin 'libjanus_sip.so'...
2026-09-13T23:37:57.482815+0600 janus-test sudo[698]: [ERR] [config.c:janus_config_parse:205] Error parsing config file at line 21: syntax error
2026-09-13T23:37:57.482815+0600 janus-test sudo[698]: [WARN] Couldn't find .jcfg configuration file (janus.plugin.sip), trying .cfg
2026-09-13T23:37:57.482815+0600 janus-test sudo[698]: [ERR] [config.c:janus_config_parse:191]   -- Error reading configuration file 'janus.plugin.sip.cfg'... error 2 (No such file or directory)
2026-09-13T23:37:57.490780+0600 janus-test sudo[698]: JANUS SIP plugin initialized!
2026-09-13T23:37:57.490780+0600 janus-test sudo[698]: Loading plugin 'libjanus_streaming.so'...
2026-09-13T23:37:57.500388+0600 janus-test sudo[698]: JANUS Streaming plugin initialized!
2026-09-13T23:37:57.500388+0600 janus-test sudo[698]: Transport plugins folder: /opt/janus/lib/janus/transports
2026-09-13T23:37:57.500930+0600 janus-test sudo[698]: Loading transport plugin 'libjanus_http.so'...
2026-09-13T23:37:57.519256+0600 janus-test sudo[698]: HTTP transport timer started
2026-09-13T23:37:57.520286+0600 janus-test sudo[698]: HTTP webserver started (port 8088, /janus path listener)...
2026-09-13T23:37:57.520556+0600 janus-test sudo[698]: Admin/monitor HTTP webserver started (port 7088, /admin path listener)...
2026-09-13T23:37:57.520556+0600 janus-test sudo[698]: JANUS REST (HTTP/HTTPS) transport plugin initialized!
2026-09-13T23:37:57.520556+0600 janus-test sudo[698]: Loading transport plugin 'libjanus_pfunix.so'...
2026-09-13T23:37:57.528619+0600 janus-test sudo[698]: [WARN] No Unix Sockets server started, giving up...
2026-09-13T23:37:57.528619+0600 janus-test sudo[698]: [WARN] The 'janus.transport.pfunix' plugin could not be initialized
2026-09-13T23:37:57.528619+0600 janus-test sudo[698]: Loading transport plugin 'libjanus_websockets.so'...
2026-09-13T23:37:57.538274+0600 janus-test sudo[698]: [WARN] libwebsockets has been built without IPv6 support, will bind to IPv4 only
2026-09-13T23:37:57.544380+0600 janus-test sudo[698]: libwebsockets logging: 0
2026-09-13T23:37:57.560787+0600 janus-test sudo[698]: Websockets server started (port 8188)...
2026-09-13T23:37:57.561723+0600 janus-test sudo[698]: JANUS WebSockets transport plugin initialized!
2026-09-13T23:37:57.562124+0600 janus-test sudo[698]: WebSockets thread started
2026-09-16T02:15:49.535565+0600 janus-test sudo[698]: [ERR] [transports/janus_http.c:janus_http_admin_handler:1882] Invalid url /bUQT
2026-09-16T02:15:49.801742+0600 janus-test sudo[698]: [ERR] [transports/janus_http.c:janus_http_admin_handler:1882] Invalid url /4ftO
2026-09-16T02:21:55.490259+0600 janus-test sudo[698]: [ERR] [transports/janus_http.c:janus_http_admin_handler:1882] Invalid url /Kes9
2026-09-16T02:21:55.768149+0600 janus-test sudo[698]: [ERR] [transports/janus_http.c:janus_http_admin_handler:1882] Invalid url /dALl
2026-09-16T19:16:45.298663+0600 janus-test sudo[698]: [ERR] [plugins/janus_sip.c:janus_sip_allocate_local_ports:6988] Bind failed for audio RTCP (port 33281), error (Address already in use), trying a different one...
2026-09-16T21:58:15.216685+0600 janus-test sudo[698]: [ERR] [plugins/janus_sip.c:janus_sip_handler:4214] Wrong state (not in a call? status=incall_reinviting)
2026-09-17T09:07:24.679445+0600 janus-test sudo[698]: tport_udp_error: Connection refused (111) [icmp type=3 code=3]
2026-09-17T09:07:24.679923+0600 janus-test sudo[698]:         reported by [103.209.42.30]:0
2026-09-17T09:07:24.680093+0600 janus-test sudo[698]: nta: REGISTER (999650812): Connection refused (111) with udp/[103.209.42.30]:5060
2026-09-20T11:44:00.268098+0600 janus-test sudo[698]: [ERR] [plugins/janus_sip.c:janus_sip_handler:3210] Invalid user address 8801730351490
-- Boot 90757d91994f4d0fb0d8e57f67561a4d --
