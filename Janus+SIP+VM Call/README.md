# Janus+SIP+VM Call

The **IC Call** Flutter app and the **one-command server installer** for the Janus-only calling system: AudioCall + CustomVideoCall across several Janus servers, on a LAN or on cloud VMs.

| Path | What it is |
|---|---|
| `ic_call_app/` | Flutter app (Android + Linux): `lib/`, `pubspec.yaml`, `pubspec.lock`, Android manifest and Gradle files, Linux runner |
| `install-ic-server.sh` | installs a complete IC server: Janus IC build with SIP, optionally FreeSWITCH with our configuration, optionally the media relay. Existing installs are backed up first |

The Janus code, the captured server configuration and the installer's README live in the Janus fork, branch [`ic-custom`](https://github.com/NazmulHoque1010/janus-gateway/tree/ic-custom), folder `Janus+SIP+VM Call/`. The installer expects to run from that clone:

```bash
git clone --branch ic-custom https://github.com/NazmulHoque1010/janus-gateway.git ~/janus-dev
bash ~/janus-dev/"Janus+SIP+VM Call"/install-ic-server.sh --dry-run
```

## Running the app

```bash
cd ic_call_app
flutter pub get
flutter analyze
flutter run -d <phone-id> --dart-define=IC_USER=Nazmul --dart-define=IC_SEEDS=<server>[:8188][,<server2>]
flutter run -d linux     --dart-define=IC_USER=Sazid
```

- `IC_USER` (required): this device's username.
- `IC_SEEDS`: one or more servers the app asks for the list of all servers, needed over the internet. On a LAN, discovery by broadcast also works.
