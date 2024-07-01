import 'dart:convert';
import 'package:jose/jose.dart';
import 'config.dart';
import 'log.dart';

// values were generated with https://github.com/powersync-ja/self-host-demo/tree/main/key-generator
// see its README.md for populating /config/config.yaml and .env

/// JWKS should match PowerSync's `config.yaml`.
const _jwksKeyStr = '''
{
  "kty": "RSA",
  "n": "wp63FeUhjsJfg2aR0P4SMZ4tUWCkQaDUZQ66BHbRLfQ4F0VVsRyRs5TBmntVVCCEvcbrfpfUhNfSR634ZxvK-1URrZOJM920TqoC28vrDLn-2i7RsKU94hQoYoDOiEtUY2UveScc3n8WId08L1eEbwWIioEYXjn3HwGdk2cz_CnageAXLKTYTKiTjLOgxMBpQ_CuRBPcuxnoepmrt9KzbajOq3ooPmlhja0_0N9SK7qE8GdEMVTMPTMCj7KXow2pjwkvLQT7O2-sATshGU3NA5ONZOI5lW5qIgSbjw_gT8PqTHZvgGrCZlm7UZ7Gz4kB6QAsKio3NMVp96QqNUSWxQ",
  "e": "AQAB",
  "alg": "RS256",
  "kid": "powersync-e928374396"
}
''';

final _jwksKey = jsonDecode(_jwksKeyStr);

// Public key should match PowerSync's `.env`.
// final _jwksPublicKeyStr = utf8.decode(base64Decode(
//   'eyJrdHkiOiJSU0EiLCJuIjoid3A2M0ZlVWhqc0pmZzJhUjBQNFNNWjR0VVdDa1FhRFVaUTY2QkhiUkxmUTRGMFZWc1J5UnM1VEJtbnRWVkNDRXZjYnJmcGZVaE5mU1I2MzRaeHZLLTFVUnJaT0pNOTIwVHFvQzI4dnJETG4tMmk3UnNLVTk0aFFvWW9ET2lFdFVZMlV2ZVNjYzNuOFdJZDA4TDFlRWJ3V0lpb0VZWGpuM0h3R2RrMmN6X0NuYWdlQVhMS1RZVEtpVGpMT2d4TUJwUV9DdVJCUGN1eG5vZXBtcnQ5S3piYWpPcTNvb1BtbGhqYTBfME45U0s3cUU4R2RFTVZUTVBUTUNqN0tYb3cycGp3a3ZMUVQ3TzItc0FUc2hHVTNOQTVPTlpPSTVsVzVxSWdTYmp3X2dUOFBxVEhadmdHckNabG03VVo3R3o0a0I2UUFzS2lvM05NVnA5NlFxTlVTV3hRIiwiZSI6IkFRQUIiLCJhbGciOiJSUzI1NiIsImtpZCI6InBvd2Vyc3luYy1lOTI4Mzc0Mzk2In0='));
// final _jwksPublicKey = jsonDecode(_jwksPublicKeyStr);

final _jwksPrivateKeyStr = utf8.decode(base64Decode(
    'eyJrdHkiOiJSU0EiLCJuIjoid3A2M0ZlVWhqc0pmZzJhUjBQNFNNWjR0VVdDa1FhRFVaUTY2QkhiUkxmUTRGMFZWc1J5UnM1VEJtbnRWVkNDRXZjYnJmcGZVaE5mU1I2MzRaeHZLLTFVUnJaT0pNOTIwVHFvQzI4dnJETG4tMmk3UnNLVTk0aFFvWW9ET2lFdFVZMlV2ZVNjYzNuOFdJZDA4TDFlRWJ3V0lpb0VZWGpuM0h3R2RrMmN6X0NuYWdlQVhMS1RZVEtpVGpMT2d4TUJwUV9DdVJCUGN1eG5vZXBtcnQ5S3piYWpPcTNvb1BtbGhqYTBfME45U0s3cUU4R2RFTVZUTVBUTUNqN0tYb3cycGp3a3ZMUVQ3TzItc0FUc2hHVTNOQTVPTlpPSTVsVzVxSWdTYmp3X2dUOFBxVEhadmdHckNabG03VVo3R3o0a0I2UUFzS2lvM05NVnA5NlFxTlVTV3hRIiwiZSI6IkFRQUIiLCJkIjoiRHRqc1owbDJkSzFyLTNxTy04WnlUV0lfbTFKMzNZRGZTMEZqSEJXVGNrSE1LS3hUdEFJVnRJRlBfdERUYXVwYkxoNDNsNDRPT3I4N1RkZ2VHQUdsQy1VS3h2YjNNLU9CVHJJR0swNEVoZEZIdWMzeUZkdVpXNzdGY1BSYUxVZ3Y3VEJLUGFBb0FlcG9uaGRDY09zb2tZNjJ3cmhFQzJZNUxkNmg3cDJrTi1PNGFyMjgwSnkxNW1abTJxdlpBQURlZ0NKeDc0UHgyTmNBMXZQVmU2UGxxRUZCZHcwZDRJWHpoMUpwVVhOX2tJSkd3VW05TWVwRS16NVFsRWlJeHJMWHg2Ul9FQmMwak96THI3X0YyVEptOUpucEl5UEdmRjI4MTVNakt5UGg1NlN3MW9yUEFkU3lMdWtRUFR6bU5YMUtyQkdVTXFhWE1yUGpqZ3JpS1F6Z0VRIiwicCI6IjYwZGM3MHFBWHBZeE5KOWJzYUpXanlKdTY1SnFrYzZVeGxlejFRQkZwT3ZVNV9adDdha09yUzFsRHVXSTZDQlpCZ0lqd0F0cTB1REotNTRrQ25HRDBZaWl2d0U2TWIteDVONTV6OEhnTWR5czlMSGxjdkdVeENkNFpLTFBXb2V1b051MDVGRkU5OF9aVzJPbUhsZ2pjTmo3NjlIME5tS1BtSnhOVzR2bjh0VSIsInEiOiIwOEttNnZ4UmlIZGJRcWpaaUNYcUxhUmU0QXhCN3o1enFnRXNDbTdTNjQyNVYyYXczSTQ0YUxYWU5EUUtzcGtlSUJaazRDTnV0WTRwLXZIQmZyckxLcWRrZUJwZW1nTU5UWE5abldEOWZZRm9mRFBPQWo3UTY2TDNmejY4bkJRM2FoSDF0Q29vWTZCOGN6ZXU0TDVqbVpIQVJDeEtQR2ZveFRabVRHZllyREUiLCJkcCI6ImpQZ1dLOTNrcWtldE5jMWhvRDRYUk8ycHJnWHRTbTJQWUlPOTRScW5uOWdabWQ1aUlTclEtMXdlbDkxWnVWTmdZNlEyaldPSjNzNEcxM2I2T3pPbWVvNDJqT0VNWURCdVF5WTFzQkNHNXZsRXU5dzNFVGJFSHY5VE9HRUFna3FYakJQM18zRGVOT2paWDlPRl9kcHJhYnJvdm5QdXNnTTk3SC1DTGg3V21fMCIsImRxIjoiT0g1Wm9aOG04VTFHWDRaRVlub2EtNG82ZFhOUHM4X3BjNVZVZG9RU2FSMHFNUk1JWkE3ZEpiSTl0OC1hZXdNMmNrRUhNSFREZUZReEJ1MndQV3NBQUtVZnZKcnNXaEl1WGxkRHRTVEctOUNtVzF4R3ZYcWNxZ0NVSHJKU0J5R3RsdktycGlFSkhXc1hTSFcyaGViRkU1YzZ2X1ZBNk5TZjJOMG1kWVBPM2tFIiwicWkiOiJkQjBUTElvWDBGUTI5Ny1jNEhzQm5IUzlZdXBHTG5saDlHVkVkZnh6UDNBZDhHWEFULWxNT1cza0xfYVlxZnVNNmdJWXhhMGZSc0NlcWoxdXhGNXltYUFYaV84NUxxOG8wSDljcnJKQVdOVm1Yc2VPLXhKNDctRmhpbVV4TXl6aHdYMVJMZFQ5MHNZZm1VSHN1aDVxdndkQmtJNWlXd2hhYlprVzlqQVk3YlkiLCJhbGciOiJSUzI1NiIsImtpZCI6InBvd2Vyc3luYy1lOTI4Mzc0Mzk2In0='));

final _jwksPrivateKey = jsonDecode(_jwksPrivateKeyStr);

final _jwkPrivateKey = JsonWebKey.fromJson(_jwksPrivateKey);

final _keyStore = JsonWebKeyStore()..addKey(_jwkPrivateKey);

Future<String> generateToken() async {
  final now = DateTime.now();

  final claims = JsonWebTokenClaims.fromJson({
    'iss': 'https://github.com/nurturenature/jepsen-powersync',
    'sub': config['USER_ID'] as String,
    'aud': ['powersync-dev', 'powersync'],
    'iat': now.millisecondsSinceEpoch / 1000,
    'exp': now.add(Duration(minutes: 5)).millisecondsSinceEpoch / 1000,
    'parameters': {'sync_filter': '*'}
  });

  final builder = JsonWebSignatureBuilder();
  builder.setProtectedHeader('alg', _jwksKey['alg']);
  builder.setProtectedHeader('kid', _jwksKey['kid']);
  builder.jsonContent = claims.toJson();
  builder.addRecipient(_jwkPrivateKey, algorithm: _jwksKey['alg']);

  final jws = builder.build().toCompactSerialization();

  log.finer(
      'Created token w/payload: ${(await JsonWebSignature.fromCompactSerialization(jws).getPayload(_keyStore)).jsonContent}');

  return jws;
}

Future<bool> verifyToken(String token) async {
  final jwt = JsonWebToken.unverified(token);
  final verified = await jwt.verify(_keyStore);

  log.finer('Token verified: $verified, with claims: ${jwt.claims}');

  return verified;
}
