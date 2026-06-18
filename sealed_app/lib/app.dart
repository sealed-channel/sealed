import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:sealed_app/ui/navigation/navigator_key.dart';
import 'package:sealed_app/ui/navigation/screens/app_shell.dart';
import 'package:sealed_app/ui/navigation/widgets/session_lock_gate.dart';
import 'package:sealed_app/ui/onboarding/screens/how_it_works.dart';
import 'package:sealed_app/ui/shared/theme.dart';

class SealedApp extends StatelessWidget {
  const SealedApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ScreenUtilInit(
      // Figma reference frame — iPhone 14 logical size.
      designSize: const Size(360, 752),
      minTextAdapt: true,
      builder: (context, child) {
        return MaterialApp(
          title: 'Sealed',

          navigatorKey: navigatorKey,
          theme: sealedTheme,
          home: child,
          // Lock layer above the root Navigator so it covers pushed routes,
          // dialogs and sheets — not just the home route. See SessionLockGate.
          builder: (context, navigator) =>
              SessionLockGate(child: navigator ?? const SizedBox.shrink()),
        );
      },
      child: AppShell(),
    );
  }
}
