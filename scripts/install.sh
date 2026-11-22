#!/bin/bash
set -euo pipefail

REPO="Asalio123/antigravity-unlocker"
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64) ARCH="amd64" ;;
  arm64|aarch64) ARCH="arm64" ;;
  *) echo "[X] Неподдерживаемая архитектура: $ARCH"; exit 1 ;;
esac

BIN_NAME="ag-unlocker-${OS}-${ARCH}"
DEST_DIR="${HOME}/.local/bin"
DEST="${DEST_DIR}/ag-unlocker"
mkdir -p "$DEST_DIR"

URL="https://github.com/${REPO}/releases/latest/download/${BIN_NAME}"
echo "[i] Скачиваю ${BIN_NAME}..."
if curl -fsSL "$URL" -o "${DEST}.tmp" 2>/dev/null; then
  chmod +x "${DEST}.tmp"
  mv "${DEST}.tmp" "$DEST"
  echo "[OK] Установлено: ${DEST}"
elif command -v go >/dev/null 2>&1; then
  rm -f "${DEST}.tmp"
  echo "[i] Релизный бинарь недоступен — собираю из исходников через Go..."
  TMPD=$(mktemp -d)
  trap 'rm -rf "$TMPD"' EXIT
  git clone --depth 1 "https://github.com/${REPO}.git" "$TMPD/repo"
  (cd "$TMPD/repo" && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o "$DEST" ./cmd/ag-unlocker)
  chmod +x "$DEST"
  echo "[OK] Собрано и установлено: ${DEST}"
else
  rm -f "${DEST}.tmp"
  echo "[X] Не удалось скачать релиз (${URL}), а Go не установлен."
  echo "[i] Либо скачай бинарь со страницы https://github.com/${REPO}/releases, либо используй bash-скрипт из папки macos/ или linux/."
  exit 1
fi

if [ "$OS" = "darwin" ]; then
  xattr -d com.apple.quarantine "$DEST" 2>/dev/null || true
fi

echo "[i] Запускаю ag-unlocker..."
exec "$DEST" "$@"
