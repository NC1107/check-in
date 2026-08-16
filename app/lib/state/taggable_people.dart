import '../api/models.dart';
import 'person_directory.dart';

/// One human the compose tag picker can offer, carrying the member id they hold on each
/// selected group's server. Tags are stored per server against that server's own user ids,
/// so a cross-post cannot send one list of ids to every group - each copy needs the ids of
/// the group it lands in, which is what [idsByGroup] holds.
class TaggablePerson {
  const TaggablePerson({
    required this.key,
    required this.name,
    required this.idsByGroup,
    this.photoId,
    this.photoGroupId,
  });

  /// The cross-group identity key from [PersonDirectory]: phone-joined where both servers
  /// know the number, else a per-group key that behaves like the unmerged world.
  final String key;

  /// Display name, taken from the first selected group that knows this human.
  final String name;

  /// Group id -> the member id this human has on that group's server.
  final Map<String, int> idsByGroup;

  /// Profile photo, and the group whose server stores it (media is per-server, so the two
  /// travel together).
  final int? photoId;
  final String? photoGroupId;

  /// The id to tag when posting to [groupId], or null when this human has no account there.
  int? idIn(String groupId) => idsByGroup[groupId];

  /// Which of [groupIds] this human is missing from, in the order given.
  List<String> missingFrom(Iterable<String> groupIds) => [
        for (final g in groupIds)
          if (!idsByGroup.containsKey(g)) g
      ];
}

/// Merges the selected groups' member lists into one entry per human, so tagging is a
/// choice about people rather than about accounts. [membersByGroup] is read in insertion
/// order - the first group that knows a human supplies their name, and the first photo
/// found fills the avatar. [excludeByGroup] drops the signed-in author on each server: the
/// post is implicitly theirs.
///
/// A human only some of the selected groups know still gets one entry, holding just the ids
/// they do have. Their copy in the other groups simply goes out without them, which is the
/// honest outcome - those servers have no account to point at.
List<TaggablePerson> mergeTaggablePeople(
  Map<String, List<User>> membersByGroup, {
  Map<String, int> excludeByGroup = const {},
}) {
  final directory = PersonDirectory.fromMemberLists(membersByGroup);
  final ids = <String, Map<String, int>>{};
  final names = <String, String>{};
  final photos = <String, ({int id, String groupId})>{};
  membersByGroup.forEach((groupId, members) {
    for (final u in members) {
      if (excludeByGroup[groupId] == u.id) continue;
      final key = directory.keyFor(groupId, u.id);
      (ids[key] ??= {})[groupId] = u.id;
      names.putIfAbsent(key, () => u.name);
      final photo = u.profileMediaId;
      if (photo != null) photos.putIfAbsent(key, () => (id: photo, groupId: groupId));
    }
  });
  final out = [
    for (final e in ids.entries)
      TaggablePerson(
        key: e.key,
        name: names[e.key] ?? '',
        idsByGroup: Map.unmodifiable(e.value),
        photoId: photos[e.key]?.id,
        photoGroupId: photos[e.key]?.groupId,
      )
  ];
  out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return out;
}
