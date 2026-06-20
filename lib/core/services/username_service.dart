import 'dart:convert';
import 'package:http/http.dart' as http;
import '../constants/network_constants.dart';

class UsernameService {
  static String get _baseUrl => NetworkConstants.apiBaseUrl;
  static const Duration _timeout = Duration(seconds: 10);

  /// Set or update username for the current device
  static Future<UsernameResponse> setUsername(
      String deviceId, String username) async {
    try {
      final response = await http
          .post(
            Uri.parse('$_baseUrl/api/username'),
            headers: {
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'deviceId': deviceId,
              'username': username,
            }),
          )
          .timeout(_timeout);

      final responseData = jsonDecode(response.body);

      if (response.statusCode == 200) {
        return UsernameResponse(
          success: true,
          message: responseData['message'],
          username: responseData['username'],
        );
      } else {
        return UsernameResponse(
          success: false,
          message: responseData['error'] ?? 'Failed to set username',
        );
      }
    } catch (e) {
      return UsernameResponse(
        success: false,
        message: 'Network error: ${e.toString()}',
      );
    }
  }

  /// Get username for a specific device
  static Future<UsernameData?> getUsername(String deviceId) async {
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/api/username/$deviceId'),
        headers: {
          'Content-Type': 'application/json',
        },
      ).timeout(_timeout);

      if (response.statusCode == 200) {
        final responseData = jsonDecode(response.body);
        return UsernameData(
          deviceId: responseData['deviceId'],
          username: responseData['username'],
          updatedAt: responseData['updatedAt'],
        );
      } else if (response.statusCode == 404) {
        // Username not found - return null
        return null;
      } else {
        throw Exception('Failed to get username: ${response.body}');
      }
    } catch (e) {
      throw Exception('Network error: ${e.toString()}');
    }
  }

  /// Get usernames for multiple devices (batch request)
  static Future<Map<String, UsernameData>> getBatchUsernames(
      List<String> deviceIds) async {
    try {
      if (deviceIds.isEmpty) return {};

      // Limit batch size to 100 as per API
      final batchIds = deviceIds.take(100).toList();

      final response = await http
          .post(
            Uri.parse('$_baseUrl/api/username/batch'),
            headers: {
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'deviceIds': batchIds,
            }),
          )
          .timeout(_timeout);

      if (response.statusCode == 200) {
        final responseData = jsonDecode(response.body);
        final usernamesMap = <String, UsernameData>{};

        final usernames = responseData['usernames'] as Map<String, dynamic>;
        usernames.forEach((deviceId, userData) {
          usernamesMap[deviceId] = UsernameData(
            deviceId: deviceId,
            username: userData['username'],
            updatedAt: userData['updatedAt'],
          );
        });

        return usernamesMap;
      } else {
        throw Exception('Failed to get batch usernames: ${response.body}');
      }
    } catch (e) {
      throw Exception('Network error: ${e.toString()}');
    }
  }

  /// Delete username for the current device
  static Future<UsernameResponse> deleteUsername(String deviceId) async {
    try {
      final response = await http.delete(
        Uri.parse('$_baseUrl/api/username/$deviceId'),
        headers: {
          'Content-Type': 'application/json',
        },
      ).timeout(_timeout);

      final responseData = jsonDecode(response.body);

      if (response.statusCode == 200) {
        return UsernameResponse(
          success: true,
          message: responseData['message'],
        );
      } else {
        return UsernameResponse(
          success: false,
          message: responseData['error'] ?? 'Failed to delete username',
        );
      }
    } catch (e) {
      return UsernameResponse(
        success: false,
        message: 'Network error: ${e.toString()}',
      );
    }
  }
}

class UsernameResponse {
  final bool success;
  final String message;
  final String? username;

  UsernameResponse({
    required this.success,
    required this.message,
    this.username,
  });
}

class UsernameData {
  final String deviceId;
  final String username;
  final String updatedAt;

  UsernameData({
    required this.deviceId,
    required this.username,
    required this.updatedAt,
  });

  @override
  String toString() {
    return 'UsernameData(deviceId: $deviceId, username: $username, updatedAt: $updatedAt)';
  }
}
