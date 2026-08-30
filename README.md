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
| `ENTERPRISE_SLUG` | Just the slug, not the full URL. From github.com/enterprises/YOUR-ENTERPRISE-SLUG, use only `YOUR-ENTERPRISE-SLUG`  |
| `INSTALLER_APP_CLIENT_ID` | The Client ID from step 4 |

## GHES

> [!NOTE]
> Requires GHES **3.19 or later**. See the
> [GHES 3.19 release notes](https://docs.github.com/en/enterprise-server@3.19/admin/release-notes#apis).

### Prerequisites

- The StepSecurity apps must already be registered on your GHES instance and
  installed on **at least in one org** before running this tool, that's how the
  apps get their client IDs (`REGULAR_APP_CLIENT_ID` / `ADVANCED_APP_CLIENT_ID`).
  Set this up first via the
  [GHES admin console guide](https://docs.stepsecurity.io/administration/admin-console/resources/github-enterprise-servers),
  then use this tool to roll the install out to the rest of your organizations.
- A **self-hosted (or GHES-hosted) runner inside your network** so the workflow
  can reach the GHES API.

### Setup

#### 1. Create the Installer App

- **GitHub App name**: `YOUR-ENTERPRISE-installer` (or similar)
- **Homepage URL**: Your enterprise URL or this repository URL
- **Webhook**: Uncheck "Active" (not needed)
- Set permissions:
  - Under **Enterprise permissions**, set **Enterprise organization installations** to **Read and write**
- Under **Where can this GitHub App be installed?**, select **Only on this account**

#### 2. Generate and Save Private Key

1. On the app's settings page, scroll to **Private keys**
2. Click **Generate a private key**
3. Save the downloaded `.pem` file securely

#### 3. Install the Installer App on Your Enterprise

1. On the app's settings page, click **Install App** in the sidebar
2. Select your enterprise account
3. Click **Install**

#### 4. Get the Client IDs

- **Installer app**: on the app's settings page, copy the **Client ID** (starts with `Iv`)
- **Target apps**: get the Client IDs of the StepSecurity apps you already
  registered/installed on this GHES instance, see the
  [GHES admin console guide](https://docs.stepsecurity.io/administration/admin-console/resources/github-enterprise-servers)

#### 5. Commit This Repo to Your GHES Instance

1. Push this repo to a repository hosted on your **GHES** instance
2. Ensure a **self-hosted runner** is available (adjust `runs-on` in
   [install-app-ghes.yml](.github/workflows/install-app-ghes.yml) if you use a specific label)

#### 6. Configure Repository Secrets and Variables

Go to this repository's **Settings > Secrets and variables > Actions** (on the GHES repo)

##### Secrets

| Name | Value |
|------|-------|
| `INSTALLER_APP_PRIVATE_KEY` | Contents of the `.pem` file (include the BEGIN/END lines) |

##### Variables

| Name | Value |
|------|-------|
| `ENTERPRISE_SLUG` | Your enterprise slug |
| `INSTALLER_APP_CLIENT_ID` | The installer app Client ID |
| `REGULAR_APP_CLIENT_ID` | Regular app Client ID (as registered on this instance) |
| `ADVANCED_APP_CLIENT_ID` | Advanced app Client ID (as registered on this instance) |

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

### Accepting Updated App Permissions

When StepSecurity releases a new feature that needs additional app permissions, GitHub
puts every existing installation into a pending "review requested permissions" state
that an org admin would normally have to accept by hand, org by org.

This workflow handles that automatically. For each app that is already installed, it
compares the permissions the installation was granted with the permissions the app
currently requests (`GET /apps/{app_slug}`). If the app requests a permission the
installation does not have yet, the workflow re-calls the enterprise install endpoint,
which [accepts the pending update request](https://docs.github.com/en/enterprise-cloud@latest/rest/enterprise-admin/organization-installations)
("If the app is already installed and has a pending update request, it will be updated
to the latest version"). Apps installed by this workflow always use all-repository
access, so the update is accepted with the same selection.

**Dry run** reports pending permission updates without accepting them.

## Workflow Output

The workflow reports:
- **Newly installed**: Apps that were installed during this run
- **Already installed**: Apps that were already present with up-to-date permissions
- **Permission updates accepted**: Installations whose pending permission update requests were accepted
- **Failed**: Apps that failed to install or update, or whose permissions could not be verified (check logs for details)

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
Already installed, permissions up to date (installation ID: 72605456)
Waiting 5 seconds before next app...

--- [2/2] StepSecurity App (Advanced App) (Iv23liR5Z8C22IM5THOA) ---
Already installed, permissions up to date (installation ID: 72605887)

==========================================
Processing organization: step-dev-org-1
==========================================

--- [1/2] StepSecurity Actions Security App (Iv1.ad96d1f00234487b) ---
Already installed, permissions up to date (installation ID: 97537007)
Waiting 5 seconds before next app...

--- [2/2] StepSecurity App (Advanced App) (Iv23liR5Z8C22IM5THOA) ---
Already installed, permissions up to date (installation ID: 97537005)

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
Permission updates accepted: 0
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

### "Integration not found" (HTTP 404)
The JWT could not be validated, or `ENTERPRISE_SLUG` is set to the full URL instead of the bare slug. Set it to just the slug (e.g. `YOUR-ENTERPRISE-SLUG`), not `https://github.com/enterprises/YOUR-ENTERPRISE-SLUG`.

## References

- [Automate installations - GitHub Docs](https://docs.github.com/en/enterprise-cloud@latest/admin/managing-github-apps-for-your-enterprise/automate-installations)
- [Generating a JWT for a GitHub App](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-json-web-token-jwt-for-a-github-app)
