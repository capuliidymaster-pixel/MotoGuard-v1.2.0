import 'package:logger/logger.dart';

// ✅ INITIALIZE LOGGER (replaces print statements)
final logger = Logger();

/// GENERATED MOCK (for development/testing)
/// Replace with Firebase Data Connect generated SDK when available
class MotoGuardConnector {
  MotoGuardConnector._();

  static final MotoGuardConnector instance = MotoGuardConnector._();

  /// MOCK DATABASE (temporary local storage simulation)
  final List<Map<String, dynamic>> _users = [];

  /// Simulates PostgreSQL insert via Firebase Data Connect
  Future<UserInsertMutation> userInsert({
    required String id,
    required String email,
    required String fullName,
    required String createdAt,
  }) async {
    return UserInsertMutation(
      id: id,
      email: email,
      fullName: fullName,
      createdAt: createdAt,
      onExecute: _users.add,
    );
  }
}

/// Wrapper for mutation execution
class UserInsertMutation {
  final String id;
  final String email;
  final String fullName;
  final String createdAt;
  final void Function(Map<String, dynamic>) onExecute;

  UserInsertMutation({
    required this.id,
    required this.email,
    required this.fullName,
    required this.createdAt,
    required this.onExecute,
  });

  /// Mimics `.execute()` from Firebase Data Connect SDK
  Future<void> execute() async {
    // ✅ FIX: Log the operation start
    logger.i("Starting user insert mutation for email: $email");

    await Future.delayed(const Duration(milliseconds: 500)); // simulate network

    try {
      onExecute({
        "id": id,
        "email": email,
        "fullName": fullName,
        "createdAt": createdAt,
      });

      // ✅ FIX: Replaced print() with logger.i() (info level)
      logger.i("✅ User saved to MotoGuard (mock DB) - ID: $id");
    } catch (e, stackTrace) {
      // ✅ FIX: Added error logging with stack trace
      logger.e(
        "❌ Error saving user to MotoGuard",
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }
}
