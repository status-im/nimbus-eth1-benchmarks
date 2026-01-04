#!/usr/bin/env python3
"""Generate simple benchmark trend graph from CSV data."""

import re
import sys
from pathlib import Path
from typing import Optional

import matplotlib.pyplot as plt
import pandas as pd
from scipy.ndimage import uniform_filter1d


def parse_duration_to_hours(duration_str: str) -> Optional[float]:
    """Convert duration string like '8h6m44s' to hours as float."""
    if not duration_str or pd.isna(duration_str):
        return None

    hours = 0
    minutes = 0
    seconds = 0

    h_match = re.search(r'(\d+)h', duration_str)
    if h_match:
        hours = int(h_match.group(1))

    m_match = re.search(r'(\d+)m', duration_str)
    if m_match:
        minutes = int(m_match.group(1))

    s_match = re.search(r'(\d+)s', duration_str)
    if s_match:
        seconds = int(s_match.group(1))

    return hours + minutes / 60 + seconds / 3600


def load_data(csv_path: Path) -> pd.DataFrame:
    """Load CSV and prepare data for plotting."""
    df = pd.read_csv(csv_path)
    df['Date'] = pd.to_datetime(df['Generated At'])
    df['Hours'] = df['Contender Time'].apply(parse_duration_to_hours)
    df = df.sort_values('Date').reset_index(drop=True)
    return df.dropna(subset=['Hours'])


def generate_trend_graph(
    short_df: pd.DataFrame,
    long_df: pd.DataFrame,
    output_path: Path
) -> None:
    """Generate simple performance trend graph."""
    _, (ax1, ax2) = plt.subplots(2, 1, figsize=(12, 6))

    # Short benchmarks
    if len(short_df) >= 7:
        smoothed = uniform_filter1d(short_df['Hours'].values, size=7)
        ax1.plot(short_df['Date'], smoothed, 'b-', linewidth=2)

    ax1.set_ylabel('Hours')
    ax1.set_title('Short Benchmark (24h run) - lower is better')
    ax1.grid(True, alpha=0.3)

    # Long benchmarks
    if len(long_df) >= 3:
        smoothed = uniform_filter1d(long_df['Hours'].values, size=3)
        ax2.plot(long_df['Date'], smoothed, 'g-', linewidth=2)

    ax2.set_ylabel('Hours')
    ax2.set_xlabel('Date')
    ax2.set_title('Long Benchmark (1 week run) - lower is better')
    ax2.grid(True, alpha=0.3)

    plt.tight_layout()
    plt.savefig(output_path, dpi=150, bbox_inches='tight')
    plt.close()
    print(f"Generated: {output_path}")


def main() -> int:
    """Main entry point."""
    script_dir = Path(__file__).parent
    assets_dir = script_dir / 'assets'
    assets_dir.mkdir(exist_ok=True)

    short_csv = script_dir / 'short-benchmark-history.csv'
    long_csv = script_dir / 'long-benchmark-history.csv'

    if not short_csv.exists() or not long_csv.exists():
        print("Error: CSV files not found. Run regenerate_readme.sh first.")
        return 1

    short_df = load_data(short_csv)
    long_df = load_data(long_csv)

    print(f"Loaded {len(short_df)} short benchmark entries")
    print(f"Loaded {len(long_df)} long benchmark entries")

    generate_trend_graph(short_df, long_df, assets_dir / 'benchmark-trend.png')

    print("Done!")
    return 0


if __name__ == '__main__':
    sys.exit(main())
