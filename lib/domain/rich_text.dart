/// Rich-text inline token format for user messages and the draft input.
///
/// The content is a plain string carrying inline tokens of the form
/// `@@${<json>}$@@`, where `<json>` is a JSON object with at least a `type`
/// field. Everything outside a token is literal text. This keeps content
/// fully serializable (one string) while embedding structured data, and is
/// extensible: today `ref-content` (a paragraph-range reference); later
/// `ref-text`, `image`, `link`, `setting`, … (not implemented yet).
///
/// The agent never sees tokens: [toAgentText] converts a rich content string
/// into the model-facing format (`[ref: 章节 起止段]` inline + the actual
/// referenced text appended at the end).
library;

import 'dart:convert';

/// A parsed inline token.
class RichToken {
  /// e.g. 'ref-content'.
  final String type;
  final Map<String, dynamic> data;

  const RichToken({required this.type, required this.data});

  /// ref-content convenience accessors.
  String get chapter => (data['chapter'] as String?) ?? '';
  int get start => (data['start'] as num?)?.toInt() ?? 0;
  int get end => (data['end'] as num?)?.toInt() ?? 0;
  String get content => (data['content'] as String?) ?? '';

  String get label {
    switch (type) {
      case 'ref-content':
        return '$chapter $start-$end 段';
      default:
        return type;
    }
  }

  Map<String, dynamic> toJson() => {'type': type, ...data};

  String serialize() => '@@\$${jsonEncode(toJson())}\$@@';

  factory RichToken.fromJson(Map<String, dynamic> json) {
    final type = (json['type'] as String?) ?? 'unknown';
    final data = Map<String, dynamic>.from(json)..remove('type');
    return RichToken(type: type, data: data);
  }

  /// Build a ref-content token.
  factory RichToken.refContent({
    required String chapter,
    required int start,
    required int end,
    required String content,
    String? id,
  }) =>
      RichToken(
        type: 'ref-content',
        data: {
          'chapter': chapter,
          'start': start,
          'end': end,
          'content': content,
          if (id != null) 'id': id,
        },
      );
}

/// One piece of parsed content: literal text or an inline token.
abstract class RichPiece {
  const RichPiece();
}

class TextPiece extends RichPiece {
  final String text;
  const TextPiece(this.text);
}

class TokenPiece extends RichPiece {
  final RichToken token;
  const TokenPiece(this.token);
}

/// Marker delimiters. Chosen so they almost never appear in prose and so the
/// JSON body can contain any text (including `}` / `$` / `@`) safely.
const _open = '@@\$';
const _close = '\$@@';

/// Parse a rich content string into ordered pieces.
List<RichPiece> parseRich(String content) {
  final out = <RichPiece>[];
  var i = 0;
  final buf = StringBuffer();
  void flush() {
    if (buf.isNotEmpty) {
      out.add(TextPiece(buf.toString()));
      buf.clear();
    }
  }

  while (i < content.length) {
    final o = content.indexOf(_open, i);
    if (o < 0) {
      buf.write(content.substring(i));
      break;
    }
    // text before token
    buf.write(content.substring(i, o));
    final c = content.indexOf(_close, o + _open.length);
    if (c < 0) {
      // Unterminated — treat the rest as literal text.
      buf.write(content.substring(o));
      break;
    }
    // The JSON body is between `@@$` and `$@@`.
    final jsonStr = content.substring(o + _open.length, c);
    try {
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;
      flush();
      out.add(TokenPiece(RichToken.fromJson(json)));
    } catch (_) {
      // Malformed token — keep as literal text.
      buf.write(content.substring(o, c + _close.length));
    }
    i = c + _close.length;
  }
  flush();
  return out;
}

/// Serialize pieces back into a rich content string.
String serializeRich(List<RichPiece> pieces) => pieces.map((p) {
      if (p is TextPiece) return p.text;
      if (p is TokenPiece) return p.token.serialize();
      return '';
    }).join();

/// Convert a rich content string into the model-facing plain text: tokens
/// become `[ref: 章节 起止段]` inline, and the actual referenced content is
/// appended at the end so the model can read it.
String toAgentText(String content) {
  final pieces = parseRich(content);
  final buf = StringBuffer();
  final refs = <RichToken>[];
  for (final p in pieces) {
    if (p is TextPiece) {
      buf.write(p.text);
    } else if (p is TokenPiece) {
      final t = p.token;
      if (t.type == 'ref-content') {
        buf.write(' [ref: ${t.chapter} ${t.start}~${t.end} 段] ');
        refs.add(t);
      }
    }
  }
  final text = buf.toString().trim();
  if (refs.isEmpty) return text;
  final appended = refs
      .map((r) => '${r.chapter} ${r.start}~${r.end} 段：\n${r.content}')
      .join('\n\n');
  return '$text\n\n$appended';
}
