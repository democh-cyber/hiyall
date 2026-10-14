import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api.dart';
import '../core/avatar_upload.dart';
import '../core/state.dart';
import '../core/user_error.dart';
import '../shared/widgets.dart';
import 'profile_editor/profile_avatar_controller.dart';
import 'profile_editor/profile_avatar_editor.dart';
import 'profile_editor/profile_editor_actions.dart';
import 'profile_editor/profile_form_fields.dart';
import 'profile_editor/profile_identity_section.dart';
import 'profile_editor/profile_interests_section.dart';
import 'profile_editor/profile_languages_section.dart';
import 'profile_editor/profile_save_bar.dart';
import 'profile_editor/profile_vibe_section.dart';

export 'profile_editor/profile_label_picker.dart' show pickProfileLabel;

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
  late final fields = ProfileFormFields(widget.profile);
  bool busy = false, conflict = false;
  String? error;
  late final avatar = ProfileAvatarController(
    ref.read(profileEditorActionsProvider),
    ref.read(imagePickerProvider),
    widget.profile,
    onMessage: (message) {
      if (mounted) showMessage(context, message);
    },
  );

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
    avatar.adopt(widget.profile);
  }

  @override
  void dispose() {
    avatar.dispose();
    fields.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (busy || !form.currentState!.validate()) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final actions = ref.read(profileEditorActionsProvider);
      await actions.saveProfile(avatar.current, fields.patch());
      actions.invalidateProfile();
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

  void addInterest(String value) {
    value = value.trim();
    if (value.isEmpty) return;
    final interests = fields.interests;
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
      fields.interest.clear();
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
        child: ProfileAvatarEditor(controller: avatar, busy: busy),
      ),
      Form(
        key: form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ProfileIdentitySection(
              name: fields.name,
              username: fields.username,
              headline: fields.headline,
              bio: fields.bio,
              quote: fields.quote,
              enabled: !busy,
            ),
            ProfileAboutSection(
              profession: fields.profession,
              pronouns: fields.pronouns,
              gender: fields.gender,
              country: fields.country,
              enabled: !busy,
              onGender: (v) => setState(() => fields.gender = v),
              onCountry: (v) => setState(() => fields.country = v),
            ),
            ProfileLanguagesSection(
              languages: fields.languages,
              enabled: !busy,
              onAdd: (code) =>
                  setState(() => fields.languages.add(ProfileLanguage(code))),
              onRemove: (i) => setState(() => fields.languages.removeAt(i)),
              onLevel: (i, level) => setState(
                () => fields.languages[i] = ProfileLanguage(
                  fields.languages[i].code,
                  level,
                ),
              ),
            ),
            ProfileInterestsSection(
              interests: fields.interests,
              controller: fields.interest,
              enabled: !busy,
              onAdd: addInterest,
              onRemove: (item) => setState(() => fields.interests.remove(item)),
            ),
            ProfileVibeSection(
              controller: fields.vibe,
              enabled: !busy,
              onPick: (item) => setState(() => fields.vibe.text = item),
              onClear: () => setState(() => fields.vibe.clear()),
            ),
            ProfileSignatureSection(
              accent: fields.accent,
              pattern: fields.pattern,
              frame: fields.frame,
              enabled: !busy,
              onAccent: (v) => setState(() => fields.accent = v),
              onPattern: (v) => setState(() => fields.pattern = v),
              onFrame: (v) => setState(() => fields.frame = v),
            ),
            ProfileSaveBar(
              error: error,
              conflict: conflict,
              busy: busy,
              canSave: !(busy || conflict || avatar.working),
              onReload:
                  widget.onReload ?? () => ref.invalidate(profileProvider),
              onSave: save,
            ),
          ],
        ),
      ),
    ],
  );
}
