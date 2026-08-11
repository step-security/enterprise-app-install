#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/local.env"
ORGS_FILE="${SCRIPT_DIR}/organizations.txt"

# Source local.env if present (local runs); CI/workflows supply env vars directly.
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

: "${INSTALLER_APP_CLIENT_ID:?set INSTALLER_APP_CLIENT_ID}"
: "${ENTERPRISE_SLUG:?set ENTERPRISE_SLUG}"
: "${REGULAR_APP_CLIENT_ID:?set REGULAR_APP_CLIENT_ID (Actions Security app)}"
: "${ADVANCED_APP_CLIENT_ID:?set ADVANCED_APP_CLIENT_ID (Advanced app)}"
DRY_RUN="${DRY_RUN:-false}"

# Installer app private key: inline PEM (CI secret) takes precedence over a file path (local).
if [ -n "${INSTALLER_APP_PRIVATE_KEY:-}" ]; then
  PEM="${INSTALLER_APP_PRIVATE_KEY}"
elif [ -n "${INSTALLER_APP_PRIVATE_KEY_PATH:-}" ] && [ -f "${INSTALLER_APP_PRIVATE_KEY_PATH}" ]; then
  PEM=$(cat "${INSTALLER_APP_PRIVATE_KEY_PATH}")
else
  echo "Set INSTALLER_APP_PRIVATE_KEY (inline PEM) or INSTALLER_APP_PRIVATE_KEY_PATH (file path)" >&2
  exit 1
fi

# API base URL priority:
#   1. GITHUB_API_URL - set automatically by GitHub Actions (github.com or GHES)
#   2. GHES_HOSTNAME  - explicit GHES host (local runs)
#   3. api.github.com - github.com default
if [ -n "${GITHUB_API_URL:-}" ]; then
  API_BASE="${GITHUB_API_URL}"
elif [ -n "${GHES_HOSTNAME:-}" ]; then
  API_BASE="https://${GHES_HOSTNAME}/api/v3"
else
  API_BASE="https://api.github.com"
fi

echo "Using API base: ${API_BASE}"

NOW=$(date +%s)
IAT=$((NOW - 60))
EXP=$((NOW + 600))

b64enc() { openssl base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n'; }

HEADER=$(echo -n '{"typ":"JWT","alg":"RS256"}' | b64enc)
PAYLOAD=$(echo -n "{\"iat\":${IAT},\"exp\":${EXP},\"iss\":\"${INSTALLER_APP_CLIENT_ID}\"}" | b64enc)
HEADER_PAYLOAD="${HEADER}.${PAYLOAD}"
SIGNATURE=$(echo -n "${HEADER_PAYLOAD}" | openssl dgst -sha256 -sign <(echo -n "${PEM}") | b64enc)
JWT="${HEADER_PAYLOAD}.${SIGNATURE}"

# --- Get Enterprise Installation ID ---
RESPONSE=$(curl -s -w "\n%{http_code}" \
  -H "Authorization: Bearer ${JWT}" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "${API_BASE}/app/installations")

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_CODE" != "200" ]; then
  echo "Failed to get installations. HTTP ${HTTP_CODE}: ${BODY}" >&2
  exit 1
fi

INSTALLATION_ID=$(echo "$BODY" | jq -r ".[] | select(.target_type == \"Enterprise\" and .account.slug == \"${ENTERPRISE_SLUG}\") | .id")

if [ -z "$INSTALLATION_ID" ] || [ "$INSTALLATION_ID" == "null" ]; then
  echo "No enterprise installation found for ${ENTERPRISE_SLUG}" >&2
  exit 1
fi
echo "Found enterprise installation ID: ${INSTALLATION_ID}"

# --- Get Installation Access Token ---
RESPONSE=$(curl -s -w "\n%{http_code}" \
  -X POST \
  -H "Authorization: Bearer ${JWT}" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "${API_BASE}/app/installations/${INSTALLATION_ID}/access_tokens")

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_CODE" != "201" ]; then
  echo "Failed to get access token. HTTP ${HTTP_CODE}: ${BODY}" >&2
  exit 1
fi

ACCESS_TOKEN=$(echo "$BODY" | jq -r '.token')
echo "Successfully obtained installation access token"

# --- Install Apps to Organizations ---
APP_NAMES=(
  "StepSecurity Actions Security App"
  "StepSecurity App (Advanced App)"
)
APP_CLIENT_IDS=(
  "${REGULAR_APP_CLIENT_ID}"
  "${ADVANCED_APP_CLIENT_ID}"
)

if [ ! -f "$ORGS_FILE" ]; then
  echo "Missing ${ORGS_FILE}" >&2
  exit 1
fi
ORGS=$(grep -v '^#' "$ORGS_FILE" | grep -v '^[[:space:]]*$' || true)

if [ -z "$ORGS" ]; then
  echo "No organizations found in ${ORGS_FILE}"
  exit 0
fi

echo ""
echo "=== Processing organizations ==="
echo "Apps to install (in order):"
for i in "${!APP_NAMES[@]}"; do
  echo "  $((i + 1)). ${APP_NAMES[$i]}"
done
echo ""

INSTALLED=0
ALREADY_INSTALLED=0
UPDATED=0
FAILED=0

while IFS= read -r ORG; do
  ORG=$(echo "$ORG" | xargs)
  [ -z "$ORG" ] && continue

  echo ""
  echo "=========================================="
  echo "Processing organization: $ORG"
  echo "=========================================="

  CHECK_RESPONSE=$(curl -s -w "\n%{http_code}" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${API_BASE}/enterprises/${ENTERPRISE_SLUG}/apps/organizations/${ORG}/installations")

  CHECK_HTTP_CODE=$(echo "$CHECK_RESPONSE" | tail -n1)
  CHECK_BODY=$(echo "$CHECK_RESPONSE" | sed '$d')

  if [ "$CHECK_HTTP_CODE" != "200" ]; then
    echo "WARNING: Failed to check installations for $ORG (HTTP $CHECK_HTTP_CODE)"
  fi

  for i in "${!APP_NAMES[@]}"; do
    APP_NAME="${APP_NAMES[$i]}"
    APP_CLIENT_ID="${APP_CLIENT_IDS[$i]}"
    echo ""
    echo "--- [$((i + 1))/${#APP_NAMES[@]}] $APP_NAME ($APP_CLIENT_ID) ---"

    INSTALLATION_JSON=$(echo "$CHECK_BODY" | jq -c ".[]? | select(.client_id == \"${APP_CLIENT_ID}\")" 2>/dev/null || echo "")
    APP_INSTALLED=$(echo "$INSTALLATION_JSON" | jq -r '.id // empty' 2>/dev/null || echo "")

    if [ -n "$APP_INSTALLED" ] && [ "$APP_INSTALLED" != "null" ]; then
      # Installed - check for a pending permission update request.
      # The installation shows the permissions that were GRANTED;
      # GET /apps/{app_slug} shows what the app currently REQUESTS.
      # Any requested permission that is missing or lower on the installation
      # means the app's updated permissions have not been accepted yet.
      APP_SLUG=$(echo "$INSTALLATION_JSON" | jq -r '.app_slug // empty')
      GRANTED_PERMS=$(echo "$INSTALLATION_JSON" | jq -c '.permissions // {}')

      MISSING_PERMS=""
      PERM_CHECK_OK=false
      if [ -n "$APP_SLUG" ]; then
        APP_RESPONSE=$(curl -s -w "\n%{http_code}" \
          -H "Authorization: Bearer ${ACCESS_TOKEN}" \
          -H "Accept: application/vnd.github+json" \
          -H "X-GitHub-Api-Version: 2022-11-28" \
          "${API_BASE}/apps/${APP_SLUG}")

        APP_HTTP_CODE=$(echo "$APP_RESPONSE" | tail -n1)
        APP_BODY=$(echo "$APP_RESPONSE" | sed '$d')

        if [ "$APP_HTTP_CODE" == "200" ]; then
          PERM_CHECK_OK=true
          REQUESTED_PERMS=$(echo "$APP_BODY" | jq -c '.permissions // {}')
          MISSING_PERMS=$(jq -n -r \
            --argjson requested "$REQUESTED_PERMS" \
            --argjson granted "$GRANTED_PERMS" '
            def rank: {"read": 1, "write": 2, "admin": 3}[.] // 0;
            [$requested | to_entries[]
              | select((.value | rank) > (($granted[.key] // "none") | rank))
              | "\(.key):\(.value)"]
            | join(", ")')
        else
          echo "WARNING: Could not fetch app manifest for ${APP_SLUG} (HTTP $APP_HTTP_CODE)"
        fi
      else
        echo "WARNING: Installation for ${APP_CLIENT_ID} has no app_slug"
      fi

      if [ "$PERM_CHECK_OK" != "true" ]; then
        echo "Already installed (installation ID: $APP_INSTALLED), but could not verify permissions are up to date"
        FAILED=$((FAILED + 1))
      elif [ -z "$MISSING_PERMS" ]; then
        echo "Already installed, permissions up to date (installation ID: $APP_INSTALLED)"
        ALREADY_INSTALLED=$((ALREADY_INSTALLED + 1))
      elif [ "$DRY_RUN" == "true" ]; then
        echo "[DRY RUN] Pending permission update (not yet granted: ${MISSING_PERMS}) - would accept"
      else
        echo "Pending permission update detected (not yet granted: ${MISSING_PERMS})"

        # Re-POSTing the install endpoint accepts a pending update request
        # ("If the app is already installed and has a pending update request,
        # it will be updated to the latest version"). Apps installed by this
        # tool always use all-repository access, so re-POST with the same
        # selection.
        UPDATE_RESPONSE=$(curl -s -w "\n%{http_code}" \
          -X POST \
          -H "Authorization: Bearer ${ACCESS_TOKEN}" \
          -H "Accept: application/vnd.github+json" \
          -H "X-GitHub-Api-Version: 2022-11-28" \
          -d "{\"client_id\":\"${APP_CLIENT_ID}\",\"repository_selection\":\"all\"}" \
          "${API_BASE}/enterprises/${ENTERPRISE_SLUG}/apps/organizations/${ORG}/installations")

        UPDATE_HTTP_CODE=$(echo "$UPDATE_RESPONSE" | tail -n1)
        UPDATE_BODY=$(echo "$UPDATE_RESPONSE" | sed '$d')

        if [ "$UPDATE_HTTP_CODE" == "201" ] || [ "$UPDATE_HTTP_CODE" == "200" ]; then
          echo "Accepted updated permissions"
          UPDATED=$((UPDATED + 1))
        else
          echo "WARNING: Failed to accept updated permissions. HTTP $UPDATE_HTTP_CODE: $UPDATE_BODY"
          FAILED=$((FAILED + 1))
        fi
      fi
    else
      if [ "$DRY_RUN" == "true" ]; then
        echo "[DRY RUN] Would install"
      else
        INSTALL_RESPONSE=$(curl -s -w "\n%{http_code}" \
          -X POST \
          -H "Authorization: Bearer ${ACCESS_TOKEN}" \
          -H "Accept: application/vnd.github+json" \
          -H "X-GitHub-Api-Version: 2022-11-28" \
          -d "{\"client_id\":\"${APP_CLIENT_ID}\",\"repository_selection\":\"all\"}" \
          "${API_BASE}/enterprises/${ENTERPRISE_SLUG}/apps/organizations/${ORG}/installations")

        INSTALL_HTTP_CODE=$(echo "$INSTALL_RESPONSE" | tail -n1)
        INSTALL_BODY=$(echo "$INSTALL_RESPONSE" | sed '$d')

        if [ "$INSTALL_HTTP_CODE" == "201" ] || [ "$INSTALL_HTTP_CODE" == "200" ]; then
          echo "Successfully installed"
          INSTALLED=$((INSTALLED + 1))
        elif [ "$INSTALL_HTTP_CODE" == "422" ]; then
          echo "Already installed (confirmed via install attempt)"
          ALREADY_INSTALLED=$((ALREADY_INSTALLED + 1))
        else
          echo "WARNING: Failed to install. HTTP $INSTALL_HTTP_CODE: $INSTALL_BODY"
          FAILED=$((FAILED + 1))
        fi
      fi
    fi

    if [ "$i" -lt "$((${#APP_NAMES[@]} - 1))" ]; then
      echo "Waiting 5 seconds before next app..."
      sleep 5
    fi
  done
done <<<"$ORGS"

echo ""
echo "=== Summary ==="
echo "Newly installed: $INSTALLED"
echo "Already installed: $ALREADY_INSTALLED"
echo "Permission updates accepted: $UPDATED"
echo "Failed: $FAILED"
