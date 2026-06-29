import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/conversation.dart';
import '../../../state/providers.dart' show editorStateProvider;

/// Parsed view of an `ask_user` tool-call's arguments.
class AskUserSpec {
  final String question;
  final String? header;
  final List<String> options;
  final bool multiSelect;
  final bool allowOther;

  AskUserSpec({
    required this.question,
    this.header,
    required this.options,
    required this.multiSelect,
    required this.allowOther,
  });

  /// Fill-in mode: no options given.
  bool get isFillIn => options.isEmpty;

  static AskUserSpec? tryParse(ToolCall call) {
    if (call.name != 'ask_user') return null;
    Map<String, dynamic>? args;
    try {
      if (call.arguments.trim().isNotEmpty) {
        args = (jsonDecode(call.arguments) as Map).cast<String, dynamic>();
      }
    } catch (_) {
      args = null;
    }
    final question = (args?['question'] as String?) ?? '';
    if (question.isEmpty && call.arguments.trim().isEmpty) return null;
    final options = ((args?['options'] as List?) ?? [])
        .map((e) => e.toString())
        .toList(growable: false);
    return AskUserSpec(
      question: question.isEmpty ? '（问题加载中…）' : question,
      header: args?['header'] as String?,
      options: options,
      multiSelect: (args?['multi_select'] as bool?) ?? false,
      allowOther: (args?['allow_other'] as bool?) ?? false,
    );
  }
}

/// The interactive card shown when an `ask_user` tool call is awaiting the
/// user. Renders one of three modes driven by [AskUserSpec]:
///   - fill-in (no options) → a TextField;
///   - single-select → radio list;
///   - multi-select → checkbox list.
/// When [allowOther] is set, an extra "其他" row with a TextField is appended.
/// On submit/skip it calls back into [EditorStateNotifier].
class AskUserCard extends ConsumerStatefulWidget {
  final ToolCall call;
  final AskUserSpec spec;

  const AskUserCard({
    super.key,
    required this.call,
    required this.spec,
  });

  @override
  ConsumerState<AskUserCard> createState() => _AskUserCardState();
}

class _AskUserCardState extends ConsumerState<AskUserCard> {
  final _fillInCtrl = TextEditingController();
  final _otherCtrl = TextEditingController();
  String? _single; // selected option index (string key) for single-select
  final Set<String> _multi = {}; // selected option labels for multi-select
  bool _otherChosen = false; // "其他" row active (multi or allow_other)

  @override
  void dispose() {
    _fillInCtrl.dispose();
    _otherCtrl.dispose();
    super.dispose();
  }

  bool get _canSubmit {
    if (widget.spec.isFillIn) return _fillInCtrl.text.trim().isNotEmpty;
    if (widget.spec.multiSelect) {
      return _multi.isNotEmpty || (_otherChosen && _otherCtrl.text.trim().isNotEmpty);
    }
    return _single != null || (_otherChosen && _otherCtrl.text.trim().isNotEmpty);
  }

  void _submit() {
    final notifier = ref.read(editorStateProvider.notifier);
    final spec = widget.spec;
    Object answer;
    if (spec.isFillIn) {
      answer = _fillInCtrl.text.trim();
    } else if (spec.multiSelect) {
      final list = <String>[..._multi];
      if (spec.allowOther && _otherChosen && _otherCtrl.text.trim().isNotEmpty) {
        list.add(_otherCtrl.text.trim());
      }
      answer = list;
    } else {
      // single-select
      if (spec.allowOther && _otherChosen && _otherCtrl.text.trim().isNotEmpty) {
        answer = _otherCtrl.text.trim();
      } else {
        answer = _single ?? '';
      }
    }
    notifier.answerAskUser(widget.call.id, answer);
  }

  void _skip() {
    ref.read(editorStateProvider.notifier).skipAskUser(widget.call.id);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final spec = widget.spec;
    return Container(
      constraints: const BoxConstraints(maxWidth: 560),
      margin: const EdgeInsets.only(top: 4, bottom: 2),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (spec.header != null && spec.header!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(spec.header!,
                    style: TextStyle(
                        fontSize: 10,
                        color: scheme.primary,
                        fontWeight: FontWeight.w600)),
              ),
            ),
          Text(spec.question,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: scheme.onTertiaryContainer)),
          const SizedBox(height: 8),
          _buildBody(scheme),
          if (spec.allowOther && !spec.isFillIn) ...[
            const SizedBox(height: 4),
            _otherRow(scheme),
          ],
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _skip,
                child: const Text('跳过'),
              ),
              const SizedBox(width: 6),
              FilledButton(
                onPressed: _canSubmit ? _submit : null,
                child: const Text('提交'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBody(ColorScheme scheme) {
    final spec = widget.spec;
    if (spec.isFillIn) {
      return TextField(
        controller: _fillInCtrl,
        minLines: 1,
        maxLines: 4,
        autofocus: true,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          isDense: true,
          hintText: '输入你的回答…',
          filled: true,
          fillColor: scheme.surface,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
        ),
      );
    }
    if (spec.multiSelect) {
      return Column(
        children: [
          for (final opt in spec.options)
            _checkRow(
              scheme,
              label: opt,
              checked: _multi.contains(opt),
              onTap: () => setState(() {
                if (_multi.contains(opt)) {
                  _multi.remove(opt);
                } else {
                  _multi.add(opt);
                }
              }),
            ),
        ],
      );
    }
    // single-select
    return Column(
      children: [
        for (final opt in spec.options)
          _radioRow(
            scheme,
            label: opt,
            selected: _single == opt,
            onTap: () => setState(() {
              _single = opt;
              _otherChosen = false;
            }),
          ),
      ],
    );
  }

  Widget _checkRow(ColorScheme scheme,
      {required String label,
      required bool checked,
      required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
        child: Row(
          children: [
            Icon(
              checked ? Icons.check_box : Icons.check_box_outline_blank,
              size: 18,
              color: scheme.primary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(label,
                  style:
                      TextStyle(fontSize: 13, color: scheme.onTertiaryContainer)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _radioRow(ColorScheme scheme,
      {required String label,
      required bool selected,
      required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
        child: Row(
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              size: 18,
              color: scheme.primary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(label,
                  style:
                      TextStyle(fontSize: 13, color: scheme.onTertiaryContainer)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _otherRow(ColorScheme scheme) {
    final spec = widget.spec;
    final isMulti = spec.multiSelect;
    return InkWell(
      onTap: () => setState(() {
        if (isMulti) {
          _otherChosen = !_otherChosen;
        } else {
          _otherChosen = true;
          _single = null;
        }
      }),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
            child: Row(
              children: [
                Icon(
                  isMulti
                      ? (_otherChosen
                          ? Icons.check_box
                          : Icons.check_box_outline_blank)
                      : (_otherChosen
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off),
                  size: 18,
                  color: scheme.primary,
                ),
                const SizedBox(width: 8),
                Text('其他',
                    style: TextStyle(
                        fontSize: 13, color: scheme.onTertiaryContainer)),
              ],
            ),
          ),
          if (_otherChosen)
            Padding(
              padding: const EdgeInsets.only(left: 26, top: 2),
              child: TextField(
                controller: _otherCtrl,
                minLines: 1,
                maxLines: 3,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: '输入…',
                  filled: true,
                  fillColor: scheme.surface,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Read-only summary of an answered `ask_user` call. Renders the question +
/// the user's chosen answer (parsed from the tool-result JSON).
class AskUserAnswered extends StatelessWidget {
  final ToolCall call;
  final String resultContent;
  const AskUserAnswered({
    super.key,
    required this.call,
    required this.resultContent,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final spec = AskUserSpec.tryParse(call);
    Map<String, dynamic>? res;
    try {
      if (resultContent.trim().isNotEmpty) {
        res = (jsonDecode(resultContent) as Map).cast<String, dynamic>();
      }
    } catch (_) {
      res = null;
    }
    final answer = res?['answer'];
    final skipped = (res?['skipped'] as bool?) ?? false;
    final cancelled = (res?['cancelled'] as bool?) ?? false;

    String answerText;
    if (cancelled) {
      answerText = '已取消';
    } else if (skipped || answer == null) {
      answerText = '已跳过';
    } else if (answer is List) {
      answerText = answer.map((e) => e.toString()).join('、');
    } else {
      answerText = answer.toString();
    }

    return Container(
      constraints: const BoxConstraints(maxWidth: 560),
      margin: const EdgeInsets.only(top: 4, bottom: 2),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (spec?.header != null && spec!.header!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(spec.header!,
                  style: TextStyle(
                      fontSize: 10,
                      color: scheme.primary,
                      fontWeight: FontWeight.w600)),
            ),
          if (spec != null && spec.question.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text(spec.question,
                  style: TextStyle(
                      fontSize: 12,
                      color: scheme.onTertiaryContainer,
                      fontWeight: FontWeight.w500)),
            ),
          Row(
            children: [
              Icon(Icons.check_circle,
                  size: 13, color: scheme.primary.withValues(alpha: 0.8)),
              const SizedBox(width: 5),
              Expanded(
                child: Text(answerText,
                    style: TextStyle(
                        fontSize: 13, color: scheme.onTertiaryContainer)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
