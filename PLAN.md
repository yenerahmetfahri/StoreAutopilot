# StoreAutopilot — Plan

End-to-end automation so that, once an app is built, nobody has to deal with store chores by hand.
A push to a branch triggers: screenshots → framed store images → listing text/forms → build → App Store + Google Play.

## Goal

1. A push lands on a branch (e.g. `release`).
2. The app's screenshots are captured automatically; **unchanged ones are not uploaded again**.
3. Screenshots are placed into a design template (device frame, caption, brand colors). The template is designed once.
4. Store text and form answers come from `store.md` in the app's repo (description, keywords, age rating, …).
   Everything the stores need to know about the app is declared there up front.
5. The app is built; iOS → TestFlight / App Store review, Android → Google Play.

## Constraints (hard)

- **App repos stay private.** No exceptions.
- **Completely free.** No paid CI (GitHub-hosted macOS minutes, paid Codemagic tiers, etc.).
- **No secrets in the repo:** `.p8`, Issuer ID, keystore, Play service account JSON, Firebase files stay on the Mac.
- **Generic:** no app-specific value is ever built into the tool; each app supplies its own `store.md`, templates
  and settings file.

## Architecture decisions

- **Where it runs:** the developer's Mac as a **GitHub self-hosted runner** (free for private repos). The Mac must be on
  when a push arrives.
  - A Linux VPS was considered and dropped: iOS builds need macOS, and splitting work with Xcode Cloud adds complexity.
- **Tooling:** fastlane (free, MIT). iOS: `pilot` (TestFlight), `deliver` (text, images, review). Android: `supply`.
- **Apple identity:** App Store Connect API key (`.p8` + Key ID + Issuer ID). No 2FA or password needed.
- **Signing:** Xcode automatic signing + `xcodebuild -allowProvisioningUpdates` + the API key. No `match` (single developer).
- **Build number:** automatic (highest number in the stores + 1).
- **Screenshots (Flutter):** an integration test run on a simulator/emulator, separately for each platform.
- **Image design:** HTML templates rendered with headless Chrome; brand colors come from the settings file.
- **App Store submission** is a separate, manual trigger so a stray push never goes to review. TestFlight is fully automatic.

## Not automatable (one-time, by hand)

**Apple:** app record (name, bundle ID, SKU, language); API key with the App Manager or Admin role; App Privacy labels
(no API); privacy policy and support URLs online; agreements/tax/banking and the first review for in-app purchases.

**Google:** create the app in Play Console; upload the first AAB by hand (turns on Play App Signing); Google Cloud
service account + JSON key + Play Console permissions; App content forms (content rating, target audience, ads — no
API); personal accounts created after November 2023 need a 14-day closed test with 12 testers.

**Mac:** runner registration (`storeautopilot runner install`); Apple account signed in to Xcode; Android upload keystore.

## Roadmap

1. Build the tool generically (settings and `store.md` formats, screenshot capture, templates, fastlane lanes,
   example GitHub workflow). — done
2. Run it end to end on a first real app. — done for TestFlight and Play closed testing; review submission pending.
3. Publish as open source (README, example app, license).
