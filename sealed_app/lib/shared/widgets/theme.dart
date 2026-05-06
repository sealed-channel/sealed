import 'package:flutter/material.dart';

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
final Color primaryColor = Color.fromARGB(255, 64, 190, 146);

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
  blurRadius: 10,
  offset: Offset(0, 4),
);

// card color
final Color cardColor = Color.fromARGB(255, 12, 12, 12);

final ThemeData sealedTheme = ThemeData(
  snackBarTheme: SnackBarThemeData(
    backgroundColor: primaryColor,
    contentTextStyle: TextStyle(
      color: Colors.white,
      fontWeight: FontWeight.w500,
    ),
  ),
  brightness: Brightness.dark,
  primaryColor: primaryColor,

  colorScheme: ColorScheme.dark(
    primary: primaryColor,
    secondary: Color(0xFF4DA898),
    surface: cardColor,
    onPrimary: Colors.white,
    onSecondary: Colors.white,
    onSurface: Colors.white,
  ),
  scaffoldBackgroundColor: const Color.fromARGB(0, 0, 0, 0),
  fontFamily: 'DexaPro',
  textTheme: const TextTheme(
    displayLarge: TextStyle(
      color: Colors.white,
      fontFamily: 'DexaPro',
      fontSize: 32,
      fontWeight: FontWeight.bold,
    ),
    displayMedium: TextStyle(
      color: Colors.white,
      fontFamily: 'DexaPro',
      fontSize: 28,
      fontWeight: FontWeight.bold,
    ),
    displaySmall: TextStyle(
      color: Colors.white,
      fontFamily: 'DexaPro',
      fontSize: 24,
      fontWeight: FontWeight.bold,
    ),
    headlineMedium: TextStyle(
      color: Colors.white,
      fontFamily: 'DexaPro',
      fontSize: 20,
      fontWeight: FontWeight.w700,
    ),
    headlineSmall: TextStyle(
      color: Colors.white,
      fontFamily: 'DexaPro',
      fontSize: 18,
      fontWeight: FontWeight.w600,
    ),
    titleLarge: TextStyle(
      color: Colors.white,
      fontFamily: 'DexaPro',
      fontSize: 16,
      fontWeight: FontWeight.w600,
    ),
    titleMedium: TextStyle(
      color: Colors.white,
      fontFamily: 'DexaPro',
      fontSize: 14,
      fontWeight: FontWeight.w500,
    ),
    titleSmall: TextStyle(
      color: Colors.white,
      fontFamily: 'DexaPro',
      fontSize: 12,
      fontWeight: FontWeight.w500,
    ),
    bodyLarge: TextStyle(
      color: Colors.white,
      fontFamily: 'DexaPro',
      fontSize: 16,
      fontWeight: FontWeight.w400,
    ),
    bodyMedium: TextStyle(
      color: Colors.white,
      fontFamily: 'DexaPro',
      fontSize: 14,
      fontWeight: FontWeight.w400,
    ),
    bodySmall: TextStyle(
      color: Colors.white,
      fontFamily: 'DexaPro',
      fontSize: 12,
      fontWeight: FontWeight.w400,
    ),
    labelLarge: TextStyle(
      color: Colors.white,
      fontFamily: 'DexaPro',
      fontSize: 14,
      fontWeight: FontWeight.w500,
    ),
  ),
);
