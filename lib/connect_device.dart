import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class ConnectDevicePage extends StatefulWidget {
  const ConnectDevicePage({super.key});

  @override
  State<ConnectDevicePage> createState() => _ConnectDevicePageState();
}

class _ConnectDevicePageState extends State<ConnectDevicePage> {
  final passkeyController = TextEditingController();

  bool loading = false;

  Future<void> connectDevice() async {
    final passkey = passkeyController.text.trim();

    if (passkey.isEmpty) {
      showMessage("Please enter the device passkey.");
      return;
    }

    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      showMessage("You must be logged in first.");
      return;
    }

    setState(() {
      loading = true;
    });

    try {
      // Find device using passkey
      final result = await FirebaseFirestore.instance
          .collection('iotDevices')
          .where('passkey', isEqualTo: passkey)
          .limit(1)
          .get();

      if (result.docs.isEmpty) {
        showMessage("Invalid passkey.");
        return;
      }

      final deviceDoc = result.docs.first;
      final deviceData = deviceDoc.data();

      final status = deviceData['status'] ?? 'available';

      // Don't allow another user to connect
      if (status != 'available') {
        showMessage("This device is already being used.");
        return;
      }

      // Connect device
      await deviceDoc.reference.update({
        'status': 'connected',
        'connectedUserId': user.uid,
        'connectedAt': FieldValue.serverTimestamp(),
      });

      if (!mounted) return;

      showMessage("Device connected successfully!");

      // Return device information
      Navigator.pop(context, {
        'deviceId': deviceData['deviceId'],
        'name': deviceData['name'],
      });
    } on FirebaseException catch (e) {
      showMessage(
        e.message ?? "Failed to connect device.",
      );
    } catch (e) {
      showMessage("An unexpected error occurred.");
    } finally {
      if (mounted) {
        setState(() {
          loading = false;
        });
      }
    }
  }

  void showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF08110D),
      ),
    );
  }

  @override
  void dispose() {
    passkeyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF050709),
      appBar: AppBar(
        title: const Text("Connect Device"),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 30),
            const Icon(
              Icons.bluetooth_connected_rounded,
              color: Colors.greenAccent,
              size: 60,
            ),
            const SizedBox(height: 20),
            const Text(
              "Connect your IoT Device",
              style: TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              "Enter the passkey provided with your device.",
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.55),
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 35),
            TextField(
              controller: passkeyController,
              style: const TextStyle(
                color: Colors.white,
              ),
              decoration: InputDecoration(
                labelText: "Device Passkey",
                labelStyle: const TextStyle(
                  color: Colors.greenAccent,
                ),
                hintText: "MG-7fK2-88xQ-LmP8-4Rt6-Zb1v",
                hintStyle: TextStyle(
                  color: Colors.white.withValues(alpha: 0.25),
                ),
                prefixIcon: const Icon(
                  Icons.key_rounded,
                  color: Colors.greenAccent,
                ),
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.05),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(18),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: const OutlineInputBorder(
                  borderRadius: BorderRadius.all(
                    Radius.circular(18),
                  ),
                  borderSide: BorderSide(
                    color: Colors.greenAccent,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 25),
            SizedBox(
              width: double.infinity,
              height: 58,
              child: ElevatedButton(
                onPressed: loading ? null : connectDevice,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.greenAccent,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
                child: loading
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          color: Colors.black,
                          strokeWidth: 2,
                        ),
                      )
                    : const Text(
                        "CONNECT DEVICE",
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.5,
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
