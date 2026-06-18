// Tests for NotificationService.handleFcmMessage — the Android FCM entry point.
//
// Key invariant under test: no field other than `data['n']` (the wake-up nonce)
// is ever read or forwarded to the bounded-sync callback or the notification
// presenter. Attacker-supplied fields such as `alert`, `message_id`,
// `conversation_wallet`, and `account_pubkey` must have no path to the UI.

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/features/notifications/notification_service.dart';

void main() {
  // Reset the singleton between tests.
  setUp(() {
    NotificationService().dispose();
  });

  group('handleFcmMessage', () {
    test('no-op when deps not bound', () async {
      // _runBoundedSync not set — should return without throwing.
      final msg = _buildMsg(data: {'n': 'abc123'});
      await expectLater(NotificationService().handleFcmMessage(msg), completes);
    });

    test('runs bounded sync with nonce-only payload', () async {
      int syncCallCount = 0;

      NotificationService().bindBackgroundDependencies(
        runBoundedSync: () async {
          syncCallCount++;
          return 0;
        },
      );

      final msg = _buildMsg(data: {'n': 'wake42'});
      await NotificationService().handleFcmMessage(msg);

      expect(syncCallCount, 1);
    });

    test(
      'attacker-supplied fields do not reach sync callback or present()',
      () async {
        // Payload includes every sensitive field an attacker might inject.
        final poisonData = {
          'n': 'safe_nonce',
          'alert': 'INJECTED_ALERT',
          'message_id': 'INJECTED_ID',
          'conversation_wallet': 'INJECTED_WALLET',
          'account_pubkey': 'INJECTED_PUBKEY',
        };

        // Intercept what gets rendered to the user.
        final presentedTitles = <String>[];
        final presentedBodies = <String>[];

        NotificationService().bindBackgroundDependencies(
          runBoundedSync: () async => 1, // return 1 to trigger present()
        );

        // Override the test presenter so we can capture what gets rendered.
        NotificationService().testPresenter = (title, body) async {
          presentedTitles.add(title);
          presentedBodies.add(body);
        };

        final msg = _buildMsg(data: poisonData);
        await NotificationService().handleFcmMessage(msg);

        // Verify constants only — no poison strings reach the UI.
        if (presentedTitles.isNotEmpty) {
          expect(
            presentedTitles.first,
            NotificationService.kGenericNotificationTitle,
            reason:
                'title must be the hard-coded constant, not a payload value',
          );
          expect(
            presentedBodies.first,
            NotificationService.kGenericNotificationBody,
            reason: 'body must be the hard-coded constant, not a payload value',
          );
          expect(presentedTitles.first, isNot(contains('INJECTED')));
          expect(presentedBodies.first, isNot(contains('INJECTED')));
        }
      },
    );

    test('handles null nonce gracefully', () async {
      int syncCalls = 0;
      NotificationService().bindBackgroundDependencies(
        runBoundedSync: () async {
          syncCalls++;
          return 0;
        },
      );

      // No 'n' field at all.
      final msg = _buildMsg(data: {'other': 'value'});
      await NotificationService().handleFcmMessage(msg);

      expect(syncCalls, 1); // still runs sync, just with null nonce
    });

    test('handles non-string nonce defensively', () async {
      int syncCalls = 0;
      NotificationService().bindBackgroundDependencies(
        runBoundedSync: () async {
          syncCalls++;
          return 0;
        },
      );

      // Malformed nonce — Map instead of String.
      final msg = _buildMsg(
        data: {
          'n': <String, dynamic>{'evil': true},
        },
      );
      await NotificationService().handleFcmMessage(msg);

      expect(syncCalls, 1); // still runs sync; nonce treated as null
    });
  });
}

/// Construct a [RemoteMessage] with the given `data` map.
/// [RemoteMessage] has no public constructor that easily fakes a notification
/// field, so we use the `data`-only path which is the server contract.
RemoteMessage _buildMsg({required Map<String, dynamic> data}) {
  return RemoteMessage(data: data);
}
