import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/infra/local/repositories/contact_repository.dart'
    show PendingInvite;
import 'package:sealed_app/providers/message_provider.dart'
    show visibleIncomingInvites;

void main() {
  PendingInvite invite(
    String ref, {
    required bool isCreator,
    bool dismissed = false,
  }) =>
      PendingInvite(
        inviteRef: ref,
        aliasDisplay: 'x',
        isCreator: isCreator,
        status: 'pending',
        createdAt: 0,
        inviteDismissed: dismissed,
      );

  test('keeps only incoming, non-dismissed invites', () {
    final out = visibleIncomingInvites([
      invite('a', isCreator: false),
      invite('b', isCreator: true), // creator-side → excluded
      invite('c', isCreator: false, dismissed: true), // declined → excluded
      invite('d', isCreator: false),
    ]);
    expect(out.map((e) => e.inviteRef), ['a', 'd']);
  });

  test('empty in → empty out', () {
    expect(visibleIncomingInvites([]), isEmpty);
  });
}
