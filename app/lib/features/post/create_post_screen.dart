import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../state/app_state.dart';

/// CreatePostScreen lets a user share a text update or a photo with a caption.
class CreatePostScreen extends ConsumerStatefulWidget {
  const CreatePostScreen({super.key});

  @override
  ConsumerState<CreatePostScreen> createState() => _CreatePostScreenState();
}

class _CreatePostScreenState extends ConsumerState<CreatePostScreen> {
  final _body = TextEditingController();
  XFile? _image;
  bool _busy = false;
  String? _error;

  Future<void> _pickImage() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 90);
    if (x != null) setState(() => _image = x);
  }

  Future<void> _submit() async {
    if (_image == null && _body.text.trim().isEmpty) {
      setState(() => _error = 'Add a photo or write something first.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final api = ref.read(apiProvider);
      if (_image != null) {
        final mediaId = await api.uploadImage(_image!.path);
        await api.createPost(kind: 'image', body: _body.text.trim(), mediaId: mediaId);
      } else {
        await api.createPost(kind: 'text', body: _body.text.trim());
      }
      if (mounted) Navigator.of(context).pop(true);
    } on DioException catch (e) {
      final data = e.response?.data;
      setState(() => _error =
          (data is Map && data['error'] is String) ? data['error'] as String : 'Could not post.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('New check-in'),
        actions: [
          TextButton(
            onPressed: _busy ? null : _submit,
            child: _busy
                ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Share'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_image != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.file(File(_image!.path), height: 240, width: double.infinity, fit: BoxFit.cover),
            ),
          const SizedBox(height: 12),
          TextField(
            controller: _body,
            minLines: 3,
            maxLines: 8,
            decoration: InputDecoration(
              hintText: _image == null ? "What have you been up to?" : 'Add a caption…',
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            icon: const Icon(Icons.photo_outlined),
            label: Text(_image == null ? 'Add a photo' : 'Change photo'),
            onPressed: _pickImage,
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: Colors.red)),
          ],
        ],
      ),
    );
  }
}
