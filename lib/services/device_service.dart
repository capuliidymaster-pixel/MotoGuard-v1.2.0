import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Result kapag successful ang device claim.
class ClaimedDevice {
  final String deviceId;
  final String name;

  const ClaimedDevice({
    required this.deviceId,
    required this.name,
  });
}

/// Service para sa MotoGuard IoT device ownership.
///
/// Flow:
/// 1. User enters passkey.
/// 2. Passkey is SHA-256 hashed locally.
/// 3. Firestore is searched using passkeyHash.
/// 4. Device must be "available".
/// 5. Firestore transaction changes it to "in_use".
/// 6. connectedUserId becomes the current Firebase Auth UID.
///
/// IMPORTANT:
/// The plaintext passkey is NEVER written to Firestore.
class DeviceService {
  DeviceService._();

  static final DeviceService instance = DeviceService._();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  CollectionReference<Map<String, dynamic>> get _devices =>
      _firestore.collection('iotDevices');

  /// SHA-256 hash of the passkey.
  ///
  /// This must match the value stored in:
  ///
  /// iotDevices/<deviceId>/passkeyHash
  String hashPasskey(String passkey) {
    return sha256.convert(utf8.encode(passkey.trim())).toString();
  }

  /// Current Firebase user's UID.
  String _requireUserId() {
    final user = _auth.currentUser;

    if (user == null) {
      throw DeviceServiceException(
        'You must be logged in before connecting to a motorcycle.',
      );
    }

    return user.uid;
  }

  /// Finds the IoT device using the passkey.
  ///
  /// The plaintext passkey never leaves this function.
  Future<DocumentSnapshot<Map<String, dynamic>>?> findDevice(
    String passkey,
  ) async {
    final cleanPasskey = passkey.trim();

    if (cleanPasskey.isEmpty) {
      return null;
    }

    final passkeyHash = hashPasskey(cleanPasskey);

    final result = await _devices
        .where('passkeyHash', isEqualTo: passkeyHash)
        .limit(1)
        .get();

    if (result.docs.isEmpty) {
      return null;
    }

    return result.docs.first;
  }

  /// Atomically claims an available IoT device.
  ///
  /// This prevents two users from successfully claiming the same
  /// motorcycle at the same time.
  Future<ClaimedDevice> claimDevice(String passkey) async {
    final userId = _requireUserId();

    final cleanPasskey = passkey.trim();

    if (cleanPasskey.length < 8) {
      throw DeviceServiceException(
        'Invalid passkey.',
      );
    }

    final passkeyHash = hashPasskey(cleanPasskey);

    // Find the device using the HASH only.
    final query = await _devices
        .where('passkeyHash', isEqualTo: passkeyHash)
        .limit(1)
        .get();

    if (query.docs.isEmpty) {
      throw DeviceServiceException(
        'Invalid passkey. Motorcycle not found.',
      );
    }

    final deviceRef = query.docs.first.reference;

    late String deviceId;
    late String deviceName;

    await _firestore.runTransaction((transaction) async {
      final snapshot = await transaction.get(deviceRef);

      if (!snapshot.exists) {
        throw DeviceServiceException(
          'Motorcycle no longer exists.',
        );
      }

      final data = snapshot.data();

      if (data == null) {
        throw DeviceServiceException(
          'Invalid motorcycle data.',
        );
      }

      final currentStatus = (data['status'] ?? 'available').toString();

      final currentUserId = (data['connectedUserId'] ?? '').toString();

      deviceId = (data['deviceId'] ?? snapshot.id).toString();

      deviceName = (data['name'] ?? deviceId).toString();

      // ------------------------------------------------------------
      // Already owned by THIS user.
      // ------------------------------------------------------------
      if (currentStatus == 'in_use' && currentUserId == userId) {
        return;
      }

      // ------------------------------------------------------------
      // Device is already being used by somebody else.
      // ------------------------------------------------------------
      if (currentStatus == 'in_use' && currentUserId != userId) {
        throw DeviceServiceException(
          'This motorcycle is currently being used by another user.',
        );
      }

      // ------------------------------------------------------------
      // Device is available -> claim it.
      // ------------------------------------------------------------
      transaction.update(deviceRef, {
        'status': 'in_use',
        'connectedUserId': userId,
        'connectedAt': FieldValue.serverTimestamp(),
      });
    });

    return ClaimedDevice(
      deviceId: deviceId,
      name: deviceName,
    );
  }

  /// Releases the device currently owned by the logged-in user.
  ///
  /// After this:
  ///
  /// status = available
  /// connectedUserId = ""
  /// connectedAt = null
  ///
  /// Another user can then claim it using the passkey.
  Future<void> releaseDevice(String deviceId) async {
    final userId = _requireUserId();

    final deviceRef = _devices.doc(deviceId);

    await _firestore.runTransaction((transaction) async {
      final snapshot = await transaction.get(deviceRef);

      if (!snapshot.exists) {
        throw DeviceServiceException(
          'Motorcycle not found.',
        );
      }

      final data = snapshot.data();

      if (data == null) {
        throw DeviceServiceException(
          'Invalid motorcycle data.',
        );
      }

      final currentStatus = (data['status'] ?? 'available').toString();

      final connectedUserId = (data['connectedUserId'] ?? '').toString();

      // Nobody owns it anymore.
      if (currentStatus == 'available') {
        return;
      }

      // Prevent User B from releasing User A's motorcycle.
      if (connectedUserId != userId) {
        throw DeviceServiceException(
          'You do not have access to this motorcycle.',
        );
      }

      transaction.update(deviceRef, {
        'status': 'available',
        'connectedUserId': '',
        'connectedAt': null,
      });
    });
  }

  /// Checks whether the current Firebase user owns the device.
  Future<bool> isOwnedByCurrentUser(String deviceId) async {
    final userId = _auth.currentUser?.uid;

    if (userId == null) {
      return false;
    }

    final snapshot = await _devices.doc(deviceId).get();

    if (!snapshot.exists) {
      return false;
    }

    final data = snapshot.data();

    if (data == null) {
      return false;
    }

    return data['status'] == 'in_use' && data['connectedUserId'] == userId;
  }

  /// Gets the currently connected device of the logged-in user.
  ///
  /// Useful when the app starts again and we want to restore
  /// the user's existing motorcycle connection.
  Future<ClaimedDevice?> getCurrentUserDevice() async {
    final userId = _auth.currentUser?.uid;

    if (userId == null) {
      return null;
    }

    final result = await _devices
        .where('connectedUserId', isEqualTo: userId)
        .where('status', isEqualTo: 'in_use')
        .limit(1)
        .get();

    if (result.docs.isEmpty) {
      return null;
    }

    final doc = result.docs.first;
    final data = doc.data();

    return ClaimedDevice(
      deviceId: (data['deviceId'] ?? doc.id).toString(),
      name: (data['name'] ?? doc.id).toString(),
    );
  }
}

/// Custom exception para madaling i-display sa UI.
class DeviceServiceException implements Exception {
  final String message;

  const DeviceServiceException(this.message);

  @override
  String toString() => message;
}
