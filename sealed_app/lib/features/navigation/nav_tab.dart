/// Tabs shown in the main bottom navigation bar.
///
/// Order here controls display order in the navbar.
enum NavTab { chats, contacts, files, settings }

/// Static metadata for a [NavTab] — label + SVG asset paths.
///
/// [svgAsset] is shown when inactive, [svgAssetActive] when active.
/// If [svgAssetActive] is null the inactive asset is used for both states.
///
/// Keeping this as plain data (no widgets) lets the navbar widget own
/// rendering and makes it trivial to add/remove tabs.
class NavTabSpec {
  const NavTabSpec({
    required this.tab,
    required this.label,
    required this.svgAsset,
    this.svgAssetActive,
    this.comingSoon = false,
  });

  final NavTab tab;
  final String label;

  /// Asset path for the outline / inactive icon.
  final String svgAsset;

  /// Asset path for the filled / active icon. Falls back to [svgAsset].
  final String? svgAssetActive;

  /// When true, tapping the tab still switches to it but the destination
  /// screen shows a "coming soon" placeholder.
  final bool comingSoon;
}

/// Default tab list for the app. Matches the Figma design (node 120:2350):
/// Chats · Contacts · Files · Settings.
const List<NavTabSpec> kDefaultNavTabs = [
  NavTabSpec(
    tab: NavTab.chats,
    label: 'Chats',
    svgAsset: 'assets/icons/nav-bar/chats.svg',
    svgAssetActive: 'assets/icons/nav-bar/chats_filled.svg',
  ),
  NavTabSpec(
    tab: NavTab.contacts,
    label: 'Contacts',
    svgAsset: 'assets/icons/nav-bar/contacts.svg',
    comingSoon: true,
  ),
  NavTabSpec(
    tab: NavTab.files,
    label: 'Files',
    svgAsset: 'assets/icons/nav-bar/file.svg',
    comingSoon: true,
  ),
  NavTabSpec(
    tab: NavTab.settings,
    label: 'Settings',
    svgAsset: 'assets/icons/nav-bar/settings.svg',
  ),
];
