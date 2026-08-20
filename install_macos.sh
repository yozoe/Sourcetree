#!/usr/bin/env bash
# Builds the release app, installs it in /Applications, and starts it.
#
# An existing /Applications/Git Desktop.app is moved aside to a timestamped
# backup instead of being deleted. The script never disables Gatekeeper or
# changes macOS security settings.
set -euo pipefail

readonly app_name='Git Desktop.app'
readonly repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly source_app="$repository_root/build/macos/Build/Products/Release/$app_name"
readonly target_app="/Applications/$app_name"

backup_app=''
install_finished=false

restore_previous_app() {
  local exit_code=$?
  if [[ "$install_finished" == false && -n "$backup_app" && -d "$backup_app" && ! -e "$target_app" ]]; then
    echo 'Installation failed; restoring the previous app.' >&2
    sudo mv "$backup_app" "$target_app"
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
  backup_app="/Applications/${app_name%.app}.backup.$(date +%Y%m%d%H%M%S).app"
  echo "Backing up the existing app to: $backup_app"
  sudo mv "$target_app" "$backup_app"
fi

echo "Installing $app_name into /Applications…"
sudo ditto "$source_app" "$target_app"
install_finished=true
trap - EXIT

echo "Starting $target_app"
open -n "$target_app"
if [[ -n "$backup_app" ]]; then
  echo "Previous app backup retained at: $backup_app"
fi
