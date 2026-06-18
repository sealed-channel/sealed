// Widget tests for RedeemCodeDialog.
//
// The redeem orchestration state-machine has its own tests
// (test/providers/redeem_provider_test.dart) — here we fake `redeemProvider`
// and assert the dialog's UI contract:
//   • format gating (submit is a no-op until the code normalizes),
//   • success → dialog closes, PinDialog.success with redeem copy shows,
//   • error → PinDialog.warning with the mapped message, dialog stays open.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/core/errors.dart';
import 'package:sealed_app/providers/redeem_provider.dart';
import 'package:sealed_app/providers/wallet_provider.dart';
import 'package:sealed_app/ui/settings/widgets/redeem_code.dart';

class _FakeRedeemNotifier extends RedeemNotifier {
  _FakeRedeemNotifier(this.result);

  /// Terminal state to settle into when redeem() is called.
  final RedeemState result;

  String? lastCode;

  @override
  RedeemState build() => const RedeemState();

  @override
  Future<void> redeem(String code) async {
    lastCode = code;
    state = result;
  }

  @override
  void cancel() {}
}

class _FakeWalletNotifier extends WalletNotifier {
  @override
  Future<WalletState> build() async {
    return WalletState(phase: OnboardingPhase.ready, walletAddress: 'A' * 58);
  }

  @override
  Future<void> refreshBalance() async {
    // no-op in tests
  }
}

const _validCode = '0123456789ABCDEF';

Future<void> _pumpHarness(
  WidgetTester tester,
  _FakeRedeemNotifier redeem,
) async {
  tester.view.physicalSize = const Size(360, 752);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        redeemProvider.overrideWith(() => redeem),
        walletProvider.overrideWith(_FakeWalletNotifier.new),
      ],
      child: ScreenUtilInit(
        designSize: const Size(360, 752),
        builder: (context, _) => MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () => RedeemCodeDialog.show(ctx),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Future<void> _enterAndSubmit(WidgetTester tester, String code) async {
  await tester.enterText(find.byKey(const Key('redeem_code_input')), code);
  await tester.pump();
  await tester.tap(find.byKey(const Key('redeem_code_submit')));
  await tester.pumpAndSettle();
}

void main() {
  group('RedeemCodeDialog', () {
    testWidgets('valid code → redeem called, dialog closes, success dialog '
        'with redeem copy', (tester) async {
      final redeem = _FakeRedeemNotifier(
        const RedeemState(phase: RedeemPhase.done, lastTxId: 'TX'),
      );
      await _pumpHarness(tester, redeem);
      await _enterAndSubmit(tester, _validCode);

      expect(redeem.lastCode, _validCode);
      // Redeem dialog closed, PinDialog.success up with redeem copy.
      expect(find.byKey(const Key('redeem_code_input')), findsNothing);
      expect(find.text('Code redeemed successfully'), findsOneWidget);
      expect(find.text('All set'), findsOneWidget);
      expect(
        find.text('Credits have been added to your balance'),
        findsOneWidget,
      );

      // Continue dismisses the success dialog.
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Code redeemed successfully'), findsNothing);
    });

    testWidgets('short code: submit is a no-op', (tester) async {
      final redeem = _FakeRedeemNotifier(
        const RedeemState(phase: RedeemPhase.done),
      );
      await _pumpHarness(tester, redeem);
      await _enterAndSubmit(tester, 'AB');

      expect(redeem.lastCode, isNull);
      expect(find.byKey(const Key('redeem_code_input')), findsOneWidget);
    });

    testWidgets('error → PinDialog.warning with mapped message, redeem dialog '
        'stays open', (tester) async {
      final redeem = _FakeRedeemNotifier(
        const RedeemState(
          phase: RedeemPhase.error,
          lastError: 'raw',
          lastException: BadRedeemCodeError('bad code'),
        ),
      );
      await _pumpHarness(tester, redeem);
      await _enterAndSubmit(tester, _validCode);

      expect(find.text('Redeem failed'), findsOneWidget);
      expect(find.text('bad code'), findsOneWidget);

      // Dismiss the warning — the redeem dialog is still open for retry.
      await tester.tap(find.text('I understand'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('redeem_code_input')), findsOneWidget);
    });
  });
}
