/// SSE (Server-Sent Events) line splitter for streaming chat completions.
///
/// Streams come in as arbitrary byte chunks; an event may span several chunks
/// and an event may have multiple `data:` lines. This class reassembles the
/// raw text and yields one "data" payload string per SSE event.
library;

class SseSplitter {
  final StringBuffer _buffer = StringBuffer();

  /// Feed a chunk of decoded text; returns complete SSE data payloads.
  Iterable<String> feed(String chunk) sync* {
    _buffer.write(chunk);
    // Normalize line endings.
    final text = _buffer.toString().replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final lines = text.split('\n');

    // Keep the last (possibly incomplete) line in the buffer.
    _buffer.clear();
    _buffer.write(lines.removeLast());

    final dataLines = <String>[];
    for (final line in lines) {
      if (line.isEmpty) {
        // Event boundary.
        if (dataLines.isNotEmpty) {
          yield dataLines.join('\n');
          dataLines.clear();
        }
        continue;
      }
      if (line.startsWith(':')) continue; // comment / heartbeat
      if (line.startsWith('data:')) {
        dataLines.add(line.substring(5).trimStartSpace());
      }
    }
  }
}

extension on String {
  String trimStartSpace() {
    var i = 0;
    while (i < length && this[i] == ' ') {
      i++;
    }
    return substring(i);
  }
}
