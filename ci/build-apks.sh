#!/bin/sh
# BC-250 LLM Alpine — CI build script
# Compila APKBUILDs de forma reprodutível
# Uso: ci/build-apks.sh [package|all]

set -eu

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APKREPO="$REPO_DIR/packages/x86_64"
TARGET="${1:-all}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

setup_abuild() {
    log "=== Configurando abuild ==="

    # Instala alpine-sdk se não presente
    if ! command -v abuild >/dev/null 2>&1; then
        apk add alpine-sdk abuild
    fi

    # Gera chave se não existir
    if [ ! -f "$HOME/.abuild/abuild.conf" ]; then
        abuild-keygen -a -i -n
    fi

    # Cria repositório local
    mkdir -p "$APKREPO"

    # Adiciona repositório local ao apk
    if ! grep -q "$APKREPO" /etc/apk/repositories 2>/dev/null; then
        echo "$APKREPO" >> /etc/apk/repositories
        apk update
    fi
}

build_package() {
    pkg_dir="$1"
    pkg_name=$(basename "$pkg_dir")

    log "=== Compilando $pkg_name ==="

    cd "$pkg_dir"

    # Verifica dependências de build
    if ! abuild checksum 2>/dev/null; then
        log "Gerando checksums..."
        abuild checksum
    fi

    # Compila
    abuild -r

    log "OK: $pkg_name compilado"
}

build_kernel() {
    log "=== Compilando kernel BC-250 ==="

    # Primeiro vendor o patch se não existir
    if [ ! -f "$REPO_DIR/apkbuilds/linux-bc250-lts/patches/bc250-40cu-amdgpu.patch" ]; then
        log "Vendoring patch 40-CU..."
        sh "$REPO_DIR/apkbuilds/linux-bc250-lts/patches/fetch-patch.sh"
    fi

    build_package "$REPO_DIR/apkbuilds/linux-bc250-lts"
}

build_governor() {
    build_package "$REPO_DIR/apkbuilds/cyan-skillfish-governor-smu"
}

build_llama() {
    build_package "$REPO_DIR/apkbuilds/llama.cpp-bc250"
}

# === Main ===
log "=== BC-250 LLM Alpine — CI Build ==="
log "Target: $TARGET"
log ""

setup_abuild

case "$TARGET" in
    kernel)
        build_kernel
        ;;
    governor)
        build_governor
        ;;
    llama)
        build_llama
        ;;
    all)
        build_kernel
        build_governor
        build_llama
        ;;
    *)
        echo "Uso: $0 [kernel|governor|llama|all]"
        exit 1
        ;;
esac

log ""
log "=== APKs em $APKREPO ==="
ls -la "$APKREPO"/*.apk 2>/dev/null || log "(nenhum APK encontrado)"