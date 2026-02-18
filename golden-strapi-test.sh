#!/usr/bin/env bash
set -euo pipefail

# ====== CONFIG ======
: "${STRAPI_BASE_URL:?Set STRAPI_BASE_URL, e.g. http://localhost:1337/api}"
: "${STRAPI_API_TOKEN:?Set STRAPI_API_TOKEN}"

COLLECTION_UID="${COLLECTION_UID:-articles}"
TITLE_FIELD="${TITLE_FIELD:-title}"
BODY_FIELD="${BODY_FIELD:-content}"
TEST_LOCALE="${TEST_LOCALE:-en}"

# ====== HELPERS ======
run() {
  echo
  echo "▶ $*"
  "$@"
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; :a;N;$!ba;s/\n/\\n/g'
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

TSX=(npx tsx src/index.ts)

STAMP="$(date +%Y%m%d-%H%M%S)"
TEST_TITLE="Golden test ${STAMP}"
TEST_BODY="Created by golden test at ${STAMP}"

TEST_TITLE_ESCAPED="$(json_escape "$TEST_TITLE")"
TEST_BODY_ESCAPED="$(json_escape "$TEST_BODY")"

CREATE_JSON="{\"${TITLE_FIELD}\":\"${TEST_TITLE_ESCAPED}\",\"${BODY_FIELD}\":\"${TEST_BODY_ESCAPED}\"}"
UPDATE_JSON="{\"${TITLE_FIELD}\":\"${TEST_TITLE_ESCAPED} (updated)\"}"

echo "== Strapi Golden E2E Test =="
echo "STRAPI_BASE_URL=$STRAPI_BASE_URL"
echo "COLLECTION_UID=$COLLECTION_UID"
echo "TITLE_FIELD=$TITLE_FIELD"
echo "BODY_FIELD=$BODY_FIELD"
echo "TEST_LOCALE=$TEST_LOCALE"

# ====== 1) BUILD / TYPECHECK ======
run npm install
run npm run typecheck
run npm run build

# ====== 2) INTROSPECTION ======
run "${TSX[@]}" content types
run "${TSX[@]}" content schema "$COLLECTION_UID"
run "${TSX[@]}" content relations
run "${TSX[@]}" content inspect "$COLLECTION_UID"

# ====== 3) BASIC READ ======
run "${TSX[@]}" collection find "$COLLECTION_UID" '{"pagination":{"page":1,"pageSize":5}}'

# ====== 4) CREATE DRAFT ======
CREATE_OUT="$("${TSX[@]}" content create-draft "$COLLECTION_UID" "$CREATE_JSON")"
echo "$CREATE_OUT"

DOC_ID=""
if command -v jq >/dev/null 2>&1; then
  DOC_ID="$(printf '%s' "$CREATE_OUT" | jq -r '.documentId // .data.documentId // .id // .data.id // empty' | head -n1)"
else
  DOC_ID="$(printf '%s' "$CREATE_OUT" | sed -n 's/.*"documentId":"\([^"]*\)".*/\1/p' | head -n1)"
  if [[ -z "$DOC_ID" ]]; then
    DOC_ID="$(printf '%s' "$CREATE_OUT" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p' | head -n1)"
  fi
fi

if [[ -z "$DOC_ID" ]]; then
  echo "❌ Could not extract document id from create output."
  echo "   Check the create-draft response format."
  exit 1
fi

echo "✅ Created document id: $DOC_ID"

# ====== 5) FIND ONE + UPDATE ======
run "${TSX[@]}" collection findOne "$COLLECTION_UID" "$DOC_ID"
run "${TSX[@]}" collection update "$COLLECTION_UID" "$DOC_ID" "$UPDATE_JSON"
run "${TSX[@]}" collection findOne "$COLLECTION_UID" "$DOC_ID"

# ====== 6) DRAFT/PUBLISH FLOW ======
run "${TSX[@]}" content drafts "$COLLECTION_UID"
run "${TSX[@]}" content publish "$COLLECTION_UID" "$DOC_ID"
run "${TSX[@]}" content published "$COLLECTION_UID"
run "${TSX[@]}" content unpublish "$COLLECTION_UID" "$DOC_ID"
run "${TSX[@]}" content drafts "$COLLECTION_UID"

# ====== 7) LOCALE/I18N SMOKE ======
run "${TSX[@]}" locale list

set +e
"${TSX[@]}" localize status collection "$COLLECTION_UID" "$DOC_ID"
LOCALIZE_STATUS_RC=$?
"${TSX[@]}" localize get collection "$COLLECTION_UID" "$TEST_LOCALE" "$DOC_ID"
LOCALIZE_GET_RC=$?
set -e

if [[ $LOCALIZE_STATUS_RC -ne 0 || $LOCALIZE_GET_RC -ne 0 ]]; then
  echo "⚠️  i18n smoke partially failed (i18n plugin or locale may not be configured) — OK for non-i18n projects."
else
  echo "✅ i18n smoke passed"
fi

# ====== 8) FILES SMOKE ======
run "${TSX[@]}" files find

echo
echo "🎉 Golden test finished."
echo "Created test document id: $DOC_ID"
echo "Optional cleanup:"
echo "  npx tsx src/index.ts collection delete $COLLECTION_UID $DOC_ID"
