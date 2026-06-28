/// Conversation / message models shared by the agent layer and UI.
library;

import 'package:uuid/uuid.dart';

const _uuid = Uuid();

enum MessageRole { system, user, assistant, tool }

String roleToString(MessageRole r) => r.name;
MessageRole roleFromString(String s) =>
    MessageRole.values.firstWhere((e) => e.name == s,
        orElse: () => MessageRole.user);

/// A single function/tool call issued by the assistant.
class ToolCall {
  /// Stable id referenced by the tool-result message (`tool_call_id`).
  final String id;
  final String name;
  final String arguments; // raw JSON string of args

  ToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });

  ToolCall copy() => ToolCall(id: id, name: name, arguments: arguments);

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'arguments': arguments};

  factory ToolCall.fromJson(Map<String, dynamic> json) => ToolCall(
        id: json['id'] as String,
        name: json['name'] as String,
        arguments: (json['arguments'] as String?) ?? '{}',
      );

  static ToolCall create({required String name, required String arguments}) =>
      ToolCall(id: 'call_${_uuid.v4()}', name: name, arguments: arguments);
}

/// A message in the conversation. Held in memory + persisted by repo.
class Message {
  final String id;
  final MessageRole role;
  String content;

  /// DeepSeek reasoning (CoT) text, if any.
  String reasoningContent;

  /// Tool calls emitted by an assistant message.
  List<ToolCall> toolCalls;

  /// For role==tool: which ToolCall this answers.
  final String? toolCallId;

  /// For role==tool: the tool name (optional, for display).
  final String? toolName;

  /// True if this assistant message is a DeepSeek prefix-continuation seed.
  final bool prefix;

  /// Group key: all messages produced in one agent turn (one user prompt →
  /// assistant rounds + tool calls + tool results) share this id, so the UI
  /// can render them as one cluster with shared action buttons. A user
  /// message's turnId is its own id.
  final String turnId;

  /// Wall-clock ordering (seconds since epoch). Set by caller to avoid
  /// depending on dart:io clocks inside pure models.
  final int createdAt;

  Message({
    required this.id,
    required this.role,
    this.content = '',
    this.reasoningContent = '',
    List<ToolCall>? toolCalls,
    this.toolCallId,
    this.toolName,
    this.prefix = false,
    required this.turnId,
    required this.createdAt,
  }) : toolCalls = toolCalls ?? [];

  Message copy() => Message(
        id: id,
        role: role,
        content: content,
        reasoningContent: reasoningContent,
        toolCalls: toolCalls.map((e) => e.copy()).toList(),
        toolCallId: toolCallId,
        toolName: toolName,
        prefix: prefix,
        turnId: turnId,
        createdAt: createdAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'role': role.name,
        'content': content,
        'reasoningContent': reasoningContent,
        'toolCalls': toolCalls.map((e) => e.toJson()).toList(),
        'toolCallId': toolCallId,
        'toolName': toolName,
        'prefix': prefix,
        'turnId': turnId,
        'createdAt': createdAt,
      };

  factory Message.fromJson(Map<String, dynamic> json) => Message(
        id: json['id'] as String,
        role: roleFromString(json['role'] as String),
        content: (json['content'] as String?) ?? '',
        reasoningContent: (json['reasoningContent'] as String?) ?? '',
        toolCalls: ((json['toolCalls'] as List?) ?? [])
            .map((e) => ToolCall.fromJson(e as Map<String, dynamic>))
            .toList(),
        toolCallId: json['toolCallId'] as String?,
        toolName: json['toolName'] as String?,
        prefix: (json['prefix'] as bool?) ?? false,
        turnId: (json['turnId'] as String?) ?? json['id'] as String,
        createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
      );

  static Message user(
    String text, {
    int? createdAt,
    String? turnId,
  }) {
    final id = _uuid.v4();
    return Message(
        id: id,
        role: MessageRole.user,
        content: text,
        turnId: turnId ?? id,
        createdAt: createdAt ?? 0);
  }
}

/// A conversation = ordered list of messages (system prompt excluded).
class Conversation {
  final String id;
  final String novelId;
  final String chapterId;
  List<Message> messages;

  Conversation({
    required this.id,
    required this.novelId,
    required this.chapterId,
    List<Message>? messages,
  }) : messages = messages ?? [];

  Map<String, dynamic> toJson() => {
        'id': id,
        'novelId': novelId,
        'chapterId': chapterId,
        'messages': messages.map((e) => e.toJson()).toList(),
      };

  factory Conversation.fromJson(Map<String, dynamic> json) => Conversation(
        id: json['id'] as String,
        novelId: json['novelId'] as String,
        chapterId: json['chapterId'] as String,
        messages: ((json['messages'] as List?) ?? [])
            .map((e) => Message.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  static Conversation create({required String novelId, required String chapterId}) =>
      Conversation(id: _uuid.v4(), novelId: novelId, chapterId: chapterId);
}
