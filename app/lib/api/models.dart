// Plain data models mirroring the server's JSON responses.

import 'package:intl/intl.dart';

class ServerInfo {
  ServerInfo({
    required this.name,
    required this.initialized,
    this.color = '',
    this.publicUrl,
    this.mediaTypes = const ['image'],
    this.gifSearch = false,
    this.commentMedia = false,
    this.recapCapable = false,
    this.recapCadence = 'weekly',
    this.recapWeekday = 1,
    this.recapHour = 19,
    this.recapOffset = 0,
    this.titlesCapable = false,
    this.memoriesCapable = false,
    this.eventsCapable = false,
    this.timelineCapable = false,
  });

  final String name;
  final bool initialized;

  /// The group's admin-set palette color id (empty when none is chosen). Members render
  /// it so the merged feed tells groups apart.
  final String color;

  /// The server's canonical public base URL, when it advertises one (multi-group
  /// installs). Used to match push payloads back to a connected group.
  final String? publicUrl;

  /// What this server accepts as an attachment ('image', 'gif', 'video'). A server that
  /// predates typed media says nothing, and only ever accepted stills - so the absent key
  /// means images only, not "anything goes". The app uses this to hide options a group's
  /// server would reject rather than letting the upload fail after the fact.
  final List<String> mediaTypes;

  /// Whether this server's Klipy gif-search proxy is usable (a key is configured on it).
  /// Gates the compose/comment gif picker entry points - false for a server with no key,
  /// or one old enough to say nothing about it at all.
  final bool gifSearch;

  /// Whether this server accepts a `mediaId` on a comment. Intrinsic to the server version
  /// (always true from the version that introduced it onward), so what a client actually
  /// gates on is the *key being present at all* - an older server, which predates the field
  /// and would 400 on an unknown `mediaId` (DisallowUnknownFields), says nothing here and
  /// this defaults to false.
  final bool commentMedia;

  /// Whether this server understands the recap feature at all: lat/lng on createPost, and
  /// the recapCadence/recapWeekday/recapHour/recapOffset fields (here and on
  /// PATCH /api/admin/server). A server predating recap says nothing, and this server
  /// rejects unknown JSON fields - so the app must only send any of the above once this is
  /// true, or a new client would fail to post at all against an old server.
  final bool recapCapable;
  final String recapCadence; // off | weekly | monthly
  final int recapWeekday; // ISO, 1=Mon..7=Sun
  final int recapHour; // 0-23, group-local
  final int recapOffset; // minutes east of UTC

  /// Whether this server's on-demand recap endpoint accepts `bestowTitles`. A server
  /// predating it rejects unknown JSON fields (DisallowUnknownFields), so the "bestow
  /// titles" toggle in the generate sheet must only appear once this is true.
  final bool titlesCapable;

  /// Whether this server has GET /api/memories/random at all. A server predating the hidden
  /// Memories surface has no such route and would 404 the request, so the client must hide
  /// the handle entirely rather than opening a surface that can never load anything.
  final bool memoriesCapable;

  /// Whether this server has GET /api/memories/events - the "Group trips" hub entry. Same
  /// story as [memoriesCapable]: a server predating it has no such route at all, so the
  /// client hides that one hub entry rather than opening a list that can never load
  /// anything. Independent of memoriesCapable - a server can have one without the other.
  final bool eventsCapable;

  /// Whether this server has GET /api/memories/timeline and
  /// /api/memories/timeline/{year}/{month} - the "Month by month" hub entry. Same story as
  /// [memoriesCapable] and [eventsCapable]: a server predating it has no such routes at
  /// all, so the client hides that hub entry rather than opening a browse that can never
  /// load anything. Independent of the other two.
  final bool timelineCapable;

  factory ServerInfo.fromJson(Map<String, dynamic> j) => ServerInfo(
        name: j['name'] as String? ?? 'Check-In',
        initialized: j['initialized'] as bool? ?? false,
        color: j['color'] as String? ?? '',
        publicUrl: j['publicUrl'] as String?,
        mediaTypes: (j['mediaTypes'] as List?)?.map((e) => e as String).toList() ?? const ['image'],
        gifSearch: j['gifSearch'] as bool? ?? false,
        commentMedia: j['commentMedia'] as bool? ?? false,
        recapCapable: j['recap'] as bool? ?? false,
        recapCadence: j['recapCadence'] as String? ?? 'weekly',
        recapWeekday: (j['recapWeekday'] as num?)?.toInt() ?? 1,
        recapHour: (j['recapHour'] as num?)?.toInt() ?? 19,
        recapOffset: (j['recapOffset'] as num?)?.toInt() ?? 0,
        titlesCapable: j['titles'] as bool? ?? false,
        memoriesCapable: j['memories'] as bool? ?? false,
        eventsCapable: j['events'] as bool? ?? false,
        timelineCapable: j['timeline'] as bool? ?? false,
      );
}

/// One Klipy search/trending result, already projected down to what the picker and the
/// re-host flow need. Never carries a Klipy key - the proxy strips it before this ever
/// reaches the client.
class GifResult {
  const GifResult({
    required this.id,
    required this.title,
    required this.previewUrl,
    required this.previewWidth,
    required this.previewHeight,
    required this.gifUrl,
    required this.width,
    required this.height,
  });

  final String id;
  final String title;

  /// A small webp (or gif, when no webp rendition exists) the picker grid loads straight
  /// from static.klipy.com - the one place this feature hotlinks Klipy's CDN, and only
  /// because it's a user-initiated browse, never something the feed ends up serving.
  final String previewUrl;
  final int previewWidth;
  final int previewHeight;

  /// The full-resolution gif to download and re-upload once this result is picked. Never
  /// fetched until the user actually selects it.
  final String gifUrl;
  final int width;
  final int height;

  /// The stored preview aspect ratio, or null when the server reported no usable dimensions
  /// (falls back to a square tile in the grid).
  double? get previewAspectRatio =>
      previewWidth > 0 && previewHeight > 0 ? previewWidth / previewHeight : null;

  factory GifResult.fromJson(Map<String, dynamic> j) => GifResult(
        id: j['id'] as String? ?? '',
        title: j['title'] as String? ?? '',
        previewUrl: j['previewUrl'] as String? ?? '',
        previewWidth: (j['previewWidth'] as num?)?.toInt() ?? 0,
        previewHeight: (j['previewHeight'] as num?)?.toInt() ?? 0,
        gifUrl: j['gifUrl'] as String? ?? '',
        width: (j['width'] as num?)?.toInt() ?? 0,
        height: (j['height'] as num?)?.toInt() ?? 0,
      );
}

/// One page of gif results: the projected items plus whether another page exists.
class GifSearchPage {
  const GifSearchPage({required this.gifs, required this.hasNext});

  final List<GifResult> gifs;
  final bool hasNext;

  factory GifSearchPage.fromJson(Map<String, dynamic> j) => GifSearchPage(
        gifs: ((j['gifs'] as List?) ?? const [])
            .map((e) => GifResult.fromJson(e as Map<String, dynamic>))
            .toList(),
        hasNext: j['hasNext'] as bool? ?? false,
      );
}

/// One attachment on a post, with the type the server stored it as. The typed list is what
/// tells a renderer whether it is looking at a photo, an animated gif or a clip; the flat
/// [Post.mediaIds] cannot, and every renderer used to just assume "decodable image".
class PostMedia {
  const PostMedia({
    required this.id,
    required this.mime,
    this.width = 0,
    this.height = 0,
    this.durationMs = 0,
    this.hasPoster = false,
  });

  final int id;
  final String mime;

  /// Stored display dimensions (0 when the server didn't report them). They let a caller
  /// size a box before the bytes arrive, so the card doesn't jump on decode.
  final int width;
  final int height;

  /// Playing time for a timed medium; 0 for a still.
  final int durationMs;

  /// Whether a poster frame is stored for this clip. The server serves the clip itself for
  /// `?variant=poster` when there is none, so a renderer must check this rather than point
  /// an image widget at bytes that will never decode.
  final bool hasPoster;

  bool get isVideo => mime.startsWith('video/');
  bool get isImage => mime.startsWith('image/');
  bool get isGif => mime == 'image/gif';

  /// The stored aspect ratio, or null when the server reported no usable dimensions.
  double? get aspectRatio => width > 0 && height > 0 ? width / height : null;

  /// "0:10" - the clip's length, or '' when this isn't a timed medium. Rounded up so a
  /// sub-second clip reads as 0:01 rather than an alarming 0:00.
  String get durationLabel {
    if (durationMs <= 0) return '';
    final total = (durationMs / 1000).ceil();
    return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
  }

  /// Image-typed entries for a bare list of media ids: what a server predating the typed
  /// array returns, and what a context that is an image by construction (a profile photo)
  /// passes to a media renderer.
  static List<PostMedia> images(List<int> ids) =>
      [for (final id in ids) PostMedia(id: id, mime: _assumedMime)];

  /// Everything an old server could store was a still it had re-encoded, so any image type
  /// is a truthful stand-in; the renderers only ever branch on the `image/` prefix.
  static const _assumedMime = 'image/jpeg';

  factory PostMedia.fromJson(Map<String, dynamic> j) => PostMedia(
        id: (j['id'] as num).toInt(),
        mime: j['mime'] as String? ?? _assumedMime,
        width: (j['width'] as num?)?.toInt() ?? 0,
        height: (j['height'] as num?)?.toInt() ?? 0,
        durationMs: (j['durationMs'] as num?)?.toInt() ?? 0,
        hasPoster: j['hasPoster'] as bool? ?? false,
      );
}

class User {
  User({
    required this.id,
    required this.name,
    required this.phone,
    required this.isAdmin,
    this.firstName = '',
    this.lastName = '',
    this.profileMediaId,
    this.birthdayMonth = 0,
    this.birthdayDay = 0,
    this.title,
  });

  final int id;
  final String name; // display name
  final String firstName;
  final String lastName;
  final String phone;
  final bool isAdmin;
  final int? profileMediaId;

  /// The member's birthday month and day (1-based; 0 = unknown). The year is never sent by
  /// the server, so a member's age can't be derived - see [birthdayLabel].
  final int birthdayMonth;
  final int birthdayDay;

  /// The member's bestowed profile title (an award id, e.g. "quiet_achiever"), or null when
  /// none has ever been bestowed. See profile_screen.dart's title chip for the id-to-label
  /// mapping - an id this build doesn't recognise (a future server's new award) is rendered
  /// as nothing rather than a raw id.
  final String? title;

  factory User.fromJson(Map<String, dynamic> j) => User(
        id: j['id'] as int,
        name: j['name'] as String,
        firstName: j['firstName'] as String? ?? '',
        lastName: j['lastName'] as String? ?? '',
        phone: j['phone'] as String? ?? '',
        isAdmin: j['isAdmin'] as bool? ?? false,
        profileMediaId: j['profileMediaId'] as int?,
        birthdayMonth: (j['birthdayMonth'] as num?)?.toInt() ?? 0,
        birthdayDay: (j['birthdayDay'] as num?)?.toInt() ?? 0,
        title: j['title'] as String?,
      );

  /// The birthday as "March 14" (month and day only), or '' when unknown.
  String get birthdayLabel {
    if (birthdayMonth < 1 || birthdayDay < 1) return '';
    // 2000 is a leap year, so Feb 29 formats fine; only the month/day are used.
    return DateFormat.MMMMd().format(DateTime(2000, birthdayMonth, birthdayDay));
  }
}

class Post {
  Post({
    required this.id,
    required this.authorId,
    required this.authorName,
    required this.kind,
    required this.body,
    required this.createdAt,
    required this.likeCount,
    required this.commentCount,
    required this.likedByViewer,
    this.mediaId,
    this.mediaIds = const [],
    List<PostMedia> media = const [],
    this.authorPhotoId,
    this.location,
    this.commentsPreview = const [],
    this.people = const [],
    this.groupId,
    this.crossPostId,
    this.copies = const [],
    this.recap,
  }) : _media = media;

  final int id;
  final int authorId;
  final String authorName;
  // 'text' | 'image' | 'video', derived by the server from what is actually attached.
  // Branch on [media] instead: kind says nothing about which attachment is which.
  final String kind;
  final String body;
  final DateTime createdAt;
  final int likeCount;
  final int commentCount;
  final bool likedByViewer;
  final int? mediaId;
  final List<int> mediaIds;

  /// The typed attachments exactly as the server sent them - empty for a text post and for
  /// every server that predates the typed array. Read [media], not this.
  final List<PostMedia> _media;
  final int? authorPhotoId;
  final String? location; // coarse "City, Country", null for most posts
  final List<CommentPreview> commentsPreview;

  /// Members tagged as appearing in the post (id for filtering, name for display).
  final List<({int id, String name})> people;

  /// Which connected group (server) this post came from. Never sent by the server -
  /// the client stamps it when fetching, so likes/comments/images on this post can be
  /// routed back to the right server in the multi-group views.
  final String? groupId;

  /// Shared id tying this copy to the same post shared to other groups at once. Server-set
  /// (null for a single-group post). Used to collapse the copies into one card.
  final String? crossPostId;

  /// The copies of a collapsed cross-post, one per group the viewer can see it in
  /// (including this one). Empty for an ordinary post; populated client-side in the merged
  /// feed so likers/comments can fan out to each group's server.
  final List<PostCopy> copies;

  /// True once this post stands in for the same post shared to more than one shown group.
  bool get isCrossPost => copies.length > 1;

  /// The panel-deck payload for a kind == 'recap' post; null for every other post. Parsing
  /// never throws (see [Post.fromJson]) - a malformed or future-shaped payload just leaves
  /// this null and the post renders as a plain caption-only card.
  final RecapPayload? recap;

  /// Comment engagement across all copies (falls back to this copy's own count when not
  /// collapsed). Unlike likes, comments never need a same-viewer correction: a comment on a
  /// cross-post is only ever posted to the one group the commenter picked (see
  /// PostDetailScreen._send), so each comment is counted exactly once, on exactly one copy.
  /// Likes work differently - liking a cross-post likes every copy the viewer can reach - so
  /// their aggregate is computed by likeView, which corrects for that; see its doc comment.
  int get totalComments =>
      isCrossPost ? copies.fold(0, (s, c) => s + c.commentCount) : commentCount;

  /// Returns this post tagged with its origin group.
  Post withGroup(String groupId) => _copy(groupId: groupId);

  /// Returns this post standing in for the given set of cross-post copies.
  Post withCopies(List<PostCopy> copies) => _copy(copies: copies);

  Post _copy({String? groupId, List<PostCopy>? copies}) => Post(
        id: id,
        authorId: authorId,
        authorName: authorName,
        kind: kind,
        body: body,
        createdAt: createdAt,
        likeCount: likeCount,
        commentCount: commentCount,
        likedByViewer: likedByViewer,
        mediaId: mediaId,
        mediaIds: mediaIds,
        media: _media,
        authorPhotoId: authorPhotoId,
        location: location,
        commentsPreview: commentsPreview,
        people: people,
        groupId: groupId ?? this.groupId,
        crossPostId: crossPostId,
        copies: copies ?? this.copies,
        recap: recap,
      );

  /// The post's images in order. Prefers the multi-photo set, falling back to the legacy
  /// single cover so older posts still render.
  List<int> get images =>
      mediaIds.isNotEmpty ? mediaIds : (mediaId != null ? [mediaId!] : const []);

  /// The post's attachments in order, typed. A server that predates the typed array sends
  /// only ids, so those are synthesised as images - which is what they always were on such
  /// a server. Computed once: it is read on every rebuild of a card.
  late final List<PostMedia> media = _media.isNotEmpty ? _media : PostMedia.images(images);

  /// The attachments that are images: the ones a plain image widget can render and the
  /// device gallery can store as photos. A clip is neither.
  List<PostMedia> get imageMedia => [
        for (final m in media)
          if (m.isImage) m
      ];

  /// The attachments that are clips: saved to the gallery as videos, not photos.
  List<PostMedia> get videoMedia => [
        for (final m in media)
          if (m.isVideo) m
      ];

  /// Ids of the tagged members, for the feed's "include posts they're in" filter.
  List<int> get peopleIds => [for (final p in people) p.id];

  /// A short "with Bob & Carol" summary of the tagged people, or '' when none.
  String get peopleLabel {
    final names = [for (final p in people) p.name];
    if (names.isEmpty) return '';
    if (names.length == 1) return 'with ${names[0]}';
    if (names.length == 2) return 'with ${names[0]} & ${names[1]}';
    return 'with ${names[0]}, ${names[1]} & ${names.length - 2} others';
  }

  factory Post.fromJson(Map<String, dynamic> j) => Post(
        id: j['id'] as int,
        authorId: j['authorId'] as int,
        authorName: j['authorName'] as String? ?? '',
        kind: j['kind'] as String,
        body: j['body'] as String? ?? '',
        createdAt: DateTime.parse(j['createdAt'] as String),
        likeCount: j['likeCount'] as int? ?? 0,
        commentCount: j['commentCount'] as int? ?? 0,
        likedByViewer: j['likedByViewer'] as bool? ?? false,
        mediaId: j['mediaId'] as int?,
        mediaIds: ((j['mediaIds'] as List?) ?? const []).map((e) => e as int).toList(),
        media: ((j['media'] as List?) ?? const [])
            .map((e) => PostMedia.fromJson(e as Map<String, dynamic>))
            .toList(),
        authorPhotoId: j['authorPhotoId'] as int?,
        location: j['location'] as String?,
        commentsPreview: ((j['commentsPreview'] as List?) ?? [])
            .map((e) => CommentPreview.fromJson(e as Map<String, dynamic>))
            .toList(),
        people: ((j['people'] as List?) ?? const [])
            .map((e) => (
                  id: (e as Map<String, dynamic>)['id'] as int,
                  name: e['name'] as String,
                ))
            .toList(),
        crossPostId: j['crossPostId'] as String?,
        recap: _tryParseRecap(j['recap']),
      );

  /// Parses a recap payload defensively: a malformed or future-shaped payload (a server
  /// running a newer schema version) must never crash the feed - it just falls back to
  /// null, and the post renders as a plain caption-only card.
  static RecapPayload? _tryParseRecap(dynamic raw) {
    if (raw is! Map<String, dynamic>) return null;
    try {
      return RecapPayload.fromJson(raw);
    } catch (_) {
      return null;
    }
  }
}

/// A recap post's panel-deck payload: a denormalised snapshot (names, avatars and counts
/// frozen at generation time) rendered as a swipeable deck. [panels] holds only the panel
/// types this client recognises - [RecapPanel.tryParse] silently drops anything else, which
/// is what lets a v1.5+ server add new panel types without breaking this client.
class RecapPayload {
  RecapPayload({
    required this.periodLabel,
    required this.cadence,
    required this.groupName,
    required this.groupColor,
    required this.stats,
    required this.panels,
    this.people = const [],
  });

  final String periodLabel; // "Aug 10-16"
  final String cadence; // weekly | monthly | custom
  final String groupName;
  final String groupColor;
  final RecapStats stats;
  final List<RecapPanel> panels;

  /// The roster of everyone who posted this period, ordered by contribution desc - the
  /// cover's avatar-bubble cluster (see recap_card.dart's _BubbleCluster). Empty on a
  /// payload recorded before this field existed (the server's `people` key is absent
  /// entirely, not an empty array): the cover then falls back to its plain photo-only
  /// treatment rather than rendering an empty cluster.
  final List<RecapPerson> people;

  factory RecapPayload.fromJson(Map<String, dynamic> j) {
    final period = (j['period'] as Map?)?.cast<String, dynamic>() ?? const {};
    final group = (j['group'] as Map?)?.cast<String, dynamic>() ?? const {};
    final panels = <RecapPanel>[];
    for (final raw in (j['panels'] as List?) ?? const []) {
      if (raw is! Map<String, dynamic>) continue;
      final panel = RecapPanel.tryParse(raw);
      if (panel != null) panels.add(panel);
    }
    final people = <RecapPerson>[
      for (final raw in (j['people'] as List?) ?? const [])
        if (raw is Map<String, dynamic>) RecapPerson.fromJson(raw),
    ];
    return RecapPayload(
      periodLabel: period['label'] as String? ?? '',
      cadence: period['cadence'] as String? ?? '',
      groupName: group['name'] as String? ?? '',
      groupColor: group['color'] as String? ?? '',
      stats: RecapStats.fromJson((j['stats'] as Map?)?.cast<String, dynamic>() ?? const {}),
      panels: panels,
      people: people,
    );
  }
}

/// One member's contribution to a recap period: one bubble in the cover's avatar cluster.
class RecapPerson {
  RecapPerson({required this.userId, required this.name, this.photoId, this.posts = 0});

  final int userId;
  final String name;
  final int? photoId;

  /// This member's post count in the period - the metric the cover's bubble cluster scales
  /// bubble size by. See the server's recapPeople doc comment for why post count rather
  /// than a best-post like count.
  final int posts;

  factory RecapPerson.fromJson(Map<String, dynamic> j) => RecapPerson(
        userId: (j['userId'] as num?)?.toInt() ?? 0,
        name: j['name'] as String? ?? '',
        photoId: (j['photoId'] as num?)?.toInt(),
        posts: (j['posts'] as num?)?.toInt() ?? 0,
      );
}

/// The at-a-glance numbers shown above the deck.
class RecapStats {
  RecapStats({
    this.posts = 0,
    this.photos = 0,
    this.clips = 0,
    this.likes = 0,
    this.comments = 0,
    this.places = 0,
    this.members = 0,
  });

  final int posts;
  final int photos;
  final int clips;
  final int likes;
  final int comments;
  final int places;
  final int members;

  factory RecapStats.fromJson(Map<String, dynamic> j) => RecapStats(
        posts: (j['posts'] as num?)?.toInt() ?? 0,
        photos: (j['photos'] as num?)?.toInt() ?? 0,
        clips: (j['clips'] as num?)?.toInt() ?? 0,
        likes: (j['likes'] as num?)?.toInt() ?? 0,
        comments: (j['comments'] as num?)?.toInt() ?? 0,
        places: (j['places'] as num?)?.toInt() ?? 0,
        members: (j['members'] as num?)?.toInt() ?? 0,
      );
}

/// One page of a recap's deck. Only "collage" and "awards" exist in v1 - [tryParse] returns
/// null for anything else, so a panel type from a newer server is silently skipped rather
/// than thrown on.
sealed class RecapPanel {
  const RecapPanel({required this.title});

  final String title;

  static RecapPanel? tryParse(Map<String, dynamic> j) {
    final title = j['title'] as String? ?? '';
    switch (j['type'] as String?) {
      case 'collage':
        final cards = <RecapCard>[
          for (final e in (j['cards'] as List?) ?? const [])
            if (e is Map<String, dynamic>) RecapCard.fromJson(e),
        ];
        return RecapCollagePanel(title: title, cards: cards);
      case 'awards':
        final awards = <RecapAward>[
          for (final e in (j['awards'] as List?) ?? const [])
            if (e is Map<String, dynamic>) RecapAward.fromJson(e),
        ];
        return RecapAwardsPanel(title: title, awards: awards);
      default:
        return null;
    }
  }
}

/// "The Wall": the ranked collage of the period's best-received check-ins, guaranteed to
/// include every member who posted.
class RecapCollagePanel extends RecapPanel {
  const RecapCollagePanel({required super.title, required this.cards});

  final List<RecapCard> cards;
}

/// "Awards Night": the period's superlatives.
class RecapAwardsPanel extends RecapPanel {
  const RecapAwardsPanel({required super.title, required this.awards});

  final List<RecapAward> awards;
}

/// One card in the collage panel: a ranked photo or clip, or a quote card for a member
/// whose guaranteed slot is text-only.
class RecapCard {
  RecapCard({
    required this.kind,
    required this.rank,
    required this.guaranteed,
    required this.postId,
    required this.authorId,
    required this.authorName,
    this.authorPhotoId,
    int? mediaId,
    String mime = '',
    int width = 0,
    int height = 0,
    int durationMs = 0,
    bool hasPoster = false,
    this.body = '',
    this.likeCount = 0,
    this.commentCount = 0,
    this.location,
  }) : media = mediaId == null
            ? null
            : PostMedia(
                id: mediaId,
                mime: mime,
                width: width,
                height: height,
                durationMs: durationMs,
                hasPoster: hasPoster,
              );

  /// "photo" | "clip" | "quote".
  final String kind;
  final int rank;

  /// True when this card is the author's guaranteed slot (their single best post), rather
  /// than a fill-pass pick.
  final bool guaranteed;
  final int postId;
  final int authorId;
  final String authorName;
  final int? authorPhotoId;
  final String body; // quote card text; empty for photo/clip
  final int likeCount;
  final int commentCount;
  final String? location;

  /// The card's attachment as a typed [PostMedia], ready for [MediaFrame] - null for a
  /// quote card, which has none.
  final PostMedia? media;

  bool get isQuote => kind == 'quote';

  factory RecapCard.fromJson(Map<String, dynamic> j) => RecapCard(
        kind: j['kind'] as String? ?? 'quote',
        rank: (j['rank'] as num?)?.toInt() ?? 0,
        guaranteed: j['guaranteed'] as bool? ?? false,
        postId: (j['postId'] as num?)?.toInt() ?? 0,
        authorId: (j['authorId'] as num?)?.toInt() ?? 0,
        authorName: j['authorName'] as String? ?? '',
        authorPhotoId: (j['authorPhotoId'] as num?)?.toInt(),
        mediaId: (j['mediaId'] as num?)?.toInt(),
        mime: j['mime'] as String? ?? '',
        width: (j['w'] as num?)?.toInt() ?? 0,
        height: (j['h'] as num?)?.toInt() ?? 0,
        durationMs: (j['durationMs'] as num?)?.toInt() ?? 0,
        hasPoster: j['hasPoster'] as bool? ?? false,
        body: j['body'] as String? ?? '',
        likeCount: (j['likeCount'] as num?)?.toInt() ?? 0,
        commentCount: (j['commentCount'] as num?)?.toInt() ?? 0,
        location: j['location'] as String?,
      );
}

/// One superlative in the Awards Night panel.
class RecapAward {
  RecapAward({
    required this.id,
    required this.label,
    required this.userId,
    required this.userName,
    this.userPhotoId,
    required this.value,
    this.postId,
    this.mediaId,
  });

  final String id; // most_liked | night_owl | ...
  final String label;
  final int userId;
  final String userName;
  final int? userPhotoId;
  final String value; // "9 likes" - already formatted for display
  final int? postId;
  final int? mediaId;

  factory RecapAward.fromJson(Map<String, dynamic> j) => RecapAward(
        id: j['id'] as String? ?? '',
        label: j['label'] as String? ?? '',
        userId: (j['userId'] as num?)?.toInt() ?? 0,
        userName: j['userName'] as String? ?? '',
        userPhotoId: (j['userPhotoId'] as num?)?.toInt(),
        value: j['value'] as String? ?? '',
        postId: (j['postId'] as num?)?.toInt(),
        mediaId: (j['mediaId'] as num?)?.toInt(),
      );
}

/// One copy of a cross-post: which group's server holds it, that copy's post id, and its
/// own engagement (each group counts only its own members). The merged card sums these.
typedef PostCopy = ({
  String groupId,
  int postId,
  int likeCount,
  int commentCount,
  bool likedByViewer,
});

/// A lightweight comment (author + body) shown inline as a preview on feed cards.
class CommentPreview {
  CommentPreview(
      {required this.authorId, required this.authorName, required this.body, this.mediaId});

  final int authorId;
  final String authorName;
  final String body;

  /// The comment's gif attachment, if any. See [previewText] for how an empty body with
  /// media renders.
  final int? mediaId;

  /// What the preview line shows for this comment's content: the body, or "GIF" when the
  /// body is empty and a gif is attached (a gif-only comment has nothing else to preview).
  String get previewText => body.isEmpty && mediaId != null ? 'GIF' : body;

  factory CommentPreview.fromJson(Map<String, dynamic> j) => CommentPreview(
        authorId: (j['authorId'] as num?)?.toInt() ?? 0,
        authorName: j['authorName'] as String? ?? '',
        body: j['body'] as String? ?? '',
        mediaId: (j['mediaId'] as num?)?.toInt(),
      );
}

class Comment {
  Comment({
    required this.id,
    required this.authorId,
    required this.authorName,
    required this.body,
    required this.createdAt,
    this.authorPhotoId,
    this.groupId,
    this.parentCommentId,
    this.mediaId,
  });

  final int id;
  final int authorId;
  final String authorName;
  final String body;
  final DateTime createdAt;
  final int? authorPhotoId;

  /// Which group's server this comment came from. Client-stamped (like [Post.groupId]) when
  /// a cross-post's thread is merged, so each comment can show its group; null otherwise.
  final String? groupId;

  /// The comment this one replies to (same server), or null for a top-level comment. Used to
  /// show a "replying to X" line and to route a reply to the parent's group.
  final int? parentCommentId;

  /// A gif attached to this comment (re-hosted on this group's own server), or null. A
  /// comment may carry one with no body at all.
  final int? mediaId;

  Comment withGroup(String? groupId) => Comment(
        id: id,
        authorId: authorId,
        authorName: authorName,
        body: body,
        createdAt: createdAt,
        authorPhotoId: authorPhotoId,
        groupId: groupId,
        parentCommentId: parentCommentId,
        mediaId: mediaId,
      );

  factory Comment.fromJson(Map<String, dynamic> j) => Comment(
        id: j['id'] as int,
        authorId: (j['userId'] as num?)?.toInt() ?? 0,
        authorName: j['authorName'] as String? ?? '',
        body: j['body'] as String? ?? '',
        createdAt: DateTime.parse(j['createdAt'] as String),
        authorPhotoId: j['authorPhotoId'] as int?,
        parentCommentId: (j['parentCommentId'] as num?)?.toInt(),
        mediaId: (j['mediaId'] as num?)?.toInt(),
      );
}

/// One entry on the admin's invite list (allowlist). [used] is true once someone has
/// signed up with this number.
class Invite {
  Invite({required this.phone, required this.used, this.createdAt});

  final String phone;
  final bool used;
  final DateTime? createdAt;

  factory Invite.fromJson(Map<String, dynamic> j) => Invite(
        phone: j['phone'] as String? ?? '',
        used: j['used'] as bool? ?? false,
        createdAt: j['createdAt'] != null ? DateTime.tryParse(j['createdAt'] as String) : null,
      );
}

class Birthday {
  Birthday({required this.userId, required this.name, required this.month, required this.day});

  final int userId;
  final String name;
  final int month;
  final int day;

  factory Birthday.fromJson(Map<String, dynamic> j) => Birthday(
        userId: j['userId'] as int,
        name: j['name'] as String,
        month: j['month'] as int,
        day: j['day'] as int,
      );
}

/// A member's content report flagging objectionable content (visible to the admin).
class ContentReport {
  ContentReport({
    required this.id,
    required this.reporterId,
    required this.reporterName,
    required this.reason,
    required this.dismissed,
    required this.createdAt,
    this.postId,
    this.commentId,
    this.contentBody = '',
    this.authorName = '',
  });

  final int id;
  final int reporterId;
  final String reporterName;
  final int? postId;
  final int? commentId;
  final String reason;
  final bool dismissed;
  final String contentBody;
  final String authorName;
  final DateTime createdAt;

  factory ContentReport.fromJson(Map<String, dynamic> j) => ContentReport(
        id: j['id'] as int,
        reporterId: j['reporterId'] as int,
        reporterName: j['reporterName'] as String? ?? '',
        postId: j['postId'] as int?,
        commentId: j['commentId'] as int?,
        reason: j['reason'] as String? ?? '',
        dismissed: j['dismissed'] as bool? ?? false,
        contentBody: j['contentBody'] as String? ?? '',
        authorName: j['authorName'] as String? ?? '',
        createdAt: DateTime.parse(j['createdAt'] as String),
      );
}

/// A member's push settings: the three instant toggles, plus an optional daily digest that
/// replaces per-check-in pushes with a single summary at a chosen local hour.
class NotifyPrefs {
  const NotifyPrefs({
    required this.posts,
    required this.replies,
    required this.likes,
    required this.digestEnabled,
    required this.digestHour,
    required this.digestOffset,
  });

  final bool posts;
  final bool replies;
  final bool likes;

  /// When on, new-check-in pushes are replaced by one summary at [digestHour] (the
  /// member's local hour, 0-23). Replies and likes stay instant either way.
  final bool digestEnabled;
  final int digestHour;

  /// The member's UTC offset in minutes, which the server uses to work out when their
  /// chosen hour has arrived. The app refreshes it on launch so a DST shift self-corrects.
  final int digestOffset;

  /// "8:00 PM" - the digest time, for display.
  String get digestLabel => DateFormat.jm().format(DateTime(2000, 1, 1, digestHour));

  NotifyPrefs copyWith(
          {bool? posts, bool? replies, bool? likes, bool? digestEnabled, int? digestHour}) =>
      NotifyPrefs(
        posts: posts ?? this.posts,
        replies: replies ?? this.replies,
        likes: likes ?? this.likes,
        digestEnabled: digestEnabled ?? this.digestEnabled,
        digestHour: digestHour ?? this.digestHour,
        digestOffset: digestOffset,
      );

  factory NotifyPrefs.fromJson(Map<String, dynamic> j) => NotifyPrefs(
        posts: j['posts'] as bool? ?? true,
        replies: j['replies'] as bool? ?? true,
        likes: j['likes'] as bool? ?? true,
        digestEnabled: j['digestEnabled'] as bool? ?? false,
        digestHour: (j['digestHour'] as num?)?.toInt() ?? 20,
        digestOffset: (j['digestOffset'] as num?)?.toInt() ?? 0,
      );
}

/// One "Group trips" detected group event - a trip (the group somewhere none of them
/// call home) or a gathering (a concentrated get-together at home turf). See the server's
/// db/events_cluster.go for the whole detection algorithm this is a snapshot of.
class Event {
  Event({
    required this.kind,
    required this.place,
    required this.startDate,
    required this.endDate,
    required this.participants,
    required this.postIds,
    required this.photoCount,
    this.coverMediaId,
    this.groupId,
  });

  /// "trip" | "gathering".
  final String kind;
  final String place;
  final DateTime startDate;
  final DateTime endDate;
  final List<EventParticipant> participants;
  final List<int> postIds;
  final int photoCount;

  /// The most-liked photo in the event, or null when nothing in it has a photo at all (an
  /// all-text or all-clip event) - the card then falls back to a plain place/date cover.
  final int? coverMediaId;

  /// Which connected group this event came from. Never sent by the server (single-tenant
  /// per server) - the client stamps it when fetching, the same way [Post.groupId] is
  /// stamped, so the event's photos and "go to post" links route to the right server.
  final String? groupId;

  bool get isTrip => kind == 'trip';

  /// "Ada, Bea & 2 others" / "Ada" / "Ada & Bea" - the participant summary a card shows
  /// under the place/date line. Mirrors [Post.peopleLabel]'s own name-list shape but
  /// without the "with" prefix, since a card names who the EVENT belongs to, not who a
  /// post is with. Names the first two rather than just a count past two, since "friends"
  /// assumes a relationship the group may not have (family, roommates, etc).
  String get participantsLabel {
    final names = [for (final p in participants) p.name];
    if (names.isEmpty) return '';
    if (names.length == 1) return names[0];
    if (names.length == 2) return '${names[0]} & ${names[1]}';
    return '${names[0]}, ${names[1]} & ${names.length - 2} others';
  }

  Event withGroup(String groupId) => Event(
        kind: kind,
        place: place,
        startDate: startDate,
        endDate: endDate,
        participants: participants,
        postIds: postIds,
        photoCount: photoCount,
        coverMediaId: coverMediaId,
        groupId: groupId,
      );

  factory Event.fromJson(Map<String, dynamic> j) => Event(
        kind: j['kind'] as String? ?? 'trip',
        place: j['place'] as String? ?? '',
        startDate: DateTime.parse(j['startDate'] as String),
        endDate: DateTime.parse(j['endDate'] as String),
        participants: ((j['participants'] as List?) ?? const [])
            .map((e) => EventParticipant.fromJson(e as Map<String, dynamic>))
            .toList(),
        postIds: ((j['postIds'] as List?) ?? const []).map((e) => (e as num).toInt()).toList(),
        photoCount: (j['photoCount'] as num?)?.toInt() ?? 0,
        coverMediaId: (j['coverMediaId'] as num?)?.toInt(),
      );
}

/// One member who showed up in an [Event], ordered in [Event.participants] by
/// contribution (see the server's own buildEvent).
class EventParticipant {
  EventParticipant({required this.id, required this.name, this.photoId});

  final int id;
  final String name;
  final int? photoId;

  factory EventParticipant.fromJson(Map<String, dynamic> j) => EventParticipant(
        id: (j['id'] as num?)?.toInt() ?? 0,
        name: j['name'] as String? ?? '',
        photoId: (j['photoId'] as num?)?.toInt(),
      );
}

/// One calendar month of a group's history for the "Month by month" browse - see the
/// server's db/timeline.go for the whole aggregation and its month-bucketing convention.
class TimelineMonth {
  TimelineMonth({
    required this.year,
    required this.month,
    required this.postCount,
    required this.photoCount,
    required this.clipCount,
    required this.placeCount,
    required this.posterCount,
    this.coverMediaIds = const [],
    this.groupId,
  });

  final int year;
  final int month; // 1-12

  final int postCount;
  final int photoCount;
  final int clipCount;
  final int placeCount;
  final int posterCount;

  /// Up to a handful of the month's most-liked photos, most-liked first. A cover id whose
  /// post or media has since been deleted is not filtered out here - see _CoverStrip's own
  /// per-tile handling in memories_screen.dart, which degrades a single missing tile rather
  /// than failing the whole card.
  final List<int> coverMediaIds;

  /// Which connected group this month came from. Never sent by the server - the client
  /// stamps it when fetching, the same way [Event.groupId] and [Post.groupId] are, so a
  /// month's photos and posts route to the right server.
  final String? groupId;

  /// "August 2026" - what a month card's title and the month-detail header both read.
  String get label => DateFormat.yMMMM().format(DateTime(year, month));

  TimelineMonth withGroup(String groupId) => TimelineMonth(
        year: year,
        month: month,
        postCount: postCount,
        photoCount: photoCount,
        clipCount: clipCount,
        placeCount: placeCount,
        posterCount: posterCount,
        coverMediaIds: coverMediaIds,
        groupId: groupId,
      );

  factory TimelineMonth.fromJson(Map<String, dynamic> j) => TimelineMonth(
        year: (j['year'] as num?)?.toInt() ?? 0,
        month: (j['month'] as num?)?.toInt() ?? 1,
        postCount: (j['postCount'] as num?)?.toInt() ?? 0,
        photoCount: (j['photoCount'] as num?)?.toInt() ?? 0,
        clipCount: (j['clipCount'] as num?)?.toInt() ?? 0,
        placeCount: (j['placeCount'] as num?)?.toInt() ?? 0,
        posterCount: (j['posterCount'] as num?)?.toInt() ?? 0,
        coverMediaIds:
            ((j['coverMediaIds'] as List?) ?? const []).map((e) => (e as num).toInt()).toList(),
      );
}

/// Result of a successful login or signup.
class AuthResult {
  AuthResult({required this.token, required this.user});

  final String token;
  final User user;

  factory AuthResult.fromJson(Map<String, dynamic> j) => AuthResult(
        token: j['token'] as String,
        user: User.fromJson(j['user'] as Map<String, dynamic>),
      );
}
