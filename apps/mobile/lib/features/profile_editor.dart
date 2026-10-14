import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api.dart';
import '../core/avatar_upload.dart';
import '../core/profile_labels.dart';
import '../core/state.dart';
import '../core/theme.dart';
import '../shared/avatar_sheet.dart';
import '../shared/person_avatar.dart';
import '../shared/widgets.dart';
import '../core/user_error.dart';

class ProfileForm extends ConsumerStatefulWidget {
  final Profile profile;

  /// Asked to load the newest profile and start the form over, after another
  /// device changed it. Without one, the profile is just reloaded.
  final VoidCallback? onReload;
  const ProfileForm({super.key, required this.profile, this.onReload});
  @override
  ConsumerState<ProfileForm> createState() => _ProfileFormState();
}

class _ProfileFormState extends ConsumerState<ProfileForm> {
  final form = GlobalKey<FormState>();
  late final name = TextEditingController(text: widget.profile.displayName);
  late final username = TextEditingController(text: widget.profile.username);
  late final headline = TextEditingController(text: widget.profile.headline);
  late final quote = TextEditingController(text: widget.profile.quote);
  late final bio = TextEditingController(text: widget.profile.bio);
  late final profession = TextEditingController(
    text: widget.profile.profession,
  );
  late final pronouns = TextEditingController(text: widget.profile.pronouns);
  late final vibe = TextEditingController(text: widget.profile.currentVibe);
  final interest = TextEditingController();
  late String gender =
      const ['woman', 'man', 'nonbinary'].contains(widget.profile.gender)
      ? widget.profile.gender
      : '';
  late String? country = widget.profile.country;
  late final languages = [...widget.profile.languages];
  late final interests = [...widget.profile.interests];
  late String accent =
      ['lime', 'violet', 'cyan'].contains(widget.profile.profileAccent)
      ? widget.profile.profileAccent
      : 'lime';
  late String pattern =
      ['glow', 'orbit', 'plain'].contains(widget.profile.profilePattern)
      ? widget.profile.profilePattern
      : 'glow';
  late String frame = ['minimal', 'orbit'].contains(widget.profile.avatarFrame)
      ? widget.profile.avatarFrame
      : 'minimal';
  bool busy = false, conflict = false;
  String? error;

  /// The profile as last seen by this form. A photo change moves its version
  /// on, and the next Save must carry that version.
  late Profile current = widget.profile;
  late final avatar = AvatarUploadController(ref.read(imagePickerProvider));
  bool attaching = false;
  String? avatarError, uploadedId;

  bool get avatarWorking => avatar.uploading || attaching;

  @override
  void initState() {
    super.initState();
    avatar.addListener(_avatarChanged);
  }

  void _avatarChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(ProfileForm old) {
    super.didUpdateWidget(old);
    // The same version again means our own photo change was read back; take
    // it for its fresh photo URLs. A different one is someone else's edit, and
    // is left to the conflict path so their changes aren't overwritten.
    if (widget.profile.version == current.version) current = widget.profile;
  }

  @override
  void dispose() {
    avatar.dispose();
    for (final controller in [
      name,
      username,
      headline,
      bio,
      quote,
      profession,
      pronouns,
      vibe,
      interest,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> save() async {
    if (busy || !form.currentState!.validate()) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await ref.read(apiProvider).updateProfile(
        ref.read(sessionProvider).asData!.value!,
        current,
        {
          'displayName': name.text.trim(),
          'username': username.text.trim(),
          'headline': headline.text.trim(),
          'bio': bio.text.trim(),
          'quote': quote.text.trim(),
          'profession': profession.text.trim(),
          'pronouns': pronouns.text.trim(),
          'gender': gender,
          'country': country,
          'languages': languages.map((v) => v.toJson()).toList(),
          'interests': interests,
          'currentVibe': vibe.text.trim(),
          'profileAccent': accent,
          'profilePattern': pattern,
          'avatarFrame': frame,
        },
      );
      ref.invalidate(profileProvider);
      if (mounted) {
        showMessage(context, 'Profile saved.');
        context.go('/profile');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = friendlyError(e);
          conflict = e is ApiFailure && e.status == 412;
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> chooseAvatar() async {
    if (busy || avatarWorking) return;
    final action = await showAvatarSheet(
      context,
      hasPhoto: current.avatarUrl != null || avatar.photo != null,
    );
    if (action == null || !mounted) return;
    setState(() => avatarError = null);
    switch (action) {
      case AvatarAction.gallery || AvatarAction.camera:
        final picked = await avatar.pick(
          action == AvatarAction.camera
              ? AvatarSource.camera
              : AvatarSource.gallery,
        );
        if (picked != null) {
          uploadedId = null;
          await sendAvatar();
        }
      case AvatarAction.remove:
        await removeAvatar();
    }
  }

  /// Uploads the chosen photo, then makes it the profile photo. A failed
  /// attach keeps the upload, so trying again doesn't send the photo twice.
  Future<void> sendAvatar() async {
    final session = ref.read(sessionProvider).asData?.value;
    if (session == null || avatar.photo == null || avatarWorking) return;
    setState(() => avatarError = null);
    final api = ref.read(apiProvider);
    final id = uploadedId ?? await avatar.upload(api, session);
    if (id == null || !mounted) return;
    uploadedId = id;
    setState(() => attaching = true);
    try {
      current = await api.setAvatar(session, current, id);
      uploadedId = null;
      avatar.clear();
      ref.invalidate(profileProvider);
      if (mounted) showMessage(context, 'Photo updated.');
    } on ApiFailure catch (failure) {
      if (mounted) setState(() => avatarError = failure.message);
    } finally {
      if (mounted) setState(() => attaching = false);
    }
  }

  Future<void> removeAvatar() async {
    final session = ref.read(sessionProvider).asData?.value;
    if (session == null) return;
    uploadedId = null;
    avatar.clear();
    if (current.avatarUrl == null) return;
    setState(() => attaching = true);
    try {
      current = await ref.read(apiProvider).setAvatar(session, current, null);
      ref.invalidate(profileProvider);
      if (mounted) showMessage(context, 'Photo removed.');
    } on ApiFailure catch (failure) {
      if (mounted) setState(() => avatarError = failure.message);
    } finally {
      if (mounted) setState(() => attaching = false);
    }
  }

  Widget _avatarEditor() {
    final scheme = Theme.of(context).colorScheme;
    final failure = avatar.error?.message ?? avatarError;
    return Column(
      children: [
        Semantics(
          button: true,
          label: 'Change profile photo',
          excludeSemantics: true,
          child: InkWell(
            key: const Key('edit-avatar'),
            customBorder: const CircleBorder(),
            onTap: busy || avatarWorking ? null : chooseAvatar,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                PersonAvatar(
                  name: current.displayName,
                  bytes: avatar.photo?.bytes,
                  avatarUrl: current.avatarFor(112),
                  userId: current.userId,
                  radius: 56,
                ),
                if (avatarWorking)
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.black38,
                      ),
                      child: Center(
                        child: CircularProgressIndicator(
                          key: const Key('avatar-progress'),
                          value: avatar.uploading && avatar.progress > 0
                              ? avatar.progress
                              : null,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: VibeColors.lime,
                      shape: BoxShape.circle,
                      border: Border.all(color: scheme.surface, width: 3),
                    ),
                    child: const Icon(
                      Icons.photo_camera_rounded,
                      size: 18,
                      color: VibeColors.ink,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        if (avatar.uploading)
          TextButton(
            key: const Key('avatar-cancel'),
            onPressed: avatar.clear,
            child: const Text('Cancel'),
          )
        else
          Text(
            'Your photo is public, like the rest of your profile.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        if (failure != null) ...[
          const SizedBox(height: 8),
          Text(
            failure,
            key: const Key('avatar-error'),
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.error),
          ),
          if (avatar.photo != null && (avatar.error?.canRetry ?? true))
            TextButton(
              key: const Key('avatar-retry'),
              onPressed: avatarWorking ? null : sendAvatar,
              child: const Text('Try again'),
            ),
        ],
      ],
    );
  }

  void addInterest(String value) {
    value = value.trim();
    if (value.isEmpty) return;
    if (interests.any((item) => item.toLowerCase() == value.toLowerCase())) {
      return;
    }
    if (interests.length >= 10) {
      showMessage(context, 'Choose up to ten interests.');
      return;
    }
    if (value.runes.length > 40) {
      showMessage(context, 'Keep each interest to 40 characters.');
      return;
    }
    setState(() {
      interests.add(value);
      interest.clear();
    });
  }

  @override
  Widget build(BuildContext context) => ListView(
    keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
    padding: const EdgeInsets.all(24),
    children: [
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton.icon(
          onPressed: busy ? null : () => context.go('/profile'),
          icon: const Icon(Icons.arrow_back),
          label: const Text('Profile'),
        ),
      ),
      const PageHeader(
        eyebrow: 'Make it yours',
        title: 'A little more you.',
        subtitle: 'Your personality, in your own words.',
      ),
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: _avatarEditor(),
      ),
      Form(
        key: form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _heading('Your identity'),
            _field(
              name,
              'Display name',
              80,
              validator: (value) => value == null || value.trim().isEmpty
                  ? 'Enter a display name.'
                  : null,
            ),
            _field(
              username,
              'Username',
              30,
              validator: (value) =>
                  RegExp(r'^[a-z0-9_]{3,30}$').hasMatch(value?.trim() ?? '')
                  ? null
                  : 'Use 3–30 lowercase letters, numbers or underscores.',
              prefix: '@',
            ),
            _field(headline, 'Headline', 100),
            _field(bio, 'Bio', 300, lines: 3),
            _field(quote, 'A little quote (optional)', 160, lines: 2),
            const Text(
              'Your headline, bio and quote follow your profile visibility.',
              style: TextStyle(fontSize: 12, height: 1.6),
            ),
            _heading('About me'),
            _field(profession, 'Profession', 100),
            _field(pronouns, 'Pronouns', 40),
            _choice('Gender', gender, const {
              '': 'Prefer not to say',
              'woman': 'Woman',
              'man': 'Man',
              'nonbinary': 'Non-binary',
            }, (v) => gender = v),
            Card(
              child: ListTile(
                enabled: !busy,
                leading: const Icon(Icons.public_rounded),
                title: const Text('Country'),
                subtitle: Text(countryNames[country] ?? 'Not added'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () async {
                  final result = await pickProfileLabel(
                    context,
                    'Choose your country',
                    countryNames,
                    allowClear: true,
                  );
                  if (result != null && mounted) {
                    setState(() => country = result.isEmpty ? null : result);
                  }
                },
              ),
            ),
            _heading('Languages'),
            for (var i = 0; i < languages.length; i++) _language(i),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: OutlinedButton.icon(
                onPressed: busy || languages.length >= 9
                    ? null
                    : () async {
                        final available = Map<String, String>.fromEntries(
                          languageNames.entries.where(
                            (e) =>
                                e.key.length == 2 &&
                                !languages.any(
                                  (l) => l.code.toLowerCase() == e.key,
                                ),
                          ),
                        );
                        final result = await pickProfileLabel(
                          context,
                          'Add a language',
                          available,
                        );
                        if (result != null && mounted) {
                          setState(
                            () => languages.add(ProfileLanguage(result)),
                          );
                        }
                      },
                icon: const Icon(Icons.add_rounded),
                label: const Text('Add language'),
              ),
            ),
            _heading('My interests'),
            if (interests.isNotEmpty)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final item in interests)
                    InputChip(
                      label: Text(item),
                      onDeleted: busy
                          ? null
                          : () => setState(() => interests.remove(item)),
                    ),
                ],
              ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final item in [
                  'Music',
                  'Technology',
                  'Travel',
                  'Photography',
                  'Finance',
                  'Movies',
                  'Art',
                  'Gaming',
                  'Reading',
                  'Fitness',
                  'Food',
                  'Nature',
                ])
                  if (!interests.any(
                    (v) => v.toLowerCase() == item.toLowerCase(),
                  ))
                    ActionChip(
                      label: Text(item),
                      onPressed: busy ? null : () => addInterest(item),
                    ),
              ],
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: interest,
              enabled: !busy,
              maxLength: 40,
              decoration: InputDecoration(
                labelText: 'Add your own interest',
                suffixIcon: IconButton(
                  tooltip: 'Add interest',
                  onPressed: busy ? null : () => addInterest(interest.text),
                  icon: const Icon(Icons.add_rounded),
                ),
              ),
              onFieldSubmitted: busy ? null : addInterest,
            ),
            Text(
              '${interests.length} of 10 · Your first interests lead the way.',
              style: const TextStyle(fontSize: 12),
            ),
            _heading('Current Vibe'),
            _field(vibe, 'What’s your vibe?', 80),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final item in [
                  '🎧 Listening to music',
                  '☕ Coffee + work',
                  '📚 Reading',
                  '✈️ Travel mode',
                  '🎮 Gaming',
                  '🌿 Taking it slow',
                ])
                  ActionChip(
                    label: Text(item),
                    onPressed: busy
                        ? null
                        : () => setState(() => vibe.text = item),
                  ),
              ],
            ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                onPressed: busy ? null : () => setState(() => vibe.clear()),
                child: const Text('Turn my vibe off'),
              ),
            ),
            _heading('Your signature'),
            _choice('Profile accent', accent, const {
              'lime': 'Electric lime',
              'violet': 'Soft violet',
              'cyan': 'Quiet cyan',
            }, (value) => accent = value),
            _choice('Profile background', pattern, const {
              'glow': 'Ambient glow',
              'orbit': 'Soft orbit',
              'plain': 'Minimal',
            }, (value) => pattern = value),
            _choice('Avatar frame', frame, const {
              'minimal': 'Clean border',
              'orbit': 'Accent outline',
            }, (value) => frame = value),
            const SizedBox(height: 16),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (conflict)
              TextButton(
                onPressed:
                    widget.onReload ?? () => ref.invalidate(profileProvider),
                child: const Text('Reload latest profile'),
              ),
            FilledButton(
              onPressed: busy || conflict || avatarWorking ? null : save,
              child: Text(busy ? 'Saving…' : 'Save profile'),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    ],
  );
  Widget _heading(String text) => Padding(
    padding: const EdgeInsets.only(top: 24, bottom: 16),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: 21),
    ),
  );
  Widget _field(
    TextEditingController controller,
    String label,
    int max, {
    String? Function(String?)? validator,
    String? prefix,
    int lines = 1,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: TextFormField(
      controller: controller,
      enabled: !busy,
      maxLength: max,
      minLines: lines,
      maxLines: lines == 1 ? 1 : 6,
      decoration: InputDecoration(labelText: label, prefixText: prefix),
      validator: validator,
    ),
  );
  Widget _choice(
    String label,
    String value,
    Map<String, String> values,
    ValueChanged<String> update,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: DropdownButtonFormField<String>(
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: values.entries
          .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
          .toList(),
      onChanged: busy
          ? null
          : (v) {
              if (v != null) setState(() => update(v));
            },
    ),
  );
  Widget _language(int index) {
    final language = languages[index];
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  languageLabel(language.code),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                tooltip: 'Remove ${languageLabel(language.code)}',
                onPressed: busy
                    ? null
                    : () => setState(() => languages.removeAt(index)),
                icon: const Icon(Icons.close_rounded, size: 18),
              ),
            ],
          ),
          DropdownButtonFormField<String>(
            key: ValueKey('level-${language.code}-${language.level}'),
            initialValue: language.level,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Proficiency'),
            items: languageLevels.entries
                .map(
                  (e) => DropdownMenuItem(value: e.key, child: Text(e.value)),
                )
                .toList(),
            onChanged: busy
                ? null
                : (value) {
                    if (value != null) {
                      setState(
                        () => languages[index] = ProfileLanguage(
                          language.code,
                          value,
                        ),
                      );
                    }
                  },
          ),
        ],
      ),
    );
  }
}

Future<String?> pickProfileLabel(
  BuildContext context,
  String title,
  Map<String, String> labels, {
  bool allowClear = false,
}) => showModalBottomSheet<String>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (sheet) {
    var query = '';
    final entries = labels.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    return StatefulBuilder(
      builder: (context, setState) => SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * .65,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: TextField(
                    decoration: const InputDecoration(
                      labelText: 'Search',
                      prefixIcon: Icon(Icons.search_rounded),
                    ),
                    onChanged: (value) =>
                        setState(() => query = value.trim().toLowerCase()),
                  ),
                ),
                if (allowClear)
                  TextButton(
                    onPressed: () => Navigator.pop(sheet, ''),
                    child: const Text('Remove country'),
                  ),
                Expanded(
                  child: ListView(
                    children: [
                      for (final entry in entries.where(
                        (e) => e.value.toLowerCase().contains(query),
                      ))
                        ListTile(
                          title: Text(entry.value),
                          onTap: () => Navigator.pop(sheet, entry.key),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  },
);
