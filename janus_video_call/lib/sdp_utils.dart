/// Moves every payload type of [codec] (e.g. "VP8") to the front of the
/// m=video line, so both phones prefer the same video codec.
///
/// Neither Janus server transcodes video, so both ends must agree on one
/// codec. Returns [sdp] unchanged if there is no video section or the codec
/// is not offered.
String preferVideoCodec(String sdp, String codec) {
  final separator = sdp.contains('\r\n') ? '\r\n' : '\n';
  final lines = sdp.split(separator);

  final videoLine = lines.indexWhere((line) => line.startsWith('m=video'));
  if (videoLine == -1) return sdp;

  final rtpmap = RegExp(
    '^a=rtpmap:(\\d+) ${RegExp.escape(codec)}/',
    caseSensitive: false,
  );

  final preferred = <String>[];
  for (var i = videoLine + 1; i < lines.length; i++) {
    if (lines[i].startsWith('m=')) break; // next media section
    final match = rtpmap.firstMatch(lines[i]);
    if (match != null) preferred.add(match.group(1)!);
  }
  if (preferred.isEmpty) return sdp;

  // m=video <port> <proto> <pt1> <pt2> ...
  final parts = lines[videoLine].split(' ');
  if (parts.length <= 3) return sdp;

  final header = parts.sublist(0, 3);
  final payloads = parts.sublist(3);

  final reordered = <String>[
    ...payloads.where(preferred.contains),
    ...payloads.where((pt) => !preferred.contains(pt)),
  ];

  lines[videoLine] = [...header, ...reordered].join(' ');
  return lines.join(separator);
}

/// Extracts "1001" from "sip:1001@192.168.97.135".
String extensionFromUri(String uri) {
  final match = RegExp(r'sip:([^@]+)@').firstMatch(uri);
  return match?.group(1) ?? (uri.isEmpty ? 'Unknown' : uri);
}
