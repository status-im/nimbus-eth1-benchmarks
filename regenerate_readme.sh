#!/usr/bin/env bash
set -e

# This script should be run from the nimbus-eth1-benchmarks repository root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NIMBUS_ETH1_BENCHMARKS_REPO="${SCRIPT_DIR}"
README_FILE_PATH="${NIMBUS_ETH1_BENCHMARKS_REPO}/README.md"
README_TEMPLATE_PATH="${NIMBUS_ETH1_BENCHMARKS_REPO}/README-TEMPLATE.md"
VENV_DIR="${NIMBUS_ETH1_BENCHMARKS_REPO}/.venv"
NIMBUS_ETH1_REPO_URL="https://github.com/status-im/nimbus-eth1/commit"
CSV_DIR="${NIMBUS_ETH1_BENCHMARKS_REPO}"
REGRESSIONS_CSV="${CSV_DIR}/regressions.csv"
IMPROVEMENTS_CSV="${CSV_DIR}/improvements.csv"
SHORT_HISTORY_CSV="${CSV_DIR}/short-benchmark-history.csv"
LONG_HISTORY_CSV="${CSV_DIR}/long-benchmark-history.csv"

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

# Convert CSV content to markdown table row with clickable SHA links
csv_to_md_row() {
  local csv_line="$1"
  # Parse CSV fields: timestamp,baseline_sha,contender_sha,baseline_time,contender_time,"time_delta"
  local timestamp=$(echo "$csv_line" | cut -d',' -f1)
  local baseline_sha=$(echo "$csv_line" | cut -d',' -f2)
  local contender_sha=$(echo "$csv_line" | cut -d',' -f3)
  local baseline_time=$(echo "$csv_line" | cut -d',' -f4)
  local contender_time=$(echo "$csv_line" | cut -d',' -f5)
  local time_delta=$(echo "$csv_line" | grep -o '"[^"]*"' | tr -d '"')
  local baseline_link=$(sha_to_link "$baseline_sha")
  local contender_link=$(sha_to_link "$contender_sha")

  echo "| $timestamp | $baseline_link | $contender_link | $baseline_time | $contender_time | $time_delta |"
}

setup_python_venv() {
  echo "Setting up Python virtual environment..."

  if [[ ! -d "$VENV_DIR" ]]; then
    echo "Creating virtual environment at $VENV_DIR"
    python3 -m venv "$VENV_DIR"
  fi

  source "$VENV_DIR/bin/activate"

  echo "Installing Python dependencies..."
  pip install --quiet --upgrade pip
  pip install --quiet -r "${NIMBUS_ETH1_BENCHMARKS_REPO}/requirements.txt"

  deactivate
}

generate_graphs() {
  echo "Generating graphs..."
  "${VENV_DIR}/bin/python" "${NIMBUS_ETH1_BENCHMARKS_REPO}/generate_graphs.py"
}

generateBenchmarkData() {
  local SHORT_ENTRIES=""
  local LONG_ENTRIES=""
  local REGRESSIONS=""
  local IMPROVEMENTS=""
  local LATEST_SHORT_ENTRIES=""
  local LATEST_LONG_ENTRIES=""
  local short_entry_count=0
  local long_entry_count=0

  # Loop variables
  local dir_path dir_name raw_timestamp timestamp contender_git_sha
  local benchmark_type_dir baseline_git_sha prev_dir found_current
  local baseline_time contender_time time_delta benchmark_type
  local entry percentage abs_percentage is_significant all_dirs d_name

  while read -r file; do
    dir_path=$(dirname "$file")
    dir_name=$(basename "$dir_path")
    raw_timestamp=$(echo "$dir_name" | grep -o '^[0-9]\{8\}T[0-9]\{6\}')
    timestamp=$(format_timestamp_date "$raw_timestamp")
    contender_git_sha=$(echo "$dir_name" | cut -d'_' -f2)

    benchmark_type_dir=$(dirname "$dir_path")
    baseline_git_sha=""
    prev_dir=""

    # Find previous directory by iterating through sorted directories
    found_current=false
    for d in "$benchmark_type_dir"/*/; do
      d_name=$(basename "$d")
      # Skip symlinks (like "latest")
      [[ -L "${d%/}" ]] && continue
      if [[ "$found_current" == "true" ]]; then
        prev_dir="$d_name"
        break
      fi
      if [[ "$d_name" == "$dir_name" ]]; then
        found_current=true
      fi
    done

    if [[ -n "$prev_dir" ]]; then
      baseline_git_sha=$(echo "$prev_dir" | cut -d'_' -f2)
    fi

    # If we can't find baseline SHA from directory structure, try extracting from file content
    if [[ -z "$baseline_git_sha" ]]; then
      baseline_git_sha=$(grep "block-import-stats.py" "$file" 2>/dev/null | grep -o '[^/]*_[^/]*' | cut -d'_' -f2 | head -n 1) || true
    fi

    # If still no baseline SHA, look for it in the comparison output
    if [[ -z "$baseline_git_sha" ]] && grep -q "blocks:" "$file"; then
      mapfile -t all_dirs < <(find "$benchmark_type_dir" -maxdepth 1 -mindepth 1 -type d | sort -r)
      for i in "${!all_dirs[@]}"; do
        if [[ "${all_dirs[$i]}" == *"$dir_name"* ]]; then
          if [[ $((i + 1)) -lt ${#all_dirs[@]} ]]; then
            baseline_git_sha=$(basename "${all_dirs[$((i + 1))]}" | cut -d'_' -f2)
            break
          fi
        fi
      done
    fi

    baseline_time=$(grep -o "baseline: [0-9hms]*" "$file" 2>/dev/null | cut -d' ' -f2) || true
    contender_time=$(grep -o "contender: [0-9hms]*" "$file" 2>/dev/null | cut -d' ' -f2) || true
    time_delta=$(grep "Time (total):" "$file" 2>/dev/null | sed 's/Time (total): \(.*\)/\1/') || true

    if [[ "$file" == *"short-benchmark"* ]]; then
      benchmark_type="short"
    else
      benchmark_type="long"
    fi

    # Remove any quotes if present
    time_delta=$(echo "$time_delta" | tr -d '"')
    baseline_time=$(echo "$baseline_time" | tr -d '"')
    contender_time=$(echo "$contender_time" | tr -d '"')

    if [[ -n "$baseline_git_sha" && -n "$contender_git_sha" && -n "$time_delta" && -n "$baseline_time" && -n "$contender_time" ]]; then
      # CSV entry (quote fields that might contain commas)
      entry="$timestamp,$baseline_git_sha,$contender_git_sha,$baseline_time,$contender_time,\"$time_delta\""

      if [[ "$benchmark_type" == "short" ]]; then
        SHORT_ENTRIES+="${entry}"$'\n'

        if [[ $short_entry_count -lt 5 ]]; then
          LATEST_SHORT_ENTRIES+="${entry}"$'\n'
          ((short_entry_count++)) || true
        fi

        percentage=$(echo "$time_delta" | grep -oE '[-]?[0-9]+\.[0-9]+%' | tr -d '%')
        if [[ -n "$percentage" ]]; then
          abs_percentage=$(awk -v pct="$percentage" 'BEGIN { print (pct < 0) ? -pct : pct }')
          is_significant=$(awk -v pct="$abs_percentage" 'BEGIN { print (pct > 1) ? "yes" : "no" }')
          if [[ "$is_significant" == "yes" ]]; then
            if awk -v pct="$percentage" 'BEGIN { exit (pct > 0) ? 0 : 1 }'; then
              REGRESSIONS+="${percentage}|${entry}"$'\n'
            else
              IMPROVEMENTS+="${percentage}|${entry}"$'\n'
            fi
          fi
        fi
      else
        LONG_ENTRIES+="${entry}"$'\n'

        if [[ $long_entry_count -lt 5 ]]; then
          LATEST_LONG_ENTRIES+="${entry}"$'\n'
          ((long_entry_count++)) || true
        fi
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

  echo "$CSV_HEADER" > "$REGRESSIONS_CSV"
  echo -n "$REGRESSIONS" | sort -t'|' -k1 -rn | cut -d'|' -f2- >> "$REGRESSIONS_CSV"
  echo "Generated: $REGRESSIONS_CSV"

  echo "$CSV_HEADER" > "$IMPROVEMENTS_CSV"
  echo -n "$IMPROVEMENTS" | sort -t'|' -k1 -n | cut -d'|' -f2- >> "$IMPROVEMENTS_CSV"
  echo "Generated: $IMPROVEMENTS_CSV"

  echo "$CSV_HEADER" > "$SHORT_HISTORY_CSV"
  echo -n "$SHORT_ENTRIES" >> "$SHORT_HISTORY_CSV"
  echo "Generated: $SHORT_HISTORY_CSV"

  echo "$CSV_HEADER" > "$LONG_HISTORY_CSV"
  echo -n "$LONG_ENTRIES" >> "$LONG_HISTORY_CSV"
  echo "Generated: $LONG_HISTORY_CSV"

  local LATEST_SHORT_TABLE="$MD_TABLE_HEADER"
  while IFS= read -r line; do
    [[ -n "$line" ]] && LATEST_SHORT_TABLE+=$'\n'"$(csv_to_md_row "$line")"
  done < <(echo -n "$LATEST_SHORT_ENTRIES")

  local LATEST_LONG_TABLE="$MD_TABLE_HEADER"
  while IFS= read -r line; do
    [[ -n "$line" ]] && LATEST_LONG_TABLE+=$'\n'"$(csv_to_md_row "$line")"
  done < <(echo -n "$LATEST_LONG_ENTRIES")

  local REGRESSIONS_TABLE="$MD_TABLE_HEADER"
  while IFS= read -r line; do
    [[ -n "$line" ]] && REGRESSIONS_TABLE+=$'\n'"$(csv_to_md_row "$line")"
  done < <(echo -n "$REGRESSIONS" | sort -t'|' -k1 -rn | cut -d'|' -f2-)

  local IMPROVEMENTS_TABLE="$MD_TABLE_HEADER"
  while IFS= read -r line; do
    [[ -n "$line" ]] && IMPROVEMENTS_TABLE+=$'\n'"$(csv_to_md_row "$line")"
  done < <(echo -n "$IMPROVEMENTS" | sort -t'|' -k1 -n | cut -d'|' -f2-)

  # Export for envsubst and generate README
  export LATEST_SHORT_TABLE LATEST_LONG_TABLE REGRESSIONS_TABLE IMPROVEMENTS_TABLE
  envsubst < "${README_TEMPLATE_PATH}" > "${README_FILE_PATH}"
  echo "Generated: ${README_FILE_PATH}"
}

echo "Starting README regeneration..."
echo "Running from: ${NIMBUS_ETH1_BENCHMARKS_REPO}"

generateBenchmarkData
setup_python_venv
generate_graphs

echo "Done!"
