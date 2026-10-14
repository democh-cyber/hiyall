import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/state.dart';
import '../../core/user_error.dart';
import '../../shared/widgets.dart';
import 'space_form_fields.dart';
import 'space_format.dart';
import 'spaces_actions.dart';

class CreateSpaceScreen extends ConsumerStatefulWidget {
  final String kind;
  final String? parentId;
  final SocialSpace? initial;
  const CreateSpaceScreen({
    super.key,
    this.kind = 'community',
    this.parentId,
    this.initial,
  });
  @override
  ConsumerState<CreateSpaceScreen> createState() => _CreateSpaceState();
}

class _CreateSpaceState extends ConsumerState<CreateSpaceScreen> {
  final title = TextEditingController(),
      description = TextEditingController(),
      rules = TextEditingController(),
      capacity = TextEditingController(text: '50'),
      zone = TextEditingController(text: 'UTC'),
      location = TextEditingController();
  String visibility = 'public';
  late DateTime start, end;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    start = DateTime.now().add(const Duration(hours: 1));
    end = start.add(const Duration(hours: 1));
    if (widget.parentId != null) visibility = 'private';
    final x = widget.initial;
    if (x != null) {
      title.text = x.title;
      description.text = x.description;
      rules.text = x.rules;
      capacity.text = '${x.capacity}';
      zone.text = x.timezone;
      location.text = x.location;
      visibility = x.visibility;
      start = x.startsAt?.toLocal() ?? start;
      end = x.endsAt?.toLocal() ?? end;
    }
  }

  @override
  void dispose() {
    for (final c in [title, description, rules, capacity, zone, location]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> pick(bool first) async {
    final initial = first ? start : end;
    final date = await showDatePicker(
      context: context,
      initialDate:
          initial.isBefore(DateTime.now().subtract(const Duration(days: 1)))
          ? DateTime.now()
          : initial,
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (date == null || !mounted) return;
    final clock = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (clock == null || !mounted) return;
    setState(() {
      final d = DateTime(
        date.year,
        date.month,
        date.day,
        clock.hour,
        clock.minute,
      );
      if (first) {
        start = d;
        if (!end.isAfter(start)) end = start.add(const Duration(hours: 1));
      } else {
        end = d;
      }
    });
  }

  Future<void> save() async {
    final s = ref.read(sessionProvider).asData?.value;
    if (s == null) return;
    final n = int.tryParse(capacity.text);
    if (title.text.trim().isEmpty || n == null || n < 2 || n > 10000) {
      showMessage(context, 'Add a title and capacity of 2–10000.');
      return;
    }
    setState(() => busy = true);
    try {
      final body = <String, dynamic>{
        'kind': widget.kind,
        'title': title.text.trim(),
        'description': description.text.trim(),
        'rules': rules.text.trim(),
        'visibility': visibility,
        'capacity': n,
        'timezone': zone.text.trim(),
        'location': location.text.trim(),
        if (widget.parentId != null) 'parentId': widget.parentId,
        if (widget.kind != 'community')
          'startsAt': start.toUtc().toIso8601String(),
        if (widget.kind != 'community') 'endsAt': end.toUtc().toIso8601String(),
      };
      final a = ref.read(spaceActionsProvider);
      final x = widget.initial == null
          ? await a.create(s, body)
          : await a.update(s, widget.initial!.spaceId, body);
      if (mounted) {
        if (widget.initial != null) {
          context.pop();
        } else {
          context.replace('/spaces/${x.spaceId}');
        }
      }
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = spaceKindNames[widget.kind] ?? 'Space';
    final editing = widget.initial != null;
    return Scaffold(
      appBar: AppBar(
        systemOverlayStyle: Theme.of(context).brightness == Brightness.dark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
        title: Text('${editing ? 'Edit' : 'New'} ${name.toLowerCase()}'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          SpaceFormIntro(widget.kind),
          const SpaceFormSection('Basics'),
          SpaceBasicsFields(
            title: title,
            description: description,
            rules: rules,
          ),
          SpaceFormSection(
            'Who can join',
            hint: editing ? 'Set when the space is created.' : null,
          ),
          SpaceAccessFields(
            visibility: visibility,
            capacity: capacity,
            onVisibility: busy || editing
                ? null
                : (v) => setState(() => visibility = v!),
          ),
          if (widget.kind != 'community')
            SpaceWhenFields(
              kind: widget.kind,
              start: start,
              end: end,
              busy: busy,
              zone: zone,
              location: location,
              onPick: pick,
            ),
          const SizedBox(height: 24),
          const SpaceDiscussionNotice(),
          const SizedBox(height: 20),
          FilledButton(
            key: const Key('publish-space'),
            onPressed: busy ? null : save,
            child: Text(
              busy
                  ? 'Saving…'
                  : editing
                  ? 'Save changes'
                  : 'Create ${name.toLowerCase()}',
            ),
          ),
        ],
      ),
    );
  }
}
