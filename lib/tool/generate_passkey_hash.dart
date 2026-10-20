import 'dart:convert';
import 'package:crypto/crypto.dart';

void main() {
  const passkey = 'MG-7Qp4-X2mK-8Rz9-T6vL';

  final bytes = utf8.encode(passkey);

  final digest = sha256.convert(bytes);

  print('Passkey: $passkey');
  print('SHA-256: $digest');
}
