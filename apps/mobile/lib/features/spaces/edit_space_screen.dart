import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/widgets.dart';
import 'create_space_screen.dart';
import 'spaces_actions.dart';

class EditSpaceScreen extends ConsumerWidget {
  final String id;
  const EditSpaceScreen({super.key, required this.id});
  @override
  Widget build(BuildContext context, WidgetRef ref) => ref
      .watch(editSpaceProvider(id))
      .when(
        data: (x) => x.host
            ? CreateSpaceScreen(kind: x.kind, parentId: x.parentId, initial: x)
            : const Scaffold(
                body: Center(child: Text('Only hosts can edit this space')),
              ),
        loading: () => const Scaffold(body: VibeLoading()),
        error: (e, _) => Scaffold(
          appBar: AppBar(
            systemOverlayStyle: Theme.of(context).brightness == Brightness.dark
                ? SystemUiOverlayStyle.light
                : SystemUiOverlayStyle.dark,
            title: const Text('Edit space'),
          ),
          body: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              FailureCard(
                error: e,
                retry: () => ref.invalidate(editSpaceProvider(id)),
              ),
            ],
          ),
        ),
      );
}
