import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:gpt_markdown/custom_widgets/markdown_config.dart';
import 'dart:async';
import 'dart:convert';

import '../../../domain/conversation.dart';
import '../../../domain/rich_text.dart';
import 'ref_badge.dart';
/// One message row.
///  - Assistant content rendered as Markdown.
///  - CoT (reasoning_content) is collapsible, collapsed by default.
///  - Tool calls are collapsible, collapsed by default, expandable to show
///    arguments + result.
/// Per-message action chips (copy / edit / retry / delete for user messages;
/// copy / retry / revert for assistant messages) live directly under each
/// bubble, passed in from the turn cluster.
class MessageTile extends StatefulWidget {
  final Message message;
  final bool streaming;
  // Per-message action chips. Null = hide that chip (e.g. disabled while
  // running). When all are null the action row is omitted entirely.
  final VoidCallback? onRetry;
  final VoidCallback? onCopy;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final VoidCallback? onRevert;
  const MessageTile({
    super.key,
    required this.message,
    this.streaming = false,
    this.onRetry,
    this.onCopy,
    this.onEdit,
    this.onDelete,
    this.onRevert,
  });

  @override
  State<MessageTile> createState() => _MessageTileState();
}

class _MessageTileState extends State<MessageTile>
    with AutomaticKeepAliveClientMixin {
  bool _cotExpanded = false;
  bool _cotUserToggled = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void didUpdateWidget(covariant MessageTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    final m = widget.message;
    final oldM = oldWidget.message;
    // Auto-expand CoT while reasoning streams in (so the user sees it arrive),
    // unless the user has already toggled it manually — then leave it alone.
    // Only expand while we're still in the reasoning phase (no body text yet):
    // once the prose starts arriving we collapse it again below.
    if (!_cotUserToggled && widget.streaming &&
        m.reasoningContent.isNotEmpty &&
        m.content.isEmpty &&
        !_cotExpanded) {
      _cotExpanded = true;
    } else if (!_cotUserToggled &&
        m.content.isNotEmpty &&
        oldM.content.isEmpty &&
        _cotExpanded) {
      // Body text just started arriving → collapse the CoT so the prose takes
      // focus. Previously this only happened after the whole message ended.
      _cotExpanded = false;
    } else if (!_cotUserToggled &&
        !widget.streaming &&
        oldWidget.streaming &&
        _cotExpanded) {
      // Streaming just ended (e.g. a reasoning-only turn) → auto-collapse
      // the CoT back, unless the user manually expanded it during the stream.
      _cotExpanded = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final m = widget.message;
    final isUser = m.role == MessageRole.user;
    final isTool = m.role == MessageRole.tool;
    final scheme = Theme.of(context).colorScheme;

    // Tool *result* messages are rendered merged with their caller in the
    // turn cluster (see _TurnCluster / _ToolCallBlock), not as a standalone
    // tile.
    if (isTool) {
      return const SizedBox.shrink();
    }

    final bubbleColor =
        isUser ? scheme.primary : scheme.surfaceContainerHigh;
    final fgColor = isUser ? scheme.onPrimary : scheme.onSurface;

    Widget bubble = Container(
      constraints: const BoxConstraints(maxWidth: 560),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: bubbleColor,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(16),
          topRight: const Radius.circular(16),
          bottomLeft: Radius.circular(isUser ? 16 : 4),
          bottomRight: Radius.circular(isUser ? 4 : 16),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // CoT (collapsible, collapsed by default).
          if (m.reasoningContent.isNotEmpty)
            _CollapsibleCot(
              content: m.reasoningContent,
              expanded: _cotExpanded,
              onToggle: () => setState(() {
                _cotUserToggled = true;
                _cotExpanded = !_cotExpanded;
              }),
              color: fgColor,
            ),
          if (m.content.isNotEmpty || !widget.streaming)
            isUser
                ? _RichUserContent(content: m.content, fgColor: fgColor)
                : _MarkdownContent(
                    // Stable key across the streaming→settled transition: we
                    // no longer remount at turn end (the old package needed a
                    // remount to toggle selection safely; gpt_markdown renders
                    // plain Text.rich in both states, so we just keep it
                    // mounted and avoid the end-of-turn flash).
                    key: ValueKey('md_${m.id}'),
                    data: m.content,
                    fgColor: fgColor,
                    theme: Theme.of(context),
                    streaming: widget.streaming,
                  )
          else
            const _TypingDots(),
          if (widget.streaming && m.content.isNotEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: _TypingDots(),
            ),
        ],
      ),
    );

    // Per-message action chips. Build only the chips that have a callback;
    // if none, the row is omitted entirely.
    final actions = <_ActionChipData>[];
    if (widget.onCopy != null) {
      actions.add(_ActionChipData(Icons.copy_outlined, '复制', widget.onCopy!));
    }
    if (widget.onEdit != null) {
      actions.add(_ActionChipData(Icons.edit_outlined, '编辑', widget.onEdit!));
    }
    if (widget.onRetry != null) {
      actions.add(_ActionChipData(Icons.refresh, '重试', widget.onRetry!));
    }
    if (widget.onRevert != null) {
      actions.add(_ActionChipData(Icons.undo, '撤回', widget.onRevert!));
    }
    if (widget.onDelete != null) {
      actions.add(_ActionChipData(Icons.delete_outline, '删除', widget.onDelete!));
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: Column(
          crossAxisAlignment:
              isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            bubble,
            if (actions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: _MessageActionBar(
                  actions: actions,
                  rightAlign: isUser,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Data for one per-message action chip.
class _ActionChipData {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _ActionChipData(this.icon, this.label, this.onTap);
}

/// A row of small action chips shown beneath a message bubble.
class _MessageActionBar extends StatefulWidget {
  final List<_ActionChipData> actions;
  final bool rightAlign;
  const _MessageActionBar(
      {required this.actions, required this.rightAlign});

  @override
  State<_MessageActionBar> createState() => _MessageActionBarState();
}

class _MessageActionBarState extends State<_MessageActionBar> {
  // Track per-chip "copied"-style feedback by label.
  String? _feedbackFor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment:
          widget.rightAlign ? MainAxisAlignment.end : MainAxisAlignment.start,
      children: [
        for (var i = 0; i < widget.actions.length; i++) ...[
          if (i > 0) const SizedBox(width: 2),
          _buildChip(widget.actions[i], scheme),
        ],
      ],
    );
  }

  Widget _buildChip(_ActionChipData a, ColorScheme scheme) {
    final feedback = _feedbackFor == a.label;
    final label = feedback ? '已复制' : a.label;
    return Tooltip(
      message: a.label,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () {
          a.onTap();
          if (a.icon == Icons.copy_outlined) {
            setState(() => _feedbackFor = a.label);
            Future.delayed(const Duration(seconds: 2), () {
              if (mounted) setState(() => _feedbackFor = null);
            });
          }
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                feedback ? Icons.check : a.icon,
                size: 13,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 3),
              Text(label,
                  style: TextStyle(
                      fontSize: 11, color: scheme.onSurfaceVariant)),
            ],
          ),
        ),
      ),
    );
  }
}
/// A merged tool-call + result block.
///
/// Expand/collapse behavior:
///  - When [streaming] is true (the call's arguments are still arriving or
///    the tool result has not landed yet), the block auto-expands so the user
///    sees the parameters stream in live.
///  - When the result lands (streaming flips to false), the block
///    auto-collapses back to its one-line summary. The user can still tap to
///    re-expand at any time.
///
/// For `edit_range` / `insert_at`, the call's `new_text` argument is parsed
/// and rendered as normal readable text (split into paragraphs) instead of
/// raw JSON, since it is novel prose the user authored.
class ToolCallBlock extends StatefulWidget {
  final ToolCall call;
  final String? resultContent; // null = still running / no result yet
  final bool streaming; // args arriving or result pending
  const ToolCallBlock({
    super.key,
    required this.call,
    this.resultContent,
    this.streaming = false,
  });

  @override
  State<ToolCallBlock> createState() => _ToolCallBlockState();
}

class _ToolCallBlockState extends State<ToolCallBlock>
    with SingleTickerProviderStateMixin {
  bool _expanded = false;
  // Did the user manually toggle? If so, stop auto-expanding on every delta —
  // otherwise streaming rebuilds would immediately re-expand what the user
  // just collapsed.
  bool _userToggled = false;
  late final AnimationController _ctrl;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 180));
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeInOutCubic);
    // Start expanded if already streaming on first mount.
    _expanded = widget.streaming;
    if (_expanded) _ctrl.value = 1.0;
  }

  @override
  void didUpdateWidget(covariant ToolCallBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Auto-expand while streaming so the user sees args stream in live — but
    // only until the user has manually interacted; after that respect their
    // choice for the rest of the stream.
    if (!_userToggled && widget.streaming && !_expanded) {
      _expanded = true;
      _ctrl.forward();
    } else if (!widget.streaming && oldWidget.streaming && _expanded) {
      // Streaming just finished (result landed) → auto-collapse once.
      _expanded = false;
      _ctrl.reverse();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _toggle() {
    _userToggled = true;
    setState(() => _expanded = !_expanded);
    if (_expanded) {
      _ctrl.forward();
    } else {
      _ctrl.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasResult = widget.resultContent != null;
    final textSpec = _TextToolSpec.tryParse(widget.call);
    final body = Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: textSpec != null
          ? _TextToolBody(spec: textSpec, scheme: scheme)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Labeled('参数', widget.call.arguments, scheme),
                if (hasResult) ...[
                  const SizedBox(height: 4),
                  _Labeled('结果', widget.resultContent!, scheme),
                ],
              ],
            ),
    );
    return Container(
      constraints: const BoxConstraints(maxWidth: 560),
      margin: const EdgeInsets.only(top: 4, bottom: 2),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: _toggle,
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                children: [
                  Icon(_toolIcon(widget.call.name),
                      size: 13, color: scheme.onTertiaryContainer),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _summary(widget.call, widget.resultContent),
                      style: TextStyle(
                          fontSize: 12,
                          color: scheme.onTertiaryContainer),
                    ),
                  ),
                  if (hasResult)
                    Icon(Icons.check_circle, size: 13, color: scheme.primary)
                  else if (widget.streaming)
                    SizedBox(
                      width: 13,
                      height: 13,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: scheme.onTertiaryContainer,
                      ),
                    )
                  else
                    Icon(Icons.hourglass_top, size: 13,
                        color: scheme.onTertiaryContainer),
                  const SizedBox(width: 4),
                  Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                      size: 16, color: scheme.onTertiaryContainer),
                ],
              ),
            ),
          ),
          SizeTransition(
            sizeFactor: _anim,
            axisAlignment: 1.0,
            child: body,
          ),
        ],
      ),
    );
  }

  /// One-line summary for the (possibly collapsed) header. Prefers the
  /// tool's structured result `summary` field; falls back to the tool name
  /// + a short arg hint for edit/insert; otherwise the raw tool name.
  String _summary(ToolCall call, String? resultContent) {
    if (resultContent != null) {
      final decoded = _tryDecode(resultContent);
      final s = decoded?['summary'];
      if (s is String && s.isNotEmpty) return s;
    }
    final spec = _TextToolSpec.tryParse(call);
    if (spec != null) return spec.header;
    return '调用工具 · ${call.name}';
  }

  IconData _toolIcon(String name) {
    switch (name) {
      case 'edit_range':
        return Icons.edit_note;
      case 'insert_at':
        return Icons.post_add;
      case 'delete_range':
        return Icons.delete_outline;
      default:
        return Icons.build;
    }
  }

  static Map<String, dynamic>? _tryDecode(String json) {
    try {
      return (jsonDecode(json) as Map).cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }
}

/// Parsed view of an `edit_range` / `insert_at` / `delete_range` tool call,
/// rendering prose (`new_text`) as normal text rather than raw JSON.
class _TextToolSpec {
  final String toolName; // edit_range | insert_at | delete_range
  final String header; // one-line summary used when collapsed/streaming
  final int? start;
  final int? end;
  final int? index;
  final String? chapter;
  final String newText; // raw new_text (may be partial while streaming)

  _TextToolSpec({
    required this.toolName,
    required this.header,
    this.start,
    this.end,
    this.index,
    this.chapter,
    required this.newText,
  });

  static _TextToolSpec? tryParse(ToolCall call) {
    final name = call.name;
    if (name != 'edit_range' && name != 'insert_at' && name != 'delete_range') {
      return null;
    }
    Map<String, dynamic>? args;
    // While streaming the arguments JSON may be incomplete / unparseable;
    // fall back to treating the whole string as raw new_text so the prose
    // still streams in.
    String rawText = '';
    if (call.arguments.trim().isNotEmpty) {
      try {
        args = (jsonDecode(call.arguments) as Map).cast<String, dynamic>();
      } catch (_) {
        // Partial JSON — best effort: pull out a new_text-ish tail.
        args = null;
        rawText = _extractPartialNewText(call.arguments);
      }
    }
    final newText = (args?['new_text'] as String?) ?? rawText;
    final chapter = args?['chapter']?.toString();
    String header;
    switch (name) {
      case 'edit_range':
        final s = args?['start'];
        final e = args?['end'];
        header = '修改段落'
            '${s != null ? " 第 $s-${e ?? s} 段" : ""}'
            '${chapter != null ? " · $chapter" : ""}';
        break;
      case 'insert_at':
        final i = args?['index'];
        header = '插入段落'
            '${i != null ? " 于第 $i 段前" : ""}'
            '${chapter != null ? " · $chapter" : ""}';
        break;
      default: // delete_range
        final s = args?['start'];
        final e = args?['end'];
        header = '删除段落'
            '${s != null ? " 第 $s-${e ?? s} 段" : ""}'
            '${chapter != null ? " · $chapter" : ""}';
        break;
    }
    return _TextToolSpec(
      toolName: name,
      header: header,
      start: args?['start'] as int?,
      end: args?['end'] as int?,
      index: args?['index'] as int?,
      chapter: chapter,
      newText: newText,
    );
  }

  /// While streaming, the args JSON is incomplete. `new_text` is usually the
  /// last field, so a common partial shape is `{"start":12,"end":13,"new_text":"...`.
  /// Pull out everything after the `"new_text":"` opener (best-effort; the
  /// closing quote may be missing), then unescape the JSON string escapes
  /// (e.g. `\n` → newline, `\"` → `"`) so the prose renders with real line
  /// breaks instead of literal backslash-n.
  static String _extractPartialNewText(String raw) {
    final markers = ['"new_text":"', '"new_text": "'];
    String? tail;
    for (final m in markers) {
      final i = raw.indexOf(m);
      if (i >= 0) {
        tail = raw.substring(i + m.length);
        break;
      }
    }
    if (tail == null) return '';
    // Drop a trailing closing quote if the value happened to finish streaming.
    if (tail.endsWith('"')) tail = tail.substring(0, tail.length - 1);
    return _unescapeJsonString(tail);
  }

  /// Best-effort JSON string-escape reversal. We can't `jsonDecode` a partial
  /// value, so handle the common escapes manually. Any unknown escape is left
  /// untouched.
  static String _unescapeJsonString(String s) {
    if (!s.contains('\\')) return s;
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      final c = s[i];
      if (c != '\\') {
        buf.write(c);
        continue;
      }
      final next = ++i < s.length ? s[i] : '';
      switch (next) {
        case 'n':
          buf.write('\n');
          break;
        case 't':
          buf.write('\t');
          break;
        case 'r':
          buf.write('\r');
          break;
        case '"':
          buf.write('"');
          break;
        case '\\':
          buf.write('\\');
          break;
        case '/':
          buf.write('/');
          break;
        case 'b':
          buf.write('\b');
          break;
        case 'f':
          buf.write('\f');
          break;
        case 'u':
          if (i + 4 < s.length) {
            final hex = s.substring(i + 1, i + 5);
            final code = int.tryParse(hex, radix: 16);
            if (code != null) {
              buf.write(String.fromCharCode(code));
              i += 4;
              break;
            }
          }
          buf.write('\\u');
          break;
        default:
          buf.write('\\');
          buf.write(next);
      }
    }
    return buf.toString();
  }
}

/// Renders the parsed edit/insert/delete spec as readable text: a small meta
/// line (start..end / index) followed by the new_text prose, with explicit
/// line breaks preserved (a single `\n` renders as a line break, not folded
/// into a space), plus the result JSON if present.
class _TextToolBody extends StatelessWidget {
  final _TextToolSpec spec;
  final ColorScheme scheme;
  const _TextToolBody({required this.spec, required this.scheme});

  @override
  Widget build(BuildContext context) {
    final meta = <String>[];
    if (spec.toolName == 'edit_range' && spec.start != null) {
      meta.add('替换 第 ${spec.start}-${spec.end ?? spec.start} 段');
    } else if (spec.toolName == 'insert_at' && spec.index != null) {
      meta.add('插入位置 第 ${spec.index} 段前');
    } else if (spec.toolName == 'delete_range' && spec.start != null) {
      meta.add('删除 第 ${spec.start}-${spec.end ?? spec.start} 段');
    }
    if (spec.chapter != null) meta.add('章节 ${spec.chapter}');

    final proseStyle =
        TextStyle(fontSize: 12, height: 1.5, color: scheme.onSurface);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (meta.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(meta.join('  ·  '),
                  style: TextStyle(
                      fontSize: 10,
                      color: scheme.onTertiaryContainer,
                      fontFamily: 'monospace')),
            ),
          // Plain Text renders `\n` as real line breaks; spec.newText is
          // already JSON-unescaped so escapes became control characters.
          Text(
            spec.newText.isEmpty ? '（无内容）' : spec.newText,
            style: proseStyle,
          ),
        ],
      ),
    );
  }
}

class _Labeled extends StatelessWidget {
  final String label;
  final String body;
  final ColorScheme scheme;
  const _Labeled(this.label, this.body, this.scheme);
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(fontSize: 10, color: scheme.onTertiaryContainer)),
        const SizedBox(height: 2),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius: BorderRadius.circular(4),
          ),
          child: SelectableText(
            body,
            style: TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: scheme.onSurface),
          ),
        ),
      ],
    );
  }
}

/// Collapsible CoT block, collapsed by default.
class _CollapsibleCot extends StatefulWidget {
  final String content;
  final bool expanded;
  final VoidCallback onToggle;
  final Color color;
  const _CollapsibleCot(
      {required this.content,
      required this.expanded,
      required this.onToggle,
      required this.color});

  @override
  State<_CollapsibleCot> createState() => _CollapsibleCotState();
}

class _CollapsibleCotState extends State<_CollapsibleCot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 180));
    // Sync the initial value to the expanded flag so a CoT that mounts already
    // expanded (e.g. streaming) is visible from the first frame — otherwise it
    // starts at height 0 and only the didUpdateWidget path would forward it,
    // which never fires on first mount.
    _ctrl.value = widget.expanded ? 1.0 : 0.0;
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeInOutCubic);
  }

  @override
  void didUpdateWidget(covariant _CollapsibleCot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.expanded != oldWidget.expanded) {
      widget.expanded ? _ctrl.forward() : _ctrl.reverse();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: widget.onToggle,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(widget.expanded ? Icons.expand_less : Icons.expand_more,
                    size: 14, color: widget.color.withValues(alpha: 0.7)),
                const SizedBox(width: 2),
                Text('思考过程',
                    style: TextStyle(
                        fontSize: 11,
                        color: widget.color.withValues(alpha: 0.7),
                        fontWeight: FontWeight.w500)),
              ],
            ),
          ),
          SizeTransition(
            sizeFactor: _anim,
            axisAlignment: 1.0,
            child: Padding(
              padding: const EdgeInsets.only(top: 4, left: 4),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  border: Border(
                      left: BorderSide(
                          width: 2,
                          color: widget.color.withValues(alpha: 0.3))),
                ),
                child: SelectableText(
                  widget.content,
                  style: TextStyle(
                      fontSize: 12,
                      color: widget.color.withValues(alpha: 0.8),
                      height: 1.4),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// User message rendered as rich text: inline ref tokens become badges.
class _RichUserContent extends StatelessWidget {
  final String content;
  final Color fgColor;
  const _RichUserContent({required this.content, required this.fgColor});

  @override
  Widget build(BuildContext context) {
    final pieces = parseRich(content);
    final spans = <InlineSpan>[];
    for (final p in pieces) {
      if (p is TextPiece) {
        spans.add(TextSpan(text: p.text));
      } else if (p is TokenPiece) {
        spans.add(WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: RefBadge(token: p.token),
        ));
      }
    }
    return RichText(
      text: TextSpan(
        style: TextStyle(color: fgColor, height: 1.4, fontSize: 14),
        children: spans.isEmpty ? [TextSpan(text: content)] : spans,
      ),
    );
  }
}

/// Assistant content rendered as streaming Markdown on top of [gpt_markdown].
///
/// `gpt_markdown` is a whole-string parser — it exposes no incremental API,
/// so feeding it the full accumulated text on every token delta would
/// re-parse the *entire* document each tick and reflow everything (the
/// classic streaming flicker). To avoid that we split the accumulated text
/// into two parts:
///
///  * **frozen blocks** — complete Markdown blocks (paragraphs, list items,
///    closed code fences, …) separated by blank lines. Each is handed to its
///    own [GptMarkdown] with a content-derived [ValueKey]. Once a block's
///    text stops changing its key is stable, so `gpt_markdown`'s internal
///    `MdWidget.didUpdateWidget` short-circuits (it only regenerates spans
///    when `exp` changes) and the block never re-parses or reflows again.
///
///  * **the tail** — the single still-growing block at the end. This is the
///    only widget that re-parses per delta, and because it's small (one
///    paragraph / list item / open fence) its reflow is confined to the
///    bottom and visually imperceptible.
///
/// Both states render as plain `Text.rich` (no selection) — there is no
/// streaming-vs-settled remount; the widget stays mounted across the
/// transition. Copying full content still works via the 「复制」 action chip.
///
/// Token deltas arrive many times per frame; we coalesce them via a short
/// throttle while streaming so we don't split+set state per token. When
/// settled (turn ended) updates flush immediately.
///
/// Code blocks get a dark, readable background regardless of the bubble
/// color via the custom [codeBuilder].
class _MarkdownContent extends StatefulWidget {
  final String data;
  final Color fgColor;
  final ThemeData theme;
  final bool streaming;
  const _MarkdownContent({
    super.key,
    required this.data,
    required this.fgColor,
    required this.theme,
    this.streaming = false,
  });

  @override
  State<_MarkdownContent> createState() => _MarkdownContentState();
}

class _MarkdownContentState extends State<_MarkdownContent> {
  // Frozen complete blocks (each rendered by its own stable-keyed
  // GptMarkdown) + the single still-growing tail block.
  List<String> _frozen = const [];
  String _tail = '';

  // The text the current split is based on. If a new `data` doesn't extend
  // this (it shrank / was edited / regenerated) we reset and re-split from
  // scratch.
  String _applied = '';

  // Coalesce rapid token deltas: re-split at most once per interval while
  // streaming. The last delta in a window wins; settling flushes immediately.
  Timer? _pumpTimer;
  bool _pumpScheduled = false;
  static const _pumpInterval = Duration(milliseconds: 30);

  // Cached text style + gpt theme. Rebuilding these objects every frame
  // would change their identity and force every dependent widget to
  // rebuild/re-parse on each delta — the main source of per-delta lag.
  TextStyle? _style;
  GptMarkdownThemeData? _gptTheme;
  Color? _styleFg;
  Brightness? _styleBrightness;
  CodeBlockBuilder? _codeBuilder;

  void _resolveStyle() {
    final fg = widget.fgColor;
    final brightness = widget.theme.brightness;
    if (_style != null &&
        _styleFg == fg &&
        _styleBrightness == brightness &&
        _codeBuilder != null) {
      return;
    }
    _style = TextStyle(color: fg, height: 1.5, fontSize: 14);
    final codeBg = brightness == Brightness.dark
        ? Colors.black.withValues(alpha: 0.35)
        : Colors.black.withValues(alpha: 0.06);
    final codeFg = brightness == Brightness.dark
        ? Colors.green.shade200
        : const Color(0xFF8E2DE2);
    _codeBuilder = (context, name, code, closed) => _CodeBlock(
          name: name,
          code: code,
          codeBg: codeBg,
          codeFg: codeFg,
        );
    _gptTheme = GptMarkdownThemeData(
      brightness: brightness,
      linkColor: widget.theme.colorScheme.primary,
      linkHoverColor: widget.theme.colorScheme.primary,
      hrLineColor: fg.withValues(alpha: 0.3),
      highlightColor: fg.withValues(alpha: 0.06),
      // Don't auto-insert a divider line after `#` headings — it reads as
      // noise inside a chat bubble.
      autoAddDividerLineAfterH1: false,
    );
    _styleFg = fg;
    _styleBrightness = brightness;
  }

  @override
  void initState() {
    super.initState();
    _rebuild(widget.data);
  }

  @override
  void didUpdateWidget(covariant _MarkdownContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.data == oldWidget.data &&
        widget.fgColor == oldWidget.fgColor &&
        widget.theme.brightness == oldWidget.theme.brightness) {
      return;
    }
    if (widget.data == oldWidget.data) {
      // Only style/theme changed → just rebuild, no re-split needed.
      return;
    }
    // Streaming: throttle so we don't split+set state per token. Settled
    // (turn ended) updates flush immediately.
    if (widget.streaming) {
      _schedulePump();
    } else {
      _rebuild(widget.data);
    }
  }

  void _schedulePump() {
    if (_pumpScheduled) return;
    _pumpScheduled = true;
    _pumpTimer = Timer(_pumpInterval, () {
      _pumpScheduled = false;
      if (!mounted) return;
      _rebuild(widget.data);
    });
  }

  void _rebuild(String data) {
    // If the new text doesn't extend what we already split (it shrank, was
    // edited, or the message was regenerated) reset and re-split from zero.
    if (!data.startsWith(_applied)) {
      _applied = '';
    }
    final (frozen, tail) = _splitBlocks(data);
    _applied = data;
    if (!mounted) return;
    setState(() {
      _frozen = frozen;
      _tail = tail;
    });
  }

  /// Split accumulated Markdown into complete blocks + a single growing tail.
  ///
  /// A "block" is text up to and including a blank line. Closed fenced code
  /// blocks are frozen immediately even without a trailing blank line (the
  /// closing ``` terminates the block). Everything after the last split point
  /// is the tail — the only part that re-parses per delta.
  static (List<String>, String) _splitBlocks(String data) {
    final normalized = data.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final lines = normalized.split('\n');
    final complete = <String>[];
    final buffer = <String>[];
    var inFence = false;
    for (final line in lines) {
      final isFence = RegExp(r'^\s*```').hasMatch(line);
      buffer.add(line);
      if (isFence) {
        inFence = !inFence;
        // Closing fence: the code block is complete even without a
        // trailing blank line — freeze it now.
        if (!inFence) {
          complete.add(buffer.join('\n'));
          buffer.clear();
        }
        continue;
      }
      // A blank line outside a fence ends the current block.
      if (!inFence && line.trim().isEmpty) {
        if (buffer.isNotEmpty) {
          complete.add(buffer.join('\n'));
          buffer.clear();
        }
      }
    }
    final tail = buffer.join('\n');
    // Drop a trailing-only tail (no content left to grow) so settled text
    // doesn't keep an empty re-parsing widget mounted.
    if (tail.trim().isEmpty && complete.isNotEmpty) {
      return (complete, '');
    }
    return (complete, tail);
  }

  @override
  void dispose() {
    _pumpTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _resolveStyle();
    final style = _style!;
    final gptTheme = _gptTheme!;
    final codeBuilder = _codeBuilder!;
    final children = <Widget>[];
    for (var i = 0; i < _frozen.length; i++) {
      final b = _frozen[i];
      if (b.trim().isEmpty) continue;
      if (children.isNotEmpty) children.add(const SizedBox(height: 8));
      children.add(GptMarkdown(
        b,
        key: ValueKey('blk_$i·${b.hashCode}'),
        style: style,
        codeBuilder: codeBuilder,
      ));
    }
    if (_tail.trim().isNotEmpty) {
      if (children.isNotEmpty) children.add(const SizedBox(height: 8));
      children.add(GptMarkdown(
        _tail,
        key: const ValueKey('tail'),
        style: style,
        codeBuilder: codeBuilder,
      ));
    }
    // RepaintBoundary isolates the streaming markdown's per-frame repaints
    // from the rest of the message list.
    return RepaintBoundary(
      child: GptMarkdownTheme(
        gptThemeData: gptTheme,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: children,
        ),
      ),
    );
  }
}

/// A dark code block with a copy button, matching the old renderer's look
/// regardless of the surrounding bubble color. Used as `codeBuilder` for
/// [GptMarkdown].
class _CodeBlock extends StatefulWidget {
  final String name;
  final String code;
  final Color codeBg;
  final Color codeFg;
  const _CodeBlock({
    required this.name,
    required this.code,
    required this.codeBg,
    required this.codeFg,
  });

  @override
  State<_CodeBlock> createState() => _CodeBlockState();
}

class _CodeBlockState extends State<_CodeBlock> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: widget.codeBg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.name.isNotEmpty)
            Padding(
              padding:
                  const EdgeInsets.only(left: 12, right: 4, top: 4),
              child: Row(
                children: [
                  Text(
                    widget.name,
                    style: TextStyle(
                      color: widget.codeFg.withValues(alpha: 0.6),
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                  const Spacer(),
                  _copyButton(),
                ],
              ),
            )
          else
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(top: 2, right: 2),
                child: _copyButton(),
              ),
            ),
          const SizedBox(height: 2),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: SelectableText(
              widget.code,
              style: TextStyle(
                color: widget.codeFg,
                fontFamily: 'monospace',
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _copyButton() {
    return IconButton(
      icon: Icon(
        _copied ? Icons.check : Icons.copy_outlined,
        size: 16,
        color: widget.codeFg.withValues(alpha: 0.7),
      ),
      tooltip: '复制代码',
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
      padding: EdgeInsets.zero,
      onPressed: () async {
        await Clipboard.setData(ClipboardData(text: widget.code));
        if (!mounted) return;
        setState(() => _copied = true);
        await Future.delayed(const Duration(seconds: 2));
        if (!mounted) return;
        setState(() => _copied = false);
      },
    );
  }
}

/// Three bouncing dots indicating streaming activity.
class _TypingDots extends StatefulWidget {
  const _TypingDots();
  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with TickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _a;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1100))
      ..repeat();
    _a = CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return AnimatedBuilder(
      animation: _a,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            final t = (_a.value * 3 - i).clamp(0.0, 1.0);
            final scale = 0.5 + 0.5 * (1 - (2 * t - 1).abs());
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1.5),
              child: Transform.scale(
                scale: scale,
                child: Container(
                  width: 5,
                  height: 5,
                  decoration:
                      BoxDecoration(color: color, shape: BoxShape.circle),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}

