import 'package:shared_preferences/shared_preferences.dart';

class AuthService {
  static const String _companyCodeKey = 'company_code';

  Future<String?> getCompanyCode() async {
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getString(_companyCodeKey);
    if (code == null || code.isEmpty) return null;
    return code;
  }

  Future<void> saveCompanyCode(String code) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_companyCodeKey, code);
  }

  Future<void> signOut() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_companyCodeKey);
  }
}
