#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NIMBUS_ETH1_BENCHMARKS_REPO="${SCRIPT_DIR}"
README_FILE_PATH="${NIMBUS_ETH1_BENCHMARKS_REPO}/README.md"
README_TEMPLATE_PATH="${NIMBUS_ETH1_BENCHMARKS_REPO}/README-TEMPLATE.md"
VENV_DIR="${NIMBUS_ETH1_BENCHMARKS_REPO}/.venv"
NIMBUS_ETH1_REPO_URL="https://github.com/status-im/nimbus-eth1/commit"

SHORT_HISTORY_CSV="${NIMBUS_ETH1_BENCHMARKS_REPO}/short-benchmark-history.csv"
LONG_HISTORY_CSV="${NIMBUS_ETH1_BENCHMARKS_REPO}/long-benchmark-history.csv"
REGRESSIONS_CSV="${NIMBUS_ETH1_BENCHMARKS_REPO}/regressions.csv"
IMPROVEMENTS_CSV="${NIMBUS_ETH1_BENCHMARKS_REPO}/improvements.csv"

SYNC_MODE=false
if [[ "${1:-}" == "--sync" ]]; then
  SYNC_MODE=true
  echo "Sync mode: will purge stale entries"
fi

CSV_HEADER="Generated At,Baseline SHA,Contender SHA,Baseline Time,Contender Time,Time Delta"
MD_TABLE_HEADER="| Generated At | Baseline SHA | Contender SHA | Baseline Time | Contender Time | Time Delta |
|--------------|--------------|---------------|---------------|----------------|------------|"

format_timestamp_date() {
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

sha_to_link() {
  local sha="$1"
  echo "[${sha}](${NIMBUS_ETH1_REPO_URL}/${sha})"
}

csv_to_md_row() {
  local csv_line="$1"
  local timestamp baseline_sha contender_sha baseline_time contender_time time_delta
  local baseline_link contender_link

  timestamp=$(echo "$csv_line" | cut -d',' -f1)
  baseline_sha=$(echo "$csv_line" | cut -d',' -f2)
  contender_sha=$(echo "$csv_line" | cut -d',' -f3)
  baseline_time=$(echo "$csv_line" | cut -d',' -f4)
  contender_time=$(echo "$csv_line" | cut -d',' -f5)
  time_delta=$(echo "$csv_line" | grep -o '"[^"]*"' | tr -d '"')
  baseline_link=$(sha_to_link "$baseline_sha")
  contender_link=$(sha_to_link "$contender_sha")

  echo "| $timestamp | $baseline_link | $contender_link | $baseline_time | $contender_time | $time_delta |"
}

get_processed_dirs() {
  local csv_file="$1"
  local ts_compact
  if [[ -f "$csv_file" ]]; then
    # Extract timestamp and contender SHA, reconstruct dir name pattern
    tail -n +2 "$csv_file" | while IFS=',' read -r timestamp _baseline contender _rest; do
      # Convert "2026-01-03 20:18:17" back to "20260103T201817"
      ts_compact=$(echo "$timestamp" | sed 's/-//g; s/ /T/; s/://g')
      echo "${ts_compact}_${contender}"
    done
  fi
}

# Purge CSV entries for benchmarks that no longer exist on disk
purge_stale_entries() {
  local benchmark_type="$1"  # "short" or "long"
  local csv_file="$2"
  local benchmark_dir="${NIMBUS_ETH1_BENCHMARKS_REPO}/${benchmark_type}-benchmark"
  local tmp_file timestamp contender ts_compact dir_name dir_path
  local purged_count=0

  [[ -f "$csv_file" ]] || return 0

  tmp_file=$(mktemp)

  # Keep header
  head -1 "$csv_file" > "$tmp_file"

  # Check each entry
  while IFS= read -r line; do
    # Extract timestamp and contender SHA to reconstruct dir name
    timestamp=$(echo "$line" | cut -d',' -f1)
    contender=$(echo "$line" | cut -d',' -f3)
    ts_compact=$(echo "$timestamp" | sed 's/-//g; s/ /T/; s/://g')
    dir_name="${ts_compact}_${contender}"
    dir_path="${benchmark_dir}/${dir_name}"

    if [[ -d "$dir_path" ]]; then
      echo "$line" >> "$tmp_file"
    else
      echo "  Purged: $dir_name (directory not found)"
      ((purged_count++)) || true
    fi
  done < <(tail -n +2 "$csv_file")

  mv "$tmp_file" "$csv_file"
  echo "Purged $purged_count stale ${benchmark_type} benchmark(s)"
}

# Process a single benchmark log file
process_benchmark_file() {
  local file="$1"
  local dir_path dir_name raw_timestamp timestamp contender_git_sha
  local benchmark_type_dir baseline_git_sha prev_dir d_name
  local baseline_time contender_time time_delta
  local found_current=false

  dir_path=$(dirname "$file")
  dir_name=$(basename "$dir_path")
  raw_timestamp=$(echo "$dir_name" | grep -o '^[0-9]\{8\}T[0-9]\{6\}')
  timestamp=$(format_timestamp_date "$raw_timestamp")
  contender_git_sha=$(echo "$dir_name" | cut -d'_' -f2)
  benchmark_type_dir=$(dirname "$dir_path")
  baseline_git_sha=""
  prev_dir=""

  # Find previous directory
  for d in "$benchmark_type_dir"/*/; do
    d_name=$(basename "$d")
    [[ -L "${d%/}" ]] && continue
    if [[ "$found_current" == "true" ]]; then
      prev_dir="$d_name"
      break
    fi
    [[ "$d_name" == "$dir_name" ]] && found_current=true
  done

  [[ -n "$prev_dir" ]] && baseline_git_sha=$(echo "$prev_dir" | cut -d'_' -f2)

  # Fallback: extract from file content
  if [[ -z "$baseline_git_sha" ]]; then
    baseline_git_sha=$(grep "block-import-stats.py" "$file" 2>/dev/null | grep -o '[^/]*_[^/]*' | cut -d'_' -f2 | head -n 1) || true
  fi

  baseline_time=$(grep -o "baseline: [0-9hms]*" "$file" 2>/dev/null | cut -d' ' -f2) || true
  contender_time=$(grep -o "contender: [0-9hms]*" "$file" 2>/dev/null | cut -d' ' -f2) || true
  time_delta=$(grep "Time (total):" "$file" 2>/dev/null | sed 's/Time (total): \(.*\)/\1/' | tr -d '"') || true
  baseline_time=$(echo "$baseline_time" | tr -d '"')
  contender_time=$(echo "$contender_time" | tr -d '"')

  if [[ -n "$baseline_git_sha" && -n "$contender_git_sha" && -n "$time_delta" && -n "$baseline_time" && -n "$contender_time" ]]; then
    echo "$timestamp,$baseline_git_sha,$contender_git_sha,$baseline_time,$contender_time,\"$time_delta\""
  else
    echo "Warning: Could not extract data from $file" >&2
    return 1
  fi
}

# Process only new benchmarks and append to CSV
process_new_benchmarks() {
  local benchmark_type="$1"  # "short" or "long"
  local csv_file="$2"
  local benchmark_dir="${NIMBUS_ETH1_BENCHMARKS_REPO}/${benchmark_type}-benchmark"
  local dir_name entry
  local new_count=0
  local new_entries=""

  # Initialize CSV if it doesn't exist
  if [[ ! -f "$csv_file" ]]; then
    echo "$CSV_HEADER" > "$csv_file"
  fi

  # Get already processed directories
  local -A processed_dirs
  while IFS= read -r dir; do
    [[ -n "$dir" ]] && processed_dirs["$dir"]=1
  done < <(get_processed_dirs "$csv_file")

  for log_file in "$benchmark_dir"/*/build-environment.log; do
    [[ -f "$log_file" ]] || continue
    dir_name=$(basename "$(dirname "$log_file")")

    # Skip symlinks
    [[ -L "$(dirname "$log_file")" ]] && continue

    # Skip if already processed
    if [[ -n "${processed_dirs[$dir_name]:-}" ]]; then
      continue
    fi

    if entry=$(process_benchmark_file "$log_file"); then
      new_entries+="${entry}"$'\n'
      ((new_count++)) || true
      echo "  New: $dir_name"
    fi
  done

  if [[ -n "$new_entries" ]]; then
    echo -n "$new_entries" >> "$csv_file"
  fi

  echo "Processed $new_count new ${benchmark_type} benchmark(s)"
}

regenerate_derived_files() {
  local tmp_file time_delta percentage abs_pct is_sig

  # Sort CSVs by date (newest first) - need to re-sort after appending
  for csv_file in "$SHORT_HISTORY_CSV" "$LONG_HISTORY_CSV"; do
    if [[ -f "$csv_file" ]]; then
      tmp_file=$(mktemp)
      head -1 "$csv_file" > "$tmp_file"
      tail -n +2 "$csv_file" | sort -t',' -k1 -r >> "$tmp_file"
      mv "$tmp_file" "$csv_file"
    fi
  done

  echo "$CSV_HEADER" > "$REGRESSIONS_CSV"
  echo "$CSV_HEADER" > "$IMPROVEMENTS_CSV"

  if [[ -f "$SHORT_HISTORY_CSV" ]]; then
    tail -n +2 "$SHORT_HISTORY_CSV" | while IFS= read -r line; do
      time_delta=$(echo "$line" | grep -o '"[^"]*"' | tr -d '"')
      percentage=$(echo "$time_delta" | grep -oE '[-]?[0-9]+\.[0-9]+%' | tr -d '%')

      if [[ -n "$percentage" ]]; then
        abs_pct=$(awk -v p="$percentage" 'BEGIN { print (p<0) ? -p : p }')
        is_sig=$(awk -v p="$abs_pct" 'BEGIN { print (p>1) ? 1 : 0 }')

        if [[ "$is_sig" == "1" ]]; then
          if awk -v p="$percentage" 'BEGIN { exit (p>0) ? 0 : 1 }'; then
            echo "${percentage}|${line}" >> "${REGRESSIONS_CSV}.tmp"
          else
            echo "${percentage}|${line}" >> "${IMPROVEMENTS_CSV}.tmp"
          fi
        fi
      fi
    done
  fi

  # Sort and finalize regressions/improvements
  if [[ -f "${REGRESSIONS_CSV}.tmp" ]]; then
    sort -t'|' -k1 -rn "${REGRESSIONS_CSV}.tmp" | cut -d'|' -f2- >> "$REGRESSIONS_CSV"
    rm "${REGRESSIONS_CSV}.tmp"
  fi
  if [[ -f "${IMPROVEMENTS_CSV}.tmp" ]]; then
    sort -t'|' -k1 -n "${IMPROVEMENTS_CSV}.tmp" | cut -d'|' -f2- >> "$IMPROVEMENTS_CSV"
    rm "${IMPROVEMENTS_CSV}.tmp"
  fi

  # Build markdown tables for README
  local LATEST_SHORT_TABLE="$MD_TABLE_HEADER"
  if [[ -f "$SHORT_HISTORY_CSV" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && LATEST_SHORT_TABLE+=$'\n'"$(csv_to_md_row "$line")"
    done < <(tail -n +2 "$SHORT_HISTORY_CSV" | head -5)
  fi

  local LATEST_LONG_TABLE="$MD_TABLE_HEADER"
  if [[ -f "$LONG_HISTORY_CSV" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && LATEST_LONG_TABLE+=$'\n'"$(csv_to_md_row "$line")"
    done < <(tail -n +2 "$LONG_HISTORY_CSV" | head -5)
  fi

  local REGRESSIONS_TABLE="$MD_TABLE_HEADER"
  if [[ -f "$REGRESSIONS_CSV" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && REGRESSIONS_TABLE+=$'\n'"$(csv_to_md_row "$line")"
    done < <(tail -n +2 "$REGRESSIONS_CSV")
  fi

  local IMPROVEMENTS_TABLE="$MD_TABLE_HEADER"
  if [[ -f "$IMPROVEMENTS_CSV" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && IMPROVEMENTS_TABLE+=$'\n'"$(csv_to_md_row "$line")"
    done < <(tail -n +2 "$IMPROVEMENTS_CSV")
  fi

  export LATEST_SHORT_TABLE LATEST_LONG_TABLE REGRESSIONS_TABLE IMPROVEMENTS_TABLE
  envsubst < "${README_TEMPLATE_PATH}" > "${README_FILE_PATH}"
  echo "Generated: ${README_FILE_PATH}"
}

setup_python_venv() {
  if [[ ! -d "$VENV_DIR" ]]; then
    echo "Creating virtual environment..."
    python3 -m venv "$VENV_DIR"
    # shellcheck source=/dev/null
    source "$VENV_DIR/bin/activate"
    pip install --quiet --upgrade pip
    pip install --quiet -r "${NIMBUS_ETH1_BENCHMARKS_REPO}/requirements.txt"
    deactivate
  fi
}

generate_graphs() {
  echo "Generating graph..."
  "${VENV_DIR}/bin/python" "${NIMBUS_ETH1_BENCHMARKS_REPO}/generate_graphs.py"
}

echo "Starting README regeneration..."

if [[ "$SYNC_MODE" == "true" ]]; then
  purge_stale_entries "short" "$SHORT_HISTORY_CSV"
  purge_stale_entries "long" "$LONG_HISTORY_CSV"
fi

process_new_benchmarks "short" "$SHORT_HISTORY_CSV"
process_new_benchmarks "long" "$LONG_HISTORY_CSV"

regenerate_derived_files
setup_python_venv
generate_graphs

echo "Done!"
