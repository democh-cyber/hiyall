import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme.dart';
import '../../shared/widgets.dart';
import 'space_format.dart';
import 'space_parts.dart';

const _gap = SizedBox(height: 14);

/// Section heading with an optional hint, used between form groups.
class SpaceFormSection extends StatelessWidget {
  final String title;
  final String? hint;
  const SpaceFormSection(this.title, {super.key, this.hint});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 12, bottom: 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        if (hint != null) ...[
          const SizedBox(height: 4),
          Text(
            hint!,
            style: TextStyle(
              fontSize: 13,
              height: 1.5,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    ),
  );
}

/// The badge and one-line pitch at the top of the create/edit form.
class SpaceFormIntro extends StatelessWidget {
  final String kind;
  const SpaceFormIntro(this.kind, {super.key});
  @override
  Widget build(BuildContext context) => Row(
    children: [
      SpaceKindBadge(kind, size: 44),
      const SizedBox(width: 14),
      Expanded(
        child: Text(
          kind == 'community'
              ? 'A home for people who share a thing.'
              : kind == 'moment'
              ? 'A short, timed get-together that ends on schedule.'
              : 'A plan to meet, online or in person.',
          style: Theme.of(context).textTheme.bodyLarge,
        ),
      ),
    ],
  );
}

/// Name, about and rules.
class SpaceBasicsFields extends StatelessWidget {
  final TextEditingController title, description, rules;
  const SpaceBasicsFields({
    super.key,
    required this.title,
    required this.description,
    required this.rules,
  });
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      TextField(
        key: const Key('space-title'),
        controller: title,
        maxLength: 80,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(
          labelText: 'Name',
          hintText: 'Give it a name',
        ),
      ),
      _gap,
      TextField(
        controller: description,
        maxLength: 2000,
        maxLines: 4,
        minLines: 2,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(
          labelText: 'About',
          hintText: 'What brings people here?',
          alignLabelWithHint: true,
        ),
      ),
      _gap,
      TextField(
        controller: rules,
        maxLength: 2000,
        maxLines: 3,
        minLines: 2,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(
          labelText: 'Rules',
          hintText: 'Rules for your circle',
          alignLabelWithHint: true,
        ),
      ),
    ],
  );
}

/// Access level and capacity. [onVisibility] is null when it cannot change.
class SpaceAccessFields extends StatelessWidget {
  final String visibility;
  final ValueChanged<String?>? onVisibility;
  final TextEditingController capacity;
  const SpaceAccessFields({
    super.key,
    required this.visibility,
    required this.onVisibility,
    required this.capacity,
  });
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      DropdownButtonFormField<String>(
        initialValue: visibility,
        decoration: const InputDecoration(labelText: 'Access'),
        items: const [
          DropdownMenuItem(
            value: 'public',
            child: Text('Public · join instantly'),
          ),
          DropdownMenuItem(
            value: 'private',
            child: Text('Private · host approves'),
          ),
          DropdownMenuItem(value: 'invite', child: Text('Invite only')),
        ],
        onChanged: onVisibility,
      ),
      _gap,
      TextField(
        controller: capacity,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: const InputDecoration(
          labelText: 'Capacity',
          helperText: 'Includes you as the host · 2 to 10000',
        ),
      ),
    ],
  );
}

/// Start and end pickers, time zone and (for events) the place.
class SpaceWhenFields extends StatelessWidget {
  final String kind;
  final DateTime start, end;
  final bool busy;
  final TextEditingController zone, location;
  final ValueChanged<bool> onPick;
  const SpaceWhenFields({
    super.key,
    required this.kind,
    required this.start,
    required this.end,
    required this.busy,
    required this.zone,
    required this.location,
    required this.onPick,
  });
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SpaceFormSection(
        'When',
        hint: 'Pick times in your device’s local time. The host zone is saved alongside UTC.',
      ),
      Row(
        children: [
          _WhenButton('Starts', start, busy ? null : () => onPick(true)),
          const SizedBox(width: 12),
          _WhenButton('Ends', end, busy ? null : () => onPick(false)),
        ],
      ),
      _gap,
      TextField(
        controller: zone,
        decoration: const InputDecoration(
          labelText: 'Host time zone',
          helperText: 'IANA name, e.g. Asia/Kolkata',
        ),
      ),
      if (kind == 'event') ...[
        _gap,
        TextField(
          controller: location,
          maxLength: 240,
          decoration: const InputDecoration(
            labelText: 'Where',
            hintText: 'Online link or meeting place',
          ),
        ),
      ],
    ],
  );
}

class _WhenButton extends StatelessWidget {
  final String label;
  final DateTime at;
  final VoidCallback? onPressed;
  const _WhenButton(this.label, this.at, this.onPressed);
  @override
  Widget build(BuildContext context) => Expanded(
    child: OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        alignment: AlignmentDirectional.centerStart,
        padding: const EdgeInsets.all(14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(VibeRadius.input),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            spaceDay(at),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          Text(spaceClock(at)),
        ],
      ),
    ),
  );
}

/// Reminder that discussion boards are not end-to-end encrypted.
class SpaceDiscussionNotice extends StatelessWidget {
  const SpaceDiscussionNotice({super.key});
  @override
  Widget build(BuildContext context) => const VibePanel(
    color: VibeColors.lilac,
    padding: EdgeInsets.all(16),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.info_outline_rounded, color: VibeColors.ink),
        SizedBox(width: 12),
        Expanded(
          child: Text(
            'Discussion boards are shared content readable by members and the service. Use encrypted chat for private conversations.',
            style: TextStyle(color: VibeColors.ink, height: 1.5),
          ),
        ),
      ],
    ),
  );
}
