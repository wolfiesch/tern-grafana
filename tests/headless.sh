#!/bin/bash
# Headless Tern check of the dashboard block against a live Grafana.
#
#   TERN_GRAFANA_URL=https://grafana.example.com grafana/tests/headless.sh [DASHBOARDS] [OUT]
#
# Opens the first dashboard through the palette command (a new tab, the path a person takes) in a
# narrow window, then widens the window and requires the 24-column grid to replace the one-column
# stack. Then it walks the first DASHBOARDS dashboards (default 1) through the block's list and
# shoots each one into OUT (default a temp dir).
#
# Headless Tern runs blocks in its own process. A desktop window runs them in the session daemon, where
# the context `init` receives keeps the width the block opened at; `tern serve` does not load plugin
# window halves when pointed at a daemon, so that case needs a check in a real window.
set -euo pipefail

: "${TERN_GRAFANA_URL:?set TERN_GRAFANA_URL to the Grafana to render}"
N=${1:-1}
OUT=${2:-$(mktemp -d "${TMPDIR:-/tmp}/tern-grafana-shots.XXXXXX")}
TERN=${TERN:-/Applications/Tern.app/Contents/MacOS/tern}
HERE=$(cd "$(dirname "$0")/.." && pwd)

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/tern-grafana-root.XXXXXX")
CFG=$(mktemp -d "${TMPDIR:-/tmp}/tern-grafana-cfg.XXXXXX")
mkdir -p "$OUT" "$ROOT/crates/app" "$ROOT/crates/plugins/fixtures"
ln -s "$HERE" "$ROOT/crates/plugins/fixtures/grafana"
CTL="$CFG/ctl.sock"

STENCIL_FIXTURE_ROOT="$ROOT/crates/app" TERN_CONFIG_DIR="$CFG" TERN_DAEMON_SOCKET="$CFG/nodaemon.sock" \
	"$TERN" serve --control "$CTL" --out "$OUT" >"$OUT/serve.log" 2>&1 &
SERVE=$!
trap 'kill $SERVE 2>/dev/null || true; wait $SERVE 2>/dev/null || true; rm -rf "$ROOT" "$CFG"' EXIT
for _ in $(seq 1 50); do [ -S "$CTL" ] && break; sleep 0.2; done

c() { "$TERN" ctl --control "$CTL" "$@" >/dev/null; }
# Shoots NAME and prints the visible dashboard grid wrappers (.gf-gN) and panel cells (.gf-cell) in it.
grids() {
	local layout="$OUT/serve/$1.layout.json"
	rm -f "$layout"
	c shot "$1"
	for _ in $(seq 1 25); do [ -s "$layout" ] && break; sleep 0.2; done
	python3 - "$layout" <<-'PY'
		import json, re, sys
		els = [e for e in json.load(open(sys.argv[1]))["elements"] if e["visible"]]
		print(sum(1 for e in els if re.search(r"\.gf-g\d+$", e["path"])), sum(1 for e in els if e["path"].endswith("gf-cell")))
	PY
}
# Shoots NAME every 2 s for up to $2 s until `test` (given wrappers and cells) passes; prints the last count.
until_grids() {
	local name=$1 tries=$(($2 / 2)) test=$3 g n
	for _ in $(seq 1 "$tries"); do
		read -r g n < <(grids "$name")
		if $test "$g" "$n"; then break; fi
		sleep 2
	done
	echo "$g $n"
}
stacked() { [ "$2" -gt 0 ] && [ "$1" -eq 0 ]; }
gridded() { [ "$1" -gt 0 ]; }

c size 700 1400
c plugins fixtures
sleep 1
c plugins run plugin.grafana.open
sleep 3
c key Enter
read -r narrow ncells < <(until_grids narrow 30 stacked)
c size 2800 2400
read -r wide _ < <(until_grids wide 20 gridded)
echo "grid wrappers: narrow=$narrow (of $ncells cells) wide=$wide"
if [ "$ncells" -eq 0 ]; then
	echo "FAIL: the dashboard did not load" >&2
	exit 1
fi
if [ "$narrow" -ne 0 ] || [ "$wide" -eq 0 ]; then
	echo "FAIL: the layout did not follow the block's width" >&2
	exit 1
fi

for i in $(seq 1 $((N - 1))); do
	c key l
	sleep 2
	c key j
	c key Enter
	sleep 14
	c shot "d$i"
done
echo "ok: shots in $OUT/serve"
