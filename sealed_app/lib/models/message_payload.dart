// MessagePayload Model
class MessagePayload {
  final String senderWallet;
  final String senderUsername;
  final String content;
  final int timestamp;

  MessagePayload({
    required this.senderWallet,
    required this.senderUsername,
    required this.content,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
    'senderWallet': senderWallet,
    'senderUsername': senderUsername,
    'content': content,
    'timestamp': timestamp,
  };

  factory MessagePayload.fromJson(Map<String, dynamic> json) {
    return MessagePayload(
      senderWallet: json['senderWallet'] as String,
      senderUsername: json['senderUsername'] as String,
      content: json['content'] as String,
      timestamp: json['timestamp'] as int,
    );
  }
}
