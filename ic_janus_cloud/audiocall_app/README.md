# IC AudioCall app

A Flutter app for **audio-only calls through the two IC Janus servers**. It uses the
custom `janus.plugin.audiocall` plugin over the Janus WebSocket API (port 8188).
There is no FreeSWITCH and no SIP.

```
App 1000 ⇄ Janus PC1 [audiocall] ⇄ peer link (UDP 7088) ⇄ [audiocall] Janus PC2 ⇄ App 1001
```

It runs on **Android** (`flutter run` on a phone) and on **Linux** (`flutter run -d linux`).
It also works with the browser test page `html/ic/audiocall-test.html`, so any mix of
clients can call each other.

## Using it

1. Choose **PC1** or **PC2**, which fills in the Janus IP. **Custom** lets you type an IP.
2. Enter a username (for example `1000`) and tap **Register**. A username can only be
   registered once, across both servers.
3. **Online users** lists the users on this server and on the other server. Tap a user,
   or type a username, then tap **Audio call**.
4. An incoming call shows an Accept / Decline dialog. The dialog closes by itself if the
   caller hangs up first.
5. During a call you can mute, switch speaker / earpiece (phones only), and hang up.

## Plugin requests used

| Request | Purpose |
|---|---|
| `register {username}` | register on this Janus server |
| `list` | users here, plus `peer_list` from the other server |
| `call {username}` + offer | call a user on either server |
| `accept` + answer | answer an incoming call |
| `hangup {reason}` | end a call, or decline an incoming one |

Events handled: `registered`, `calling`, `incomingcall`, `accepted`, `hangup`, and errors
(for example 476 username taken, 478 no such user, 484 audio only).

## Network notes

- The phone must be on the **same LAN / Wi-Fi** as the PCs. The USB cable is only used by
  `flutter run` to install and debug the app.
- No STUN or TURN server is configured, because LAN host candidates are enough.
