/// Credential & authentication resolver
abstract class AuthProvider {
  bool hasUser(String username);

  List<String> existingUsers(List<String> usernames) =>
      usernames.where((e) => hasUser(e)).toList();

  bool validate(String username, String password);
}

/// Simple in-memory auth provider
class MapAuthProvider extends AuthProvider {
  final Map<String, String> users;

  MapAuthProvider(this.users);

  @override
  bool hasUser(String username) => users.containsKey(username);

  @override
  bool validate(String username, String password) =>
      users[username] == password;
}
