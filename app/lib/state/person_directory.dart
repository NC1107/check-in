import '../api/models.dart';

/// Joins the same human across groups by phone number - the identity axiom every server
/// already enforces locally (allowlist, login, uniqueness). Servers store phones
/// pre-normalized, so exact string comparison is safe; a number that doesn't match simply
/// stays split (a mismatch can only split, never wrongly join). Accounts themselves stay
/// sovereign per server - this is a presentation-layer join only.
class PersonDirectory {
  PersonDirectory._(this._phoneByGroupUser, this._groupsByPhone);

  const PersonDirectory.empty()
      : _phoneByGroupUser = const {},
        _groupsByPhone = const {};

  /// '$groupId~$userId' -> normalized phone.
  final Map<String, String> _phoneByGroupUser;

  /// normalized phone -> ids of groups where an account with that phone exists.
  final Map<String, Set<String>> _groupsByPhone;

  /// Builds the join from each group's member list. Groups whose list couldn't be
  /// fetched are simply absent - their people fall back to per-group keys.
  factory PersonDirectory.fromMemberLists(Map<String, List<User>> membersByGroup) {
    final phoneByGroupUser = <String, String>{};
    final groupsByPhone = <String, Set<String>>{};
    membersByGroup.forEach((groupId, members) {
      for (final u in members) {
        if (u.phone.isEmpty) continue;
        phoneByGroupUser['$groupId~${u.id}'] = u.phone;
        (groupsByPhone[u.phone] ??= {}).add(groupId);
      }
    });
    return PersonDirectory._(phoneByGroupUser, groupsByPhone);
  }

  /// The stable filter key for a person: phone-based when the directory knows this
  /// (group, user) - identical across every group the human is in - else a per-group
  /// fallback that behaves exactly like the unmerged world.
  String keyFor(String? groupId, int userId) {
    final phone = _phoneByGroupUser['${groupId ?? ''}~$userId'];
    return phone != null ? 'phone:$phone' : 'local:${groupId ?? ''}~$userId';
  }

  /// The groups a (merged) person belongs to. Local fallback keys resolve to their one
  /// group; unknown keys to none.
  Set<String> groupsFor(String key) {
    if (key.startsWith('phone:')) {
      return _groupsByPhone[key.substring(6)] ?? const {};
    }
    if (key.startsWith('local:')) {
      final sep = key.indexOf('~');
      if (sep > 6) return {key.substring(6, sep)};
    }
    return const {};
  }
}
