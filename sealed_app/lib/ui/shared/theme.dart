import 'package:flutter/material.dart';
import 'package:flutter_gap/flutter_gap.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

final double horizontalPadding = 20.0;

// Dark green gradient
final LinearGradient sealedBackgroundGradient = LinearGradient(
  colors: [Color.fromARGB(255, 0, 60, 55), Color.fromARGB(255, 3, 3, 3)],
  begin: Alignment.topCenter,
  end: Alignment(0, -0.72),
);
// Primary gradient
final LinearGradient primaryGradient = LinearGradient(
  colors: [Color.fromARGB(255, 0, 137, 114), Color.fromARGB(255, 19, 45, 39)],
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
);
// primary color
final Color primaryColor = Color.fromARGB(255, 107, 250, 214);

// Messagge bubble gradient for outgoing messages
final LinearGradient outgoingMessage = LinearGradient(
  colors: [
    Color.fromARGB(255, 99, 179, 164).withValues(alpha: 0.4),
    Color.fromARGB(255, 74, 221, 194).withValues(alpha: 0.1),
  ],
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
);

// Messagge bubble gradient for incoming messages
final LinearGradient incomingMessage = LinearGradient(
  colors: [
    Color.fromARGB(255, 255, 255, 255).withValues(alpha: 0.2),
    Color.fromARGB(255, 255, 255, 255).withValues(alpha: 0.02),
  ],
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
);

// Icon Gradient
final LinearGradient iconGradient = LinearGradient(
  colors: [Color(0xFF97F5CB), Color(0xFF4DA898)],
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
);

// primary shadow
final BoxShadow primaryShadow = BoxShadow(
  color: Color(0xFF53FFE1).withOpacity(0.5),
  blurRadius: 10.sp,
  offset: Offset(0, 4.sp),
);

// card color
final Color cardColor = Color.fromARGB(255, 25, 25, 26);

final Color mutedColor = Color.fromRGBO(75, 85, 81, 1);

final Color neutralColor = Color.fromRGBO(175, 182, 175, 1);

ThemeData sealedTheme = ThemeData(
  snackBarTheme: SnackBarThemeData(
    backgroundColor: primaryColor,
    contentTextStyle: TextStyle(
      color: Colors.white.withValues(alpha: 0.9),
      fontWeight: FontWeight.w500,
    ),
  ),
  brightness: Brightness.dark,
  primaryColor: primaryColor,
  colorScheme: ColorScheme.dark(
    primary: primaryColor,
    secondary: Color(0xFF4DA898),
    surface: cardColor,
    onPrimary: Colors.white.withValues(alpha: 0.9),
    onSecondary: Colors.white.withValues(alpha: 0.9),
    onSurface: Colors.white.withValues(alpha: 0.9),
  ),
  scaffoldBackgroundColor: const Color.fromARGB(255, 5, 10, 10),
  fontFamily: 'DexaPro',
  textTheme: TextTheme(
    displayLarge: TextStyle(
      color: Colors.white.withValues(alpha: 0.9),
      fontFamily: 'DexaPro',
      fontSize: 32.sp,
      fontWeight: FontWeight.bold,
    ),
    displayMedium: TextStyle(
      color: Colors.white.withValues(alpha: 0.9),
      fontFamily: 'DexaPro',
      fontSize: 28.sp,
      fontWeight: FontWeight.bold,
    ),
    displaySmall: TextStyle(
      color: Colors.white.withValues(alpha: 0.9),
      fontFamily: 'DexaPro',
      fontSize: 10.sp,
      fontWeight: FontWeight.w400,
    ),
    headlineMedium: TextStyle(
      color: Colors.white.withValues(alpha: 0.9),
      fontFamily: 'DexaPro',
      fontSize: 24.sp,
      fontWeight: FontWeight.w600,
    ),
    headlineSmall: TextStyle(
      color: Colors.white.withValues(alpha: 0.9),
      fontFamily: 'DexaPro',
      fontSize: 20.sp,
      height: 1.2,
      fontWeight: FontWeight.w600,
    ),

    titleLarge: TextStyle(
      color: Colors.white.withValues(alpha: 0.9),
      fontFamily: 'DexaPro',
      fontSize: 16.sp,
      fontWeight: FontWeight.w600,
    ),
    titleMedium: TextStyle(
      color: Colors.white.withValues(alpha: 0.9),
      fontFamily: 'DexaPro',
      fontSize: 14.sp,
      fontWeight: FontWeight.w600,
    ),
    titleSmall: TextStyle(
      color: Colors.white.withValues(alpha: 0.9),
      fontFamily: 'DexaPro',
      fontSize: 10.sp,
      fontWeight: FontWeight.w600,
    ),
    bodyLarge: TextStyle(
      color: Colors.white.withValues(alpha: 0.9),
      fontFamily: 'DexaPro',
      fontSize: 16.sp,
      fontWeight: FontWeight.w400,
    ),
    bodyMedium: TextStyle(
      color: Colors.white.withValues(alpha: 0.9),
      fontFamily: 'DexaPro',
      fontSize: 14.sp,
      fontWeight: FontWeight.w400,
      height: 1.66
    ),
    bodySmall: TextStyle(
      color: Colors.white.withValues(alpha: 0.9),
      fontFamily: 'DexaPro',
      fontSize: 12.sp,
      height: 1.66,
      fontWeight: FontWeight.w400,
    ),
    labelLarge: TextStyle(
      color: Colors.white.withValues(alpha: 0.9),
      fontFamily: 'DexaPro',
      fontSize: 16.sp,
      height: 1.66,
      fontWeight: FontWeight.w500,
    ),
    labelSmall: TextStyle(
      color: Colors.white.withValues(alpha: 0.9),
      fontFamily: 'DexaPro',
      fontSize: 12.sp,
      fontWeight: FontWeight.w500,
    ),
    labelMedium: TextStyle(
      color: Colors.white.withValues(alpha: 0.9),
      fontFamily: 'DexaPro',
      fontSize: 14.sp,
      height: 1.66,
      fontWeight: FontWeight.w500,
    ),
  ),
);
