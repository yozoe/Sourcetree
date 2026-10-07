#!/bin/zsh

set -euo pipefail
umask 077

if [[ "$#" -lt 1 || "$#" -gt 2 ]]; then
  print -u2 "Usage: $0 ARTIFACT_DIR [OUTPUT_MARKDOWN]"
  exit 64
fi

artifact_dir="${1:A}"
output_path="${2:-}"
if [[ ! -d "$artifact_dir" ]]; then
  print -u2 "Artifact directory does not exist: $artifact_dir"
  exit 64
fi

for command_name in jq xmllint sort awk rg; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    print -u2 "Required command is unavailable: $command_name"
    exit 69
  fi
done

memory_files=("$artifact_dir"/git_desktop_macos_memory_*.json(N))
profile_files=("$artifact_dir"/profile_*.json(N))
if (( ${#profile_files} == 0 )); then
  profile_files=("$artifact_dir"/git_desktop_macos_performance_report*.json(N))
fi
if (( ${#memory_files} == 0 )); then
  print -u2 "No memory summary JSON files found in $artifact_dir"
  exit 66
fi
if (( ${#profile_files} == 0 )); then
  print -u2 "No Profile report JSON files found in $artifact_dir"
  exit 66
fi

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/git-desktop-summary.XXXXXX")"
cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT INT TERM

typeset -a startup_memory_values scroll_memory_values memory_delta_values
memory_validation_failed=0
for file in "${memory_files[@]}"; do
  if ! jq -e '
    (.driveExitCode == 0 and .xctraceExitCode == 0 and .footprintExitCode == 0 and
     .recordingEndReason == "Target app exited" and
     (.startupPhysFootprintBytes | type) == "number" and
     (.historyScrollPhysFootprintBytes | type) == "number" and
     (.historyScrollPhysFootprintDeltaBytes | type) == "number")
  ' "$file" >/dev/null; then
    print -u2 "Invalid or incomplete memory summary: $file"
    memory_validation_failed=1
    continue
  fi
  toc_path="$(jq -r '.toc' "$file")"
  toc_reason="$(xmllint --xpath 'string(//end-reason)' "$toc_path" 2>/dev/null || true)"
  if [[ ! -f "$toc_path" ]] || [[ "$toc_reason" != "Target app exited" ]] ||
     ! rg -q 'template-name.*Allocations' "$toc_path" || ! rg -q 'VM Tracker' "$toc_path"; then
    print -u2 "Invalid trace TOC for memory summary: $file"
    memory_validation_failed=1
    continue
  fi
  startup_memory_values+=("$(jq -r '.startupPhysFootprintBytes' "$file")")
  scroll_memory_values+=("$(jq -r '.historyScrollPhysFootprintBytes' "$file")")
  memory_delta_values+=("$(jq -r '.historyScrollPhysFootprintDeltaBytes' "$file")")
done

typeset -a interactive_values first_frame_values scroll_p95_values
profile_validation_failed=0
for file in "${profile_files[@]}"; do
  if ! jq -e '
    (.report.macos_startup_performance.startup_to_interactive_millis | type) == "number" and
    (.report.macos_startup_performance.first_frame_build_time_millis | type) == "number" and
    (.report.macos_history_scroll_performance.p95_frame_build_time_millis | type) == "number" and
    (.report.macos_history_scroll_performance.frame_count | type) == "number"
  ' "$file" >/dev/null; then
    print -u2 "Invalid or incomplete Profile report: $file"
    profile_validation_failed=1
    continue
  fi
  interactive_values+=("$(jq -r '.report.macos_startup_performance.startup_to_interactive_millis' "$file")")
  first_frame_values+=("$(jq -r '.report.macos_startup_performance.first_frame_build_time_millis' "$file")")
  scroll_p95_values+=("$(jq -r '.report.macos_history_scroll_performance.p95_frame_build_time_millis' "$file")")
done

if (( memory_validation_failed || profile_validation_failed )); then
  exit 1
fi

write_values() {
  local path="$1"
  shift
  print -l -- "$@" >"$path"
}

compute_stats() {
  sort -n "$1" | awk '
    { values[NR] = $1 }
    END {
      n = NR
      if (n == 0) exit 1
      p95_index = int((n * 95 + 99) / 100)
      if (p95_index < 1) p95_index = 1
      if (n % 2 == 0) median = (values[n / 2] + values[n / 2 + 1]) / 2
      else median = values[int((n + 1) / 2)]
      printf "%s\t%s\t%s\t%s\n", median, values[p95_index], values[1], values[n]
    }
  '
}

write_values "$tmp_dir/startup-memory" "${startup_memory_values[@]}"
write_values "$tmp_dir/scroll-memory" "${scroll_memory_values[@]}"
write_values "$tmp_dir/memory-delta" "${memory_delta_values[@]}"
write_values "$tmp_dir/interactive" "${interactive_values[@]}"
write_values "$tmp_dir/first-frame" "${first_frame_values[@]}"
write_values "$tmp_dir/scroll-p95" "${scroll_p95_values[@]}"

IFS=$'\t' read -r startup_memory_median startup_memory_p95 startup_memory_min startup_memory_max < <(compute_stats "$tmp_dir/startup-memory")
IFS=$'\t' read -r scroll_memory_median scroll_memory_p95 scroll_memory_min scroll_memory_max < <(compute_stats "$tmp_dir/scroll-memory")
IFS=$'\t' read -r memory_delta_median memory_delta_p95 memory_delta_min memory_delta_max < <(compute_stats "$tmp_dir/memory-delta")
IFS=$'\t' read -r interactive_median interactive_p95 interactive_min interactive_max < <(compute_stats "$tmp_dir/interactive")
IFS=$'\t' read -r first_frame_median first_frame_p95 first_frame_min first_frame_max < <(compute_stats "$tmp_dir/first-frame")
IFS=$'\t' read -r scroll_p95_median scroll_p95_sample_p95 scroll_p95_min scroll_p95_max < <(compute_stats "$tmp_dir/scroll-p95")

budget_status() {
  if awk -v value="$1" -v budget="$2" 'BEGIN { exit !(value <= budget) }'; then
    print "PASS"
  else
    print "FAIL"
  fi
}

interactive_status="$(budget_status "$interactive_p95" 3000)"
scroll_status="$(budget_status "$scroll_p95_sample_p95" 24)"
generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
typeset -a report_lines
report_lines+=("# macOS Profile / Engine-native 性能基线摘要")
report_lines+=("")
report_lines+=("- 生成时间：$generated_at")
report_lines+=("- 采样目录：$artifact_dir")
report_lines+=("- 内存有效轮次：${#startup_memory_values}")
report_lines+=("- Profile 有效轮次：${#interactive_values}")
report_lines+=("")
report_lines+=("| 指标 | n | 中位数 | 样本 P95 | 最小值 | 最大值 | 预算/状态 |")
report_lines+=("| --- | ---: | ---: | ---: | ---: | ---: | --- |")
report_lines+=("| 启动到可交互（ms） | ${#interactive_values} | $interactive_median | $interactive_p95 | $interactive_min | $interactive_max | ≤ 3000ms：$interactive_status |")
report_lines+=("| 首帧构建（ms） | ${#first_frame_values} | $first_frame_median | $first_frame_p95 | $first_frame_min | $first_frame_max | 描述性样本 |")
report_lines+=("| 历史滚动构建 P95（ms） | ${#scroll_p95_values} | $scroll_p95_median | $scroll_p95_sample_p95 | $scroll_p95_min | $scroll_p95_max | ≤ 24ms：$scroll_status |")
report_lines+=("| 启动完成 phys_footprint（B） | ${#startup_memory_values} | $startup_memory_median | $startup_memory_p95 | $startup_memory_min | $startup_memory_max | 诊断基线 |")
report_lines+=("| 滚动完成 phys_footprint（B） | ${#scroll_memory_values} | $scroll_memory_median | $scroll_memory_p95 | $scroll_memory_min | $scroll_memory_max | 诊断基线 |")
report_lines+=("| 滚动阶段 phys_footprint 增量（B） | ${#memory_delta_values} | $memory_delta_median | $memory_delta_p95 | $memory_delta_min | $memory_delta_max | 诊断基线 |")
report_lines+=("")
report_lines+=("所有内存轮次均校验 drive/xctrace/footprint 退出码为 0、TOC 结束原因为 \`Target app exited\`，并包含 Allocations 与 VM Tracker。")
report_lines+=("内存增量包含滚动缓存和测量开销，不直接等同于泄漏或发布预算。")

print -l -- "${report_lines[@]}"
if [[ -n "$output_path" ]]; then
  print -l -- "${report_lines[@]}" >"${output_path:A}"
fi

if [[ "$interactive_status" != PASS || "$scroll_status" != PASS ]]; then
  exit 1
fi
