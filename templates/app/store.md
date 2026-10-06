---
# Store listing for {{app_name}}. One `# <locale id>` section per locale in storeautopilot.yml.
# Section bodies are plain text; don't start lines with '#'.
support_url: {{support_url}}
privacy_url: {{privacy_url}}
marketing_url:
# App Review notes (App Store): how to test, demo account hints. Multi-line: `review_notes: |` + indented lines.
review_notes:
# Who Apple contacts if the review gets stuck (phone with country code).
# review_contact: { first_name: Jane, last_name: Doe, phone: "+1 555 010 0100", email: jane@example.com }
# If the app needs a login: the demo account's user name; its password goes in
# ~/.storeautopilot/<app_id>/review_demo_password.txt, never in this file.
# review_demo_user: reviewer@example.com
# Does the app show content it doesn't own (third-party text, images, music…)? Apple asks before review.
{{content_line}}
# What the app collects, for both stores' privacy forms; `storeautopilot privacy` suggests a start from your packages
# and prints what to tick in App Privacy and Data safety.
# privacy:
#   tracking: false
#   encrypted_in_transit: true
#   deletion_request: true
#   collected:
#     - { type: email, purposes: [account], linked: true }
copyright: {{year}} {{app_name}}
{{category_line}}
# age_rating:   # optional; same keys as fastlane deliver's app_rating_config_path JSON
---
{{sections}}