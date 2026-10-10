#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
PYTHON="${ASISTAN_PYTHON:-${ASISTAN_BETA_PYTHON:-}}"
if [ -z "$PYTHON" ]; then
  PYTHON="$HOME/Documents/Asistan Data/.venv/bin/python"
  [ -x "$PYTHON" ] || PYTHON="$HOME/Documents/Codex/Asistan Beta Data/.venv/bin/python"
fi
"$PYTHON" -B -m unittest discover -s tests -v
TEST_BUILD="${TMPDIR:-/tmp}/asistan-test-build"
mkdir -p "$TEST_BUILD/cache"
swiftc -module-cache-path "$TEST_BUILD/cache" app/Protocol.swift tests/ProtocolTests.swift -o "$TEST_BUILD/protocol-tests"
"$TEST_BUILD/protocol-tests"
swiftc -module-cache-path "$TEST_BUILD/cache" app/ModelConfiguration.swift tests/ModelConfigurationTests.swift -o "$TEST_BUILD/model-tests"
"$TEST_BUILD/model-tests"
swiftc -module-cache-path "$TEST_BUILD/cache" app/CallPolicy.swift tests/CallPolicyTests.swift -o "$TEST_BUILD/call-tests"
"$TEST_BUILD/call-tests"
swiftc -module-cache-path "$TEST_BUILD/cache" app/CallPolicy.swift app/CallerIdentity.swift tests/CallerIdentityTests.swift -o "$TEST_BUILD/caller-tests"
"$TEST_BUILD/caller-tests"
swiftc -module-cache-path "$TEST_BUILD/cache" app/AssistantPreferences.swift tests/AssistantPreferencesTests.swift -o "$TEST_BUILD/preferences-tests"
"$TEST_BUILD/preferences-tests"
swiftc -module-cache-path "$TEST_BUILD/cache" app/MobileProtocol.swift app/FocusMonitor.swift tests/MobileFocusTests.swift -o "$TEST_BUILD/mobile-focus-tests"
"$TEST_BUILD/mobile-focus-tests"
swiftc -module-cache-path "$TEST_BUILD/cache" app/Migration.swift app/RecentNotes.swift tests/MigrationNotesTests.swift -o "$TEST_BUILD/migration-notes-tests"
"$TEST_BUILD/migration-notes-tests"
swiftc -module-cache-path "$TEST_BUILD/cache" app/AnswerMode.swift tests/AnswerModeTests.swift -o "$TEST_BUILD/answer-mode-tests"
"$TEST_BUILD/answer-mode-tests"
swiftc -module-cache-path "$TEST_BUILD/cache" app/MenuRoute.swift tests/MenuRouteTests.swift -o "$TEST_BUILD/menu-route-tests"
"$TEST_BUILD/menu-route-tests"
for script in build.sh setup.sh test.sh make_cert.sh paketle.sh; do bash -n "$script"; done
