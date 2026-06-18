/// Addressing model for opening a chat detail screen by wallet (legacy
/// wallet-addressed flow). The preview/list-row model lives in
/// `chat_preview.dart`.
library;

class Conversation {
  final String contactWallet;
  final String? contactUsername;

  Conversation({required this.contactWallet, this.contactUsername});
}
