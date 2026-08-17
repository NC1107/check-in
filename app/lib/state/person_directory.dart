import '../api/models.dart';

/// Joins the same human across groups by phone number - the identity axiom every server
/// already enforces locally (allowlist, login, uniqueness). A peer view carries [User.phoneKey]
/// (a one-way hash) rather than the number itself, so the server never has to hand back
/// another member's real phone for this join to work - see [User.phoneKey]'s doc comment.
/// The key is deterministic, so exact string comparison is still safe; a number that doesn't
/// match simply stays split (a mismatch can only split, never wrongly join). Accounts
/// themselves stay sovereign per server - this is a presentation-layer join only.
class PersonDirectory {
  PersonDirectory._(this._phoneByGroupUser, this._groupsByPhone);

  const PersonDirectory.empty()
      : _phoneByGroupUser = const {},
        _groupsByPhone = const {};

  /// '$groupId~$userId' -> phone identity key ([User.phoneKey], falling back to the raw
  /// [User.phone] against an older server that doesn't send it yet).
  final Map<String, String> _phoneByGroupUser;

  /// phone identity key -> ids of groups where an account with that phone exists.
  final Map<String, Set<String>> _groupsByPhone;

  /// Builds the join from each group's member list. Groups whose list couldn't be
  /// fetched are simply absent - their people fall back to per-group keys.
  factory PersonDirectory.fromMemberLists(Map<String, List<User>> membersByGroup) {
    final phoneByGroupUser = <String, String>{};
    final groupsByPhone = <String, Set<String>>{};
    membersByGroup.forEach((groupId, members) {
      for (final u in members) {
        final key = u.phoneKey.isNotEmpty ? u.phoneKey : u.phone;
        if (key.isEmpty) continue;
        phoneByGroupUser['$groupId~${u.id}'] = key;
        (groupsByPhone[key] ??= {}).add(groupId);
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
