#!/usr/bin/env python3
"""Fetch US-stock perp weekend gaps and funding from Hyperliquid's public info API.

Read-only, no account, no key. The endpoint below is a public HTTPS REST info
endpoint (NOT a chain RPC endpoint); no credentials or secrets are used or stored.

Outputs:
  data/perp_universe.csv        discovered candidate markets and the selected ones
  data/<ASSET>_candles_hourly.csv   raw hourly candle rows (all 8 weekends)
  data/<ASSET>_funding_hourly.csv   raw hourly funding rows (all 8 weekends)
  data/weekend_summary.csv      derived per-weekend metrics
  data/metrics.json             headline numbers used in README.md
  charts/*.png                  visualisations (requires matplotlib)
"""

from __future__ import annotations

import argparse
import csv
import json
import statistics
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

# Public, read-only REST info endpoint. Not an RPC URL, not a secret.
INFO_ENDPOINT = "https://api.hyperliquid.xyz/info"
SYMBOLS = ("NVDA", "TSLA", "AAPL")
NY = ZoneInfo("America/New_York")
MS_PER_HOUR = 3_600_000


# --------------------------------------------------------------------------- #
# HTTP helpers
# --------------------------------------------------------------------------- #
def post_info(payload: dict, retries: int = 4, pause: float = 0.25) -> object:
    """POST one request body to the public info endpoint with light retries."""
    body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    request = urllib.request.Request(
        INFO_ENDPOINT,
        data=body,
        headers={"Content-Type": "application/json", "User-Agent": "weekend-gap-risk/1.0"},
        method="POST",
    )
    last_error: Exception | None = None
    for attempt in range(retries):
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.loads(response.read().decode("utf-8"))
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
            last_error = exc
            if attempt + 1 < retries:
                time.sleep(pause * (attempt + 1))
    raise RuntimeError(f"info request failed after {retries} attempts: {last_error}")


def ms(dt: datetime) -> int:
    return int(dt.timestamp() * 1000)


def utc_iso(millis: int) -> str:
    return datetime.fromtimestamp(millis / 1000, tz=timezone.utc).isoformat()


# --------------------------------------------------------------------------- #
# Discovery
# --------------------------------------------------------------------------- #
@dataclass(frozen=True)
class Market:
    symbol: str
    coin: str
    dex: str
    oi_cap: float


def discover_markets(symbols: tuple[str, ...]) -> tuple[list[dict], dict[str, Market]]:
    """Find perps matching the symbols across all perps dexs, pick largest OI cap."""
    dexes = post_info({"type": "perpDexs"})
    rows: list[dict] = []
    best: dict[str, Market] = {}
    for dex in dexes:
        if not isinstance(dex, dict):
            continue  # the null entry is the main (non-HIP-3) perp dex
        name = dex.get("name", "")
        caps = dict(dex.get("assetToStreamingOiCap", []))
        for symbol in symbols:
            coin = f"{name}:{symbol}" if name else symbol
            if coin not in caps:
                continue
            try:
                cap = float(caps[coin])
            except (TypeError, ValueError):
                cap = 0.0
            rows.append(
                {
                    "symbol": symbol,
                    "coin": coin,
                    "dex": name,
                    "oi_cap_usd": cap,
                    "selected": "",
                }
            )
            candidate = Market(symbol, coin, name, cap)
            if symbol not in best or cap > best[symbol].oi_cap:
                best[symbol] = candidate
    missing = [s for s in symbols if s not in best]
    if missing:
        raise RuntimeError(f"no perp market found for: {', '.join(missing)}")
    for row in rows:
        row["selected"] = "yes" if best[row["symbol"]].coin == row["coin"] else "no"
    return rows, best


# --------------------------------------------------------------------------- #
# Weekend windows
# --------------------------------------------------------------------------- #
@dataclass(frozen=True)
class Weekend:
    label: str
    friday_close_ms: int   # 16:00 America/New_York (cash close)
    friday_anchor_ms: int  # hourly candle starting 15:00 ET (last full session hour)
    monday_open_ms: int    # 09:00 America/New_York (hour containing 09:30 cash open)
    monday_anchor_ms: int  # hourly candle starting 09:00 ET
    fetch_start_ms: int
    fetch_end_ms: int


def last_weekends(n: int, today: datetime, now_ms: int | None = None) -> list[Weekend]:
    """Return the last n *completed* weekends (full Monday open candle), oldest first."""
    today = today.astimezone(NY)
    days_since_saturday = (today.weekday() - 5) % 7
    saturday = (today - timedelta(days=days_since_saturday)).date()
    out: list[Weekend] = []
    i = 0
    while len(out) < n:
        sat = saturday - timedelta(weeks=i)
        fri = sat - timedelta(days=1)
        mon = sat + timedelta(days=2)
        friday_close = datetime(fri.year, fri.month, fri.day, 16, 0, tzinfo=NY)
        monday_open = datetime(mon.year, mon.month, mon.day, 9, 0, tzinfo=NY)
        candidate = Weekend(
            label=sat.isoformat(),
            friday_close_ms=ms(friday_close),
            friday_anchor_ms=ms(friday_close - timedelta(hours=1)),
            monday_open_ms=ms(monday_open),
            monday_anchor_ms=ms(monday_open),
            fetch_start_ms=ms(datetime(fri.year, fri.month, fri.day, 12, 0, tzinfo=NY)),
            fetch_end_ms=ms(datetime(mon.year, mon.month, mon.day, 11, 0, tzinfo=NY)),
        )
        # The 09:00 ET candle must have finished before a weekend counts as complete.
        if now_ms is None or candidate.monday_anchor_ms + MS_PER_HOUR <= now_ms:
            out.append(candidate)
        i += 1
        if i > 52:
            raise RuntimeError("could not find n completed weekends")
    return list(reversed(out))


def fetch_candles(coin: str, start: int, end: int) -> list[dict]:
    result = post_info(
        {
            "type": "candleSnapshot",
            "req": {"coin": coin, "interval": "1h", "startTime": start, "endTime": end},
        }
    )
    if not isinstance(result, list):
        raise RuntimeError(f"unexpected candleSnapshot response for {coin}: {result!r}")
    return result


def fetch_funding(coin: str, start: int, end: int) -> list[dict]:
    """Page fundingHistory if it hits the documented 500-element response limit."""
    out: list[dict] = []
    cursor = start
    for _ in range(20):
        batch = post_info({"type": "fundingHistory", "coin": coin, "startTime": cursor})
        if not isinstance(batch, list):
            raise RuntimeError(f"unexpected fundingHistory response for {coin}: {batch!r}")
        batch = [row for row in batch if row.get("time", 0) <= end]
        out.extend(batch)
        if len(batch) < 500 or not batch:
            break
        cursor = max(row["time"] for row in batch) + 1
    return out


# --------------------------------------------------------------------------- #
# Metrics
# --------------------------------------------------------------------------- #
def pct(new: float, old: float) -> float:
    if old == 0:
        return float("nan")
    return (new - old) / old * 100.0


def analyse_weekend(candles: list[dict], funding: list[dict], w: Weekend) -> dict | None:
    by_t = {c["t"]: c for c in candles}
    fri = by_t.get(w.friday_anchor_ms)
    mon = by_t.get(w.monday_anchor_ms)
    if fri is None or mon is None:
        return None
    friday_close = float(fri["c"])
    monday_open = float(mon["o"])
    window = sorted(
        (c for c in candles if w.friday_anchor_ms <= c["t"] < w.monday_anchor_ms),
        key=lambda c: c["t"],
    )
    if len(window) < 2:
        return None
    highs = [float(c["h"]) for c in window]
    lows = [float(c["l"]) for c in window]
    peak, trough = max(highs), min(lows)
    closes = [float(c["c"]) for c in window]
    largest_1h = max(abs(pct(closes[i], closes[i - 1])) for i in range(1, len(closes)))
    rates = [float(r["fundingRate"]) for r in funding if w.friday_close_ms <= r["time"] <= w.monday_open_ms]
    return {
        "weekend": w.label,
        "friday_close_utc": utc_iso(fri["t"]),
        "friday_close_px": friday_close,
        "monday_open_utc": utc_iso(mon["t"]),
        "monday_open_px": monday_open,
        "gap_abs": monday_open - friday_close,
        "gap_pct": pct(monday_open, friday_close),
        "weekend_peak": peak,
        "weekend_trough": trough,
        "peak_trough_pct": pct(peak, trough),
        "largest_1h_close_move_pct": largest_1h,
        "hours_observed": len(window),
        "funding_prints": len(rates),
        "funding_mean_hourly": statistics.fmean(rates) if rates else 0.0,
        "funding_sum": sum(rates),
        "funding_min_hourly": min(rates) if rates else 0.0,
        "funding_max_hourly": max(rates) if rates else 0.0,
    }


# --------------------------------------------------------------------------- #
# Output
# --------------------------------------------------------------------------- #
def write_csv(path: Path, fieldnames: list[str], rows: list[dict]) -> None:
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def make_charts(summary: list[dict], chart_dir: Path) -> None:
    try:
        import matplotlib

        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("matplotlib not installed; skipping charts", file=sys.stderr)
        return
    chart_dir.mkdir(parents=True, exist_ok=True)
    colors = {"NVDA": "#76b900", "TSLA": "#e82127", "AAPL": "#555555"}
    labels = sorted({r["weekend"] for r in summary})

    fig, axes = plt.subplots(2, 1, figsize=(11, 8), sharex=True)
    for ax, metric, title in zip(
        axes,
        ("gap_pct", "peak_trough_pct"),
        ("Friday close -> Monday open gap (%)", "Weekend peak-to-trough range (%)"),
    ):
        width = 0.26
        for i, symbol in enumerate(SYMBOLS):
            values = [
                next((r[metric] for r in summary if r["asset"] == symbol and r["weekend"] == label), 0)
                for label in labels
            ]
            positions = [j + (i - 1) * width for j in range(len(labels))]
            ax.bar(positions, values, width=width, label=symbol, color=colors[symbol])
        ax.axhline(0, color="black", linewidth=0.8)
        ax.set_title(title)
        ax.set_ylabel("%")
        ax.grid(axis="y", alpha=0.3)
    axes[-1].set_xticks(range(len(labels)))
    axes[-1].set_xticklabels(labels, rotation=45, ha="right")
    axes[0].legend(ncol=3, loc="upper left")
    fig.suptitle("US-stock perps: eight recent weekends (Hyperliquid hourly candles)")
    fig.tight_layout()
    fig.savefig(chart_dir / "gap_and_weekend_range.png", dpi=150)
    plt.close(fig)

    fig, ax = plt.subplots(figsize=(11, 4.5))
    width = 0.26
    for i, symbol in enumerate(SYMBOLS):
        values = [
            next((r["funding_sum"] * 100 for r in summary if r["asset"] == symbol and r["weekend"] == label), 0)
            for label in labels
        ]
        positions = [j + (i - 1) * width for j in range(len(labels))]
        ax.bar(positions, values, width=width, label=symbol, color=colors[symbol])
    ax.axhline(0, color="black", linewidth=0.8)
    ax.set_title("Cumulative hourly funding over the weekend (sum of rates, in %)")
    ax.set_ylabel("%")
    ax.set_xticks(range(len(labels)))
    ax.set_xticklabels(labels, rotation=45, ha="right")
    ax.grid(axis="y", alpha=0.3)
    ax.legend(ncol=3)
    fig.tight_layout()
    fig.savefig(chart_dir / "weekend_funding.png", dpi=150)
    plt.close(fig)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--weekends", type=int, default=8)
    parser.add_argument("--data-dir", type=Path, default=Path("data"))
    parser.add_argument("--chart-dir", type=Path, default=Path("charts"))
    parser.add_argument("--today", type=str, default="", help="UTC date YYYY-MM-DD (default: now)")
    args = parser.parse_args()

    today = (
        datetime.strptime(args.today, "%Y-%m-%d").replace(tzinfo=timezone.utc)
        if args.today
        else datetime.now(tz=timezone.utc)
    )
    args.data_dir.mkdir(parents=True, exist_ok=True)
    args.chart_dir.mkdir(parents=True, exist_ok=True)
    now_ms = ms(datetime.now(tz=timezone.utc))
    weekends = last_weekends(args.weekends, today, now_ms=now_ms)

    universe, selected = discover_markets(SYMBOLS)
    write_csv(
        args.data_dir / "perp_universe.csv",
        ["symbol", "coin", "dex", "oi_cap_usd", "selected"],
        universe,
    )
    print("Selected markets:")
    for symbol in SYMBOLS:
        m = selected[symbol]
        print(f"  {symbol:<5} -> {m.coin:<12} (dex={m.dex}, OI cap=${m.oi_cap:,.0f})")

    candle_rows: dict[str, list[dict]] = {s: [] for s in SYMBOLS}
    funding_rows: dict[str, list[dict]] = {s: [] for s in SYMBOLS}
    summary: list[dict] = []

    for symbol in SYMBOLS:
        coin = selected[symbol].coin
        for w in weekends:
            candles = fetch_candles(coin, w.fetch_start_ms, w.fetch_end_ms)
            funding = fetch_funding(coin, w.friday_close_ms, w.monday_open_ms)
            for c in candles:
                c["weekend"] = w.label
            for r in funding:
                r["weekend"] = w.label
            candle_rows[symbol].extend(candles)
            funding_rows[symbol].extend(funding)
            row = analyse_weekend(candles, funding, w)
            if row is None:
                print(f"  WARNING: incomplete candle data for {symbol} {w.label}", file=sys.stderr)
                continue
            row["asset"] = symbol
            summary.append(row)
            print(
                f"  {symbol} {w.label}: {row['friday_close_px']:.2f} -> "
                f"{row['monday_open_px']:.2f} ({row['gap_pct']:+.2f}%), "
                f"range {row['peak_trough_pct']:.2f}%, funding sum {row['funding_sum']*100:+.4f}%"
            )
            time.sleep(0.2)

    candle_fields = ["weekend", "s", "t", "T", "i", "o", "h", "l", "c", "v", "n"]
    funding_fields = ["weekend", "coin", "time", "fundingRate", "premium"]
    for symbol in SYMBOLS:
        write_csv(args.data_dir / f"{symbol}_candles_hourly.csv", candle_fields, candle_rows[symbol])
        write_csv(args.data_dir / f"{symbol}_funding_hourly.csv", funding_fields, funding_rows[symbol])

    summary_fields = [
        "asset", "weekend", "friday_close_utc", "friday_close_px", "monday_open_utc",
        "monday_open_px", "gap_abs", "gap_pct", "weekend_peak", "weekend_trough",
        "peak_trough_pct", "largest_1h_close_move_pct", "hours_observed", "funding_prints",
        "funding_mean_hourly", "funding_sum", "funding_min_hourly", "funding_max_hourly",
    ]
    write_csv(args.data_dir / "weekend_summary.csv", summary_fields, summary)

    abs_gaps = [abs(r["gap_pct"]) for r in summary]
    largest_gap = max(summary, key=lambda r: abs(r["gap_pct"]))
    largest_range = max(summary, key=lambda r: r["peak_trough_pct"])
    largest_hour = max(summary, key=lambda r: r["largest_1h_close_move_pct"])
    metrics = {
        "generated_at_utc": datetime.now(tz=timezone.utc).isoformat(),
        "weekends_requested": args.weekends,
        "weekends_analysed": len({r["weekend"] for r in summary}),
        "markets": {s: selected[s].coin for s in SYMBOLS},
        "assets_analysed": len({r["asset"] for r in summary}),
        "median_abs_gap_pct": statistics.median(abs_gaps),
        "mean_abs_gap_pct": statistics.fmean(abs_gaps),
        "largest_abs_gap": {k: largest_gap[k] for k in ("asset", "weekend", "gap_pct")},
        "largest_weekend_range": {
            k: largest_range[k] for k in ("asset", "weekend", "peak_trough_pct")
        },
        "largest_1h_close_move": {
            k: largest_hour[k] for k in ("asset", "weekend", "largest_1h_close_move_pct")
        },
        "per_asset": {
            s: {
                "median_abs_gap_pct": statistics.median(
                    [abs(r["gap_pct"]) for r in summary if r["asset"] == s]
                ),
                "worst_abs_gap_pct": max(abs(r["gap_pct"]) for r in summary if r["asset"] == s),
                "mean_weekend_range_pct": statistics.fmean(
                    [r["peak_trough_pct"] for r in summary if r["asset"] == s]
                ),
                "mean_funding_sum_pct": statistics.fmean(
                    [r["funding_sum"] * 100 for r in summary if r["asset"] == s]
                ),
                "mean_funding_hourly_pct": statistics.fmean(
                    [r["funding_mean_hourly"] * 100 for r in summary if r["asset"] == s]
                ),
                "funding_sign_flips": sum(
                    1
                    for a, b in zip(
                        sorted((r for r in summary if r["asset"] == s), key=lambda r: r["weekend"]),
                        sorted((r for r in summary if r["asset"] == s), key=lambda r: r["weekend"])[1:],
                    )
                    if a["funding_sum"] * b["funding_sum"] < 0
                ),
            }
            for s in SYMBOLS
        },
    }
    (args.data_dir / "metrics.json").write_text(json.dumps(metrics, indent=2) + "\n", encoding="utf-8")
    make_charts(summary, args.chart_dir)
    print(f"\nWrote CSVs to {args.data_dir}/ and charts to {args.chart_dir}/")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
