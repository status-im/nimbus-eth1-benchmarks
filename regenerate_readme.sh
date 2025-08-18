#!/usr/bin/env bash
set -e

# This script should be run from the nimbus-eth1-benchmarks repository root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NIMBUS_ETH1_BENCHMARKS_REPO="${SCRIPT_DIR}"
README_FILE_PATH="${NIMBUS_ETH1_BENCHMARKS_REPO}/README.md"
README_TEMPLATE_PATH="${NIMBUS_ETH1_BENCHMARKS_REPO}/README-TEMPLATE.md"

function format_timestamp_date() {
  echo "$1" | awk '{
      year=substr($0,1,4)
      month=substr($0,5,2)
      day=substr($0,7,2)
      hour=substr($0,10,2)
      min=substr($0,12,2)
      sec=substr($0,14,2)
      print year "-" month "-" day " " hour ":" min ":" sec
  }'
}

function generateBenchmarkRepoReadme() {
  TABLE_HEADER="| Generated At | Baseline SHA | Contender SHA | Baseline Time | Contender Time | Time Delta |
|--------------|--------------|---------------|---------------|----------------|------------|"

  local LONG_BENCHMARK_TABLE="$TABLE_HEADER"
  local SHORT_BENCHMARK_TABLE="$TABLE_HEADER"

  while read -r file; do
      local dir_path=$(dirname "$file")
      local dir_name=$(basename "$dir_path")
      local raw_timestamp=$(echo "$dir_name" | grep -o '^[0-9]\{8\}T[0-9]\{6\}')
      local timestamp=$(format_timestamp_date "$raw_timestamp")
      
      # Extract git SHA from directory name (after underscore)
      local contender_git_sha=$(echo "$dir_name" | cut -d'_' -f2)
      
      # Try to get baseline SHA from the previous benchmark in the same directory
      local benchmark_type_dir=$(dirname "$dir_path")
      local prev_dir=$(ls -1 "$benchmark_type_dir" | grep -B1 "^${dir_name}$" | head -n1)
      local baseline_git_sha=""
      
      if [ "$prev_dir" != "$dir_name" ] && [ ! -z "$prev_dir" ]; then
          baseline_git_sha=$(echo "$prev_dir" | cut -d'_' -f2)
      fi
      
      # If we can't find baseline SHA from directory structure, try extracting from file content
      if [ -z "$baseline_git_sha" ]; then
          # Try to extract from python command line if it exists
          baseline_git_sha=$(grep "block-import-stats.py" "$file" 2>/dev/null | grep -o '[^/]*_[^/]*' | cut -d'_' -f2 | head -n 1) || true
      fi
      
      # If still no baseline SHA, look for it in the comparison output
      if [ -z "$baseline_git_sha" ] && grep -q "blocks:" "$file"; then
          # This is likely from a comparison, try to find the previous benchmark
          local all_dirs=($(ls -1dr "$benchmark_type_dir"/*/))
          for i in "${!all_dirs[@]}"; do
              if [[ "${all_dirs[$i]}" == *"$dir_name"* ]]; then
                  if [ $((i+1)) -lt ${#all_dirs[@]} ]; then
                      local prev_full_dir="${all_dirs[$((i+1))]}"
                      baseline_git_sha=$(basename "$prev_full_dir" | cut -d'_' -f2)
                      break
                  fi
              fi
          done
      fi

      # Extract baseline and contender times
      local baseline_time=$(grep -o "baseline: [0-9hms]*" "$file" 2>/dev/null | cut -d' ' -f2) || true
      local contender_time=$(grep -o "contender: [0-9hms]*" "$file" 2>/dev/null | cut -d' ' -f2) || true

      # Extract combined time delta and percentage
      local time_delta=$(grep "Time (total):" "$file" 2>/dev/null | sed 's/Time (total): \(.*\)/\1/') || true

      if [[ "$file" == *"short-benchmark"* ]]; then
          local benchmark_type="short"
      else
          local benchmark_type="long"
      fi

      # Remove any quotes if present
      local time_delta=$(echo "$time_delta" | tr -d '"')
      local baseline_time=$(echo "$baseline_time" | tr -d '"')
      local contender_time=$(echo "$contender_time" | tr -d '"')

      if [ ! -z "$baseline_git_sha" ] && [ ! -z "$contender_git_sha" ] && [ ! -z "$time_delta" ] && [ ! -z "$baseline_time" ] && [ ! -z "$contender_time" ]; then
          local entry="| $timestamp | $baseline_git_sha | $contender_git_sha | $baseline_time | $contender_time | $time_delta |"
          if [[ "$benchmark_type" == "short" ]]; then
              SHORT_BENCHMARK_TABLE="${SHORT_BENCHMARK_TABLE}
$entry"
          else
              LONG_BENCHMARK_TABLE="${LONG_BENCHMARK_TABLE}
$entry"
          fi
      else
          echo "Warning: Could not extract all required data from $file" >&2
          echo "  Directory: $dir_name" >&2
          echo "  Baseline SHA: '$baseline_git_sha'" >&2
          echo "  Contender SHA: '$contender_git_sha'" >&2
          echo "  Baseline Time: '$baseline_time'" >&2
          echo "  Contender Time: '$contender_time'" >&2
          echo "  Time Delta: '$time_delta'" >&2
      fi
  done < <(find "${NIMBUS_ETH1_BENCHMARKS_REPO}" -name "build-environment.log" | sort -t'/' -k3 -r)

  export LONG_BENCHMARK_TABLE
  export SHORT_BENCHMARK_TABLE

  envsubst < "${README_TEMPLATE_PATH}" > "${README_FILE_PATH}"

  echo "Benchmarking History updated in ${README_FILE_PATH}"
}

echo "Starting README regeneration..."
echo "Running from: ${NIMBUS_ETH1_BENCHMARKS_REPO}"
generateBenchmarkRepoReadme
echo "Done!"