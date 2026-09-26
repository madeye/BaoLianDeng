#!/bin/bash
# Shared helpers for the local deploy/build scripts (dev-deploy.sh,
# release-deploy.sh, build-appstore-pkg.sh, build-release-pkg.sh,
# build-release-dmg.sh). Sourced, never executed directly.
#
# Fixes GitHub issue #113 finding 3: `xcodebuild ... | tail -N` under
# `set -e` (without pipefail) reports the exit status of `tail`, not
# `xcodebuild` — so a failed build (e.g. exit 65) was silently treated as
# success, and callers went on to `rm -rf` the previously-installed app
# before copying in a missing/incomplete replacement.
#
# dev-deploy.sh and release-deploy.sh call `build_and_install_app` (below)
# for their whole build+install sequence, rather than each re-implementing
# the build/status-check/install control flow inline — that keeps the real
# code path small enough for tests/scripts/test-deploy-guards.sh to exercise
# directly instead of re-deriving it.

# xcodebuild_logged <log_file> <tail_lines> <xcodebuild args...>
#
# Runs `xcodebuild "$@"` with combined stdout/stderr captured to
# <log_file>, then prints the last <tail_lines> lines of it (matching the
# old `2>&1 | tail -N` output — `tail` without `-f` only ever prints once
# the input is exhausted, so this produces the same visible output).
# Returns xcodebuild's own exit status, never a status masked by a pipe.
xcodebuild_logged() {
  local log_file="$1"
  shift
  local tail_lines="$1"
  shift
  local status=0
  xcodebuild "$@" >"$log_file" 2>&1 || status=$?
  tail -n "$tail_lines" "$log_file"
  return "$status"
}

# install_app_bundle <built_app_path> <install_path> [required_plugin_rel_path]
#
# Validates that a freshly built .app bundle looks complete (an executable
# at Contents/MacOS/<name>, Contents/Info.plist, and the expected plugin —
# Contents/PlugIns/TransparentProxy.appex by default), stages a copy of it,
# and only then swaps it into <install_path>: the previous install (if any)
# is moved aside, the staged copy is moved into place, and the old install
# is removed only after that swap succeeds. On any failure the previous
# install is left exactly as it was (restored from the aside-move if the
# final swap itself failed).
install_app_bundle() {
  local built_app="$1"
  local install_path="$2"
  local required_plugin="${3:-Contents/PlugIns/TransparentProxy.appex}"
  local app_name
  app_name="$(basename "$install_path" .app)"

  if [ ! -d "$built_app" ]; then
    echo "ERROR: built app not found at ${built_app}"
    return 1
  fi
  if [ ! -f "${built_app}/Contents/MacOS/${app_name}" ]; then
    echo "ERROR: built app missing executable Contents/MacOS/${app_name}"
    return 1
  fi
  if [ ! -f "${built_app}/Contents/Info.plist" ]; then
    echo "ERROR: built app missing Contents/Info.plist"
    return 1
  fi
  if [ ! -d "${built_app}/${required_plugin}" ]; then
    echo "ERROR: built app missing ${required_plugin}"
    return 1
  fi

  local staging
  staging="$(mktemp -d "${TMPDIR:-/tmp}/${app_name}-stage.XXXXXX")" || {
    echo "ERROR: mktemp -d failed while staging the built app"
    return 1
  }
  if ! cp -R "$built_app" "${staging}/${app_name}.app"; then
    echo "ERROR: failed to stage built app"
    rm -rf "$staging"
    return 1
  fi
  # The Xcode project still embeds the Developer ID system-extension
  # product. Local Debug/Release uses the app extension; prune the sysext
  # so the two providers (same bundle ID) cannot compete at runtime.
  rm -rf "${staging}/${app_name}.app/Contents/Library/SystemExtensions"

  local backup=""
  if [ -d "$install_path" ]; then
    backup="${install_path}.bak.$$"
    if ! mv "$install_path" "$backup"; then
      echo "ERROR: failed to move aside existing install at ${install_path}"
      rm -rf "$staging"
      return 1
    fi
  fi

  if ! mv "${staging}/${app_name}.app" "$install_path"; then
    echo "ERROR: failed to move staged app into ${install_path}"
    if [ -n "$backup" ]; then
      mv "$backup" "$install_path"
    fi
    rm -rf "$staging"
    return 1
  fi

  rm -rf "$staging"
  if [ -n "$backup" ]; then
    rm -rf "$backup"
  fi
  return 0
}

# build_and_install_app <built_app_glob> <install_path> <tail_lines> <required_plugin> -- <xcodebuild args...>
#
# The single code path dev-deploy.sh and release-deploy.sh use to turn an
# `xcodebuild build` invocation into an installed app. Runs xcodebuild via
# xcodebuild_logged (so a failed build reports its own exit status, never
# tail's) and, on any build failure, returns that status immediately
# *without touching <install_path>* — the previous install is left exactly
# as it was. The log is kept (not deleted) on failure and its path is
# printed, since the caller only ever sees the last <tail_lines> lines of
# it. On a successful build, <built_app_glob> (a shell glob pattern — e.g.
# one containing a DerivedData `BaoLianDeng-*` wildcard, which is why this
# resolves it with `eval echo` rather than a literal path) is expanded to
# the produced .app and installed via install_app_bundle, which validates
# the bundle and stages the swap before ever removing a previous install.
#
# tests/scripts/test-deploy-guards.sh calls this exact function (with a
# stub failing xcodebuild on PATH) to guard against a regression of issue
# #113 finding 3 — the test exercises this real code path, not a
# reimplementation of the scripts' control flow.
build_and_install_app() {
  local built_app_glob="$1"
  shift
  local install_path="$1"
  shift
  local tail_lines="$1"
  shift
  local required_plugin="$1"
  shift
  if [ "${1:-}" = "--" ]; then
    shift
  fi

  local build_log
  build_log="$(mktemp "${TMPDIR:-/tmp}/BaoLianDeng-build.XXXXXX")" || {
    echo "ERROR: mktemp failed while preparing the build log"
    return 1
  }
  local build_status=0
  xcodebuild_logged "$build_log" "$tail_lines" "$@" || build_status=$?
  if [ "$build_status" -ne 0 ]; then
    echo "ERROR: xcodebuild build failed (exit ${build_status}); leaving installed app untouched"
    echo "Full log: $build_log"
    return "$build_status"
  fi
  rm -f "$build_log"

  local built_app
  built_app=$(eval echo "$built_app_glob")
  if ! install_app_bundle "$built_app" "$install_path" "$required_plugin"; then
    echo "ERROR: install failed; any previously-installed app was left in place"
    return 1
  fi
  return 0
}
