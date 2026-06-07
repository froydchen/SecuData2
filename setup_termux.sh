#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

echo "SECU-DAT Termux Setup"

if command -v python >/dev/null 2>&1; then
  echo "Python ist bereits vorhanden: $(python --version 2>&1)"
else
  echo "Python fehlt noch."
  echo "Installiere es bei Bedarf manuell mit:"
  echo "  pkg install python"
  echo
  echo "Ich starte hier bewusst kein pkg update/pkg install und kein pip install,"
  echo "damit Termux-Repo-Fehler den Setup nicht blockieren."
fi

echo
echo "Setup abgeschlossen."
echo "Starten mit: bash start_termux.sh"
