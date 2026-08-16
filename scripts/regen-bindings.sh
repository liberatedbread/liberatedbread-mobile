#!/usr/bin/env bash
# Regenerate the Rust FFI (flutter_rust_bridge) bindings when — and only when —
# the Rust API has changed since they were last generated. Sourced by the
# run-*.sh scripts so a `flutter run` always reflects the current Rust: a change
# to a DTO or an api fn is otherwise invisible until someone remembers to regen
# by hand, which is exactly how a stale build ships the old surface.
#
# This is a REBUILD, not a clean rebuild: it touches only the generated bindings
# and leaves cargo's incremental cache alone. Set LB_FRB_REGEN=0 to skip it.

# Regenerate FFI bindings if any rust/src/**.rs is newer than the generated
# Dart. Expects PROJECT_DIR set and a `log` function; both are provided by the
# run-*.sh caller. No-op (with a note) when the codegen isn't installed.
regen_frb_bindings() {
  [[ "${LB_FRB_REGEN:-1}" == "0" ]] && return 0
  local project="${PROJECT_DIR:-$(pwd)}"
  local generated="$project/lib/src/rust/frb_generated.dart"

  if ! command -v flutter_rust_bridge_codegen >/dev/null 2>&1; then
    log "flutter_rust_bridge_codegen not on PATH — skipping FFI regen (run scripts/setup.sh to install it)."
    return 0
  fi

  # Regenerate only when a Rust source is newer than the generated bindings, so
  # a launch that changed no Rust pays nothing.
  if [[ -f "$generated" ]] &&
     [[ -z "$(find "$project/rust/src" -name '*.rs' -newer "$generated" -print -quit 2>/dev/null)" ]]; then
    return 0
  fi

  log "Rust changed since the last generate — regenerating FFI bindings..."
  ( cd "$project" && flutter_rust_bridge_codegen generate )
}
