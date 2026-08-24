import '../state/app_state.dart';

/// Where a notification tap should land.
///
/// A push payload names the post it is about, but post ids are only unique per server, so
/// the id alone is not enough to open anything: the same number is a different check-in in
/// every group. Working out WHICH group is the whole job here, and getting it wrong is
/// worse than doing nothing - it opens a stranger's unrelated check-in and looks, to the
/// member, exactly like the notification lied to them.
class NotificationRoute {
  const NotificationRoute({
    required this.groupId,
    required this.postId,
    this.commentId,
    this.focusComments = false,
  });

  final String groupId;
  final int postId;

  /// The comment to scroll to and highlight, when the notification was about one.
  final int? commentId;

  /// Fall back to scrolling to the top of the thread. Only for a comment-shaped
  /// notification from a server old enough not to send [commentId] - the activity list
  /// always has one, because the same server that serves the list also sends the id.
  final bool focusComments;
}

/// Reads the post id a payload refers to, or null when it names none.
///
/// The daily digest is the case that names none: it says "3 new check-ins", not which. Its
/// tap belongs on the feed rather than nowhere, which is what it used to do.
int? pushPostId(Map<String, dynamic> data) => int.tryParse('${data['postId']}');

/// Reads the comment a payload is about, or null for a payload about the post itself (a
/// like, a new check-in) or from a server too old to send one.
int? pushCommentId(Map<String, dynamic> data) => int.tryParse('${data['commentId']}');

/// Resolves the group a push belongs to, or null when it cannot be told safely.
///
/// [postExists] probes one group for the post, and is only ever called when the payload
/// itself could not settle the question - which happens when the origin server has no
/// public URL configured, so it cannot say who it is (see the Go side's pushData).
///
/// The last rule is the important one: when several groups could hold that id, this gives
/// up rather than picking. Opening the wrong check-in is a worse outcome than opening none,
/// because the member cannot tell it is wrong - they just see a notification that took them
/// somewhere unrelated.
Future<ServerAccount?> resolvePushGroup(
  MultiSession session,
  Map<String, dynamic> data,
  int postId,
  Future<bool> Function(ServerAccount group) postExists,
) async {
  final signedIn = session.signedIn;
  if (signedIn.isEmpty) return null;

  // 1. The payload names its server, and we are signed in to it. The normal case.
  final server = data['server'] as String?;
  if (server != null && server.isNotEmpty) {
    final named = session.byId(MultiSessionController.groupIdFor(server));
    if (named != null && named.isSignedIn) return named;
  }

  // 2. Only one group is connected, so there is nothing to be ambiguous about - whichever
  //    server sent this, it is that one.
  if (signedIn.length == 1) return signedIn.first;

  // 3. Ask the groups. A single group holding that post is an answer; none or several is
  //    not, and this returns null rather than guessing.
  final found = <ServerAccount>[];
  final results = await Future.wait([
    for (final g in signedIn) postExists(g).catchError((_) => false),
  ]);
  for (var i = 0; i < signedIn.length; i++) {
    if (results[i]) found.add(signedIn[i]);
  }
  return found.length == 1 ? found.first : null;
}
