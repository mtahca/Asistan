#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
BETA_PYTHON="${ASISTAN_BETA_PYTHON:-$HOME/Documents/Codex/Asistan Beta Data/.venv/bin/python}"
"$BETA_PYTHON" -B -m unittest discover -s tests -v
TEST_BUILD="${TMPDIR:-/tmp}/asistan-beta-test-build"
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
for script in build.sh setup.sh test.sh; do bash -n "$script"; done
