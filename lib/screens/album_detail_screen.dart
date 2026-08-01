import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timesgaze/controllers/auth_controller.dart';
import 'package:timesgaze/repositories/auth_repositories.dart' show PickerAlbum;

class AlbumDetailScreen extends ConsumerStatefulWidget {
  final PickerAlbum album;
  const AlbumDetailScreen({required this.album, super.key});

  @override
  ConsumerState<AlbumDetailScreen> createState() => _AlbumDetailScreenState();
}

class _AlbumDetailScreenState extends ConsumerState<AlbumDetailScreen> {
  late Set<int> _disabledIndices;
  bool _hasChanges = false;

  @override
  void initState() {
    super.initState();
    _disabledIndices = Set<int>.from(widget.album.disabledPhotoIndices);
  }

  Future<void> _saveAndPop() async {
    if (_hasChanges) {
      await ref.read(authControllerProvider).updatePhotoSelection(
            widget.album.id,
            _disabledIndices.toList(),
          );
    }
    if (mounted) Navigator.pop(context);
  }

  void _togglePhoto(int index) {
    setState(() {
      if (_disabledIndices.contains(index)) {
        _disabledIndices.remove(index);
      } else {
        _disabledIndices.add(index);
      }
      _hasChanges = true;
    });
  }

  void _selectAll() {
    setState(() {
      _disabledIndices.clear();
      _hasChanges = true;
    });
  }

  void _deselectAll() {
    setState(() {
      _disabledIndices =
          Set.from(Iterable.generate(widget.album.photoPaths.length));
      _hasChanges = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.album.photoPaths.length;
    final enabledCount = total - _disabledIndices.length;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _saveAndPop();
      },
      child: Scaffold(
        backgroundColor: Colors.white,
        appBar: AppBar(
          backgroundColor: Colors.white,
          leading: BackButton(onPressed: _saveAndPop),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.album.name,
                  style: const TextStyle(fontSize: 16)),
              Text(
                '$enabledCount of $total selected',
                style:
                    const TextStyle(fontSize: 12, fontWeight: FontWeight.normal),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: _selectAll,
              child: const Text('All'),
            ),
            TextButton(
              onPressed: _deselectAll,
              child: const Text('None'),
            ),
          ],
        ),
        body: GridView.builder(
          padding: const EdgeInsets.all(4),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            crossAxisSpacing: 4,
            mainAxisSpacing: 4,
          ),
          itemCount: total,
          itemBuilder: (ctx, i) {
            final isSelected = !_disabledIndices.contains(i);
            return GestureDetector(
              onTap: () => _togglePhoto(i),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.file(
                    File(widget.album.photoPaths[i]),
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      color: Colors.grey[300],
                      child: const Icon(Icons.broken_image, color: Colors.grey),
                    ),
                  ),
                  if (!isSelected)
                    Container(color: Colors.black.withValues(alpha: 0.5)),
                  Positioned(
                    top: 6,
                    right: 6,
                    child: Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: isSelected
                            ? const Color.fromARGB(255, 245, 166, 75)
                            : Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isSelected
                              ? const Color.fromARGB(255, 245, 166, 75)
                              : Colors.grey,
                          width: 2,
                        ),
                        boxShadow: const [
                          BoxShadow(
                              color: Colors.black26,
                              blurRadius: 2,
                              offset: Offset(0, 1)),
                        ],
                      ),
                      child: isSelected
                          ? const Icon(Icons.check, size: 14, color: Colors.white)
                          : null,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
