class Session {
  const Session({
    required this.companyCode,
    required this.orgId,
    required this.userId,
    required this.token,
    required this.expiresAt,
  });

  final String companyCode;
  final String orgId;
  final String userId;
  final String token;
  final DateTime expiresAt;

  bool get isExpired => DateTime.now().isAfter(expiresAt);

  Map<String, dynamic> toJson() => {
        'company_code': companyCode,
        'org_id': orgId,
        'user_id': userId,
        'token': token,
        'expires_at': expiresAt.toUtc().toIso8601String(),
      };

  factory Session.fromJson(Map<String, dynamic> json) {
    return Session(
      companyCode: json['company_code'] as String,
      orgId: json['org_id'] as String,
      userId: json['user_id'] as String,
      token: json['token'] as String,
      expiresAt: DateTime.parse(json['expires_at'] as String),
    );
  }
}
