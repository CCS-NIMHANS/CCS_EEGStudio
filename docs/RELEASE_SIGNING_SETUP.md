# Release Code Signing & Notarization Setup (`CCS-NIMHANS/CCS_EEGStudio`)

This guide finishes the one-time external credentials setup for **macOS Developer ID notarization** (Apple Team `Y445J7MR4Q`) and **Windows EV code signing** (free SignPath Foundation for open-source MIT projects).

> All repository scripts, entitlements, policy docs, and the drop-in workflow template are already committed in the repository.

---

## 1. macOS — Developer ID Application + Notarization (Team `Y445J7MR4Q`)

### A. Create & export the `Developer ID Application` certificate
1. Open **Xcode** on your Mac (`arunsasidharan`) → **Settings… → Accounts → Arun Sasidharan (`Y445J7MR4Q`) → Manage Certificates…** → click **`+` → Developer ID Application**.
   *(Alternatively, create it at [developer.apple.com/account/resources/certificates](https://developer.apple.com/account/resources/certificates/list) and double-click to install in Keychain Access.)*
2. Open **Keychain Access** → **login → My Certificates**, locate **`Developer ID Application: Arun Sasidharan (Y445J7MR4Q)`**, right-click → **Export "Developer ID Application: …"**, and save it as `devid.p12` with a strong password.

### B. Create an App Store Connect API Key (`.p8`) for unattended notarization
1. Open [appstoreconnect.apple.com/access/integrations/api](https://appstoreconnect.apple.com/access/integrations/api) under Team `Y445J7MR4Q`.
2. Click **`+` (Generate API Key)**, choose **Developer** access, and download `AuthKey_<KEY_ID>.p8`.
3. Note the **Issuer ID** (UUID shown at the top of the page) and the **Key ID**.

### C. Push the macOS secrets to GitHub
Run these commands in Terminal (replacing the file paths, password, Key ID, and Issuer ID):

```bash
base64 -i ~/Desktop/devid.p12 | tr -d '\n' | gh secret set MACOS_CERT_P12_BASE64 -R CCS-NIMHANS/CCS_EEGStudio
gh secret set MACOS_CERT_PASSWORD -R CCS-NIMHANS/CCS_EEGStudio
base64 -i ~/Downloads/AuthKey_YOURKEYID.p8 | tr -d '\n' | gh secret set MACOS_NOTARY_KEY_BASE64 -R CCS-NIMHANS/CCS_EEGStudio
gh secret set MACOS_NOTARY_KEY_ID -b "YOURKEYID" -R CCS-NIMHANS/CCS_EEGStudio
gh secret set MACOS_NOTARY_ISSUER_ID -b "YOUR-ISSUER-UUID" -R CCS-NIMHANS/CCS_EEGStudio
```

*(Optional)* Also store a local keychain profile so `./scripts/build_macos.sh` can notarize on your Mac too:
```bash
xcrun notarytool store-credentials "ccs-notary" \
  --key ~/Downloads/AuthKey_YOURKEYID.p8 \
  --key-id "YOURKEYID" \
  --issuer "YOUR-ISSUER-UUID"
```

---

## 2. Windows — Free SignPath Foundation Open-Source Signing

SignPath Foundation eliminates **both** Windows 11 **Smart App Control** and **Microsoft Defender SmartScreen** warnings at zero cost for public MIT-licensed repositories (`https://github.com/CCS-NIMHANS/CCS_EEGStudio`).

### A. Apply & link GitHub
1. Submit the free open-source application at [signpath.org/open-source](https://signpath.org/open-source) pointing to:
   - Repository: `https://github.com/CCS-NIMHANS/CCS_EEGStudio`
   - License: `MIT` (`LICENSE`)
   - Signing Policy: `https://github.com/CCS-NIMHANS/CCS_EEGStudio/blob/main/CODE_SIGNING_POLICY.md`
2. Once approved, install the **SignPath GitHub App** on `CCS-NIMHANS/CCS_EEGStudio` and copy your **Organization ID** (`SIGNPATH_ORG_ID`) and CI **API Token** (`SIGNPATH_API_TOKEN`) from SignPath.

### B. Configure project, policy & two artifact configurations in SignPath
Create Project slug `ccs-eeg-studio` and Signing Policy slug `release-signing` (trusted build systems: GitHub Actions on `main` / tag `v*`). Then create two **Artifact Configurations**:

1. Slug **`app-binaries`** *(signs `ccs_eeg_app.exe`, `ccs-eeg-engine.exe`, and bundled `.dll`s inside `windows-app-unsigned.zip` before Inno Setup packages them)*:
```xml
<?xml version="1.0" encoding="utf-8"?>
<artifact-configuration xmlns="http://signpath.io/artifact-configuration/v1">
  <zip-file>
    <pe-file path="*.exe">
      <authenticode-sign />
    </pe-file>
    <pe-file path="*.dll">
      <authenticode-sign />
    </pe-file>
  </zip-file>
</artifact-configuration>
```

2. Slug **`installer`** *(signs `CCSEEGStudio-Installer.exe` produced by Inno Setup)*:
```xml
<?xml version="1.0" encoding="utf-8"?>
<artifact-configuration xmlns="http://signpath.io/artifact-configuration/v1">
  <pe-file>
    <authenticode-sign />
  </pe-file>
</artifact-configuration>
```

### C. Push the SignPath secrets to GitHub
```bash
gh secret set SIGNPATH_API_TOKEN -R CCS-NIMHANS/CCS_EEGStudio
gh secret set SIGNPATH_ORG_ID -b "YOUR-SIGNPATH-ORG-UUID" -R CCS-NIMHANS/CCS_EEGStudio
```

---

## 3. Activate the Signed CI Workflow

Because GitHub requires the `workflow` OAuth scope to push edits under `.github/workflows/`, refresh your local `gh` login once and copy the ready-to-use workflow into place:

```bash
gh auth refresh -h github.com -s workflow
cp docs/workflows/build_with_signing.yml .github/workflows/build.yml
git add .github/workflows/build.yml
git commit -m "Enable macOS notarization and Windows SignPath code signing in CI"
git push origin main
```

*(Alternatively, paste the contents of [build_with_signing.yml](workflows/build_with_signing.yml) directly into `.github/workflows/build.yml` via the GitHub Web UI.)*

After merging/pushing, cutting the next `v*` tag produces:
- Windows: Signed `CCSEEGStudio-Installer.exe` containing signed `ccs_eeg_app.exe`, `ccs-eeg-engine.exe`, and `.dll`s (no Smart App Control or SmartScreen warnings).
- macOS: Notarized & stapled `CCSEEGStudio-macos.zip` and drag-to-Applications `CCSEEGStudio-macos.dmg` (no Gatekeeper or `xattr` commands required).
