# Darni releases

Darni was called ReArc up to build 1053. The entries for those builds keep the name they
shipped under.

Every distributed build (a DMG or an update in the appcast) has an entry here, newest
first. The entry lists everything that changed since the previous release, written for
the people who use Darni. `shell/scripts/release.sh --dmg` refuses to build until the
committed `RELEASES.md` has a heading for the build it is about to make:

    ## Darni <YYYY.MMDD>.<build> — <YYYY-MM-DD>

for example `## Darni 2026.1120.1060 — 2026-11-20`: the version is the release's date, the
same date as after the dash, and its build. `<build>` is the commit count of the commit
that adds the entry, so write it as the last commit before the release, with
`echo $(( $(git rev-list --count HEAD) + 1 ))` as the number. Entries for builds 678 to
1053 keep their `## ReArc <YYYY.MMDD>.<build> — <YYYY-MM-DD>` headings, and entries up to
677 keep `## ReArc 0.1.0 (<build>) — <YYYY-MM-DD>`. The script that checks this is
`shell/scripts/release/version.py check-notes`. Details: engine/docs/RELEASE.md,
"Release notes" and "Versioning".

## Unreleased

Merged since the last release and not yet in a build. The next release's entry takes these
lines and this section starts empty again.

## Darni 2026.1127.1440 — 2026-11-27

**New**
- Peek at URL… has a shortcut: ⇧⌘P (also in the File menu) opens the command bar in Peek
  mode. With a link copied, ⇧⌘P then Return peeks it. Right-click a link for "Open Link in
  Peek". Command bar commands now show their shortcuts.
- Task Manager: each tab is now a stack with its page and frame processes under it, and an
  estimated total (≈; a process that tabs share is split evenly between them). Filter by All,
  Tabs, Subframes, Extensions or Browser. New State and Idle columns show which tabs are
  active, sleeping (frozen, still in memory) or unloaded (no process, still listed so you can
  find them), and how long since you last looked at each.

## Darni 2026.1125.1433 — 2026-11-25

**Fixed**
- With a Peek open, Copy URL (⇧⌘C), Copy as Markdown and Copy as Quote copied the tab underneath.
  They now copy the page the Peek shows, also after you follow a link inside it.
- The reader keeps your place when you change its font or text size.
- While the reader is open, the toolbar takes the reader's colour (light, sepia or dark) instead
  of the page's.
- When you save a passkey on this Mac, Darni's sheet stays up and says "Waiting for macOS…" while
  macOS asks for Touch ID or your password, so the page no longer looks idle.
- Closing the welcome screen while its music played could crash Darni. It no longer can.

## Darni 2026.1125.1377 — 2026-11-25

**New**
- Reader view. On an article, click the page icon in the address field, or press ⌥⌘R, to read
  the text alone. Choose the font, size, width and theme (light, sepia, dark, or following the
  Mac). It is scripted, not AI. In private windows and containers it shows the text without
  pictures.
- Dark mode for websites, in Settings › General. Sites with a dark theme of their own use it,
  and other sites are darkened, with photos and videos left as they are. Change it for one site
  in the site controls beside the address. Clearing your history clears these choices too.
- Every way you copy a link now gives a clean link without tracking tags: Peek, Little Darni,
  the Archive, the command bar, split view and a page's Copy Link Address, as well as ⇧⌘C.
  Switch it off in Settings › Advanced.
- Tabs you haven't looked at for 30 minutes now go to sleep: they stop running in the background
  but stay loaded, and wake at once when you open them. After 4 hours a sleeping tab is unloaded
  to free memory, as before. Choose both times in Settings › General. A tab that is playing
  sound, being shared, on a call, downloading or waiting on you never sleeps.
- Passkeys on this Mac. When a site offers to create a passkey, you can now keep it on this Mac,
  protected by Touch ID or your Mac password. A passkey made this way stays in that profile on
  this Mac: it does not sync to your other devices or to iCloud. See and delete them in
  Settings › Profiles › Passkeys on This Mac. Signing in with your phone or a security key works
  as before.

**Good to know**
- If you go back to an older version of Darni, it cannot use passkeys made on this Mac. Install
  this version or a later one again to use them.

## Darni 2026.1124.1338 — 2026-11-24

**New**
- Sites can share your screen. When a site such as Google Meet asks to share, Darni shows a sheet
  where you pick a tab, a window or your entire screen; a window or the screen is picked in the
  macOS picker. While a tab is shared, a bar on it says "Sharing a tab with …" and has Stop, and
  the tab's row in the sidebar shows it too. A site can only ask right after you click or press
  a key on it, and a tab you share in the background is not told it is being shown.

## Darni 2026.1124.1329 — 2026-11-24

**New**
- A tab can be dragged from one window's sidebar into another window's sidebar, and it moves
  there. Moving a tab to a space in another profile or container asks first, as Move to Profile
  does.
- Little Darni opens where you last left one, at the same size and on the same screen.

**Security**
- The engine is updated to Chromium 156.0.8078.114, with Google's latest security fixes.

## Darni 2026.1123.1255 — 2026-11-23

**Fixes**
- An extension can no longer flood Darni with tabs or windows. Each extension can open up to 10
  tabs or windows in 10 seconds in a profile. If it asks for more, Darni stops it and shows a
  notice with the extension's name.
- A window an extension opens on its own, such as a sign-in or permission prompt, now opens
  behind the window you are using, unless you just clicked or typed in Darni. A notice in every
  Darni window says how many windows are waiting, and Show brings them forward. If you are in
  another app, Darni's Dock icon bounces once.
- Darni no longer downloads Live Caption's speech models, about 440 MB, the first time it starts.
  It also uses much less of your Mac's processor in its first minutes.

## Darni 2026.1122.1231 — 2026-11-22

**New**
- Split View panes can be put in a different order. Move Pane Left and Move Pane Right (Up and
  Down when the panes are stacked) are in the pane's split menu, in the menu of a pane's chip in
  the sidebar, in the View menu and in the command bar. You can also drag a pane's chip along
  the split's row in the sidebar. A pane keeps its width and its page when it moves.
- Add to Split View in a tab's menu adds the tab, or the selected tabs, to a split in the same
  space, up to four panes.
- Separate Page from Split View is now in the View menu, as in Arc, and takes the pane you are
  using out of its split. The split view items moved from the Tabs menu to the View menu.
- Settings › Profiles has a Download location row, to choose the folder for downloads.

**Fixes**
- An extension installed in more than one profile could make Darni switch between spaces
  without stopping, and fill Today with blank tabs. This happened when the Claude extension
  connected to Claude Code. An extension now selects a tab in its own space without bringing
  that space forward. The space on screen changes only after you click or type in Darni. If
  pages or extensions keep switching spaces, Darni stops following them for a minute and
  says so.
- The search engine choice in Settings › Profiles was missing when Darni had started normally.
  It is always there now, and it keeps listing every engine after you change it, including a
  custom engine you had chosen before.
- The Air Traffic Control window is wider, can be resized and keeps its size. Long space and
  profile names show in full, and the bin button of a rule is never under the scroll bar.
- File › Capture shows its shortcut as ⇧⌘2.
- The menu of a download in the sidebar no longer starts with "Ask Siri", and its tooltip shows
  the file's folder, not the whole path.
- Some labels said "Chromium" or "ReArc". They say Darni now, or name what they do.

## Darni 2026.1121.1164 — 2026-11-21

**Fixes**
- Going back on a tab opened from a link now takes you back to the tab you came from, as in Arc.
  A tab you open with ⌘-click, a middle click, or a link that opens in a new tab starts with no
  page behind it, so swiping back, ⌘[ and the Back button did nothing there. Now they close
  that tab and show the tab whose link opened it, if it is still open. Pinned tabs, favorites
  and tabs in a split view are never closed this way. Darni remembers which tab opened which
  only until it quits.
- Swiping back and forward with two fingers now works on sites such as YouTube and GitHub.
  There, the swipe scrolled the page instead of going back. It now goes back or forward as on
  any other site. A swipe over a row that scrolls sideways, such as a carousel, still scrolls
  the row until it reaches its end.

## Darni 2026.1120.1152 — 2026-11-20

**Fixes**
- An address you type or edit in the command bar now opens. Before, if a tab was already open
  on the same site, Darni offered only Switch to Tab, so Return went to that tab, sometimes on
  another account or page. Now the first row opens exactly what you typed: in a new tab after
  ⌘T, in the current tab after ⌘L. Switch to Tab is the next row, one ↓ away. Return on the
  address ⌘L filled in, left as it is, still keeps you on the tab without reloading it.
- A folder's menu has Move to Space. The folder moves to the other space whole, with its tabs
  and the folders inside it, in the same order.
- Little Darni's Open in button and its list of spaces look like Arc's. The button shows the
  space's name in the space's colour, adjusted so it is always easy to read, with ⌘O beside
  it. The arrow next to it opens a list of all your spaces with their icons. Type to search,
  use the arrow keys to move, press Return to choose and Esc to close.
- Open in on a Little Darni window now names the space of the Darni window you used last,
  also when that space is in another profile. The name and the toolbar colour change as soon
  as you click another Darni window or switch its space. If the space is in another profile
  or a container, the button and ⌘O ask first, because the page opens there without this
  window's sign-ins.
- Open in and its arrow stay in the Little Darni toolbar when the window is narrow. The
  address field shrinks first.
- The ⌃Tab switcher now looks like Arc's. Your recent tabs show as a row of cards, each with a
  small picture of its page and the site's icon and title beneath. The tab you are on is
  marked in your space's colour. A tab Darni has no picture of yet, such as one you have not
  looked at since Darni started, shows its site's icon instead. With more than five recent tabs, the row
  slides along as you press Tab, and arrows at its ends show there are more. The pictures stay in memory
  only. Darni never saves them to disk and never takes them in a private window.
- With the command bar open in one window, a click in another Darni window always closes the
  bar and brings that window forward. Until now the bar could stay open and the other window
  stay behind.
- The welcome page shows "Welcome to Darni" in the address field. The last scene of the
  first-run tour showed `rearc://welcome` there, and the window itself showed the long path
  of a file on your Mac. Command-L on the welcome page now starts with an empty field, as on
  a new tab.
- Hiding the sidebar with ⌘S now hides it only in the window you are using. Until now every
  open Darni window hid its sidebar too. The sidebar that floats in at the edge of a window
  also shows only in that window. A new window opens with its sidebar as the window you
  opened it from has it.
- With more than one window open, a question such as "Rename" or "Delete Space" shows only
  in the window you are using.
- Spotlight, Finder, the Dock and Launchpad show Darni for a copy updated from ReArc, which
  keeps its file name ReArc.app. Until now they showed ReArc there, and Spotlight did not find
  the app by "Darni". Typing "ReArc" still finds it.
- "Allow on This Site" in the list of what was blocked now lets the site through everywhere on
  the page. Until now it covered what the page itself asked for, and not what the allowed site
  asked for from a frame of its own. An ad or a video player you had allowed could then stay
  blocked, and the site stood under "Allowed on this site" and in the blocked list at once.
  Sites you allowed before are covered too. Nothing you have to do.
- The same holds for an exception you typed into your own blocking rules with `$domain=`, such
  as `@@||ads.example^$domain=news.example`, and for one that sync brought from another Mac: it
  now also covers what frames ask for in pages of that site. That allows more than before. If
  you wrote such a rule to allow less, look at it again in Settings › Profiles.
- A click on Allow in that list is no longer lost. A click that came very soon after the pointer
  reached the line could do nothing, with no sign. Now, if the line does not show "Allow" yet,
  the click makes it show, and the next click allows the site.
- When a site you allowed is still blocked on a page, the list says why: one of your own rules
  blocks it, or the page has to be reloaded.
- Settings counts your own blocking rules by the lines you wrote, and says when some
  exceptions cannot cover frames because the limit of 5,000 rules is reached.
- The arrow beside "Open in" in a Little Darni window now lists all your other spaces, in
  every profile, under each profile's name. Until now it listed only the spaces of the
  window's own profile. With one space in that profile there was no arrow at all, and a click
  moved the page straight into that space. A space in the same profile takes the page as it
  is. A space in another profile opens the same address in a new tab there, and the sign-ins
  of the first profile stay in the first profile, so you may need to sign in again. Darni
  asks before it does this and names the site and the space, and Cancel leaves the window as
  it is. The visit is then kept in that profile's history. Only web pages can open in another
  profile or container. For any other page those spaces are greyed out and the menu says why.
  From a container's window, the spaces of its profile are marked as outside the container.
- The red, yellow and green window buttons stay in their place. Until now they could jump up
  and to the left when you chose a tab or when a page changed its title, and they stayed there
  until you clicked another window and came back.
- The site controls panel no longer stays cut off after you click Allow in the list of what
  was blocked. Now and then the panel stayed too short, with its top buttons and bottom rows
  out of view, until you closed and opened it again.

## Darni 2026.1120.1105 — 2026-11-20

**Fixes**
- Spotlight finds Darni when you type "Darni" or "ReArc". After the update the app in your
  Applications folder is still called ReArc.app, and until now typing "Darni" found nothing. A new
  download, Darni.app, is also found by "ReArc".
- A boost for a site with an international name, such as `bücher.example`, now works. Until
  now a boost made by typing such a site in the Boosts library, or imported from a file, never
  matched the site.
- A boost that has stopped running says so in the Boosts library, with the reason, for example
  "Not running: web.app is shared by many unrelated sites." Make the boost again on the one
  site it is for.
- If the page changes while you choose "Turn Off Blocking for This Site", Darni says that
  nothing was changed, in that command's own words. It used to show the message that belongs
  to Allow.
- The site controls also mark an older "blocking off" entry that covers more than the site
  you are on without being a shared ending, such as `azure.com` for a site under it, and offer
  "Turn Off Blocking for This Site Only".

**Security**
- A boost that came from a file, carries a script and was set for a whole shared ending such as
  `web.app` is switched off when Darni starts, and Darni tells you which one. Such a boost
  could no longer run. Now it is also off, on your other Macs too if you sync.
- A boost file is refused when one of its sites is not a plain site name.
- The Boosts library and the sheets that ask you to allow a script or CSS show a boost's sites
  with invisible and text-direction characters removed.
- Allow in the "Blocked on this page" list is not offered on an error page, and it now judges
  the page's own site by the same list as the rest of Darni. A page on a shared ending such as
  `web.app` itself has no Allow.

## Darni 2026.1119.1080 — 2026-11-19

**ReArc is now Darni**
- ReArc has a new name, Darni. It is the same browser. Your spaces, tabs, bookmarks, history,
  saved passwords, sign-ins, passkeys, extensions and settings are where you left them, and
  nothing needs setting up again. Updates arrive the same way as before.
- If you update from ReArc, the app in your Applications folder is still called ReArc. The menu
  bar, the windows and the About window say Darni. Finder shows the file's old name, and the
  Dock may too, until you rename it. To rename it, quit Darni, change the name from ReArc to
  Darni in the Applications folder, then open it again. Renaming is optional. Updates work
  either way.
- A new download is called Darni. The disk image is named Darni and holds Darni.app.
- Keep one copy. The simplest way is to let ReArc update itself. If you download Darni instead,
  quit ReArc and move ReArc.app to the Trash before you open Darni. Both use the same data on
  your Mac, and two copies running at once can lose changes to your sidebar.
- Little ReArc is now Little Darni. Menus, Settings and messages use the new name throughout.
- The sunrise you see on first launch no longer lands on three words. It ends on the Darni name
  under the mark. The welcome page and the membership card show the name the same way.
- If 1Password stops filling in Darni, add it again in 1Password under Settings › Browser ›
  Add Browser, then restart Darni.
- macOS may still say ReArc in a few places that do not change with the name. The keychain
  item that protects your saved passwords is still called "ReArc Safe Storage", and your data
  stays in the same folder on your Mac. That is on purpose. It is what keeps you signed in.


**New**
- See what was blocked on a page. In the site controls (the button beside the address), the
  "Block ads and trackers" row now has an arrow beside "N blocked on this page". It opens a list
  of the sites whose requests were blocked on this page, each with how many and with what blocked
  it: Ad, Tracker, Annoyance, or Your rule for one of your own rules.
- Allow a blocked site on one site. Point at a line of that list and choose Allow: Darni adds one
  line to your own rules (Settings › Profiles › Advanced), reloads the page and shows the site
  under "Allowed on this site", where Remove takes it back. A name that is not one site, such
  as `localhost` or `co.uk`, has no Allow.
- The list is kept in memory, for that tab only, and starts again when the page loads. It is
  never saved, synced or sent anywhere, and it holds site names only, never full addresses. A
  private window shows the list without Allow. Very busy pages show the first 100 sites and how
  many more requests were blocked.
- A space's icon can be a picture. In Create a Space or Edit Space, under the icons, choose
  Choose Image… or Paste Image, or drop an image on the picker. A big picture is scaled down to
  icon size (64 pixels on its longer side) and kept whole, not cropped. Remove Image goes back to
  the space's icon. With Sync Sidebar on, the picture goes to your other Macs. A Mac still on
  ReArc shows the space's icon or emoji instead until it updates. Opening your profile in ReArc
  and coming back drops the picture unless Sync Sidebar brings it back, so set it again.

**Fixes**
- Emoji icons work again. The icon pickers for spaces, profiles, folders and tabs have an Emoji tab
  with every emoji, searchable by name ("dog", "rocket", "work"). Typing or pasting an emoji
  into the search field offers that one first, flags and skin tones included. Until now the
  Emoji & Symbols button did nothing in Create a Space, and an emoji picked from the system's
  palette closed the picker before it arrived.
- With two windows open on the same space, ⌘T and ⌘L open the command bar only in the window
  you are using. Until now it opened in both, and what you typed showed in both. Clicking into
  another window closes it.
- In a space with its own container, Settings' first tab and the membership card name your profile,
  not the container. Change Name renames the profile, and Settings › Profiles opens on the profile,
  where ad and tracker blocking is set (a container follows its profile).
- A page you cannot see gets no passkey request at all. A sign-in request from a background
  tab, a hidden or minimised window, a hidden Little Darni window or a window that another
  app's window covers is now refused as it starts, before Darni looks for a security key, a
  phone or Bluetooth. Until now it was refused a moment later, when its sheet was about to
  open, and on a Mac that had never answered macOS's Bluetooth question such a page could
  bring that question up. A request you started while its page was in view stays open when you
  switch away, as before. Darni's log now says when a request is refused.

**Security**
- "Turn Off Blocking for This Site" turns blocking off for the site you are on, worked out the way
  Chromium does, and never for a whole shared ending. In ReArc 2026.1118.1027, turning it off on a
  site such as `someone.web.app` stored `web.app`, which is every site under it, and the same for
  other shared addresses. Settings › Profiles › Advanced now marks such an entry "Off for every
  site under web.app", and the site's controls offer "Turn Off Blocking for This Site Only", which
  keeps blocking off for that one site and turns it back on for the rest. Darni does not change
  these entries by itself. A name like `web.app` or `co.uk` can no longer be added there.
- "Turn Off Blocking for This Site" acts on the page the panel was opened for. If the page
  changed in the meantime, nothing is changed and Darni says so.
- A boost can no longer apply to a whole group of unrelated sites. A boost made on
  `someone.web.app` or `school.edu.au` used to be scoped to `web.app` or `edu.au`, and a boost
  from a file could name such a scope and bring a script with it. Darni now refuses a boost
  whose scope is one of these shared endings, and a boost you already have with such a scope
  stops running. Darni does not yet point out which boost stopped. If a boost no longer works,
  open it and set its scope to the one site you want. New boosts are scoped to the site you are on.
- A long site address shortened in the address bar, Little Darni, Peek and the permission and
  sign-in prompts always keeps the site's own name. Until now a long name on a shared address
  such as web.app, github.io or vercel.app could show as "…web.app".
- A passkey or security key request that you left open in a tab or window you no longer see is
  cancelled when a page in front of you starts one. Until now it stayed open, and a touch of
  your security key meant for the page in front could have answered the older request.
- A page you cannot see can ask for a passkey over and over, and each try is refused. Darni's log
  now has one line for a tab's first refusal and counts the rest (a line at the 10th, the 100th,
  the 1000th and so on, and the total when the tab closes), so such a page cannot fill the log.

**Changes**
- The passkey sheet and the dialogs a page opens (alerts and confirmations, HTTP sign-in, choosing a
  certificate) use your space's colours, like Darni's notices and permission cards.

## ReArc 2026.1118.1027 — 2026-11-18

**New**
- ReArc can block ads and trackers itself, with no extension. A new install has it on, at the
  level Ads and trackers. If you already use ReArc, nothing changes until you turn it on: the
  sidebar offers it once, and the switch is in Settings › Profiles under Your Data and Settings,
  for each profile. Choose Trackers only, Ads and trackers or Strict. Advanced has the filter
  lists, your own rules and the sites you turned blocking off for. Private windows follow their
  profile.
- The site controls (the button beside the address) have a "Block ads and trackers" row. It
  shows how many requests were blocked on the page. Click it to turn blocking off for that
  site, or back on; the tab reloads.
- The filter lists (EasyPrivacy, Peter Lowe's list, EasyList, Fanboy's Annoyance list and the
  EasyList Cookie List) come with ReArc, so blocking works offline. ReArc looks for newer lists
  once a day at rearc.imara.ae and uses a download only if it carries ReArc's lists signature.
  The request carries no cookie or identifier, and none is made while blocking is off in every
  profile. What was blocked is counted on your Mac only.
- Your blocking settings sync with the profile when sync is on.
- Sign in with a passkey or a security key. When a site asks for "Face, fingerprint, PIN or
  security key", ReArc shows its own sheet, which names the site on every step: use a phone or
  tablet, or a USB security key with its PIN and touch. For a phone or tablet, scan the QR code
  with it. Bluetooth (which macOS asks you to allow the first time) only checks that the phone is
  near; the Mac and the phone then talk through a relay on the internet run by Google or Apple,
  encrypted between the two devices. Before this, such sign-ins waited and failed. A request from
  a background tab in a browser window is refused. Passkeys saved on this Mac or kept in iCloud
  Keychain are not available yet.
- The address bar has a site information button. It lists what the site may use (notifications,
  clipboard, camera, location and the rest, and devices it was given) with Allow, Block and
  Reset, and shows what it is using now. The site controls list the same, and a private window
  has its own.

**Security**
- The address bar can no longer be used to disguise a site. A long address is shortened from
  the left, so the site's real domain always shows; only the path is cut, at its end. Characters
  that reverse text direction or are invisible, and spaces, stay encoded (`%E2%80%AE`, `%20`)
  instead of being drawn. An IPv6 address keeps its brackets.

**Fixes**
- ReArc no longer quits when the program that started it has closed its log output.
- After Add Split View, the page you were typing in keeps the keyboard even when the Mac is busy
  and the new pane takes a moment to appear.

## ReArc 2026.1118.968 — 2026-11-18

**New**
- Arc's 56 space icons are in ReArc's icon pickers, in Arc's order, followed by the icons ReArc
  already had (house, briefcase, globe, graduation cap, game controller, cart, brush, hammer,
  camera, chart, cup). Icons of spaces imported from Arc, such as Arc's code and planet icons, now
  show instead of nothing. SF Symbols has no planet, egg, pizza or skull, so a globe, an oval, a
  takeaway bag and theatre masks stand in for them.
- Library › Spaces: drag a space's ✥ handle, at the foot of its card, to change the order of your
  spaces, or use the card's ··· menu (Move Left, Move Right). The order is the one the sidebar,
  ⌃1…9 and the space switcher use.
- Task Manager: double-click a tab or subframe, or right-click it and choose Show Tab, to see
  that tab in its window and space.

**Fixes**
- Swiping to a space (or switching to it any other way) no longer opens a tab by itself. The
  space shows the tab you used last there if its page is still open, otherwise nothing until
  you choose a tab.
- The address bar shows a page's port, so `localhost:3000` no longer reads as `localhost`.

**Changes**
- The sidebar no longer shows a scroll bar. It still scrolls.
- Library › Spaces looks like Arc's: each space is a card with rounded corners, 24 pt apart on the
  window's theme, with an edit button beside its name and its folders open or closed as in the
  sidebar.
- A site's permission request ("wants to use your camera…") and the offers to save a password,
  card or address now use your space's colours, like ReArc's other notices, instead of plain
  grey system controls.

**Security**
- The engine has the fixes for two bugs Chrome rates Critical, CVE-2026-131060 (MP4 video
  files) and CVE-2026-131031 (graphics), and for sixteen it rates High: in video files
  (CVE-2026-121047), WebGL shaders (CVE-2026-130910, -130954, -130996, -121037), graphics
  (CVE-2026-131002, -131007, -131076, -131083, -131103, -130940), JavaScript
  (CVE-2026-125344, CVE-2026-131042), page elements (CVE-2026-131068), layout
  (CVE-2026-130980) and extensions (CVE-2026-130909).

## ReArc 2026.1118.931 — 2026-11-18

This release also brings everything in 2026.1117.849 and 2026.1117.864 below (Task Manager,
Tab Groups, the 1Password card and their fixes), which were not announced on their own.

**Fixes**
- On first launch macOS no longer shows a "Chromium" notifications banner beside ReArc's: the
  helper that delivers website notifications now carries ReArc's name and icon. Camera,
  microphone, location and Bluetooth prompts say ReArc instead of Chromium, in every language.
- A two-finger swipe goes back or forward a page even when your fingers start slightly up or
  down, as they nearly always do. Before, ReArc judged the swipe by its first tiny movement, so
  most real swipes nudged the page sideways (on Pinterest, for one) instead of going back.
- A two-finger swipe goes back or forward a page in any ReArc window under the pointer, as in
  Arc, not only in the active one. Before, a swipe in a window behind another nudged the page
  sideways instead.
- Swiping between spaces in the sidebar moves the way your scroll direction setting moves
  content, as in Arc. With natural scrolling off it used to run the other way.
- A space swipe works over the sidebar while another app is in front, without clicking first.
  A second ReArc window behind the first still needs a click.
- A space swipe moves only sideways: the space's list no longer drifts up or down or shows its
  scroll bar at the start of a swipe.
- Two windows on the same space are no longer linked: each keeps its own selected tab, closed
  folders and multi-selection, so choosing a tab in one no longer changes the other, and a
  call's video shows only in its own window's sidebar.
- Clicking a tab that is playing video in a window behind moves it there in one click, not two.

**Sync**
- With Sync Sidebar on, a tab group's tab sends its new address to your other Macs only once
  it has stayed on that page for 2 seconds, so the short-lived sign-in redirects that carry
  one-time codes never sync.

**Security**
- The engine is updated to Chromium 156.0.8078.109, Chromium's latest security update for
  the 156 line.

## ReArc 2026.1117.864 — 2026-11-17

**Fixes**
- Tab groups are either open or closed. A closed group hides all its tabs; closing a group while
  one of its tabs is showing leaves a blank page, and the tabs stay loaded.
- Taking the last tab out of a tab group (closing, removing or dragging it) asks whether to delete
  the group, as Chrome does, with "Don't ask again".
- The ⌘T bar shows tab groups as coloured chips across the bar, so many groups fit. Tab moves into
  them and Return adds the chosen group to the space.
- Tab in the ⌘T bar accepts the suggested completion ("post" becomes "posthog.com") and keys typed
  in the bar never reach the page behind it.
- The "Connect 1Password to ReArc" card goes away by itself once 1Password is connected, and
  Settings › General says "Connected". ReArc only checks that 1Password's helper stays attached;
  it never reads what passes between them.
- A new tab group opens its name and colour editor straight away.

**Settings**
- Settings now say that, with Sync Sidebar on, the addresses of a tab group's tabs sync to your
  other Macs as they change.

## ReArc 2026.1117.849 — 2026-11-17

**New**
- Task Manager, as in Chrome: Window › Task Manager, or right-click empty space in the sidebar.
  It lists every tab, extension and engine process with its memory, CPU, network use and
  process ID, in three views (tabs and extensions, browser, all tasks), with search, sortable
  columns and a column chooser. End task stops a stuck page; its tab shows "This page crashed"
  with a Reload button.
- Tab groups, as in Chrome, off until you turn them on in Settings › General. A group is a
  coloured, named set of tabs that more than one space can show: change it in one space and
  every space that shows it sees the change. Make one by right-clicking "+ New Tab", empty
  sidebar space or a tab. ⌘T lists the groups this space doesn't show yet, and picking one adds
  it. Rename, recolour, ungroup, remove from a space or delete it from its right-click menu;
  deleting asks first, as Chrome does. A group's tabs never auto-archive.
- 1Password: a one-time card explains how to let 1Password unlock in ReArc (in 1Password,
  Settings › Browser › Add Browser, then choose ReArc). The same steps are in Settings › General.

**Fixes**
- Links from other apps set to open in Little ReArc always open in Little ReArc, as in Arc,
  even when the page is already a tab in one of your spaces.

## ReArc 2026.1116.820 — 2026-11-16

**Fixes**
- Scrolling no longer flickers. When you started scrolling again after a pause, the page went
  blank for a moment and jumped sideways, then came back.
- ⌃Tab opens the tab switcher after you've used a Little ReArc window. Once one had closed,
  ⌃Tab could do nothing in the main window.

**Security**
- The engine now carries seven fixes that Chrome 157 has and ReArc's engine line, 156, did not:
  CVE-2026-121083 (animations), CVE-2026-121100 (page elements), CVE-2026-121117 (backdrop
  filters), CVE-2026-121140 (WebGL), CVE-2026-121181 (text ranges), CVE-2026-121185
  (Picture in Picture) and CVE-2026-126845 (graphics). Chrome rates each High.

## ReArc 2026.1116.811 — 2026-11-16

**New**
- Video that only played in Chrome now plays in ReArc: H.264 and HEVC video, AAC audio and HLS
  streams, as on X, Reddit, Vimeo and most news sites, decoded by macOS's own decoders. Protected
  video (Netflix, Disney+ and other DRM services) still doesn't play.

**Fixes**
- A link from another app that an Air Traffic Control rule sends to an archived space now
  brings that space back and opens there, instead of disappearing.
- Little ReArc's toolbar keeps its height when your profile has a photo: the picture filled
  the toolbar instead of showing as a small round avatar.
- Little ReArc opens at a size you can read a page in, instead of a small window.
- Pages that open a window of their own (a site's Preview button, "Log in with Google" in an
  extension) now load in it, instead of leaving an empty about:blank tab.
- Settings › General shows when ReArc is your default browser, with a tick when it becomes the
  default, instead of asking again after you've chosen ReArc.

**Security**
- Crash reports stay in ReArc's own data folder instead of the Chromium folder other
  Chromium-based apps share.

## ReArc 2026.1115.802 — 2026-11-15

**Fixes**
- Archived spaces now sync to your other Macs with Sync Sidebar on (iCloud's server was
  updated for them on 14 November).
- Reopen Closed Tab brings a tab back in the space you're in when its own space has been
  archived since, instead of hiding it in the archived space.
- An extension can no longer open a tab in an archived space.
- A pinned tab can be removed from its row again: once it is closed, its button turns to ✕, and
  ✕ takes it out of the sidebar, as in Arc. ⌘W still keeps pinned tabs.
- A space you left blank comes back blank: a tab you closed no longer reopens after visiting
  another space.
- Closing the open tab in a pinned folder now leaves a blank page, as in Arc, instead of jumping
  to a Today tab. A collapsed folder no longer shows the closed tab.
- 1Password's extension can unlock with the 1Password app: when 1Password is set up for Arc
  or Chrome, ReArc uses the same link to the app. 1Password asks once to trust ReArc. Only
  1Password's link is used. Not yet checked end to end with 1Password.
- Archiving the space you're on shows Undo again (785 showed it only when archiving another
  space).
- A space in a container can now be archived. Its container and sign-ins wait with it, out of
  Settings › Profiles, and come back when you restore the space.

**Security**
- An extension can no longer open a tab in an archived space, where no list would show it.

## ReArc 2026.1114.785 — 2026-11-14

**New**
- Archive Space. Put a space away without deleting it: right-click the space and choose
  Archive Space, or use the Spaces menu or the command bar. It leaves the sidebar, the space
  switcher and ⌃1–9, and keeps its pinned tabs, folders, Today tabs, theme and icon exactly as
  they were. An Undo button shows straight after, in case you didn't mean it.
- Find archived spaces in Settings › Profiles under Archived Spaces. Restore puts a space back
  where it was and switches to it; Delete… removes it for good.

**Known**
- Archived spaces don't sync to your other Macs yet; they will once iCloud's server is
  updated for them. Macs on an older ReArc show archived spaces as ordinary spaces.

## ReArc 2026.1114.778 — 2026-11-14

**Security**
- Deleting a profile "from This Mac and iCloud" now removes an iCloud profile only when all of
  its spaces belong to the profile you are deleting. When that iCloud profile came from another
  Mac or an earlier install, the confirmation names it and lists its spaces. An iCloud profile
  that only shares some spaces with one of this Mac's profiles is listed under "In iCloud only"
  with its own Delete from iCloud…, and the profile on this Mac offers Put in iCloud….
- If iCloud's copy changes between the question and your answer so that it no longer belongs to
  the profile, nothing is deleted and ReArc says why.
- After a page keeps ReArc open at quit, quitting again within 30 seconds quits without asking.
  Any later quit asks "Leave site?" again and lets pages finish their work as usual.
- The engine now has the fix for CVE-2026-121203, a memory-safety bug in how pages watch
  elements change size. Chrome fixed it in 157; ReArc's engine line, 156, did not have it.
- ReArc turns off an engine memory optimisation that could be misused through preloaded pages
  (CVE-2026-121035). Tabs that are not loaded use slightly more memory until the engine
  carries Chrome's own fix.

**New**
- A space in a container is now easy to spot: its icon sits in a ring of the container's
  colour, and its profile picture has the same ring with a larger container badge. The ring
  and badge stay visible on every space colour, in light and dark; before, the badge took the
  space's own colour and disappeared into the sidebar.
- Site controls: pinned extensions have a blue pin button on their tile, as in Arc. Point at
  an extension that isn't pinned and a pale pin button appears; click it to pin the extension
  to the toolbar, and click a pinned extension's button to unpin it.
- Site controls: point at an extension to see its name. Manage shows when you point at the
  Extensions section, as in Arc.

## ReArc 2026.1114.767 — 2026-11-14

**Fixes**
- The icon you pick in Settings › Icon is now ReArc's icon everywhere: in Finder,
  Applications, Spotlight, Launchpad and the Dock while ReArc is closed. Before, only the
  Dock icon of the running app changed. ReArc puts your icon back after each update. If
  ReArc is installed where your account can't write (an app folder owned by another
  account), only the running app's icon changes, as before.

**Known**
- The Dock may keep showing the old icon for a ReArc tile kept in the Dock until you
  log out or restart.

## ReArc 2026.1113.765 — 2026-11-13

**Fixes**
- Turning Sync Sidebar on can no longer empty your sidebar. If you had deleted a profile's
  copy from iCloud, the first sync after turning sync on treated this Mac's spaces as deleted
  too and removed them. Now, when iCloud holds no space, the first sync uploads this Mac's
  whole sidebar, and a profile you put back in iCloud wins over iCloud's old deletions.
- A fresh install no longer lists your imported profile under "In iCloud only". Each install
  gives the profile a new ID, so iCloud's copy of the same spaces looked like a different
  profile; ReArc now recognises it as yours.
- The Sync Sidebar switch can be switched off while ReArc is still looking at iCloud, and that
  cancels the look. Before, it showed off during the look and could turn itself on afterwards.

**New**
- Settings › Profiles has Sync Sidebar itself: the iCloud row says where the profile is
  ("Synced with iCloud", "On this Mac and in iCloud" or "Only on this Mac"), and the same
  switch as the account tab turns sync on or off for every profile. Turning it off changes
  nothing in iCloud.
- Put in iCloud… puts a profile that is only on this Mac back in iCloud, from the iCloud row
  or the profile's right-click menu. With sync off it turns sync on, looks at iCloud first and
  asks before changing anything there.

## ReArc 2026.1113.761 — 2026-11-13

**Fixes**
- Quitting always ends. A quit that stalled left ReArc running half-stopped: ⌘Q and an
  update's restart did nothing, the update never installed, and every tab opened after it
  ran on the system's WebKit instead of ReArc's engine, with its own sign-ins and a menu
  whose Download Image saved nothing. Now a quit that has not started after 10 seconds is
  forced, and one where no tab has closed for 45 seconds saves your sidebar and windows and
  ends ReArc, so an update always installs. Choosing Stay on a "Leave site?" puts ReArc
  back exactly as it was, and the next ⌘Q quits at once.
- No page runs on WebKit any more: a tab asked for while ReArc starts or quits waits for
  the engine.
- Quitting is quick. ReArc's windows, Dock icon and menu bar go the moment you quit, and
  the engine now closes every page that has nothing to ask together, as Chrome does,
  instead of one tab after another. Pages with a "Leave site?" still ask first, and nothing
  else closes until you answer.

**New**
- Right-click an image or a link and the menu follows Arc's: Open Link in New Tab, New
  Window, Split View, Little ReArc and Private Window; Save Link As… and Copy Link Address; Open Image in New
  Tab, Save Image As…, Copy Image, Copy Image Address, and Search Google (or Bing) for Image
  when that is your search engine.
- Downloads have one menu in the downloads tray, the download stack at the bottom of the
  sidebar and the Library: Open, Show in Finder, Pause or Resume, Cancel, Copy (the file
  itself, to paste into Finder or Mail), Copy Download Link, Move to Trash and Remove from
  List. Tray rows show the image's thumbnail, open with one click and drag out to Finder.

**Known**
- Capture Image… is not there yet.

## ReArc 2026.1112.749 — 2026-11-12

**New**
- The command bar looks and moves like Arc's. ⌘T opens a solid card over the page, with no
  dimming behind it. The selected row is filled with the space's colour. Results are in a
  clearer order: open tabs that start with what you typed, then the site the field completed
  to, then a plain search for your text, then history. An empty ⌘T lists your five most
  recent tabs.
- Site search shortcuts. Type a site search's keyword and the field shows "Search <name>"
  with a Tab key. Press Tab and the site's name appears as a chip in the site's colour, the
  list folds away, and you finish the search. From then on only your earlier searches on that
  site are suggested. While a chip is on, what you type goes nowhere until you press Return.
  The exception is your default search engine, which suggests as it does in the plain bar.
- Bring your site searches from another browser. File › Import from Another Browser… has a
  new "Site searches" choice for Arc, Chrome and the other Chromium browsers. It brings the
  keyword, name and search address of the ones you added yourself.
- A container now belongs to its profile. "New Container for This Space" keeps the space
  where it is, in the same profile and the same place in the strip, and gives that space its
  own cookies, sign-ins and site data. A container is no longer listed as a profile. Every
  tab in a container shows a chip with the container's name in the address area, in split
  panes, in the tab's hover card and in a Peek, and the space's icon carries a badge. The
  space menu has "Remove Container…", which puts the space back in the profile's own session
  and deletes the container's data after a confirmation.
- Profile menus tell you more. Each profile shows its avatar, its number of spaces and a
  checkmark when it is the active one. The menu on the avatar at the top is headed "Switch
  to Profile"; the one beside the space name is headed "Switch Space to Profile".
- A picture as a profile's avatar. Settings › Profiles › Avatar and colour › Edit… has
  Choose Image…, and you can also drop or paste one. ReArc keeps its own small copy with the
  metadata removed. The picture stays on this Mac; other Macs show the profile's symbol or
  emoji.
- See and manage your profiles in iCloud. Settings › Profiles shows whether each profile is
  on this Mac and in iCloud or only on this Mac, and lists the profiles that are in iCloud
  only, with their spaces. "Delete from iCloud…" deletes one profile, its spaces and their
  tabs from iCloud and nothing else. It works with Sync Sidebar off, and it saves what it
  deletes to a file in ReArc's Backups folder first. The records are marked deleted the way
  sync deletes; a Mac that syncs clears them out for good after 30 days.
- A new version shows the way it does in Arc. A pill at the bottom of the sidebar reads "New
  ReArc Version Available". Rest the pointer on it for the "Automatic Updates" checkbox and
  "Restart and Update", which installs and reopens ReArc with your windows. A security fix
  reads "Critical Update Available"; an update that a build can no longer do without reads
  "Required Update". Neither forces anything: you still choose when to restart.
- Settings › Max is back, and none of it is AI. Tidy Tab Titles, Tidy Downloads, Tidy Tabs
  and Instant Links are small scripted helpers: each follows fixed rules on your Mac and
  sends nothing anywhere. The assistants in the command bar are only shortcuts that open
  ChatGPT, Claude or another company's own site with what you typed. ReArc itself runs no
  AI. Everything in the tab is off until you turn it on.
  - Tidy Tab Titles shortens a tab's title when you pin it. A title you typed is never
    replaced, and Reset Title brings the page's own title back.
  - Tidy Downloads gives a finished download a clearer name. It never overwrites a file,
    never changes the extension, and leaves installers, disk images and scripts alone. The
    Downloads tray shows the earlier name with "Use Original Name".
  - Tidy Tabs: with more than six Today tabs, a broom by the Today divider files them into
    folders by topic and site. One Undo puts every tab back.
  - Instant Links: ⇧↩ on a search opens its first result (DuckDuckGo and Google; other
    search engines open their results page). Searches separated by commas open one tab each,
    five at most.
  - Assistants: ChatGPT, Claude, Perplexity, Grok, Le Chat and HuggingChat open with your
    text filled in. Gemini, Copilot, DeepSeek and Kimi cannot take text in their address, so
    ReArc opens the site and copies your text for you to paste. You can add your own.
- New app icons, all drawn from ReArc's own sunrise. Settings › Icon has two lists. Along the
  Sun's Path shows the mark at five moments of the sunrise: ReArc, First Light, Daybreak,
  Golden Hour and Moonrise. Treatments shows it in other finishes: Neon, Fluted Glass,
  Sorbet, Sketchbook, Prism and Graphite. Each row says in a few words what it is, and the
  one in use is marked Current icon. As before, the Dock shows your choice while ReArc is
  running; Finder and Launchpad keep the standard icon.
- The first time you switch to the mini sidebar (⇧⌘S), a note says the address bar can hide
  itself, with a button to the setting.
- A new version number. ReArc's version is now the release date and the build, as in
  2026.1112.749: year, month and day, then the build. Builds up to 677 were all "0.1.0" with the
  build in brackets. Updating from an older build works as before.
- About ReArc shows the latest version. Under your version it says "You have the latest
  version." with the time it last checked, or "Latest: … — Update available" with Restart
  and Update. Opening About checks quietly, at most once a minute.
- The media player in the sidebar tells you where the tab is. Rest the pointer on the player
  and under the title it names the space and folder the playing tab is in. Clicking it now
  also opens a collapsed folder, scrolls to the tab, and switches profile when the tab is in
  another one.

**Changed**
- "Play video in the sidebar" is gone from Settings › Advanced for now. It used the same
  drawing that was black, and comes back when that is fixed.
- Containers you made before this build still show as profiles, because nothing recorded
  which profile they came from. Settings › Profiles offers "Make This a Container of ▸" on
  any profile with exactly one space. Nothing changes until you choose.
- Deleting a profile deletes its containers too; the confirmation names them.
- "Auto-hide address bar" in Settings › Advanced no longer needs "Show URL in toolbar" to be
  on, because the mini sidebar always puts the address in the toolbar.
- With Instant Links on, ⇧↩ on a plain web search opens the first result. It used to open
  the search in Little ReArc, and still does for addresses, tabs, history and site searches.
- The command bar no longer has a row of key hints under the list; a row's tooltip shows
  them.
- In the space header, the "…" button now appears to the left of the profile avatar, so the
  avatar no longer moves when the pointer comes over the header.
- The old alternate icons (Sextant, Compass, Loupe, Arch, Aperture, Monogram and Electric
  Arc) are gone. If you had chosen one, ReArc shows its standard icon after this update;
  pick a new one in Settings › Icon.

**Fixes**
- Picture in Picture shows the video again. In every build so far the floating video window
  was black: sound, no picture. You saw it when you left a playing video's tab with the
  window covered or minimized, or pressed the player's Picture in Picture button. The
  floating window is now the engine's own, and it shows the video.
- You can always find a playing video. The player in the sidebar now stays whenever the
  playing tab is off screen, also while the video is in the floating window. Before, the
  player hid behind that window, and with the window black there was nothing left to click.
- A tab that is playing in another space is no longer archived by "Archive tabs after". Tabs
  in a call are spared too.
- A player you closed with ✕ comes back when the next track of a playlist starts.

**Known**
- Site searches you add in the engine's own search settings page do not become shortcuts
  yet; imported ones and the built-in list do.
- Tidy Tabs puts its folders in the Pinned section, because folders only exist there. Until
  you undo, those tabs are pinned, and with Sync Sidebar on they sync.
- With Instant Links on, a single search that contains a comma is split into several.
- After Tidy Downloads renames a file, the engine's own downloads page still shows the
  earlier name.
- "Delete from This Mac and iCloud" on a profile does not delete its containers' records
  from iCloud when Sync Sidebar is off; the confirmation says so.
- Clear Browsing Data does not clear your earlier site-search queries; Clear Command Bar
  History does.

## ReArc 0.1.0 (677) — 2026-11-12

**New**
- Peek looks and works like Arc's. ⇧-click a link and it opens in a borderless card over the
  page, with three round buttons floating at its top right: close, expand into a tab, and open
  in Split View. Click anywhere outside the card, the sidebar included, and it closes. Esc
  closes it too. Expand (or ⌘O) keeps the page as it is: the same scroll position, what you
  typed, and its back history.
- Select several tabs. ⌘-click adds or removes a sidebar row and ⇧-click selects a range; the
  tab you are on is part of the selection. Right-click the selection for Copy Links, Copy
  Links as Markdown, Pin, Unpin, Add to Favorites, Duplicate, Open in Split View, Move to
  Folder, New Folder with Selection, Move to Space and Archive. Move to Profile sends the
  selection to a space of another profile, after one confirmation that says what stays behind
  (cookies and sign-ins). ⌘C and ⇧⌘C copy the selection's links one per line and ⌘W closes
  the whole selection. Drag one selected row and the rest come with it. Esc clears the
  selection.
- Mini sidebar. ⇧⌘S shrinks the sidebar to a column of site icons, in the same order as the
  full sidebar; ⇧⌘S again brings the full sidebar back. ⌘S still hides and shows the sidebar,
  and a mini sidebar comes back mini. Each window remembers its own mode. View › Show Mini
  Sidebar does the same.

**Changed: Sync Sidebar is off by default**
- 608 switched Sync Sidebar on by itself after onboarding. If your iCloud already held a ReArc
  sidebar from an earlier install, that sidebar was merged into what you had just imported,
  without a word. ReArc no longer turns sync on by itself, on a new install or an existing
  one.
- If Sync Sidebar was on in 602, 605 or 608, it is off after this update, whether ReArc or you
  switched it on: those builds did not record which. Nothing on your Mac or in iCloud is
  changed by that. If you sync between Macs, turn it on again in Settings › Account on each.
- Turning it on looks first. Settings › Account › Sync Sidebar reads what is in iCloud before
  anything is merged. If iCloud already has a ReArc sidebar, a sheet says so, with how many
  spaces, pinned tabs and favorites it holds, and warns that it can change what is on this
  Mac, including what you just imported. You choose: use the iCloud sidebar on this Mac,
  replace what is in iCloud with this Mac's sidebar, merge both, or cancel. Each of the first
  three saves this Mac's sidebar to a backup file before it changes anything. Cancel is the
  default and changes nothing.
- Manage what is in iCloud. Settings › Account has a new "Sidebar in iCloud" box that shows
  what iCloud holds and when it was last edited, with Use on This Mac…, Replace iCloud with
  This Mac… and Delete iCloud Content…. Reading a large sidebar can take half a minute or
  more; the box shows progress while it reads.

**Fixes**
- Imported spaces no longer look empty, and Arc spaces are no longer duplicated. Up to 608,
  every install imported each Arc space as a new space, and merging with iCloud left several
  copies of one space, only one of which held the tabs. Switching between spaces landed on
  the empty copies, so it looked as if the tabs were gone. They were not. On first launch this
  build merges the copies of each Arc space into one and keeps every tab. Your sidebar file
  is saved first, beside the original, as `sidebar.before-arc-twin-repair-<time>.json`. From
  now on, importing the same Arc space on two Macs, or twice, gives one space.

**Security**
- The engine is updated to Chromium 156.0.8078.100, Chromium's latest security update for
  the 156 line.
- A shipped ReArc no longer accepts a data folder, a profile folder, the self-test or the
  launch probe from the command line or the environment, so another program cannot start
  your ReArc on a folder of its choosing.
- Sync uploads a pinned tab's saved address, never the page you happen to have open in it,
  and only web pages become synced tabs. A first join keeps iCloud's copy of rows it already
  has, and records that cannot be valid are set aside instead of applied.
- Boost CSS is checked the way the engine reads it, and CSS that arrives in a Boost file waits
  for your review. A Boost with no approval record approves nothing.
- Importing from other browsers opens no links, stays inside the browser's own folder, and
  limits how deep and how large a bookmarks file it reads.
- A shipped ReArc ignores the engine trace switch, so a program that starts ReArc cannot make
  it write page addresses and titles to a file of its choosing.
- A release build clears the TLS key log and Google key overrides from its environment before
  the engine starts.
- The Delete Profile dialog says when a container's browsing data stays on disk, and a deleted
  container that comes back through sync is not deleted again at the next launch.

**Known**
- ⇧⌘S was Save Page As in Arc. ReArc never had Save Page As, and the keys now toggle the mini
  sidebar.
- ⇧⌘T after ⌘W on a selection can take two presses: the tab you were on comes back first,
  then the rest together.
- Using or merging the iCloud sidebar on a second Mac can put spaces in a profile that is new
  on that Mac. Sites then ask you to sign in again there, and the cookies and history of the
  profile those spaces were in stay on disk, where ReArc no longer shows them. The sheet warns
  about the sign-ins. Replace keeps no copy of what iCloud held.
- A page that adds history entries from script, without a click, gets no Back entry for them
  in a Peek or after Expand, as in Chrome.
- For sites opened in 605, their older local storage is still on disk but not yet restored
  (see 608).

## ReArc 0.1.0 (608) — 2026-11-11

This build replaces 605 and 602, which were both withdrawn within about an hour of release.

**If you installed 605**
- 605 lost website data on profiles made by earlier builds: sites' local storage read as
  empty, and a site's IndexedDB data was deleted the first time you opened that site in 605.
  Cookies and sign-ins that rely on them were not affected.
- This build stops the loss. Sites you did not open in 605 have all their data. For sites you
  did open, what they stored before 605 in IndexedDB is gone; their older local storage is
  still on disk but not yet restored.

**Fixes since 605**
- Website data made by builds 500, 544 and 564 reads back again. The engine runs with the
  same feature set those builds used, with one change: Safe Browsing uses the list protocol
  Google serves, so the threat lists arrive.
- HTTP cache and connection partitioning, which 602 and 605 had switched off, are on again.
- ReArc opens on profiles made by earlier builds. 602 quit at launch on them; if 602 will not
  open, install this build over it.
- Every release now has to read back, in the new build, website data stored by the release
  before it.

**New**
- Your Arc card comes with you. Settings › your name › Import Your Card from Arc brings over
  your Arc membership card: its title, shape and colours, and your Arc member-since date. The
  card plays an Arc to ReArc transition that you can replay, and the import is offered again
  after Randomize. From Arc's sign-in file ReArc reads only the account's creation date and
  name.
- Onboarding finds all your browsers. The browser step now lists every browser on your Mac,
  including the ones macOS keeps private: Chrome, Brave and Safari show as Locked, with one
  Allow access… button that opens System Settings beside the onboarding. Switch ReArc on (a
  small panel gives you the ReArc icon to drag in if it is not listed), come back, and they
  turn to Found. If macOS reopens ReArc, the onboarding resumes at the same step. The Import
  window works the same way.
- More browsers to import from: Chrome Beta, Dev and Canary, Brave Beta and Nightly, Edge,
  Vivaldi, Opera, Opera GX and Chromium, plus Safari (bookmarks, Reading List and history) and
  Firefox (bookmarks and history). Passwords and cookies are still never read.
- Manage Extensions: the site control panel has a Manage link beside the "+" that opens the
  Chrome Web Store, and every extension tile's right-click menu has Manage Extensions….
- Sync Sidebar is on by default once onboarding finishes, when you are signed in to iCloud. If
  you turned it off, it stays off. Sync problems show a plain message, with the technical text
  under Details.
- Little Arc is now called Little ReArc.

**Security**
- Safe Browsing now works. Builds 544 and 564 said it did, but their engine never received
  Google's threat lists, so they showed no phishing or malware warnings. The engine no longer
  runs Chromium's test configuration, the lists arrive within a few minutes of first launch,
  and Settings › Profiles shows the real state: Starting, On, Not working or Out of date. A
  release cannot be built unless a test launch receives the lists.
- With the address bar auto-hidden, it shows for three seconds whenever you arrive at a
  different site, and stays while a permission, sign-in or certificate prompt is up.
- A popup or new tab opened from a Little ReArc in another container opens in that container,
  under its own badge. Links, searches, Boosts and command-bar history no longer cross
  containers. Deleting a container closes its Little ReArcs and removes its data.
- Boost CSS needs your approval on each Mac, like Boost scripts, and can no longer load
  anything from the web. Approving a script shows its code first, and a script runs only if
  the code is what you approved.
- Extension install and permission sheets appear one at a time, and Return always cancels.
- A release build no longer runs its self-test against your real profile.

**Fixes**
- Sidebar text is readable on every space colour. On mid-tone and vivid themes the space
  name, New Tab and icons were almost the colour of the sidebar.
- Syncing Boosts no longer fails with "Cannot create new type SidebarBoostRecord", and one
  rejected kind of record no longer holds up everything else waiting to sync.
- Settings › Links shows rearc.imara.ae, and Share ReArc links to it.

## ReArc 0.1.0 (605) — 2026-11-11

Withdrawn. It lost website data on profiles made by earlier builds.

## ReArc 0.1.0 (602) — 2026-11-11

Withdrawn. It quit at launch on existing profiles. Everything it added is in the next build.

## ReArc 0.1.0 (564) — 2026-11-10

Correction, 2026-11-11: Safe Browsing did not work in this build. See the next release.

**New**
- Auto-hide address bar: Settings › Advanced › Auto-hide address bar. The address bar slides
  away when you move onto the page and comes back when the pointer reaches the top of the page
  or you press ⌘L. In split view each pane's bar hides and shows on its own. It is off by default.
- Containers: a space can have its own profile, with its own cookies and sign-ins, so the same
  site can be signed in with different accounts in different spaces. Choose it from the profile
  badge next to the space name, the space menu's Change Profile, or the space's edit sheet.
  Settings › General › New spaces decides whether new spaces share the default profile (the
  default) or get their own container.
- Onboard later: if you choose Onboard later, a card at the bottom of the sidebar and
  ReArc › Finish Setting Up ReArc… bring you back to importing from Arc, Chrome or Brave.
  Closing the card keeps the menu item; importing or choosing Start Fresh removes both.

**Fixes**
- The profile badge next to the space name is legible on every theme, and the profile list is
  never empty: it always shows your profiles, New Profile… and New Container for This Space.
- The New Tab row in the sidebar is easier to read on coloured themes.
- Opening split view while the page has keyboard focus no longer crashes.
- Removing or editing a boost while its page is loading no longer leaves the old boost applied.

## ReArc 0.1.0 (544) — 2026-11-10

Security release candidate. It fixes the findings of the security review of build 500.

**Security**
- The engine moves to Chromium 156.0.8078.96, with 65 security fixes from Google, including
  CVE-2026-125350, which is exploited in the wild. Release builds now refuse an engine that is
  behind Chrome's latest Mac security release.
- Safe Browsing was meant to work from this build: the key and the page checks are in.
  Correction, 2026-11-11: it did not. The engine never received Google's threat lists, so this
  build showed no warnings. The next release fixes it.
- ReArc ignores debugging and sandbox-weakening launch switches, so another program can no
  longer relaunch it with remote debugging to read your cookies.
- Permission prompts ignore clicks and keys for half a second after they appear, and
  "Remember this decision" starts off. Extension install and permission dialogs work the same
  way, and Return means Cancel on permission requests.
- Extensions from another browser install from the Chrome Web Store only, and only the ones
  counted when you agreed. A Web Store version asking for more permissions than your old copy
  asks you first. Unpacked extensions are listed with their folder, to load by hand.
- Onboarding no longer copies the password database, even to count it, and the importer no
  longer opens Arc's sign-in file.
- A password found in a data breach now shows a warning.
- Page full screen names the site that took it over.
- Links opened from the context menu open as link clicks, from http and https only, and carry
  the page that linked to them.
- Automatic Peek ignores clicks a page fakes with script.
- The call card shows a microphone or camera as live whenever it is recording, whatever the
  page says.
- Script boosts that arrive by iCloud sync stay off until you approve them on this Mac.
- Updates: the Sparkle feed is signed and each update is verified before it is unpacked.
- Search suggestions are fetched over https only, and prompts show http:// for insecure sites.

## ReArc 0.1.0 (500) — 2026-11-10

Release candidate. Developer ID signed, notarized, Production iCloud.

**Onboarding and first run**
- The sunrise onboarding now plays on every new install, and again on the next launch if
  it was quit or interrupted before it finished. Existing installs are never onboarded again.
- A new install starts empty, with no sample spaces, tabs or favorites. The onboarding
  creates your spaces; skipping it gives one empty space.
- Resuming an interrupted onboarding reuses what it had already imported, with no duplicate
  spaces or profiles, and the welcome page counts your spaces correctly.

**Importing from Arc, Chrome and Brave**
- Extensions install by themselves in the background after the onboarding, with a quiet
  progress count and one "N extensions installed" toast. No list to step through.
- Extensions are consolidated first: one copy of each across browsers and profiles, and none
  that are built in, turned off everywhere, retired or already installed.
- Extensions' welcome pages open unselected at the bottom of Today; ReArc's own welcome page
  stays in front.
- Importing again never duplicates anything. Sources already brought over say "Imported",
  and only new items come over.
- Arc's bookmarks no longer come in as an extra space that repeats your sidebar.
- The Import window's Spaces & Sidebar pane shows what came over.

**Sidebar**
- Closing a pinned tab ("—", Close and Keep Pinned, ⌘W) unloads it without opening the next
  pinned tab in the folder.
- Folders show an open-folder icon when expanded and slide open and closed, as in Arc; a
  folder holding a loaded tab shows "•••" and offers Close This Folder.
- The close button sits on a rounded chip: "—" for pinned tabs, × for Today tabs.

**Developer tools**
- ⋮ › Dock side: right, left, bottom or a separate window, remembered between uses.
- The device toolbar (⌘⇧M) works docked and in a separate window.

**Windows**
- ⌘W closes About, Settings, Import and the developer tools window when they are in front,
  instead of the tab behind them.
- The About window's sting and text no longer overlap.
- The DMG window leaves room for Finder's path bar and status bar.

**Reliability**
- A page capture and the toolbar colour sampling no longer collide.

## ReArc 0.1.0 (469) — 2026-11-09

First notarized alpha, distributed as a Developer ID signed DMG.

- About ReArc, first in the ReArc menu, with the ReArc sting, version, Chromium engine
  version and copyright, and links to the Chromium credits.
- chrome://credits opens in ReArc with Chromium's open source licences.
- Automatic updates through Sparkle: ReArc › Check for Updates…, with an "Update Available"
  badge, from https://rearc.imara.ae/updates/appcast.xml.
- Developer ID signing, notarization and a signed DMG.
