#!/bin/zsh

set -euo pipefail
umask 077

if [[ "$(uname -s)" != "Darwin" ]]; then
  print -u2 "This memory profile requires macOS Instruments (xctrace)."
  exit 64
fi

repo_root="${0:A:h}/.."
output_dir="${1:-/private/tmp/git-desktop-macos-memory}"
mkdir -p "$output_dir"

stamp="$(date +%Y%m%d-%H%M%S)"
trace_path="$output_dir/git_desktop_macos_memory_${stamp}.trace"
toc_path="$output_dir/git_desktop_macos_memory_${stamp}.toc.xml"
drive_log="$output_dir/git_desktop_macos_memory_${stamp}.drive.log"
xctrace_log="$output_dir/git_desktop_macos_memory_${stamp}.xctrace.log"
metadata_path="$output_dir/git_desktop_macos_memory_${stamp}.json"
coordination_dir="$output_dir/git_desktop_macos_memory_${stamp}.coordination"
metadata_plist="$coordination_dir/metadata.plist"
startup_footprint="$output_dir/git_desktop_macos_memory_${stamp}.after_startup.footprint.txt"
scroll_footprint="$output_dir/git_desktop_macos_memory_${stamp}.after_history_scroll.footprint.txt"
drive_status=0
trace_status=0
footprint_status=0
drive_pid=""
trace_pid=""
app_pid=""
trace_end_reason=""

cleanup() {
  if [[ -n "$trace_pid" ]] && kill -0 "$trace_pid" 2>/dev/null; then
    kill "$trace_pid" 2>/dev/null || true
  fi
  if [[ -n "$drive_pid" ]] && kill -0 "$drive_pid" 2>/dev/null; then
    kill "$drive_pid" 2>/dev/null || true
  fi
}
trap cleanup INT TERM

cd "$repo_root"
mkdir -p "$coordination_dir"
GIT_DESKTOP_MEMORY_PROFILE_DIR="$coordination_dir" \
  flutter drive --profile --no-pub --no-dds -d macos \
  --target=integration_test/macos_performance_test.dart >"$drive_log" 2>&1 &
drive_pid="$!"

for attempt in {1..180}; do
  child_pids="$(pgrep -P "$drive_pid" || true)"
  for candidate in ${(f)child_pids}; do
    child_name="$(ps -p "$candidate" -o comm= || true)"
    if [[ "$child_name" == *"Git Desktop"* ]]; then
      app_pid="$candidate"
      break
    fi
  done
  if [[ -n "$app_pid" ]]; then
    break
  fi
  if ! kill -0 "$drive_pid" 2>/dev/null; then
    break
  fi
  sleep 1
done

if [[ -z "$app_pid" ]]; then
  wait "$drive_pid" || drive_status="$?"
  print -u2 "Could not find the Profile app process. See $drive_log"
  if [[ "$drive_status" -eq 0 ]]; then
    drive_status=1
  fi
  exit "$drive_status"
fi

print "Recording Allocations for PID $app_pid to $trace_path"
xcrun xctrace record \
  --template 'Allocations' \
  --attach "$app_pid" \
  --output "$trace_path" \
  --no-prompt >"$xctrace_log" 2>&1 &
trace_pid="$!"

for label in after_startup after_history_scroll; do
  ready="$coordination_dir/$label.ready"
  resume="$coordination_dir/$label.continue"
  sample_path="$startup_footprint"
  if [[ "$label" == "after_history_scroll" ]]; then
    sample_path="$scroll_footprint"
  fi
  sample_ready=false
  for attempt in {1..180}; do
    if [[ -f "$ready" ]]; then
      sample_ready=true
      break
    fi
    if ! kill -0 "$drive_pid" 2>/dev/null; then
      break
    fi
    sleep 1
  done
  if [[ "$sample_ready" == true ]]; then
    footprint --pid "$app_pid" -f bytes >"$sample_path" 2>&1 || footprint_status="$?"
    touch "$resume"
  else
    footprint_status=1
    print -u2 "Timed out waiting for the $label memory checkpoint."
    break
  fi
done

wait "$drive_pid" || drive_status="$?"
wait "$trace_pid" || trace_status="$?"
trace_pid=""
drive_pid=""

if [[ -e "$trace_path" ]]; then
  xcrun xctrace export --input "$trace_path" --toc --output "$toc_path"
  trace_end_reason="$(xmllint --xpath 'string(//end-reason)' "$toc_path" 2>/dev/null || true)"
  if [[ "$trace_status" -eq 0 ]] && [[ "$trace_end_reason" != "Target app exited" ]]; then
    trace_status=1
    print -u2 "Instruments ended unexpectedly: ${trace_end_reason:-unknown reason}."
  fi
elif [[ "$trace_status" -eq 0 ]]; then
  trace_status=1
  print -u2 "Instruments did not produce a trace at $trace_path."
fi

startup_phys_footprint=null
startup_phys_footprint_peak=null
scroll_phys_footprint=null
scroll_phys_footprint_peak=null
phys_footprint_delta=null
if [[ -f "$startup_footprint" ]]; then
  startup_phys_footprint="$(awk '/^[[:space:]]*phys_footprint:/ {print $2; exit}' "$startup_footprint")"
  startup_phys_footprint_peak="$(awk '/^[[:space:]]*phys_footprint_peak:/ {print $2; exit}' "$startup_footprint")"
  [[ -n "$startup_phys_footprint" ]] || startup_phys_footprint=null
  [[ -n "$startup_phys_footprint_peak" ]] || startup_phys_footprint_peak=null
fi
if [[ -f "$scroll_footprint" ]]; then
  scroll_phys_footprint="$(awk '/^[[:space:]]*phys_footprint:/ {print $2; exit}' "$scroll_footprint")"
  scroll_phys_footprint_peak="$(awk '/^[[:space:]]*phys_footprint_peak:/ {print $2; exit}' "$scroll_footprint")"
  [[ -n "$scroll_phys_footprint" ]] || scroll_phys_footprint=null
  [[ -n "$scroll_phys_footprint_peak" ]] || scroll_phys_footprint_peak=null
fi
if [[ "$startup_phys_footprint" != null ]] && [[ "$scroll_phys_footprint" != null ]]; then
  phys_footprint_delta="$((scroll_phys_footprint - startup_phys_footprint))"
fi

plutil -create xml1 "$metadata_plist"
plutil -insert trace -string "$trace_path" "$metadata_plist"
plutil -insert toc -string "$toc_path" "$metadata_plist"
plutil -insert driveLog -string "$drive_log" "$metadata_plist"
plutil -insert xctraceLog -string "$xctrace_log" "$metadata_plist"
plutil -insert startupFootprint -string "$startup_footprint" "$metadata_plist"
plutil -insert historyScrollFootprint -string "$scroll_footprint" "$metadata_plist"
plutil -insert recordingEndReason -string "$trace_end_reason" "$metadata_plist"
plutil -insert appPid -integer "$app_pid" "$metadata_plist"
plutil -insert driveExitCode -integer "$drive_status" "$metadata_plist"
plutil -insert xctraceExitCode -integer "$trace_status" "$metadata_plist"
plutil -insert footprintExitCode -integer "$footprint_status" "$metadata_plist"
if [[ "$startup_phys_footprint" != null ]]; then
  plutil -insert startupPhysFootprintBytes -integer "$startup_phys_footprint" "$metadata_plist"
fi
if [[ "$startup_phys_footprint_peak" != null ]]; then
  plutil -insert startupPhysFootprintPeakBytes -integer "$startup_phys_footprint_peak" "$metadata_plist"
fi
if [[ "$scroll_phys_footprint" != null ]]; then
  plutil -insert historyScrollPhysFootprintBytes -integer "$scroll_phys_footprint" "$metadata_plist"
fi
if [[ "$scroll_phys_footprint_peak" != null ]]; then
  plutil -insert historyScrollPhysFootprintPeakBytes -integer "$scroll_phys_footprint_peak" "$metadata_plist"
fi
if [[ "$phys_footprint_delta" != null ]]; then
  plutil -insert historyScrollPhysFootprintDeltaBytes -integer "$phys_footprint_delta" "$metadata_plist"
fi
plutil -convert json -o "$metadata_path" "$metadata_plist"

if [[ "$drive_status" -ne 0 ]]; then
  exit "$drive_status"
fi
if [[ "$trace_status" -ne 0 ]]; then
  exit "$trace_status"
fi
if [[ "$footprint_status" -ne 0 ]]; then
  exit "$footprint_status"
fi
