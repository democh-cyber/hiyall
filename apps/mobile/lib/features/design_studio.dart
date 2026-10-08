import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app.dart';
import '../core/state.dart';
import '../core/theme.dart';
import '../shared/widgets.dart';
import '../shared/navigation_dock.dart';
import '../shared/studio_widgets.dart';
import 'design_catalog.dart';
import 'people_filters.dart';

export '../shared/studio_widgets.dart';
export 'design_catalog.dart';

class DesignStudioScreen extends StatefulWidget {
  const DesignStudioScreen({super.key});
  @override
  State<DesignStudioScreen> createState() => _DesignStudioState();
}

class _DesignStudioState extends State<DesignStudioScreen> {
  String query = '';
  @override
  Widget build(BuildContext context) {
    final groups = designScreens.map((s) => s.group).toSet();
    return Scaffold(
      body: SafeArea(
        child: ReadingWidth(
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Row(
                children: [
                  const BrandMark(),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'kairova / studio',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Back to the app',
                    onPressed: () => context.go('/home'),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 30),
              const VibeHero(
                tag: 'The full experience / design preview',
                title: 'Your space.\nEvery little part.',
                subtitle: 'Explore the complete screen system. These previews use sample layouts and local interactions. Account features live in the main app.',
                art: 'discover',
              ),
              const SizedBox(height: 24),
              TextField(
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search_rounded),
                  labelText: 'Find a screen',
                ),
                onChanged: (value) =>
                    setState(() => query = value.toLowerCase()),
              ),
              for (final group in groups) ...[
                if (designScreens.any(
                  (s) =>
                      s.group == group &&
                      '${s.title} ${s.id} ${s.group}'.toLowerCase().contains(
                        query,
                      ),
                )) ...[
                  SectionTitle(group, label: 'SCREEN COLLECTION'),
                  LayoutBuilder(
                    builder: (context, box) {
                      final columns =
                          box.maxWidth >= 700 &&
                              MediaQuery.textScalerOf(context).scale(1) < 1.4
                          ? 3
                          : box.maxWidth >= 480
                          ? 2
                          : 1;
                      final items = designScreens
                          .where(
                            (s) =>
                                s.group == group &&
                                '${s.title} ${s.id} ${s.group}'
                                    .toLowerCase()
                                    .contains(query),
                          )
                          .toList();
                      return Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          for (final item in items)
                            SizedBox(
                              width:
                                  (box.maxWidth - (columns - 1) * 12) / columns,
                              child: InkWell(
                                borderRadius: BorderRadius.circular(20),
                                onTap: () => context.go('/design/${item.id}'),
                                child: VibePanel(
                                  padding: const EdgeInsets.all(20),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Icon(
                                            _kindIcon(item.kind),
                                            color: Theme.of(context)
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                          const Spacer(),
                                          const Icon(
                                            Icons.arrow_outward_rounded,
                                            size: 18,
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 20),
                                      Text(
                                        item.id.replaceAll('-', ' '),
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleMedium,
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        item.title,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ],
              ],
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}

IconData _kindIcon(String kind) => switch (kind) {
  'auth' || 'splash' || 'intro' => Icons.auto_awesome_rounded,
  'chat' ||
  'chat-list' ||
  'voice' ||
  'call' => Icons.chat_bubble_outline_rounded,
  'people' || 'profile' || 'space' => Icons.face_rounded,
  'compose' || 'vibe' => Icons.draw_outlined,
  'settings' || 'security' || 'privacy' => Icons.tune_rounded,
  _ => Icons.explore_outlined,
};

class ScreenPreview extends ConsumerStatefulWidget {
  final String id;
  const ScreenPreview({super.key, required this.id});
  @override
  ConsumerState<ScreenPreview> createState() => _ScreenPreviewState();
}

class _ScreenPreviewState extends ConsumerState<ScreenPreview> {
  final draft = TextEditingController();
  final selectedTopics = <String>{};
  final reactions = <String>{};
  final formKey = GlobalKey<FormState>();
  String audience = 'Friends',
      vibe = 'Coffee mode',
      language = 'English',
      filter = 'All';
  int introStep = 0, storyStep = 0, accent = 0;
  double speed = 1;
  bool paused = false, muted = false, speaker = false, replies = false;
  final preferences = <String, bool>{};
  final privacyAudiences = <String, String>{};
  @override
  void dispose() {
    draft.dispose();
    super.dispose();
  }

  void open(String id) => context.go('/design/$id');
  void feedback(String text) => showMessage(context, text);
  DesignScreen get screen => designScreens.firstWhere(
    (s) => s.id == widget.id,
    orElse: () => const DesignScreen(
      'missing',
      'Studio',
      'This space is still taking shape.',
      'missing',
      'Choose a screen from the design studio.',
    ),
  );
  Widget button(
    String label,
    String id, {
    IconData icon = Icons.arrow_outward_rounded,
  }) => OutlinedButton.icon(
    onPressed: () => open(id),
    icon: Icon(icon, size: 18),
    label: Text(label),
  );
  Widget heading(String text) => Padding(
    padding: const EdgeInsets.only(top: 24, bottom: 14),
    child: Text(text, style: Theme.of(context).textTheme.titleLarge),
  );
  Widget chips(List<String> items, {bool multi = false}) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final item in items)
        ChoiceChip(
          label: Text(item),
          selected: multi
              ? selectedTopics.contains(item)
              : (filter == item ||
                    (filter == 'All' &&
                        !items.contains('All') &&
                        item == items.first)),
          selectedColor: VibeColors.lime,
          labelStyle: TextStyle(
            color: (multi ? selectedTopics.contains(item) : filter == item)
                ? VibeColors.ink
                : null,
          ),
          onSelected: (_) => setState(() {
            if (multi) {
              selectedTopics.contains(item)
                  ? selectedTopics.remove(item)
                  : selectedTopics.add(item);
            } else {
              filter = item;
            }
          }),
        ),
    ],
  );
  Widget unavailable(String title, String body) => EmptyCard(
    icon: Icons.hourglass_bottom_rounded,
    title: title,
    description: body,
  );
  Widget field(
    String label, {
    int lines = 1,
    int? maxLength,
    bool required = false,
    TextInputType? type,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: TextFormField(
      maxLines: lines,
      maxLength: maxLength,
      keyboardType: type,
      decoration: InputDecoration(labelText: label),
      validator: required
          ? (value) => value == null || value.trim().isEmpty
                ? 'Add a little here first.'
                : null
          : null,
    ),
  );
  Widget audienceControl() => DropdownButtonFormField<String>(
    initialValue: audience,
    isExpanded: true,
    decoration: const InputDecoration(labelText: 'Who gets to see this?'),
    items: [
      'Only me',
      'Friends',
      'Followers',
      'Public',
    ].map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
    onChanged: (value) => setState(() => audience = value ?? audience),
  );

  @override
  Widget build(BuildContext context) {
    final s = screen;
    const destinations = [
      'home',
      'chats',
      'discover',
      'activity',
      'my-profile',
    ];
    final destination = destinations.indexOf(s.id);
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Back to design studio',
                    onPressed: () => context.go('/design'),
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Design preview',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        Text(
                          'Sample content · temporary local interactions',
                          style: TextStyle(
                            fontSize: 10,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Change appearance',
                    onPressed: () => ref
                        .read(themeProvider.notifier)
                        .toggle(
                          Theme.of(context).brightness != Brightness.dark,
                        ),
                    icon: Icon(
                      Theme.of(context).brightness == Brightness.dark
                          ? Icons.light_mode_outlined
                          : Icons.dark_mode_outlined,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ReadingWidth(
                child: ListView(
                  padding: const EdgeInsets.all(24),
                  children: [
                    const PreviewNotice(),
                    const SizedBox(height: 28),
                    PageHeader(
                      eyebrow: '${s.group} / ${s.id.replaceAll('-', ' ')}',
                      title: s.title,
                      subtitle: s.description,
                    ),
                    ...content(s),
                    const SizedBox(height: 36),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: s.id == 'home'
          ? FloatingActionButton(
              tooltip: 'Make a little space',
              backgroundColor: VibeColors.lime,
              foregroundColor: VibeColors.ink,
              onPressed: () => showCreationOrbit(context),
              child: const Icon(Icons.auto_awesome_rounded),
            )
          : null,
      bottomNavigationBar: destination < 0
          ? null
          : NavigationDock(
              selectedIndex: destination,
              profileName: ref.watch(sessionProvider).asData?.value != null
                  ? ref.watch(profileProvider).asData?.value.displayName ?? 'K'
                  : 'You',
              onSelected: (index) => open(destinations[index]),
            ),
    );
  }

  List<Widget> content(DesignScreen s) => switch (s.kind) {
    'splash' => [
      const VibeArt(height: 280),
      const SizedBox(height: 24),
      Center(
        child: Text(
          'kairova',
          style: Theme.of(context).textTheme.displayMedium,
        ),
      ),
      const SizedBox(height: 24),
      button('Meet your people', 'welcome'),
    ],
    'intro' => intro(),
    'auth' => auth(s.id),
    'interests' => interests(),
    'language' => languages(),
    'compose' => compose(s.id),
    'people' => people(s.id),
    'feed' => feed(s.id),
    'post' => [post(), heading('The conversation'), commentThread()],
    'story' => story(),
    'search' => search(),
    'discover' => discover(),
    'activity' => activity(),
    'profile' => profile(s.id),
    'space' => space(),
    'media' => media(),
    'media-viewer' => [
      const VibeArt(kind: 'discover', height: 360),
      const SizedBox(height: 20),
      const VibeTag('Abstract sample artwork'),
      button('Back to conversation', 'chat'),
    ],
    'chat-list' => chatList(),
    'chat' => chat(s.id),
    'voice' => [
      const VoiceWaveform(),
      heading('Choose a playback speed'),
      Wrap(
        spacing: 8,
        children: [
          for (final value in [1.0, 1.5, 2.0])
            ChoiceChip(
              label: Text('${value}x'),
              selected: speed == value,
              onSelected: (_) => setState(() => speed = value),
            ),
        ],
      ),
      const SizedBox(height: 20),
      Text('Selected preview speed: ${speed}x. No audio is playing.'),
    ],
    'call' => call(s.id),
    'communities' => communities(),
    'community' => community(),
    'events' => events(),
    'vibe' => [
      vibePicker(),
      const SizedBox(height: 24),
      audienceControl(),
      const SizedBox(height: 24),
      FilledButton(
        onPressed: () => feedback('Vibe updated in this preview only.'),
        child: const Text('Preview my vibe'),
      ),
    ],
    'privacy' => privacy(),
    'security' => security(),
    'preferences' => notificationPreferences(),
    'appearance' => appearance(),
    'blocked' => [
      unavailable(
        'Your boundaries have a place.',
        'No real blocked-account list is loaded in this preview. Use the main app’s other-profile control to remove your own block.',
      ),
      button('See profile safety tools', 'other-profile'),
    ],
    'settings' => settings(s.id),
    'help' => help(),
    _ => [button('Choose a screen', 'welcome')],
  };

  List<Widget> intro() {
    const titles = [
      'Meet your people.',
      'Share your world.',
      'Talk beyond borders.',
      'Find your vibe.',
    ];
    const bodies = [
      'Connections that start with something in common.',
      'Thoughts, moments and a little everyday magic.',
      'Your voice belongs here. Privacy comes first.',
      'The things you love are a good place to start.',
    ];
    return [
      AnimatedSwitcher(
        duration: VibeMotion.duration(context),
        child: VibePanel(
          key: ValueKey(introStep),
          color: pastelColors[introStep],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              VibeArt(kind: introStep == 2 ? 'chats' : 'discover', height: 240),
              const SizedBox(height: 24),
              Text(
                titles[introStep],
                style: const TextStyle(
                  fontFamily: 'SpaceGrotesk',
                  fontWeight: FontWeight.w700,
                  fontSize: 32,
                  color: VibeColors.ink,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                bodies[introStep],
                style: const TextStyle(color: VibeColors.ink),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 20),
      Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          for (var i = 0; i < 4; i++)
            Semantics(
              label: 'Introduction step ${i + 1} of 4',
              selected: i == introStep,
              child: OutlinedButton(
                onPressed: () => setState(() => introStep = i),
                child: Text('${i + 1}'),
              ),
            ),
        ],
      ),
      const SizedBox(height: 20),
      FilledButton(
        onPressed: () {
          if (introStep == 3) {
            open('signup');
          } else {
            setState(() => introStep++);
          }
        },
        child: Text(introStep == 3 ? 'Create your space' : 'Next'),
      ),
      button('Skip to login', 'login'),
    ];
  }

  List<Widget> auth(String id) => [
    VibePanel(
      child: Form(
        key: formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const VibeTag(
              'Identity provider integration pending',
              color: VibeColors.lilac,
            ),
            const SizedBox(height: 24),
            if (id == 'login') ...[
              for (final entry in [
                (Icons.apple, 'Continue with Apple'),
                (Icons.g_mobiledata_rounded, 'Continue with Google'),
                (Icons.phone_outlined, 'Continue with Phone'),
              ])
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: OutlinedButton.icon(
                    onPressed: null,
                    icon: Icon(entry.$1),
                    label: Text(entry.$2),
                  ),
                ),
              const SizedBox(height: 16),
              field('Email address', type: TextInputType.emailAddress),
              const FilledButton(
                onPressed: null,
                child: Text('Continue with Email'),
              ),
              const SizedBox(height: 14),
              button('Create an account', 'signup'),
              button('Need a little help?', 'forgot-password'),
            ] else if (id == 'signup') ...[
              field('Display name', required: true, maxLength: 80),
              field('Username', maxLength: 30),
              field('Email address', type: TextInputType.emailAddress),
              const Text(
                'Terms and privacy consent will appear here once the production account flow is configured.',
              ),
              const SizedBox(height: 20),
              const FilledButton(
                onPressed: null,
                child: Text('Create account'),
              ),
              button('Explore onboarding', 'interests'),
            ] else if (id == 'otp') ...[
              field(
                'Six-digit verification code',
                maxLength: 6,
                type: TextInputType.number,
              ),
              const FilledButton(onPressed: null, child: Text('Verify code')),
              const TextButton(onPressed: null, child: Text('Resend code')),
              const Text('No verification code has been sent in this preview.'),
            ] else ...[
              field('Email or phone linked to your account'),
              const FilledButton(
                onPressed: null,
                child: Text('Start recovery'),
              ),
              const SizedBox(height: 16),
              const Text('No recovery message is sent from this preview.'),
              button('Explore recovery help', 'help'),
            ],
          ],
        ),
      ),
    ),
  ];

  List<Widget> interests() => [
    topicGrid(selectable: true),
    const SizedBox(height: 24),
    Text('${selectedTopics.length} interests selected for this preview.'),
    const SizedBox(height: 16),
    FilledButton(
      onPressed: () => open('language'),
      child: const Text('Next: your language'),
    ),
    button('Skip for now', 'profile-setup'),
  ];

  Widget topicGrid({bool selectable = false}) => LayoutBuilder(
    builder: (context, box) {
      final columns =
          box.maxWidth >= 700 && MediaQuery.textScalerOf(context).scale(1) < 1.4
          ? 4
          : box.maxWidth >= 330 &&
                MediaQuery.textScalerOf(context).scale(1) < 1.4
          ? 2
          : 1;
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (var i = 0; i < topicNames.length; i++)
            SizedBox(
              width: (box.maxWidth - 12 * (columns - 1)) / columns,
              child: Semantics(
                button: true,
                selected: selectable && selectedTopics.contains(topicNames[i]),
                child: InkWell(
                  borderRadius: BorderRadius.circular(24),
                  onTap: () {
                    if (selectable) {
                      setState(
                        () => selectedTopics.contains(topicNames[i])
                            ? selectedTopics.remove(topicNames[i])
                            : selectedTopics.add(topicNames[i]),
                      );
                    } else {
                      setState(() => filter = topicNames[i]);
                      feedback(
                        '${topicNames[i]} selected. Live discovery is still being built.',
                      );
                    }
                  },
                  child: VibePanel(
                    color: pastelColors[i % pastelColors.length],
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(topicIcons[i], color: VibeColors.ink),
                            const Spacer(),
                            if (selectable &&
                                selectedTopics.contains(topicNames[i]))
                              const Icon(
                                Icons.check_circle_rounded,
                                color: VibeColors.ink,
                              ),
                          ],
                        ),
                        const SizedBox(height: 30),
                        Text(
                          topicNames[i],
                          style: const TextStyle(
                            fontFamily: 'SpaceGrotesk',
                            fontWeight: FontWeight.w700,
                            color: VibeColors.ink,
                            fontSize: 17,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );

  List<Widget> languages() => [
    unavailable(
      'Global, from the start.',
      'This is a language preference preview. App-wide translations are not implemented yet.',
    ),
    const SizedBox(height: 24),
    VibePanel(
      child: RadioGroup<String>(
        groupValue: language,
        onChanged: (value) => setState(() => language = value ?? language),
        child: Column(
          children: [
            for (final item in [
              'English',
              'हिन्दी',
              'Español',
              'العربية',
              'Français',
              '日本語',
              'Português',
            ])
              RadioListTile<String>(title: Text(item), value: item),
          ],
        ),
      ),
    ),
    const SizedBox(height: 20),
    FilledButton(
      onPressed: () {
        feedback('Language selected for this preview only.');
      },
      child: const Text('Preview this language'),
    ),
    button('Next: your profile', 'profile-setup'),
  ];

  List<Widget> compose(String id) => [
    VibePanel(
      child: Form(
        key: formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (['profile-setup', 'edit-profile'].contains(id)) ...[
              const Align(
                alignment: Alignment.centerLeft,
                child: SampleAvatar(size: 80),
              ),
              const SizedBox(height: 24),
              field('Display name', required: true, maxLength: 80),
              field('Username', maxLength: 30),
              field('A little about you', lines: 3, maxLength: 300),
            ] else if (id == 'create-community') ...[
              field('Name your community', required: true, maxLength: 80),
              field('What brings people together?', lines: 3, maxLength: 300),
              field('A few good rules', lines: 3),
              const Text(
                'Community creation needs moderation, membership and safety services before launch.',
              ),
            ] else if (id == 'group-create') ...[
              field('Name your circle', required: true, maxLength: 80),
              button('Choose people', 'friends'),
              const Text(
                'Group creation stays unavailable until consent and group encryption are implemented.',
              ),
            ] else if (id == 'create-event') ...[
              field('What’s the plan?', required: true),
              field('Where will it happen?'),
              field('Date, local time and time zone'),
              const Text(
                'Time-zone-aware scheduling and RSVPs are not connected in this preview.',
              ),
            ] else ...[
              if (id == 'create-story') ...[
                const VibeArt(height: 200),
                const SizedBox(height: 24),
              ],
              field(
                id == 'create-poll' || id == 'create-question'
                    ? 'Your question'
                    : 'Your thought',
                lines: 3,
                required: true,
                maxLength: 300,
              ),
              if (id == 'create-poll') ...[
                field('First option', required: true),
                field('Second option', required: true),
              ],
              if (id != 'create-question' && id != 'create-poll')
                const OutlinedButton(
                  onPressed: null,
                  child: Text('Add media · coming soon'),
                ),
            ],
            const SizedBox(height: 20),
            audienceControl(),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () {
                if (formKey.currentState!.validate()) {
                  feedback(
                    'Draft kept for this preview. Nothing has been published or saved to your account.',
                  );
                }
              },
              icon: const Icon(Icons.check_rounded, size: 18),
              label: const Text('Keep preview draft'),
            ),
            const SizedBox(height: 14),
            const Text(
              'Drafts are temporary and disappear when you leave this screen. This form does not publish, register an account or change your real profile.',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    ),
  ];

  List<Widget> people(String id) => [
    if (id == 'find-friends') ...[
      OutlinedButton.icon(
        onPressed: () => showPeopleFilters(context, preview: true),
        icon: const Icon(Icons.tune_rounded),
        label: const Text('Preview people filters'),
      ),
      const SizedBox(height: 16),
    ],
    TextField(
      controller: draft,
      decoration: const InputDecoration(
        prefixIcon: Icon(Icons.search_rounded),
        labelText: 'Search people, interests, communities…',
      ),
      onChanged: (_) => setState(() {}),
    ),
    const SizedBox(height: 20),
    chips(['Your vibe', 'Music people', 'Gamers', 'Creators']),
    const SizedBox(height: 24),
    unavailable(
      'Your people are waiting.',
      'No live people or relationship results are loaded. The card below shows the design anatomy of a sample profile.',
    ),
    const SizedBox(height: 20),
    VibePanel(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const VibeArt(kind: 'discover', height: 160),
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const VibeTag(
                  'Sample profile / no real person',
                  color: VibeColors.lilac,
                ),
                const SizedBox(height: 20),
                const SampleAvatar(),
                const SizedBox(height: 18),
                Text(
                  'A creative kind of human',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const Text('@sample_person'),
                const SizedBox(height: 14),
                const Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    VibeTag('Design', color: VibeColors.pink),
                    VibeTag('Music', color: VibeColors.mint),
                  ],
                ),
                const SizedBox(height: 16),
                const Text(
                  'Recommendation explanations will appear only when backed by consented interests or visible connections.',
                ),
                const SizedBox(height: 20),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    const FilledButton(onPressed: null, child: Text('Connect')),
                    button('View sample', 'other-profile'),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  ];

  List<Widget> feed(String id) => [
    if (id == 'home') ...[
      const VibeTag(
        'Rectangular story strip / sample layout',
        color: VibeColors.lilac,
      ),
      const SizedBox(height: 16),
      SizedBox(
        height: MediaQuery.textScalerOf(context).scale(1) > 1.4 ? 280 : 170,
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            for (final label in ['Your vibe', 'Close friends', 'Communities'])
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: StoryTile(
                  label: label,
                  onTap: () => open(
                    label == 'Your vibe' ? 'create-vibe' : 'story-viewer',
                  ),
                ),
              ),
          ],
        ),
      ),
      const SizedBox(height: 24),
    ],
    chips(['For you', 'Friends', 'Communities']),
    const SizedBox(height: 24),
    post(),
    const SizedBox(height: 20),
    VibePanel(
      color: VibeColors.peach,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const VibeTag('Sample question', color: Colors.white),
          const SizedBox(height: 20),
          const Text(
            'What song feels like your week?',
            style: TextStyle(
              fontFamily: 'SpaceGrotesk',
              fontWeight: FontWeight.w700,
              fontSize: 28,
              color: VibeColors.ink,
            ),
          ),
          const SizedBox(height: 20),
          button('Explore the conversation', 'post-details'),
        ],
      ),
    ),
    const SizedBox(height: 20),
    VibePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const VibeTag('Sample poll'),
          const SizedBox(height: 18),
          Text(
            'Your next side quest?',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 14),
          chips(['A new café', 'A little hike']),
          const SizedBox(height: 10),
          const Text(
            'Preview selection only. No votes or results are submitted.',
          ),
        ],
      ),
    ),
    const SizedBox(height: 20),
    Container(
      padding: const EdgeInsets.all(24),
      decoration: const BoxDecoration(
        border: Border(left: BorderSide(color: VibeColors.pink, width: 4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const VibeTag('Sample vibe post', color: VibeColors.pink),
          const SizedBox(height: 18),
          Text(
            'On repeat. Off the clock.',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 12),
          const Text('A short thought with a tiny signal of your day.'),
          const SizedBox(height: 16),
          const VibeTag('Listening / sample vibe', color: VibeColors.lilac),
        ],
      ),
    ),
    const SizedBox(height: 24),
    const VibeTag(
      'Photo dump / abstract sample layout',
      color: VibeColors.mint,
    ),
    const SizedBox(height: 16),
    ...media(),
    const SizedBox(height: 24),
    const VibePanel(
      color: VibeColors.ink,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          VibeTag('Sample moment', color: VibeColors.peach),
          SizedBox(height: 22),
          Text(
            'Here for a little while.',
            style: TextStyle(
              fontFamily: 'SpaceGrotesk',
              fontSize: 30,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
          SizedBox(height: 14),
          Text(
            'A temporary thought, with expiry made clear. No live expiry timer is running in this preview.',
            style: TextStyle(color: Color(0xffd5d8cc)),
          ),
        ],
      ),
    ),
    const SizedBox(height: 24),
    VibePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const VibeTag('Sample link preview', color: VibeColors.lilac),
          const SizedBox(height: 20),
          Row(
            children: [
              const Icon(Icons.link_rounded, size: 36),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  'Something worth sharing',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          const Text(
            'A title, source and thumbnail belong here. This sample does not open an external website.',
          ),
        ],
      ),
    ),
    const SizedBox(height: 24),
    VibePanel(
      color: VibeColors.mint,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const VibeTag('Sample community post', color: Colors.white),
          const SizedBox(height: 20),
          const Text(
            'From the creative corner.',
            style: TextStyle(
              fontFamily: 'SpaceGrotesk',
              fontSize: 28,
              fontWeight: FontWeight.w700,
              color: VibeColors.ink,
            ),
          ),
          const SizedBox(height: 14),
          const Text(
            'A shared community gives a thought its context.',
            style: TextStyle(color: VibeColors.ink),
          ),
          const SizedBox(height: 20),
          button('Explore community context', 'community-details'),
        ],
      ),
    ),
    const SizedBox(height: 24),
    OutlinedButton.icon(
      onPressed: () => showCreationOrbit(context),
      icon: const Icon(Icons.auto_awesome_rounded),
      label: const Text('Open creation menu'),
    ),
  ];

  Widget post() => VibePanel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            SampleAvatar(size: 44),
            SizedBox(width: 12),
            Expanded(child: Text('Sample creator\nEditorial post example')),
          ],
        ),
        const SizedBox(height: 22),
        Text(
          'Small moments deserve a little space.',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 14),
        const Text(
          'A thought, a photo, a song you found at the right time. The little things count.',
        ),
        const SizedBox(height: 20),
        const VibeArt(kind: 'discover', height: 220),
        const SizedBox(height: 20),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final reaction in [
              'Love',
              'Spark',
              'Laugh',
              'Fire',
              'Seen',
              'Relatable',
              'Support',
            ])
              FilterChip(
                selected: reactions.contains(reaction),
                label: Text(reaction),
                avatar: Icon(switch (reaction) {
                  'Love' => Icons.favorite_border_rounded,
                  'Spark' => Icons.auto_awesome_rounded,
                  'Laugh' => Icons.sentiment_very_satisfied_rounded,
                  'Fire' => Icons.local_fire_department_outlined,
                  'Relatable' => Icons.sentiment_dissatisfied_rounded,
                  'Support' => Icons.volunteer_activism_outlined,
                  _ => Icons.visibility_outlined,
                }, size: 18),
                onSelected: (_) => setState(
                  () => reactions.contains(reaction)
                      ? reactions.remove(reaction)
                      : reactions.add(reaction),
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        const Text(
          'Reactions are local preview selections.',
          style: TextStyle(fontSize: 11),
        ),
        button(
          'Open thread',
          'post-details',
          icon: Icons.chat_bubble_outline_rounded,
        ),
      ],
    ),
  );

  Widget commentThread() => VibePanel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            SampleAvatar(size: 38),
            SizedBox(width: 12),
            Expanded(
              child: Text('Sample reply\nLittle things make a good day.'),
            ),
          ],
        ),
        TextButton.icon(
          onPressed: () => setState(() => replies = !replies),
          icon: Icon(replies ? Icons.expand_less : Icons.expand_more),
          label: Text(replies ? 'Hide sample thread' : 'Expand sample thread'),
        ),
        if (replies)
          const Padding(
            padding: EdgeInsets.only(left: 24, top: 8),
            child: Text('Sample creator · Absolutely. That’s the whole idea.'),
          ),
        const SizedBox(height: 18),
        const TextField(
          enabled: false,
          decoration: InputDecoration(
            labelText: 'Replies will open when posts are connected',
          ),
        ),
      ],
    ),
  );

  List<Widget> story() => [
    VibePanel(
      color: pastelColors[storyStep % pastelColors.length],
      child: Column(
        children: [
          Row(
            children: [
              for (var i = 0; i < 3; i++)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(3),
                    child: LinearProgressIndicator(
                      value: i <= storyStep ? 1 : 0,
                      color: VibeColors.ink,
                      backgroundColor: Colors.white54,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 22),
          const Row(
            children: [
              SampleAvatar(size: 40),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Sample story',
                  style: TextStyle(color: VibeColors.ink),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          VibeArt(kind: storyStep == 1 ? 'chats' : 'discover', height: 300),
          const SizedBox(height: 22),
          const Text(
            'A little everyday magic.',
            style: TextStyle(
              fontFamily: 'SpaceGrotesk',
              fontWeight: FontWeight.w700,
              fontSize: 28,
              color: VibeColors.ink,
            ),
          ),
        ],
      ),
    ),
    const SizedBox(height: 20),
    Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        OutlinedButton.icon(
          onPressed: storyStep == 0 ? null : () => setState(() => storyStep--),
          icon: const Icon(Icons.arrow_back),
          label: const Text('Previous'),
        ),
        OutlinedButton.icon(
          onPressed: () => setState(() => paused = !paused),
          icon: Icon(paused ? Icons.play_arrow_rounded : Icons.pause_rounded),
          label: Text(paused ? 'Resume preview' : 'Pause preview'),
        ),
        FilledButton.icon(
          onPressed: storyStep == 2 ? null : () => setState(() => storyStep++),
          icon: const Icon(Icons.arrow_forward),
          label: const Text('Next'),
        ),
      ],
    ),
    const SizedBox(height: 12),
    const Text('This story preview does not auto-advance or play sound.'),
  ];

  List<Widget> search() => [
    TextField(
      controller: draft,
      decoration: InputDecoration(
        prefixIcon: const Icon(Icons.search_rounded),
        labelText: 'Search anything…',
        suffixIcon: IconButton(
          tooltip: 'Clear search',
          onPressed: () => setState(() => draft.clear()),
          icon: const Icon(Icons.close_rounded),
        ),
      ),
      onChanged: (_) => setState(() {}),
    ),
    const SizedBox(height: 20),
    chips(['People', 'Posts', 'Communities', 'Topics', 'Events']),
    heading(draft.text.isEmpty ? 'A little inspiration' : 'Preview results'),
    if (draft.text.isEmpty) ...[
      chips(['Music', 'Design', 'Photography']),
      const SizedBox(height: 20),
      const Text('No account search history is stored in this preview.'),
    ] else
      unavailable(
        'Curiosity looks good on you.',
        'Live $filter search is still being built. Try exploring a category below.',
      ),
    const SizedBox(height: 20),
    button('Explore interests', 'discover'),
  ];

  List<Widget> discover() => [
    const VibeArt(kind: 'discover', height: 240),
    heading('Find your niche'),
    topicGrid(),
    heading('Around the world'),
    VibePanel(
      color: VibeColors.mint,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.public_rounded, color: VibeColors.ink),
          const SizedBox(height: 20),
          const Text(
            'Different places. Shared interests.',
            style: TextStyle(
              fontFamily: 'SpaceGrotesk',
              fontSize: 28,
              fontWeight: FontWeight.w700,
              color: VibeColors.ink,
            ),
          ),
          const SizedBox(height: 20),
          button('Find your people', 'find-friends'),
          button('Explore communities', 'communities'),
        ],
      ),
    ),
  ];

  List<Widget> activity() => [
    chips(['All', 'Social', 'Messages', 'Communities', 'Mentions']),
    const SizedBox(height: 24),
    unavailable(
      'Looks quiet. A little room to breathe.',
      'No live activity is loaded in this design preview.',
    ),
    heading('Grouped activity anatomy'),
    VibePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const VibeTag('Sample notification', color: VibeColors.pink),
          const SizedBox(height: 18),
          const Wrap(
            spacing: 8,
            children: [
              SampleAvatar(size: 36),
              SampleAvatar(size: 36),
              SampleAvatar(size: 36),
            ],
          ),
          const SizedBox(height: 18),
          Text(
            'Related reactions, one little update.',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          const Text(
            'Real activity will group related updates with context and a clear destination.',
          ),
        ],
      ),
    ),
    const SizedBox(height: 20),
    button('Choose what reaches you', 'notification-settings'),
  ];

  List<Widget> profile(String id) => [
    VibePanel(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const VibeArt(kind: 'discover', height: 180),
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SampleAvatar(size: 80),
                const SizedBox(height: 20),
                Text(
                  id == 'my-profile'
                      ? 'Your name. Your story.'
                      : 'A creative kind of human',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const Text('@sample_person · preview identity'),
                const SizedBox(height: 16),
                VibeTag(vibe, color: VibeColors.lilac),
                const SizedBox(height: 18),
                const Text(
                  'Coffee, creative side quests, and a little space to grow.',
                ),
                const SizedBox(height: 20),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    if (id == 'my-profile')
                      button('Make it yours', 'my-space')
                    else
                      const FilledButton(
                        onPressed: null,
                        child: Text('Connect'),
                      ),
                    button('Preview conversation', 'chat'),
                    if (id == 'other-profile')
                      OutlinedButton.icon(
                        onPressed: () => feedback(
                          'This is a sample profile. No real account can be blocked or reported here.',
                        ),
                        icon: const Icon(Icons.shield_outlined),
                        label: const Text('Safety tools'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    ),
    const SizedBox(height: 24),
    chips(['Posts', 'Vibes', 'Media', 'Communities', 'About']),
    const SizedBox(height: 20),
    if (filter == 'Media')
      ...media()
    else if (filter == 'Communities')
      ...communities()
    else if (filter == 'Vibes')
      vibePicker()
    else if (filter == 'About')
      const VibePanel(
        child: Text(
          'A bio, visible interests and profile fields belong here. Real account data is managed in the main app.',
        ),
      )
    else
      post(),
  ];

  Widget vibePicker() => VibePanel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const VibeTag('A little signal', color: VibeColors.lilac),
        const SizedBox(height: 20),
        Text(
          'Today’s frequency',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final entry in [
              (Icons.headphones_rounded, 'On repeat'),
              (Icons.coffee_rounded, 'Coffee mode'),
              (Icons.auto_stories_outlined, 'Studying'),
              (Icons.flight_takeoff_rounded, 'Traveling'),
              (Icons.sports_esports_outlined, 'Gaming'),
              (Icons.laptop_rounded, 'Working'),
              (Icons.nightlight_outlined, 'Night mode'),
              (Icons.fitness_center_rounded, 'Gym'),
            ])
              ChoiceChip(
                avatar: Icon(entry.$1, size: 18),
                label: Text(entry.$2),
                selected: vibe == entry.$2,
                selectedColor: VibeColors.lime,
                labelStyle: TextStyle(
                  color: vibe == entry.$2 ? VibeColors.ink : null,
                ),
                onSelected: (_) => setState(() => vibe = entry.$2),
              ),
          ],
        ),
      ],
    ),
  );

  List<Widget> space() => [
    VibePanel(
      color: pastelColors[accent],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SampleAvatar(size: 80),
          const SizedBox(height: 20),
          const Text(
            'A little room for you.',
            style: TextStyle(
              fontFamily: 'SpaceGrotesk',
              fontSize: 32,
              fontWeight: FontWeight.w700,
              color: VibeColors.ink,
            ),
          ),
          const SizedBox(height: 18),
          VibeTag(vibe, color: Colors.white),
          const SizedBox(height: 18),
          const Text(
            'Your music. Your interests. Your next chapter.',
            style: TextStyle(color: VibeColors.ink),
          ),
        ],
      ),
    ),
    heading('Choose your accent'),
    Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        for (var i = 0; i < pastelColors.length; i++)
          Semantics(
            label: 'Accent ${['Lilac', 'Pink', 'Lime', 'Mint', 'Peach'][i]}',
            selected: accent == i,
            button: true,
            child: InkWell(
              onTap: () => setState(() => accent = i),
              borderRadius: BorderRadius.circular(18),
              child: Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(
                  color: pastelColors[i],
                  borderRadius: BorderRadius.circular(18),
                ),
                child: accent == i
                    ? const Icon(Icons.check_rounded, color: VibeColors.ink)
                    : null,
              ),
            ),
          ),
      ],
    ),
    const SizedBox(height: 24),
    vibePicker(),
    heading('Your little details'),
    field('A quote that feels like you', lines: 2, maxLength: 180),
    chips(topicNames, multi: true),
    const SizedBox(height: 24),
    audienceControl(),
    const SizedBox(height: 24),
    FilledButton(
      onPressed: () => feedback('My Space updated in this preview only.'),
      child: const Text('Preview my space'),
    ),
  ];

  List<Widget> media() => [
    const VibeTag('Abstract artwork / sample grid', color: VibeColors.mint),
    const SizedBox(height: 20),
    TwoUp(
      first: InkWell(
        onTap: () => open('media-viewer'),
        child: const VibeArt(kind: 'discover', height: 270),
      ),
      second: Column(
        children: [
          InkWell(
            onTap: () => open('media-viewer'),
            child: const VibeArt(kind: 'chats', height: 127),
          ),
          const SizedBox(height: 16),
          InkWell(
            onTap: () => open('media-viewer'),
            child: const VibeArt(kind: 'bell', height: 127),
          ),
        ],
      ),
    ),
  ];

  List<Widget> chatList() => [
    TextField(
      decoration: const InputDecoration(
        labelText: 'Find a conversation',
        prefixIcon: Icon(Icons.search_rounded),
      ),
    ),
    const SizedBox(height: 20),
    chips(['All', 'Friends', 'Groups', 'Requests']),
    const SizedBox(height: 24),
    unavailable(
      'Your conversations will find a home here.',
      'There are no real chats in this preview. Messaging stays unavailable until the encryption integration is complete.',
    ),
    heading('Conversation anatomy'),
    VibePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              SampleAvatar(size: 52),
              SizedBox(width: 14),
              Expanded(
                child: Text(
                  'Sample conversation\nA little thought, a little energy.',
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const VibeTag('No real message data', color: VibeColors.lilac),
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              button('Explore direct chat', 'chat'),
              button('Explore group chat', 'group-chat'),
            ],
          ),
        ],
      ),
    ),
    const SizedBox(height: 20),
    button('Start with a hello', 'new-chat'),
  ];

  List<Widget> chat(String id) => [
    VibePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 16,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const SampleAvatar(size: 54),
              Text(
                id == 'group-chat' ? 'Sample circle' : 'Sample human',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              IconButton(
                tooltip: 'Preview voice call',
                onPressed: () => open('call'),
                icon: const Icon(Icons.call_outlined),
              ),
              IconButton(
                tooltip: 'Preview video call',
                onPressed: () => open('video-call'),
                icon: const Icon(Icons.videocam_outlined),
              ),
            ],
          ),
          const SizedBox(height: 18),
          const VibeTag(
            'Illustrative messages / no live conversation',
            color: VibeColors.lilac,
          ),
          const SizedBox(height: 30),
          const Align(
            alignment: Alignment.centerLeft,
            child: MessageSurface(
              text: 'A small thought can start a big conversation.',
              outgoing: false,
            ),
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerRight,
            child: MessageSurface(
              text: 'Room for your kind of energy.',
              outgoing: true,
              color: switch (filter) {
                'Sunset' || 'Retro' => VibeColors.peach,
                'Aurora' || 'Ocean' => VibeColors.mint,
                'Candy' => VibeColors.pink,
                'Cosmic' => VibeColors.lilac,
                'Midnight' => VibeColors.ink,
                'Monochrome' || 'Minimal' => VibeColors.cream,
                _ => VibeColors.lime,
              },
            ),
          ),
          const SizedBox(height: 20),
          const VoiceWaveform(),
          const SizedBox(height: 20),
          button('Open sample media', 'media-viewer'),
          const SizedBox(height: 24),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final item in [
                'Minimal',
                'Sunset',
                'Aurora',
                'Midnight',
                'Candy',
                'Ocean',
                'Cosmic',
                'Retro',
                'Monochrome',
              ])
                ChoiceChip(
                  label: Text(item),
                  selected: filter == item,
                  onSelected: (_) => setState(() => filter = item),
                ),
            ],
          ),
          const SizedBox(height: 20),
          const Text(
            'Conversation themes are preview selections. Actual key verification, encrypted storage and delivery are still being built.',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 24),
          const TextField(
            enabled: false,
            decoration: InputDecoration(
              labelText: 'Messaging opens when encryption is ready',
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: attachments,
                icon: const Icon(Icons.add_rounded),
                label: const Text('Explore attachments'),
              ),
              FilledButton.icon(
                onPressed: null,
                icon: Icon(Icons.send_rounded, size: 18),
                label: Text('Send unavailable'),
              ),
            ],
          ),
        ],
      ),
    ),
  ];

  void attachments() => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
        ? AnimationStyle.noAnimation
        : const AnimationStyle(duration: Duration(milliseconds: 220)),
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            const VibeTag(
              'Attachment menu / design preview',
              color: VibeColors.lilac,
            ),
            const SizedBox(height: 18),
            for (final item in [
              'Camera',
              'Photos',
              'Music',
              'Location',
              'File',
              'Sticker',
              'Poll',
              'GIF',
            ])
              ListTile(
                title: Text(item),
                trailing: const Icon(Icons.hourglass_bottom_rounded, size: 18),
              ),
            const Text(
              'These are layout examples. No camera, file picker, recording or upload is opened.',
            ),
          ],
        ),
      ),
    ),
  );

  List<Widget> call(String id) => [
    VibePanel(
      color: VibeColors.ink,
      child: Column(
        children: [
          const VibeTag(
            'Call layout preview / offline',
            color: VibeColors.lilac,
          ),
          const SizedBox(height: 32),
          if (id == 'video-call')
            const VibeArt(height: 240)
          else
            const SampleAvatar(size: 110),
          const SizedBox(height: 28),
          const Text(
            'A familiar face',
            style: TextStyle(
              fontFamily: 'SpaceGrotesk',
              fontSize: 30,
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'No call is connected. Camera and microphone are off.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0xffd5d8cc)),
          ),
          const SizedBox(height: 30),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            alignment: WrapAlignment.center,
            children: [
              FilledButton.tonalIcon(
                onPressed: () => setState(() => muted = !muted),
                icon: Icon(
                  muted ? Icons.mic_off_rounded : Icons.mic_none_rounded,
                ),
                label: Text(muted ? 'Muted preview' : 'Mute preview'),
              ),
              FilledButton.tonalIcon(
                onPressed: () => setState(() => speaker = !speaker),
                icon: const Icon(Icons.volume_up_outlined),
                label: Text(speaker ? 'Speaker preview on' : 'Speaker preview'),
              ),
              FilledButton.icon(
                onPressed: () => open('chats'),
                style: FilledButton.styleFrom(backgroundColor: VibeColors.pink),
                icon: const Icon(Icons.call_end_rounded),
                label: const Text('Close preview'),
              ),
            ],
          ),
        ],
      ),
    ),
  ];

  List<Widget> communities() => [
    chips(['Your interests', 'Creative', 'Music', 'Learning']),
    heading('Little worlds worth exploring'),
    TwoUp(
      first: communityTile(
        'Creative side quests',
        VibeColors.lilac,
        Icons.draw_outlined,
      ),
      second: communityTile(
        'The listening room',
        VibeColors.mint,
        Icons.headphones_rounded,
      ),
    ),
    const SizedBox(height: 20),
    button('Start a community', 'create-community'),
  ];
  Widget communityTile(String title, Color color, IconData icon) => VibePanel(
    color: color,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 36, color: VibeColors.ink),
        const SizedBox(height: 30),
        Text(
          title,
          style: const TextStyle(
            fontFamily: 'SpaceGrotesk',
            fontSize: 28,
            fontWeight: FontWeight.w700,
            color: VibeColors.ink,
          ),
        ),
        const SizedBox(height: 16),
        const VibeTag('Sample community', color: Colors.white),
        const SizedBox(height: 20),
        button('Take a look', 'community-details'),
      ],
    ),
  );
  List<Widget> community() => [
    const VibeArt(kind: 'discover', height: 220),
    heading('Creative side quests'),
    const Text(
      'Sample community: a place for small ideas and creative experiments. No real membership or community activity is loaded.',
    ),
    heading('A few good rules'),
    const VibePanel(
      child: Text(
        'Be kind. Credit the work. Respect boundaries. Keep private details private.',
      ),
    ),
    const SizedBox(height: 24),
    const FilledButton(onPressed: null, child: Text('Join · coming soon')),
    const SizedBox(height: 16),
    Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        button('Explore the feed', 'community-feed'),
        button('Meet the members', 'community-members'),
        button('See events', 'community-events'),
      ],
    ),
  ];
  List<Widget> events() => [
    VibePanel(
      color: VibeColors.peach,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const VibeTag('Event anatomy / sample', color: Colors.white),
          const SizedBox(height: 22),
          const Text(
            'A creative hangout',
            style: TextStyle(
              fontFamily: 'SpaceGrotesk',
              fontWeight: FontWeight.w700,
              fontSize: 30,
              color: VibeColors.ink,
            ),
          ),
          const SizedBox(height: 18),
          const Text(
            'Local date and time · organizer time zone\nLocation or private link · audience',
            style: TextStyle(color: VibeColors.ink),
          ),
          const SizedBox(height: 24),
          const FilledButton(
            onPressed: null,
            child: Text('RSVP · coming soon'),
          ),
        ],
      ),
    ),
    const SizedBox(height: 20),
    button('Plan an event', 'create-event'),
  ];

  List<Widget> privacy() => [
    for (final group in [
      'Who can contact you?',
      'Who can see you?',
      'Who can find you?',
      'Your activity',
      'Location',
      'Stories',
      'Messages',
    ]) ...[
      heading(group),
      VibePanel(
        child: DropdownButtonFormField<String>(
          initialValue: privacyAudiences[group] ?? 'Friends',
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Preview audience'),
          items: [
            'Only me',
            'Friends',
            'Followers',
            'Public',
          ].map((a) => DropdownMenuItem(value: a, child: Text(a))).toList(),
          onChanged: (value) =>
              setState(() => privacyAudiences[group] = value ?? 'Friends'),
        ),
      ),
    ],
    const SizedBox(height: 24),
    button('Review blocked accounts', 'blocked'),
    if (ref.watch(sessionProvider).asData?.value != null)
      FilledButton(
        onPressed: () => context.go('/profile/privacy'),
        child: const Text('Open saved account privacy controls'),
      ),
    const SizedBox(height: 14),
    const Text(
      'The selectors above are design examples. They do not change account privacy settings.',
    ),
  ];
  List<Widget> security() => [
    const VibeArt(height: 200),
    const SizedBox(height: 24),
    unavailable(
      'Private chats need a careful foundation.',
      'End-to-end encryption, device verification and key lifecycle integration are pending. This preview does not claim conversations are encrypted.',
    ),
    const SizedBox(height: 20),
    if (ref.watch(sessionProvider).asData?.value != null)
      FilledButton.icon(
        onPressed: () => context.go('/profile/sessions'),
        icon: const Icon(Icons.devices_outlined),
        label: const Text('Review actual account sessions'),
      ),
    const SizedBox(height: 20),
    button('Explore account recovery', 'recovery'),
  ];
  List<Widget> notificationPreferences() => [
    VibePanel(
      child: Column(
        children: [
          for (final title in [
            'Social activity',
            'Messages',
            'Communities',
            'Mentions',
            'Quiet hours',
          ])
            SwitchListTile(
              title: Text(title),
              value: preferences[title] ?? false,
              onChanged: (value) => setState(() => preferences[title] = value),
            ),
        ],
      ),
    ),
    const SizedBox(height: 20),
    const Text(
      'Local preview preferences only. Push notifications and OS permission requests are not connected.',
    ),
  ];
  List<Widget> appearance() => [
    const VibeArt(kind: 'chats', height: 220),
    heading('Light or late-night?'),
    Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        FilledButton.icon(
          onPressed: () => ref.read(themeProvider.notifier).toggle(false),
          icon: const Icon(Icons.light_mode_outlined),
          label: const Text('Light'),
        ),
        FilledButton.tonalIcon(
          onPressed: () => ref.read(themeProvider.notifier).toggle(true),
          icon: const Icon(Icons.dark_mode_outlined),
          label: const Text('Dark'),
        ),
      ],
    ),
    const SizedBox(height: 24),
    OutlinedButton.icon(
      onPressed: () => ref.read(themeProvider.notifier).useSystem(),
      icon: const Icon(Icons.brightness_auto_outlined),
      label: const Text('Use system appearance'),
    ),
    button('Customize My Space', 'my-space'),
    const SizedBox(height: 16),
    const Text(
      'The appearance controls change the actual local app theme. Profile accents are preview-only. System reduced-motion settings are respected.',
    ),
  ];

  List<Widget> settings(String id) {
    final entries = switch (id) {
      'account' => [
        ('Login methods', 'login'),
        ('Recover access', 'recovery'),
        ('Security & sessions', 'security'),
      ],
      'data-privacy' => [
        ('Privacy controls', 'privacy'),
        ('Account access', 'security'),
        ('Data questions', 'help'),
      ],
      _ => [
        ('Account', 'account'),
        ('Privacy', 'privacy'),
        ('Security', 'security'),
        ('Notifications', 'notification-settings'),
        ('Appearance', 'appearance'),
        ('Language', 'app-language'),
        ('Blocked accounts', 'blocked'),
        ('Data & privacy', 'data-privacy'),
        ('Help & support', 'help'),
      ],
    };
    return [
      VibePanel(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          children: [
            for (final item in entries)
              ListTile(
                title: Text(item.$1),
                leading: Icon(
                  _kindIcon(
                    designScreens.firstWhere((s) => s.id == item.$2).kind,
                  ),
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => open(item.$2),
              ),
          ],
        ),
      ),
      if (id == 'account' || id == 'data-privacy') ...[
        const SizedBox(height: 24),
        unavailable(
          'Your choices deserve real controls.',
          'Provider linking, export and deletion need verified backend workflows. They are not simulated here.',
        ),
      ],
    ];
  }

  List<Widget> help() => [
    const TextField(
      decoration: InputDecoration(
        labelText: 'What can we help with?',
        prefixIcon: Icon(Icons.search_rounded),
      ),
    ),
    const SizedBox(height: 24),
    VibePanel(
      child: Column(
        children: [
          for (final topic in [
            'Privacy and visibility',
            'Account access',
            'Safety and blocking',
            'About this preview',
          ])
            ExpansionTile(
              title: Text(topic),
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(switch (topic) {
                    'Privacy and visibility' => 'Use the main app’s privacy editor to change saved audiences. Preview selectors do not change your account.',
                    'Account access' => 'Actual sessions can be reviewed and revoked in the main app. Production identity providers are not configured yet.',
                    'Safety and blocking' => 'The main app supports per-person block and unblock. Report and moderation workflows are still being built.',
                    _ => 'The design studio shows sample screen layouts and local interactions. It does not publish content, send messages or place calls.',
                  }),
                ),
              ],
            ),
        ],
      ),
    ),
    const SizedBox(height: 20),
    const OutlinedButton(
      onPressed: null,
      child: Text('Contact support · coming soon'),
    ),
  ];
}
