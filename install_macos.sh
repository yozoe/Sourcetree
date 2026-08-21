#!/usr/bin/env bash
# Builds the release app, installs it in /Applications, and starts it.
#
# An existing /Applications/Git Desktop.app is overwritten in place. The
# script never disables Gatekeeper or changes macOS security settings.
set -euo pipefail

readonly app_name='Git Desktop.app'
readonly repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly source_app="$repository_root/build/macos/Build/Products/Release/$app_name"
readonly target_app="/Applications/$app_name"
readonly target_process_pattern='^/Applications/Git Desktop[.]app/Contents/MacOS/Git Desktop( |$)'
readonly lsregister='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'

staging_directory=''
staged_app=''
previous_app=''
target_was_moved=false
install_finished=false

run_installer_command() {
  if [[ -w '/Applications' ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

running_app_pids() {
  # Match only processes launched from the canonical installed bundle. This
  # includes the library process and every Dock-less repository workspace,
  # without stopping Debug builds or an unrelated app with the same name.
  /usr/bin/pgrep -f "$target_process_pattern"
}

is_app_running() {
  running_app_pids >/dev/null 2>&1
}

terminate_remaining_app_processes() {
  local pids=()
  local pid=''
  while IFS= read -r pid; do
    if [[ -n "$pid" ]]; then
      pids+=("$pid")
    fi
  done < <(running_app_pids || true)

  if (( ${#pids[@]} == 0 )); then
    return
  fi

  echo 'Stopping remaining Git Desktop workspace processes…'
  # A process can finish between pgrep and kill; the verification loop below
  # remains the source of truth for whether every installed instance exited.
  /bin/kill -TERM "${pids[@]}" 2>/dev/null || true
}

restore_previous_app() {
  local exit_code=$?
  if [[ "$install_finished" == false && "$target_was_moved" == true && -d "$previous_app" ]]; then
    echo 'Installation failed; restoring the previous app.' >&2
    if [[ -d "$target_app" ]]; then
      run_installer_command rm -rf "$target_app"
    fi
    run_installer_command mv "$previous_app" "$target_app"
  fi
  if [[ -n "$staging_directory" && -d "$staging_directory" ]]; then
    run_installer_command rm -rf "$staging_directory"
  fi
  exit "$exit_code"
}
trap restore_previous_app EXIT

cd -- "$repository_root"
flutter build macos --release

if [[ ! -d "$source_app" ]]; then
  echo "Release app was not produced: $source_app" >&2
  exit 1
fi
if [[ -L "$target_app" || ( -e "$target_app" && ! -d "$target_app" ) ]]; then
  echo "Refusing to replace a non-directory target: $target_app" >&2
  exit 1
fi

if [[ -d "$target_app" ]]; then
  echo 'Requesting the running Git Desktop app to quit…'
  /usr/bin/osascript -e 'tell application id "com.yozoe.gitDesktop" to quit' >/dev/null 2>&1 || true
  for _ in {1..40}; do
    if ! is_app_running; then
      break
    fi
    sleep 0.25
  done
  if is_app_running; then
    # Apple Events address one application instance. Repository workspaces are
    # separate accessory processes, so stop only the remaining processes that
    # belong to the canonical installed bundle before replacing it.
    terminate_remaining_app_processes
    for _ in {1..40}; do
      if ! is_app_running; then
        break
      fi
      sleep 0.25
    done
  fi
  if is_app_running; then
    echo 'Git Desktop is still running; installation was not started.' >&2
    exit 1
  fi
fi

staging_directory="$(run_installer_command mktemp -d '/Applications/.git-desktop-install.XXXXXX')"
staged_app="$staging_directory/$app_name"
previous_app="$staging_directory/previous.app"
echo 'Staging the new application…'
run_installer_command ditto "$source_app" "$staged_app"

echo "Installing $app_name into /Applications…"
if [[ -d "$target_app" ]]; then
  run_installer_command mv "$target_app" "$previous_app"
  target_was_moved=true
fi
run_installer_command mv "$staged_app" "$target_app"
"$lsregister" -f "$target_app"
install_finished=true
trap - EXIT
run_installer_command rm -rf "$staging_directory"

echo "Starting $target_app"
open "$target_app"
