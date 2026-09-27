#!/bin/bash

# Shared helpers for the tests in this directory, in the shape of Omarchy's
# test/shell.d/base-test.sh: TAP-style ok/not ok lines, and run_node_test for
# checking Model.js under node.

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  echo "source test/base-test.sh from a test; do not run it directly" >&2
  exit 1
fi

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export ROOT

pass() {
  printf 'ok - %s\n' "$1"
}

fail() {
  local description="$1"
  local detail="${2:-}"

  [[ -n $detail ]] && printf '%s\n' "$detail" >&2
  printf 'not ok - %s\n' "$description" >&2
  exit 1
}

assert() {
  local description="$1"
  shift
  if "$@"; then
    pass "$description"
  else
    fail "$description"
  fi
}

assert_equal() {
  local actual="$1" expected="$2" description="$3"
  if [[ $actual == "$expected" ]]; then
    pass "$description"
  else
    fail "$description" "expected: $expected"$'\n'"actual:   $actual"
  fi
}

require_command() {
  command -v "$1" >/dev/null || fail "required command is available: $1"
}

run_node_test() {
  require_command node

  {
    cat <<'JS_PRELUDE'
const path = require('path')
const fs = require('fs')
const root = process.env.ROOT

function fail(description, detail) {
  if (detail) console.error(detail)
  console.error(`not ok - ${description}`)
  process.exit(1)
}

function pass(description) {
  console.log(`ok - ${description}`)
}

function assert(condition, description, detail) {
  if (!condition) fail(description, detail)
  pass(description)
}

function assertEqual(actual, expected, description) {
  assert(actual === expected, description, `expected: ${expected}\nactual:   ${actual}`)
}

function assertDeepEqual(actual, expected, description) {
  const actualJson = JSON.stringify(actual)
  const expectedJson = JSON.stringify(expected)
  assert(actualJson === expectedJson, description, `expected: ${expectedJson}\nactual:   ${actualJson}`)
}

function requireFromRoot(relativePath) {
  return require(path.join(root, relativePath))
}

function readFixture(name) {
  return fs.readFileSync(path.join(root, 'test/fixtures', name), 'utf8')
}
JS_PRELUDE
    cat
  } | node -
}
