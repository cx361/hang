import 'package:flutter/foundation.dart';

/// Centralized validation helper to prevent duplicated logic and ensure consistency.
class ValidationHelpers {
  /// Validates handle format: only lowercase a-z, 0-9, dot, underscore, hyphen.
  /// Length: 3-20 characters.
  static (bool, String?) validateHandle(String input) {
    var handle = input.trim().toLowerCase();
    // Allow optional leading @ and remove it
    handle = handle.replaceFirst(RegExp(r'^@+'), '');

    if (handle.isEmpty) {
      return (false, 'Please enter a handle');
    }

    if (handle.length < 3) {
      return (false, 'Handle must be at least 3 characters long');
    }

    if (handle.length > 20) {
      return (false, 'Handle may not exceed 20 characters');
    }

    if (!RegExp(r'^[a-z0-9._-]+$').hasMatch(handle)) {
      return (false, 'Handle may only contain lowercase letters, numbers, dot, underscore and hyphen');
    }

    return (true, null);
  }

  /// Validates password strength.
  /// Requirements: minimum 8 characters, at least 1 number, at least 1 special character.
  static (bool, String?) validatePassword(String input) {
    if (input.isEmpty) {
      return (false, 'Please enter a password');
    }

    if (input.length < 8) {
      return (false, 'Password must be at least 8 characters long');
    }

    if (!RegExp(r'\d').hasMatch(input)) {
      return (false, 'Password must contain at least 1 number');
    }

    if (!RegExp(r'[!@#$%^&*(),.?":{}|<>]').hasMatch(input)) {
      return (false, 'Password must contain at least 1 special character (!@#\$%^&*(),.?":{}|<>)');
    }

    return (true, null);
  }

  /// Validates email format.
  static (bool, String?) validateEmail(String input) {
    if (input.isEmpty) {
      return (false, 'Please enter an email');
    }

    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(input)) {
      return (false, 'Please enter a valid email address');
    }

    return (true, null);
  }

  /// Validates incognito duration.
  /// Constraints: minimum 1 minute, maximum 24 hours, or null (indefinite).
  static (bool, String?) validateIncognitoDuration(Duration? duration) {
    if (duration == null) {
      // Indefinite is valid
      return (true, null);
    }

    if (duration.inMinutes < 1) {
      return (false, 'Duration must be at least 1 minute');
    }

    if (duration.inHours > 24) {
      return (false, 'Duration may not exceed 24 hours');
    }

    return (true, null);
  }

  /// Sanitizes search query to prevent SQL injection.
  /// Returns lowercase trimmed query with special characters escaped.
  static String sanitizeSearchQuery(String query) {
    // Trim and lowercase
    var sanitized = query.trim().toLowerCase();

    // Escape SQL special characters for use in LIKE patterns
    // These are: %, _, \
    sanitized = sanitized.replaceAll(r'\', r'\\');
    sanitized = sanitized.replaceAll('%', r'\%');
    sanitized = sanitized.replaceAll('_', r'\_');

    return sanitized;
  }

  /// Logs messages only in debug mode to prevent sensitive data exposure.
  static void debugLog(String tag, String message) {
    if (kDebugMode) {
      debugPrint('[$tag] $message');
    }
  }
}
