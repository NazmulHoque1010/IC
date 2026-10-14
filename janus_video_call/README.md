# janus_video_call

Prototype Flutter app for **audio + video calls between two Janus servers**
(Janus PC1 `192.168.97.135`, Janus PC2 `192.168.99.112`), with no FreeSWITCH.

Each user registers through **their own Janus** using the Janus SIP plugin.
Janus registers the user with a signaling-only SIP proxy/registrar
(e.g. Kamailio). Audio and video flow:

```
Phone A ⇄ WebRTC ⇄ Janus PC1 ⇄ RTP ⇄ Janus PC2 ⇄ WebRTC ⇄ Phone B
```

## Files

| File | Purpose |
|---|---|
| `lib/main.dart` | UI: server presets, register, dial, incoming call card, video call screen |
| `lib/janus_sip_client.dart` | Janus WebSocket client: session, SIP plugin handle, keepalive, register/call/accept/decline/hangup, trickle |
| `lib/sdp_utils.dart` | Puts VP8 first in the SDP (neither Janus transcodes video) |
| `test/sdp_utils_test.dart` | Unit tests for the SDP helper |
| `android/app/src/main/AndroidManifest.xml` | Adds CAMERA permission |

## Using it

1. Choose **PC1** or **PC2**. This fills in the Janus host and the SIP proxy host. Both can be edited.
2. Enter your extension and password, then tap **Register**.
3. Enter the other extension and tap **Video call**.
4. In a call you can mute, turn the camera off, switch cameras, toggle the speaker and hang up.

## Requirements

- Janus with the WebSocket transport enabled (port 8188) and the SIP plugin.
- A SIP registrar/proxy reachable at the "SIP proxy host".
- The phones on the same LAN as the PCs. No STUN/TURN servers are configured.
