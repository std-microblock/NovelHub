import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../../../domain/conversation.dart';
import '../../../domain/rich_text.dart';
import 'ref_badge.dart';

/// One message row.
///  - Assistant content rendered as Markdown.
///  - CoT (reasoning_content) is collapsible, collapsed by default.
///  - Tool calls are collapsible, collapsed by default, expandable to show
///    arguments + result.
/// Per-message edit/retry/copy actions live on the turn cluster's action bar
/// (rendered in agent_pane), NOT here.
class MessageTile extends StatefulWidget {
  final Message message;
  final bool streaming;
  const MessageTile({
    super.key,
    required this.message,
    this.streaming = false,
  });

  @override
  State<MessageTile> createState() => _MessageTileState();
}

class _MessageTileState extends State<MessageTile> {
  bool _cotExpanded = false;
  final Map<String, bool> _toolExpanded = {}; // toolCallId -> expanded

  @override
  Widget build(BuildContext context) {
    final m = widget.message;
    final isUser = m.role == MessageRole.user;
    final isAssistant = m.role == MessageRole.assistant;
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

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
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
                  onToggle: () =>
                      setState(() => _cotExpanded = !_cotExpanded),
                  color: fgColor,
                ),
              if (m.content.isNotEmpty || !widget.streaming)
                isUser
                    ? _RichUserContent(content: m.content, fgColor: fgColor)
                    : _MarkdownContent(
                        data: m.content,
                        fgColor: fgColor,
                        theme: Theme.of(context),
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
        ),
      ),
    );
  }
}
/// A merged tool-call + result block: collapsed by default, animated expand.
/// Shows the tool name + status; expands to reveal the call arguments JSON and
/// the tool result JSON together. Max width constrained like the bubbles.
class ToolCallBlock extends StatefulWidget {
  final ToolCall call;
  final String? resultContent; // null = still running / no result yet
  const ToolCallBlock({super.key, required this.call, this.resultContent});

  @override
  State<ToolCallBlock> createState() => _ToolCallBlockState();
}

class _ToolCallBlockState extends State<ToolCallBlock>
    with SingleTickerProviderStateMixin {
  bool _expanded = false;
  late final AnimationController _ctrl;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 180));
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeInOutCubic);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _toggle() {
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
                  Icon(Icons.build, size: 13, color: scheme.onTertiaryContainer),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '调用工具 · ${widget.call.name}',
                      style: TextStyle(
                          fontSize: 12,
                          color: scheme.onTertiaryContainer),
                    ),
                  ),
                  if (hasResult)
                    Icon(Icons.check_circle, size: 13, color: scheme.primary)
                  else
                    SizedBox(
                      width: 13,
                      height: 13,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: scheme.onTertiaryContainer,
                      ),
                    ),
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
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Labeled('参数', widget.call.arguments, scheme),
                  if (hasResult) ...[
                    const SizedBox(height: 4),
                    _Labeled('结果', widget.resultContent!, scheme),
                  ],
                ],
              ),
            ),
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

/// Assistant content rendered as Markdown. Code blocks get a dark,
/// readable background regardless of the bubble color (avoids the
/// light-blue-bg / light-pink-text clash from the default theme).
class _MarkdownContent extends StatelessWidget {
  final String data;
  final Color fgColor;
  final ThemeData theme;
  const _MarkdownContent({
    required this.data,
    required this.fgColor,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    final codeBg = theme.brightness == Brightness.dark
        ? Colors.black.withValues(alpha: 0.35)
        : Colors.black.withValues(alpha: 0.06);
    final codeFg = theme.brightness == Brightness.dark
        ? Colors.green.shade200
        : const Color(0xFF8E2DE2);
    final codeStyle = TextStyle(
      backgroundColor: codeBg,
      color: codeFg,
      fontFamily: 'monospace',
      fontSize: 13,
      height: 1.4,
    );
    final style = MarkdownStyleSheet.fromTheme(theme).copyWith(
      p: TextStyle(color: fgColor, height: 1.5, fontSize: 14),
      code: codeStyle,
      codeblockDecoration: BoxDecoration(
        color: codeBg,
        borderRadius: BorderRadius.circular(6),
      ),
      blockquoteDecoration: BoxDecoration(
        color: fgColor.withValues(alpha: 0.06),
        border: Border(
            left: BorderSide(color: fgColor.withValues(alpha: 0.3), width: 2)),
      ),
      a: TextStyle(color: theme.colorScheme.primary),
    );
    return MarkdownBody(
      data: data,
      selectable: true,
      styleSheet: style,
    );
  }
}

/// A small "copy" button shown beneath assistant markdown content.
class _CopyButton extends StatefulWidget {
  final String text;
  const _CopyButton({required this.text});

  @override
  State<_CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<_CopyButton> {
  bool _copied = false;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: widget.text));
        setState(() => _copied = true);
        Future.delayed(const Duration(seconds: 2),
            () => mounted ? setState(() => _copied = false) : null);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_copied ? Icons.check : Icons.copy, size: 13,
                color: scheme.onSurfaceVariant),
            const SizedBox(width: 3),
            Text(_copied ? '已复制' : '复制',
                style: TextStyle(
                    fontSize: 11, color: scheme.onSurfaceVariant)),
          ],
        ),
      ),
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

