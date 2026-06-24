import 'package:flutter/material.dart';

import '../../api/api_client.dart';
import '../../api/models.dart';
import '../../widgets/auth_image.dart';

/// UserSearchDelegate powers the top search bar: type a name, pick a person.
class UserSearchDelegate extends SearchDelegate<User?> {
  UserSearchDelegate(this._api);

  final ApiClient _api;

  @override
  String get searchFieldLabel => 'Search people';

  @override
  List<Widget> buildActions(BuildContext context) =>
      [if (query.isNotEmpty) IconButton(icon: const Icon(Icons.clear), onPressed: () => query = '')];

  @override
  Widget buildLeading(BuildContext context) =>
      IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => close(context, null));

  @override
  Widget buildResults(BuildContext context) => _results();

  @override
  Widget buildSuggestions(BuildContext context) => _results();

  Widget _results() {
    return FutureBuilder<List<User>>(
      future: _api.searchUsers(query),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final users = snap.data ?? [];
        if (users.isEmpty) return const Center(child: Text('No people found'));
        return ListView.builder(
          itemCount: users.length,
          itemBuilder: (context, i) {
            final u = users[i];
            return ListTile(
              leading: Avatar(name: u.name, mediaId: u.profileMediaId),
              title: Text(u.name),
              onTap: () => close(context, u),
            );
          },
        );
      },
    );
  }
}
