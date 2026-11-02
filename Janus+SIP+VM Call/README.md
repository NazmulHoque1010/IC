# Janus+SIP+VM Call

The **IC SIP Call** Flutter app and the **one-command server installer** for the IC calling system: Janus (WebRTC) and FreeSWITCH (SIP) on cloud VMs.

| Path | What it is |
|---|---|
| `ic_call_app/` | IC SIP Call Flutter app (Android + Linux), package `com.ic.sipcall`: `lib/`, `pubspec.yaml`, `pubspec.lock`, Android manifest and Gradle files, Linux runner |
| `install-ic-server.sh` | installs a complete IC server: Janus IC build with SIP, optionally FreeSWITCH with our configuration, optionally the media relay. Existing installs are backed up first |

The Janus code, the captured server configuration and the installer's README live in the Janus fork, branch [`ic-custom`](https://github.com/NazmulHoque1010/janus-gateway/tree/ic-custom), folder `Janus+SIP+VM Call/`. The installer expects to run from that clone:

```bash
git clone --branch ic-custom https://github.com/NazmulHoque1010/janus-gateway.git ~/janus-dev
bash ~/janus-dev/"Janus+SIP+VM Call"/install-ic-server.sh --dry-run
```

## The app

- First start: asks for a name and remembers it; every later start registers it automatically (password 1234). "Disconnect & rename" frees the name.
- Joins the server with the fewest users, using the IC status service (port 8190) of the seed servers.
- Registers the name twice with Janus:
  - `janus.plugin.videocall`: calls between app users. Janus connects the two apps directly; FreeSWITCH is not involved and nothing is transcoded (Opus, plus video).
  - `janus.plugin.sip`: calls with SIP phones such as MizuDroid, through the FreeSWITCH on the same VM, which converts the app's Opus to the phone's PCMU. Audio only.
- Users that the status service lists under `phones` are called through SIP; everyone else through VideoCall.

## Running the app

```bash
cd ic_call_app
flutter pub get
flutter analyze
flutter run -d <phone-id> --dart-define=IC_SEEDS=<vm1 public IP>,<vm2 public IP>
flutter run -d linux     --dart-define=IC_SEEDS=<vm1 public IP>,<vm2 public IP>
```

- `IC_SEEDS` (required): one or more servers whose status service lists all servers and their users.
- `IC_STATUS_PORT` (optional): status service port, default 8190.
- Server side: the IC status service 1.2 (with the `phones` list) and the FreeSWITCH configuration with codecs by device type.

The previous Janus-only app (AudioCall + CustomVideoCall, username set with `IC_USER`) is in this repository's history, commit `3655627`.
