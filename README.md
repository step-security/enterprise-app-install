# Enterprise App Install

Automates the installation of GitHub Apps to organizations within a GitHub Enterprise. This workflow uses an "installer app" with enterprise-level permissions to install target apps to specified organizations.

Based on [GitHub's guide for automating app installations](https://docs.github.com/en/enterprise-cloud@latest/admin/managing-github-apps-for-your-enterprise/automate-installations).

## Prerequisites

- GitHub Enterprise Cloud
- Enterprise owner or admin permissions

## Setup

### 1. Create the Installer App

The installer app is an enterprise-owned GitHub App that has permission to install other apps to organizations.

1. Go to your enterprise settings: `https://github.com/enterprises/YOUR-ENTERPRISE/settings/apps`
2. Click **New GitHub App**
3. Configure the app:
   - **GitHub App name**: `YOUR-ENTERPRISE-installer` (or similar)
   - **Homepage URL**: Your enterprise URL or this repository URL
   - **Webhook**: Uncheck "Active" (not needed)
4. Set permissions:
   - Under **Organization permissions**, set **Enterprise organization installations** to **Read and write**
5. Under **Where can this GitHub App be installed?**, select **Only on this account**
6. Click **Create GitHub App**

### 2. Generate and Save Private Key

1. On the app's settings page, scroll to **Private keys**
2. Click **Generate a private key**
3. Save the downloaded `.pem` file securely

### 3. Install the Installer App on Your Enterprise

1. On the app's settings page, click **Install App** in the sidebar
2. Select your enterprise account
3. Click **Install**

### 4. Get the Client ID

1. On the app's settings page, copy the **Client ID** (starts with `Iv`)

### 5. Configure Repository Secrets and Variables

Go to this repository's **Settings > Secrets and variables > Actions**

#### Secrets

| Name | Value |
|------|-------|
| `INSTALLER_APP_PRIVATE_KEY` | Contents of the `.pem` file (include the BEGIN/END lines) |

#### Variables

| Name | Value |
|------|-------|
| `ENTERPRISE_SLUG` | Your enterprise slug (from URL: `github.com/enterprises/YOUR-SLUG`) |
| `INSTALLER_APP_CLIENT_ID` | The Client ID from step 4 |

## Usage

### Add Organizations

Edit `organizations.txt` and add one organization name per line:

```
my-org-1
my-org-2
my-org-3
```

Lines starting with `#` are treated as comments.

### Run the Workflow

The workflow runs automatically when:
- `organizations.txt` is modified (push to main)
- Daily at midnight UTC (scheduled)

To run manually:
1. Go to **Actions > Install GitHub App to Organizations**
2. Click **Run workflow**
3. Optionally enable **Dry run** to check status without installing

### Target Apps

This workflow installs the following apps (hardcoded):

| App | Client ID |
|-----|-----------|
| StepSecurity Actions Security App | `Iv1.ad96d1f00234487b` |
| StepSecurity App (Advanced App) | `Iv23liR5Z8C22IM5THOA` |

To modify the target apps, edit the `APPS` array in `.github/workflows/install-app.yml`.

## Workflow Output

The workflow reports:
- **Newly installed**: Apps that were installed during this run
- **Already installed**: Apps that were already present
- **Failed**: Apps that failed to install (check logs for details)

### Example Execution

When the workflow runs, you'll see output like this:

```
=== Processing organizations ===
Apps to install (in order):
  1. StepSecurity Actions Security App
  2. StepSecurity App (Advanced App)


==========================================
Processing organization: step-integration-tests
==========================================

--- [1/2] StepSecurity Actions Security App (Iv1.ad96d1f00234487b) ---
Already installed (installation ID: 72605456)
Waiting 5 seconds before next app...

--- [2/2] StepSecurity App (Advanced App) (Iv23liR5Z8C22IM5THOA) ---
Already installed (installation ID: 72605887)

==========================================
Processing organization: step-dev-org-1
==========================================

--- [1/2] StepSecurity Actions Security App (Iv1.ad96d1f00234487b) ---
Already installed (installation ID: 97537007)
Waiting 5 seconds before next app...

--- [2/2] StepSecurity App (Advanced App) (Iv23liR5Z8C22IM5THOA) ---
Already installed (installation ID: 97537005)

==========================================
Processing organization: step-dev-org-2
==========================================

--- [1/2] StepSecurity Actions Security App (Iv1.ad96d1f00234487b) ---
Successfully installed
Waiting 5 seconds before next app...

--- [2/2] StepSecurity App (Advanced App) (Iv23liR5Z8C22IM5THOA) ---
Successfully installed

=== Summary ===
Newly installed: 2
Already installed: 4
Failed: 0
```

## Troubleshooting

### "Integration must generate a public key"
The private key is not configured correctly. Ensure:
- The secret `INSTALLER_APP_PRIVATE_KEY` exists
- The full PEM content is included (with `-----BEGIN RSA PRIVATE KEY-----` headers)

### "No enterprise installation found"
The installer app is not installed on your enterprise. Go to the app's settings and install it on your enterprise account.

### Apps show as "Successfully installed" but were already installed
This can happen if the install API is idempotent. The workflow now checks existing installations before attempting to install.

## References

- [Automate installations - GitHub Docs](https://docs.github.com/en/enterprise-cloud@latest/admin/managing-github-apps-for-your-enterprise/automate-installations)
- [Generating a JWT for a GitHub App](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-json-web-token-jwt-for-a-github-app)
