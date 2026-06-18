import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/core/errors.dart';
import 'package:sealed_app/models/user_profile.dart';
import 'package:sealed_app/providers/user_provider.dart';
import 'package:sealed_app/ui/settings/widgets/username_change.dart';

/// Proves the credit gate on username claims: when `setUsername` throws
/// [NoCreditsError], [ChangeUsernameDialog] surfaces [CreditsRequiredDialog]
/// instead of the generic failure snackbar.

/// Drain cosmetic RenderFlex overflows (SealedDialog header in the narrow
/// test viewport) so they don't fail the test; re-raise anything else.
/// Same pattern as change_pin_flow_test.
void _drainRenderOverflow(WidgetTester tester) {
  while (true) {
    final ex = tester.takeException();
    if (ex == null) return;
    if (!ex.toString().contains('A RenderFlex overflowed')) {
      throw ex;
    }
  }
}

/// Bounded settle: the dialog's autofocused TextField blinks its caret
/// forever, so pumpAndSettle would time out. Pump a fixed number of frames
/// instead (enough for dialog/snackbar transitions).
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
  _drainRenderOverflow(tester);
}

class _FakeUserNotifier extends UserNotifier {
  _FakeUserNotifier({required this.error});

  final Object error;
  final List<String> setUsernameCalls = [];

  @override
  Future<UserState> build() async => const UserState(phase: UserPhase.ready);

  @override
  Future<UserProfile> setUsername({required String username}) async {
    setUsernameCalls.add(username);
    throw error;
  }
}

class _FakeUsernameController extends UsernameController {
  @override
  Future<UsernameCheckState> build() async => const UsernameCheckState(
    input: 'igor',
    isChecking: false,
    availabilityResult: NameAvailable(),
  );

  /// No-op: the dialog resets input post-frame; keep NameAvailable so the
  /// "Set" button stays enabled without a chain probe.
  @override
  void onInputChanged(String raw) {}
}

Future<void> _pumpDialog(WidgetTester tester, _FakeUserNotifier fake) async {
  tester.view.physicalSize = const Size(360, 752);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        userProvider.overrideWith(() => fake),
        usernameControllerProvider.overrideWith(_FakeUsernameController.new),
      ],
      child: ScreenUtilInit(
        designSize: const Size(360, 752),
        builder: (context, _) =>
            const MaterialApp(home: Scaffold(body: ChangeUsernameDialog())),
      ),
    ),
  );
  await _settle(tester);
}

void main() {
  group('ChangeUsernameDialog credit gate', () {
    testWidgets('NoCreditsError shows CreditsRequiredDialog', (tester) async {
      final fake = _FakeUserNotifier(error: const NoCreditsError());
      await _pumpDialog(tester, fake);

      await tester.tap(find.text('Set'));
      await _settle(tester);

      expect(fake.setUsernameCalls, ['igor']);
      expect(find.text('Credits Required'), findsOneWidget);
      expect(find.text('Top Up Credits'), findsOneWidget);
      // No generic failure snackbar.
      expect(find.textContaining('Failed to claim username'), findsNothing);
    });

    testWidgets('other errors keep the failure snackbar', (tester) async {
      final fake = _FakeUserNotifier(error: const NameTakenError());
      await _pumpDialog(tester, fake);

      await tester.tap(find.text('Set'));
      await _settle(tester);

      expect(find.text('Credits Required'), findsNothing);
      expect(find.textContaining('Failed to claim username'), findsOneWidget);
    });
  });
}
