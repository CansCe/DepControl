/// An authenticated principal, derived from a *verified* Supabase JWT.
///
/// Only ever constructed after signature + expiry checks pass (see
/// `SupabaseJwtVerifier`), so downstream code can treat it as trusted identity.
class AuthUser {
  const AuthUser({
    required this.id,
    required this.role,
    this.email,
    this.claims = const {},
  });

  /// Builds an [AuthUser] from a set of verified JWT claims.
  factory AuthUser.fromClaims(Map<String, dynamic> claims) {
    return AuthUser(
      id: claims['sub'] as String,
      role: (claims['role'] as String?) ?? 'authenticated',
      email: claims['email'] as String?,
      claims: claims,
    );
  }

  /// Supabase user id (JWT `sub`) — the stable identifier to key ownership on.
  final String id;

  /// Supabase role, e.g. `authenticated` (JWT `role`).
  final String role;

  /// User email, when present in the token.
  final String? email;

  /// All verified claims, for callers that need more than id/email/role.
  final Map<String, dynamic> claims;

  /// Safe public projection (never leaks the raw claim set).
  Map<String, dynamic> toJson() => {
        'id': id,
        'email': email,
        'role': role,
      };
}
