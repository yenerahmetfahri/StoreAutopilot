# StoreAutopilot example

A small Flutter app (a task list and a stats screen, in English and German) set up for StoreAutopilot. Use it to see
what the tool produces before connecting your own app.

- `storeautopilot.yml` – settings
- `store.md` – store text in both languages
- `integration_test/store_screenshots_test.dart` – opens the two screens and takes the screenshots

Preview the store images (needs Xcode, Android Studio with an emulator, Flutter and Google Chrome; nothing is uploaded):

    cd example
    storeautopilot shots

The Xcode project targets iPhone and iPad, so you get iPhone, iPad and Android images.
