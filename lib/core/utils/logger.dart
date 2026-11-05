import 'package:flutter/foundation.dart';

class Logger {
  static void info(String message, [Map<String, dynamic>? context]) {
    _log('INFO', message, context);
  }
  
  static void warning(String message, [Map<String, dynamic>? context]) {
    _log('WARNING', message, context);
  }
  
  static void error(String message, [Map<String, dynamic>? context]) {
    _log('ERROR', message, context);
  }
  
  static void debug(String message, [Map<String, dynamic>? context]) {
    _log('DEBUG', message, context);
  }
  
  static void _log(String level, String message, [Map<String, dynamic>? context]) {
    final timestamp = DateTime.now().toIso8601String();
    final buffer = StringBuffer();
    
    buffer.write('[$timestamp] [$level] $message');
    
    if (context != null && context.isNotEmpty) {
      buffer.write(' | Context: $context');
    }
    
    debugPrint(buffer.toString());
  }
}
