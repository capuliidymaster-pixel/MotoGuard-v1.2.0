import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_auth/firebase_auth.dart';

class EditProfilePage extends StatefulWidget {
  final String currentName;
  final String currentEmail;

  const EditProfilePage({
    super.key,
    required this.currentName,
    required this.currentEmail,
  });

  @override
  State<EditProfilePage> createState() => _EditProfilePageState();
}

class _EditProfilePageState extends State<EditProfilePage> {
  late TextEditingController _nameController;
  late TextEditingController _emailController;

  bool isLoading = false;

  @override
  void initState() {
    super.initState();

    _nameController = TextEditingController(
      text: widget.currentName,
    );

    _emailController = TextEditingController(
      text: widget.currentEmail,
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  // ================= SAVE =================
  Future<void> _saveChanges() async {
    try {
      setState(() {
        isLoading = true;
      });

      final prefs = await SharedPreferences.getInstance();

      await prefs.setString(
        "name",
        _nameController.text.trim(),
      );

      await prefs.setString(
        "email",
        _emailController.text.trim(),
      );

      User? user = FirebaseAuth.instance.currentUser;

      if (user != null) {
        await user.updateDisplayName(
          _nameController.text.trim(),
        );

        if (_emailController.text.trim() != user.email) {
          await user.verifyBeforeUpdateEmail(
            _emailController.text.trim(),
          );
        }

        await user.reload();
      }

      if (!mounted) return;

      _showSuccess(
        "Profile updated",
      );

      Navigator.pop(
        context,
        true,
      );
    } catch (e) {
      _showError(
        "Failed saving profile",
      );
    } finally {
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  // ================= UI =================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF050709),
      appBar: AppBar(
        title: const Text(
          "Edit Profile",
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            const SizedBox(height: 20),
            const CircleAvatar(
              radius: 50,
              backgroundColor: Colors.orange,
              child: Icon(
                Icons.person,
                size: 50,
                color: Colors.black,
              ),
            ),
            const SizedBox(height: 30),
            _buildTextField(
              "Full Name",
              _nameController,
              Icons.person,
            ),
            const SizedBox(height: 20),
            _buildTextField(
              "Email",
              _emailController,
              Icons.email,
            ),
            const SizedBox(height: 40),
            SizedBox(
              width: double.infinity,
              height: 55,
              child: ElevatedButton(
                onPressed: isLoading ? null : _saveChanges,
                child: isLoading
                    ? const CircularProgressIndicator(
                        color: Colors.black,
                      )
                    : const Text(
                        "Save Changes",
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ================= NORMAL FIELD =================
  Widget _buildTextField(
    String label,
    TextEditingController controller,
    IconData icon,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Colors.grey,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          style: const TextStyle(
            color: Colors.white,
          ),
          decoration: InputDecoration(
            prefixIcon: Icon(icon),
          ),
        ),
      ],
    );
  }

  // ================= SNACKBAR =================
  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: Colors.red,
        content: Text(message),
      ),
    );
  }

  void _showSuccess(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: Colors.green,
        content: Text(message),
      ),
    );
  }
}
