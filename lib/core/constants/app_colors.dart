import 'package:flutter/material.dart';

class AppColors {
  // Primary brand colors
  static const Color primary = Color.fromRGBO(184, 203, 137, 1); // Main green
  static const Color primaryDark = Color(0xFF6FA654); // Darker green
  static const Color primaryLight = Color(0xFFA7D685); // Lighter green

  // Background colors
  static const Color background = Color(0xFFEFEFEF); // Light gray background
  static const Color surface = Colors.white;
  static const Color surfaceDark = Color(0xFF121212);

  // Message bubble colors
  static const Color senderBubble = Color(0xFFEFFEDD); // Light green bubble
  static const Color receiverBubble = Colors.white;
  static const Color messageText = Color(0xFF303030); // Dark gray text

  // Text colors
  static const Color textPrimary = Color(0xFF303030); // Dark text
  static const Color textSecondary = Color(0xFF8F8F8F); // Gray text
  static const Color textLight = Colors.white;

  // Status colors
  static const Color success = Color(0xFF4CAF50); // Success green
  static const Color error = Color(0xFFE74C3C); // Error red
  static const Color warning = Color(0xFFF39C12); // Warning orange
  static const Color info = Color(0xFF3498DB); // Info blue

  // Chat specific colors
  static const Color timestamp = Color(0xFF8F8F8F); // Message timestamp
  static const Color messageStatus = Color(0xFF34B7F1); // Blue ticks
  static const Color chatAction = Color(0xFF34B7F1); // Action buttons

  // Other colors
  static const Color divider = Color(0xFFE0E0E0); // Light divider
  static const Color shadow = Color(0x1F000000); // Shadows
  static const Color transparent = Colors.transparent;

  // Gradient colors
  static const Color gradientStart = Color(0xFFBCE869); // Start of gradient
  static const Color gradientEnd = Color(0xFF8BC869); // End of gradient
}
