# StoreAutopilot

Release a Flutter app to the App Store and Google Play by pushing to a branch.

You push to `release`. Your Mac takes fresh screenshots of the app on iPhone and iPad simulators and an Android emulator,
puts them into store images with your captions and colors, builds the app, uploads it to TestFlight and Google Play,
and updates the store text and images. When you want the version to go live, you click one button.

It costs nothing to run, your repository stays private, and your keys never leave your Mac.

## Why

Shipping an update usually means an hour of store chores: new screenshots for every language, resizing them, writing
the same text into two web consoles, bumping build numbers, building twice, uploading twice. StoreAutopilot does all
of that from two files that live in your app's repository:

- `storeautopilot.yml` – which platforms, languages, screenshots and brand colors
- `store.md` – everything the stores show: name, description, keywords, release notes, screenshot captions

Edit those files, push, and the stores follow.

## How it works

StoreAutopilot runs on your own Mac as a GitHub Actions runner for your private repository. GitHub runners on your own
machine are free, so there are no paid build minutes. A push to the `release` branch starts this:

1. **Store check.** It asks App Store Connect and Google Play about the app before anything is built. If the version
   in your `pubspec.yaml` is already live or approved and waiting to be released, it stops right away and tells you
   which version to use instead. Otherwise it takes the highest build number of both stores and uses the next one on
   both.
2. **Screenshots.** It runs your screenshot test (a normal Flutter integration test) on a 6.9" iPhone simulator, a
   13" iPad simulator if your app runs on iPad, and an Android emulator, once per language. Each device is captured
   separately, so each store gets real screenshots of its own platform.
3. **Store images.** Each screenshot is placed into an HTML template with its caption and rendered with headless
   Chrome at the exact size each store requires. A Google Play feature graphic is made the same way.
4. **Build and upload.** The iOS app is built and uploaded to TestFlight. The Android app bundle is built, checked to
   be signed with your upload key (not the debug key), and uploaded to the Play track you chose.
5. **Store listing.** Text and images are uploaded only if they changed since the last release.

Submitting for App Store review and promoting to Google Play production is a separate, manual step, so a careless
push never ends up in front of reviewers or users.

## Requirements

- A Mac with Xcode and an iOS simulator runtime
- Flutter
- Android Studio with the Android SDK and at least one emulator (AVD)
- Google Chrome
- Homebrew (it brings Ruby and fastlane along); without it, Ruby 3.1 or newer and fastlane
- GitHub CLI, logged in (`brew install gh && gh auth login`)
- Your app in a **private** GitHub repository
- An Apple Developer account and a Google Play developer account

## Install

    brew install yenerahmetfahri/storeautopilot/storeautopilot

This also installs Ruby and fastlane. Check it works:

    storeautopilot --version

To update later: `brew upgrade storeautopilot`.

Without Homebrew, clone the repository and link the command:

    git clone https://github.com/yenerahmetfahri/StoreAutopilot.git ~/StoreAutopilot
    ln -s ~/StoreAutopilot/bin/storeautopilot /opt/homebrew/bin/storeautopilot

## Try it first

The [example](example) folder of this repository holds a small Flutter app that is already set up. To see the store
images it produces on your Mac, without any store account or upload:

    git clone https://github.com/yenerahmetfahri/StoreAutopilot.git
    cd StoreAutopilot/example
    storeautopilot shots

## Set up an app

You do this once per app. `storeautopilot doctor` checks every step below and tells you what is still missing, so run
it whenever you are unsure.

### 1. Add the files

In the root of your app's repository:

    storeautopilot init

It asks a few questions — the app's name, languages, support and privacy URLs, App Store category, whether the app
shows content it doesn't own or uses its own encryption, a brand color — and fills in the files with the answers.
Press Enter to keep a suggestion; everything can be changed later. It adds the following and never overwrites a file
that already exists:

| File | What it is |
|---|---|
| `storeautopilot.yml` | Settings. Bundle ID and package name are filled in from your project. |
| `store.md` | Store text for every language. |
| `storeautopilot/frame.html`, `feature.html` | Templates for the store images. Change them as you like. |
| `integration_test/store_screenshots_test.dart` | The screenshot test you fill in. |
| `test_driver/store_screenshots_driver.dart` | Saves the screenshots. No need to touch it. |
| `.github/workflows/store.yml` | The GitHub Actions workflow. |

It also adds `integration_test` and `flutter_driver` to your dev dependencies, adds rules to `.gitignore` so keys
and keystores can't be committed, and creates a private folder for your keys: `~/.storeautopilot/<app_id>/`.

### 2. Fill in the settings

`storeautopilot.yml`:

```yaml
app_id: my-app                 # name of the key folder, ~/.storeautopilot/my-app
flutter_project: .             # where pubspec.yaml is

locales:                       # your language ids → each store's language code
  en: { apple: en-US, play: en-US }
  de: { apple: de-DE, play: de-DE }

screenshots: [01_home, 02_game, 03_stats]   # in the order the stores should show them

brand:
  background: "#111827"
  text: "#FFFFFF"
  accent: "#F59E0B"

ios:
  bundle_id: com.example.myapp
  # ipad: false                # default: follow the Xcode project (iPad screenshots if the app runs on iPad)
  # phased_release: true       # after approval, release to users gradually over 7 days
  # testflight_notes: true     # release_notes become TestFlight's "What to Test" (the upload waits a few minutes)
  # uses_encryption: false     # only encryption built into iOS (HTTPS…): no export compliance question per build

android:
  package: com.example.myapp
  track: internal              # internal, alpha, beta or production
  release_status: completed    # use "draft" while Play still treats the app as a draft
  # emulator: Pixel_8          # AVD to use; default is the first one
  # keystore_properties: ~/Keys/my-app/key.properties   # lets doctor check signing
  # rollout: 20                # production starts with 20% of users (see "Going live")
  # halt_crash_rate: 1.09      # rollout watch halts above this crash rate (percent)
```

Leave out `ios` or `android` if you only publish to one store.

### 3. Write the store text

`store.md` has a short header for links, then one section per language:

```markdown
---
support_url: https://example.com/support
privacy_url: https://example.com/privacy
marketing_url: https://example.com
copyright: 2026 Example Ltd
review_notes: |
  Notes for the App Store reviewer: how to test, demo account.
review_contact: { first_name: Jane, last_name: Doe, phone: "+1 555 010 0100", email: jane@example.com }
review_demo_user: reviewer@example.com
---
# en
## name
My App
## subtitle
Short line under the name (App Store)
## keywords
puzzle,words,daily
## promotional_text
## description
The full description.
## short_description
One sentence for Google Play.
## release_notes
What's new in this version.
## captions
- 01_home: Your words, every day
- 02_game: Play against the clock
- 03_stats: Watch yourself improve
```

Every field is checked against the store's length limits before anything is built, so a description that is too long
fails in a second, not after a 20-minute build. Inside a section, don't start a line with `#`.

`doctor` and `release` also point out text that works against you without breaking anything: keywords already in the
name or subtitle (the App Store searches those anyway), spaces after commas and repeated keywords (they eat into the
100 characters), unused keyword room, captions long enough to wrap to three lines, missing release notes.

`review_contact` and `review_demo_user` are for App Review: who Apple contacts if the review gets stuck, and the login
to use if your app needs one. The demo account's password goes in
`~/.storeautopilot/<app_id>/review_demo_password.txt`, never in `store.md`.

**App already in the stores?** Skip writing it by hand:

    storeautopilot import

This reads the current text from App Store Connect and Google Play and writes `store.md` (or `store.imported.md` if
you already have one, so nothing is overwritten). Where the two stores differ it keeps the App Store text and tells
you.

### 4. Write the screenshot test

Open `integration_test/store_screenshots_test.dart`. Start your app with demo data (no real account, no network), go to
each screen and call `takeStoreScreenshot` with the ids from `storeautopilot.yml`:

```dart
testWidgets('store screenshots', (tester) async {
  await app.startForScreenshots(locale: storeLocale);
  await takeStoreScreenshot(tester, '01_home');

  await tester.tap(find.text('Play'));
  await takeStoreScreenshot(tester, '02_game');
});
```

`storeLocale` holds the current language id, so you can start the app in that language. `storeDevice` is `phone` or
`tablet` (iPad), in case a screen should look different on the larger display. Then preview the result:

    storeautopilot shots

This captures everything, builds the store images and opens a preview page: per language, the App Store and Google
Play pages side by side with their images, character counts against each limit, and suggestions for the text.
Nothing is uploaded. `storeautopilot preview` opens the same page after you edit `store.md`, without new screenshots.

### 5. Add your keys

Put these files in `~/.storeautopilot/<app_id>/`. They never go into your repository or into GitHub.

| File | Where it comes from |
|---|---|
| `asc_key.p8` | App Store Connect → Users and Access → Integrations → App Store Connect API. Create a key with the App Manager role and download it. |
| `asc_key.json` | `{"key_id": "…", "issuer_id": "…"}`, both shown on the same page. |
| `play.json` | Google Cloud: create a service account and a JSON key. In Play Console → Users and permissions, invite the service account's email with release and store listing permissions. |

Android release signing is not done by StoreAutopilot: set it up in Gradle as usual, with your upload keystore on
this Mac.

**Export compliance:** Apple asks about encryption for every build, and TestFlight holds the build until it is
answered. If your app only uses the encryption built into iOS (HTTPS, Keychain and the like), set
`uses_encryption: false` under `ios`: the answer is written into `Info.plist` on the next build (commit that change)
and Apple stops asking.

### 6. Declare what data the app collects

Both stores ask what your app collects and why: App Store Connect in **App Privacy**, Google Play in **Data
safety**. Neither form can be filled through an API key, so you fill them in by hand — but from one list in
`store.md`:

    storeautopilot privacy

The first time, this suggests a `privacy` section based on the packages your app uses (AdMob, Firebase, RevenueCat,
sign-in packages and others). Adjust it and add it to `store.md`'s header:

```yaml
privacy:
  tracking: false
  encrypted_in_transit: true
  deletion_request: true
  collected:
    - { type: email, purposes: [account], linked: true }
    - { type: device_id, purposes: [advertising], linked: false, shared: true }
    - { type: crash_data, purposes: [analytics] }
```

Run it again and it prints, for each store, exactly what to tick, in that store's own words. `doctor` warns when a
package you use is known to collect data your list leaves out — a common reason for rejection.

Google Play can also take the form as a file: in Play Console, App content → Data safety → Export to CSV, and save
it as `storeautopilot/data_safety.csv` in your repository. From then on it is uploaded whenever it changes.

### 7. Do the store steps that have no API

Some things can only be done by hand, once:

- **App Store Connect:** create the app record (name, bundle ID, SKU, language); fill in the App Privacy labels; put
  your privacy policy and support pages online; sign the agreements and fill in tax and banking if you sell in-app
  purchases.
- **Play Console:** create the app; upload the first app bundle by hand (this turns on Play App Signing); fill in the
  App content forms (content rating, target audience, ads, data safety). Personal developer accounts created after
  November 2023 have to run a 14-day closed test with at least 12 testers before they can publish to production.
- **Xcode:** sign in with your Apple account once, so automatic signing works.

### 8. Check and connect the runner

    storeautopilot doctor --online
    storeautopilot runner install

`--online` also signs in to App Store Connect and Google Play with your keys and checks that the app records exist,
that the version in `pubspec.yaml` can still take builds, and whether the first Android upload has been done. It
takes about half a minute.

`runner install` downloads the official GitHub Actions runner, verifies its checksum, registers it for this repository
only and starts it as a background service. It refuses to do this for a public repository.

## Releasing

    git push origin HEAD:release

Your Mac must be awake and online. You can follow the run under the repository's Actions tab, and you get a macOS
notification when it finishes or fails. The run's summary page lists every step with its duration, or what failed and
how to fix it. After that, the build is in TestFlight and on your Play track, and the store pages show the new text
and screenshots.

To see where things stand in both stores at any time — live version, version in review, newest builds, Apple's
processing result for the last upload (with the reason if it was rejected), Play tracks:

    storeautopilot status

And what users are saying, newest first in both stores, with an id to answer the ones without a reply:

    storeautopilot reviews
    storeautopilot reviews reply ios:1234567890 "Thanks! Fixed in 1.2.4."

Screenshots are taken again only when the app itself changed. If only `store.md` or the version number changed, the
screenshots from the last run are reused, which saves a few minutes.

To try a release without the push, or to see what it would do:

    storeautopilot release --dry-run
    storeautopilot release --only android
    storeautopilot release --skip-shots      # keep the screenshots already in the stores
    storeautopilot release --fresh-shots     # take new screenshots even if the app didn't change

## Going live

When the build has been tested: on GitHub, open Actions → Store → Run workflow and tick **submit for review**. Or run:

    storeautopilot submit

Before submitting anything, it checks that App Review has what it needs for this version: a processed build,
screenshots for every language (and iPad if the app runs on iPad), a privacy policy URL, a review contact, the age
rating answers, and whether the app shows third-party content (`third_party_content: false` in `store.md` answers
that for you). If something is missing it lists all of it and submits nothing. `storeautopilot submit --dry-run` runs
only the check.

This submits the latest TestFlight build of the current version for App Store review and promotes the newest release
on your Play track to production. After Apple approves the version, you release it in App Store Connect; with
`phased_release: true` it then reaches users gradually over seven days.

With `rollout: 20` under `android`, Google Play production starts with 20% of users. When nothing has gone wrong,
widen it, and finish at 100:

    storeautopilot rollout 50
    storeautopilot rollout 100

Before widening, the crash rate of the new version is checked in Google Play's vitals; a version that crashes clearly
more than the one before is not widened. The workflow from `init` also runs `storeautopilot rollout watch` every six
hours: it halts the staged rollout when the new version's crash rate goes above `halt_crash_rate` (1.09% by default,
Google's own "bad behavior" line) or above three times the previous version's. This needs the Google Play Developer
Reporting API enabled in the Google Cloud project of your service account.

## Commands

| Command | What it does |
|---|---|
| `storeautopilot init` | Adds the StoreAutopilot files to an app repository |
| `storeautopilot import` | Writes `store.md` from the text already in both stores |
| `storeautopilot doctor` | Checks tools, settings, store text, keys, repository safety and the runner; `--online` also checks both stores |
| `storeautopilot status` | Shows what App Store Connect and Google Play hold for the app |
| `storeautopilot reviews` | Newest reviews in both stores; `reviews reply` answers one |
| `storeautopilot privacy` | Shows what to tick in App Privacy and Data safety, from `store.md` |
| `storeautopilot shots` | Captures and composes the store images locally and opens the preview |
| `storeautopilot preview` | Opens the store preview with the last images |
| `storeautopilot release` | Builds, uploads and updates the store listings |
| `storeautopilot submit` | Sends the release for App Store review and to Google Play production |
| `storeautopilot rollout 50` | Widens a staged Google Play rollout; 100 finishes it |
| `storeautopilot rollout watch` | Halts a staged Google Play rollout whose crash rate is too high |
| `storeautopilot runner install` | Connects this Mac to the repository as its runner |

Options: `--config PATH`, `--only ios|android`, `--skip-shots` (release), `--fresh-shots` (release and shots),
`--dry-run` (release, submit and rollout), `--online` (doctor).

## Changing the look of the store images

The images come from `storeautopilot/frame.html` (screenshots) and `storeautopilot/feature.html` (the Play feature
graphic) in your repository. They are plain HTML and CSS. These placeholders are filled in:

- `frame.html`: `{{caption}}`, `{{screenshot}}`, `{{platform}}` (`ios`, `ipad` or `android`)
- `feature.html`: `{{name}}`, `{{tagline}}`
- both: `{{background}}`, `{{text}}`, `{{accent}}`, `{{font}}`, `{{width}}`, `{{height}}`

Run `storeautopilot shots` to see your changes. Output sizes are 1320×2868 for the 6.9" iPhone and 2064×2752 for the
13" iPad on the App Store, 1080×1920 for Google Play phone screenshots and 1024×500 for the feature graphic.

## When something goes wrong

Every command writes a log to `~/Library/Logs/StoreAutopilot/` with everything it printed and the full output of
Flutter, Xcode and fastlane. The last 30 logs are kept. When something fails you see one line saying what went wrong,
a hint on how to fix it, and the path of the log.

Most setup problems are caught by `storeautopilot doctor --online` before you push. It also looks for what gets apps
rejected most often, as far as the project shows it:

- **Store rules that change over time:** Google Play's target SDK (API 36 since August 31, 2026), Xcode 26 or later,
  iOS 13 or later. A rule already in force stops the release before the build; an upcoming one is a warning with its
  date.
- **Crashes on launch or first use:** a missing AdMob app id (iOS and Android), missing permission texts for camera,
  photos, location, Face ID and similar packages, tracking declared without its prompt text.
- **Account deletion:** with a sign-in package, Apple requires deleting the account inside the app; `doctor` reminds
  you to say where in `review_notes`.
- **Privacy manifest:** a note when `ios/Runner/PrivacyInfo.xcprivacy` is missing.

During a run:

- **A stuck command is stopped.** No command waits for keyboard input, and one that prints nothing for 30 minutes
  (an app frozen in its screenshot test, say) is stopped with everything it started, so the runner is free again.
- **Passing store errors are retried.** Store checks and listing updates are tried again after a short wait. Build
  uploads are never repeated automatically.
- **A re-run continues where the last one stopped.** If iOS reached TestFlight and Android then failed, use Re-run
  on the GitHub run: iOS is not built or uploaded again, and Android gets the same build number. This works for the
  same commit; a new commit, or local uncommitted changes, always builds everything.

## Security

- Keys stay in `~/.storeautopilot/<app_id>/`, readable only by you. Only their file paths are passed to fastlane; their
  contents are never printed or logged.
- The runner serves one private repository. The workflow runs only on pushes and manual starts, never on pull
  requests, so nobody else's code runs on your Mac. `doctor` fails if a pull request trigger is added.
- `doctor` fails if keys, keystores or service account files are committed to git.
- Android bundles signed with the debug key are refused before upload.

## Built with

- [fastlane](https://fastlane.tools) for everything that talks to the stores: `deliver` and `pilot` for App Store
  Connect, `supply` for Google Play, `gym` for the iOS build
- App Store Connect API keys, so no Apple ID password or two-factor prompts are needed
- Xcode automatic signing (`-allowProvisioningUpdates`) with the same API key, so no certificates to manage
- Flutter `integration_test` and `flutter drive` for the screenshots, on an iPhone simulator and an Android emulator
- Headless Google Chrome to turn the HTML templates into images
- GitHub Actions with a self-hosted runner on your Mac
- Plain Ruby for the tool itself, with no gems beyond fastlane

## Limitations

- Flutter apps only.
- Runs on macOS only, and the Mac has to be on when you push.
- No Android tablet screenshots. Google Play doesn't require them, but tablet users won't see any.
- App Privacy labels and Play's App content forms have no API and stay manual.

## Development

    bin/test

The tests need nothing but Ruby: external commands and fastlane are replaced by fakes. They run on every push and
pull request on GitHub's hosted Linux machines, with the oldest and newest supported Ruby.

## License

MIT. See [LICENSE](LICENSE).
