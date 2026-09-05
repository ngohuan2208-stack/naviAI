# NaviAI

NaviAI is an AI-powered browser for **iPhone**, built with SwiftUI + `WKWebView`.
An in-page AI agent can navigate, read, click, type, search and scroll for you
using your own API provider (OpenAI-compatible, DeepSeek, Claude, Gemini,
OpenRouter, or a custom endpoint).

> **You only need an iPhone.** All builds happen on **CodeMagic Cloud**. No local
> Mac, no Xcode, no installed toolchain. You push to GitHub, run the workflow,
> download the `.ipa`, and sideload it.

---

## How the pipeline works

```
GitHub  ──push──▶  CodeMagic Cloud  ──build──▶  IPA artifact  ──download──▶  Sideload on iPhone
```

Everything in this repository is designed so that **zero build work happens on
your device**:

| Step | Who does it | Where |
|------|-------------|-------|
| Checkout source | CodeMagic | Cloud macOS machine |
| Install dependencies | CodeMagic | `xcodegen` (Homebrew) |
| Choose Xcode version | CodeMagic | `xcode: latest` in `codemagic.yaml` |
| Generate Xcode project | CodeMagic | `xcodegen` from `project.yml` |
| Build / Archive / Export `.ipa` | CodeMagic | `xcodebuild` on cloud |
| Publish artifact | CodeMagic | listed under **Artifacts** |

---

## Repository structure

```
NaviAI/
├── NaviAI/
│   ├── App/          # @main entry point + root view model
│   ├── Browser/      # WKWebView tabs, JS engine, browser store
│   ├── Agent/        # AI agent loop + tools (click / type / scroll / read)
│   ├── AI/           # vision fallback lives under Agent
│   ├── Models/       # Chat, provider, library (history / bookmarks / downloads)
│   ├── Services/     # LLM networking, Keychain, provider & settings stores
│   ├── Views/        # Onboarding, browser UI, chat panel, settings
│   └── Assets.xcassets
├── NaviAI.xcodeproj  # committed iOS project (detectable by CodeMagic)
│   └── xcshareddata/xcschemes/NaviAI.xcscheme
├── project.yml        # optional XcodeGen spec (regeneration reference only)
├── codemagic.yaml     # CodeMagic CI config (both workflows)
├── README.md
└── .gitignore
```

`NaviAI.xcodeproj` and `NaviAI/Info.plist` are **committed to Git**, so
CodeMagic's auto-detection recognizes this repository as an iOS application and
`xcodebuild` builds it **directly** — no project generation step, no XcodeGen,
no local Xcode.

> `project.yml` is kept purely as an optional XcodeGen spec if you ever want to
> regenerate the `.xcodeproj` by hand; it is not used by CodeMagic.

---

## Your only tasks

1. **(Optional) Edit provider / API defaults** in
   `NaviAI/Sources/Models/Provider.swift` (base URLs, suggested models). Users
   can also change providers & API keys inside the app's Settings.
2. **Push** the code to GitHub.
3. **Run the CodeMagic workflow** (defined in `codemagic.yaml`).
4. **Download the `.ipa`** from the build's **Artifacts** tab.
5. **Sideload** it onto your iPhone.

No Xcode command is ever run on your machine.

---

## Building on CodeMagic (setup)

1. In CodeMagic, connect your GitHub repo (**Settings → Integrations → GitHub**).
   Because `NaviAI.xcodeproj` is committed, CodeMagic auto-detects the project as
   an **iOS application** (if an old scan already failed, click **Set manually** /
   refresh, or re-scan — the project type is `iOS`).
2. CodeMagic auto-detects `codemagic.yaml`; the two workflows appear:
   - **`NaviAI - iOS (unsigned IPA)`** — always builds, no signing configured.
   - **`NaviAI - iOS (signed IPA, via CodeMagic signing)`** — needs signing
     credentials in the CodeMagic UI (see below).
3. Pick a workflow and press **Start new build**.

> The App ID / bundle identifier is `com.naviai.app`
> (`PRODUCT_BUNDLE_IDENTIFIER` in `project.yml`). The iOS deployment target is
> **16.0** or later.

---

## iOS code signing on CodeMagic (required for installing on a phone)

Signing setup is done **in the CodeMagic web UI**, never in Git. No certificates,
provisioning profiles or private keys are stored in this repository.

### Option A — Quick sideload, no Apple developer account (`ios-unsigned`)

This workflow disables signing and packages a clean unsigned `.ipa`. Because an
unsigned build cannot be installed directly, you re-sign it on your own machine
with a **free Apple ID** using one of:

- **Sideloadly** (macOS/Windows free): drag the `.ipa`, pick your Apple ID.
- **AltStore / AltSign**: installs the app on your iPhone.

Notes for free Apple IDs:
- Installations expire after **7 days** and must be re-signed / re-installed.
- The app won't run unless your free Apple ID is trusted on the device
  (Settings → General → VPN & Device Management → trust NaviAI developer).

### Option B — Properly signed IPA via CodeMagic signing (`ios-signed`)

Requires an **Apple Developer account**. Configure signing once in CodeMagic:

1. **Flutter/iOS → Code signing identities**: upload or create an
   **Apple Development certificate** (`.p12`) plus its password.
2. **Provisioning profiles**: upload a **development** (or **ad-hoc**) profile
   that includes your device's **UDID**.
3. Add your device's **UDID** to the profile **before** building.
4. Run the `ios-signed` workflow. CodeMagic signs and exports the `.ipa`.

The workflow's `ios_signing` block (already in `codemagic.yaml`):

```yaml
ios_signing:
  distribution_type: development
  bundle_identifier: com.naviai.app
```

CodeMagic rewrites all signing settings automatically at build time. **No
signing material is ever committed to Git.** If you ever change the bundle id,
update it in both `project.yml` (`PRODUCT_BUNDLE_IDENTIFIER`) and
`codemagic.yaml`.

---

## Sideloading the IPA onto your iPhone

1. Download the `.ipa` from the CodeMagic **Artifacts** tab.
2. Install / re-sign:
   - **Unsigned build** → re-sign with your Apple ID via **Sideloadly** or
     **AltStore**, then transfer to the phone.
   - **Signed build** → install directly with AltStore / Apple Configurator /
     your device management profile.
3. On first launch (free-ID builds), trust the developer:
   **Settings → General → VPN & Device Management → trust NaviAI**.

---

## First-run configuration & API providers

On first launch NaviAI shows onboarding:
- Pick an AI provider (OpenAI-compatible, DeepSeek, Claude, Gemini, OpenRouter,
  or **Custom API** for `https://modelapi.vn/v1`-style endpoints).
- Enter your **API key** and **model id**, optionally **Test Connection**.
- API keys are stored in the **iOS Keychain** — never in the app or in Git.

Defaults (base URLs / suggested models) can be edited in
`NaviAI/Sources/Models/Provider.swift`.

---

## Configuring CodeMagic's Xcode version

`codemagic.yaml` uses `xcode: latest`. To pin a fixed version, replace it with a
version CodeMagic offers, for example:

```yaml
environment:
  xcode: 16.0
```

CodeMagic also lets you choose the Xcode version in the web UI per build.

---

## Common troubleshooting

- **Unsigned IPA fails to install** → you must re-sign it (Option A) or use the
  `ios-signed` workflow (Option B).
- **"The developer of this app needs to be trusted"** → trust the developer
  certificate on the iPhone.
- **Certificate/profile mismatch** → make sure the profile contains your
  device's UDID and matches bundle id `com.naviai.app`.
- **App crashes on launch** → check your chosen provider + model is reachable;
  requests only go to the AI provider you selected.

---

## Nice to know

- Minimum iOS: **16.0**.
- Full browser: tabs, history, bookmarks, downloads, desktop mode, and an AI
  agent with a visible cursor that clicks and types for you.
- **Debug mode**: switch the agent to *Debug* to diagnose broken pages with a
  Problem → Evidence → Cause → Fix report (LLM when configured, offline
  heuristic otherwise). DevTools gains a **Debug** tab and a **Select Element**
  tap-inspector (tag, selector, attributes, text, bounding box).
- **Smart welcome screen**: greeting, AI command bar with intent routing
  (search, open site, deep research, image, DevTools, private tab…) and recent
  tabs/chats/research to continue where you left off.
- AI never bypasses CAPTCHAs — it pauses and asks you to solve them. 
