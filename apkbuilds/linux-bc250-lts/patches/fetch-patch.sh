#!/bin/sh
# Vendor de patch 40-CU de duggasco/bc250-40cu-unlock
# Executar da raiz do repositório
set -eu

PATCH_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCH_FILE="$PATCH_DIR/bc250-40cu-amdgpu.patch"
TMPDIR=$(mktemp -d)

echo "Fetching BC-250 40-CU patch from duggasco/bc250-40cu-unlock..."
git clone --depth 1 https://github.com/duggasco/bc250-40cu-unlock.git "$TMPDIR/bc250-40cu-unlock"

if [ -f "$TMPDIR/bc250-40cu-unlock/patch/bc250-40cu-amdgpu.patch" ]; then
    cp "$TMPDIR/bc250-40cu-unlock/patch/bc250-40cu-amdgpu.patch" "$PATCH_FILE"
    echo "OK: vendored em $PATCH_FILE"
    echo "SHA256: $(sha256sum "$PATCH_FILE" | cut -d' ' -f1)"
else
    echo "ERRO: patch não encontrado no repositório" >&2
    rm -rf "$TMPDIR"
    exit 1
fi

rm -rf "$TMPDIR"