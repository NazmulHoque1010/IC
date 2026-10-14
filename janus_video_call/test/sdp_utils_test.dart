import 'package:flutter_test/flutter_test.dart';
import 'package:janus_video_call/sdp_utils.dart';

void main() {
  const sdp = 'v=0\r\n'
      'm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n'
      'a=rtpmap:111 opus/48000/2\r\n'
      'm=video 9 UDP/TLS/RTP/SAVPF 96 97 98 99\r\n'
      'a=rtpmap:96 H264/90000\r\n'
      'a=rtpmap:97 rtx/90000\r\n'
      'a=rtpmap:98 VP8/90000\r\n'
      'a=rtpmap:99 rtx/90000\r\n';

  test('VP8 is moved to the front of the m=video line', () {
    final result = preferVideoCodec(sdp, 'VP8');
    expect(result, contains('m=video 9 UDP/TLS/RTP/SAVPF 98 96 97 99'));
    expect(result, contains('m=audio 9 UDP/TLS/RTP/SAVPF 111'));
  });

  test('SDP without the codec is returned unchanged', () {
    expect(preferVideoCodec(sdp, 'AV1'), sdp);
  });

  test('extension is extracted from a SIP URI', () {
    expect(extensionFromUri('sip:1001@192.168.99.112'), '1001');
  });
}
