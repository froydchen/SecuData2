#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
echo "SECU-DAT Build: fix11-wer-rawcollector-no-regression-20260529"
echo "Server läuft gleich auf 0.0.0.0:8787"
echo "Im Browser besser die WLAN-IP oder localhost nutzen, nicht 0.0.0.0."
python -m secudata_web.app
