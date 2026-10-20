#!/bin/sh
# Prints per-file line coverage for App Mixer's sources (not the tests) from an .xcresult bundle.
# Usage: scripts/coverage.sh <TestResults.xcresult> [--markdown]
set -eu

result=${1:?usage: scripts/coverage.sh <TestResults.xcresult> [--markdown]}
format=${2:-text}

# A source file can appear in several targets; keep its best-covered entry.
xcrun xccov view --report --json "$result" |
    jq -r '
        [.targets[].files[] | select(.path | test("/AppMixer/[^/]+\\.swift$"))]
        | group_by(.path)
        | map(max_by(.coveredLines))
        | sort_by(.name)[]
        | [.name, .coveredLines, .executableLines] | @tsv
    ' |
    awk -F '\t' -v format="$format" '
        function pct(covered, total) { return total > 0 ? 100 * covered / total : 100 }
        BEGIN {
            if (format == "--markdown") {
                print "| File | Coverage | Lines |"
                print "| --- | ---: | ---: |"
            } else {
                printf "%-24s %9s %11s\n", "File", "Coverage", "Lines"
            }
        }
        {
            covered += $2; total += $3
            if (format == "--markdown") printf "| %s | %.1f%% | %d/%d |\n", $1, pct($2, $3), $2, $3
            else printf "%-24s %8.1f%% %11s\n", $1, pct($2, $3), $2 "/" $3
        }
        END {
            if (NR == 0) { print "No coverage data for App Mixer sources." > "/dev/stderr"; exit 1 }
            if (format == "--markdown") printf "| **Total** | **%.1f%%** | **%d/%d** |\n", pct(covered, total), covered, total
            else printf "%-24s %8.1f%% %11s\n", "Total", pct(covered, total), covered "/" total
        }
    '
