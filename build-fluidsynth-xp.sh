#!/usr/bin/env bash
# build-fluidsynth-xp.sh
#
# Compila a ultima release do FluidSynth (ou uma tag indicada) para Windows XP
# 32 bits, por compilacao cruzada em Linux (Debian/antiX/Ubuntu) com mingw-w64.
# Gera um exe estatico (com libsndfile + ogg/vorbis/flac/opus incluidos,
# logo com suporte a .sf3) e um pacote por variante em build/release/.
#
# Variantes:
#   prescott  Pentium 4 Prescott: -march=prescott -mtune=prescott -mfpmath=sse
#   generic   sem optimizacao especifica: -march=i686 -mtune=generic
#
# Uso:
#   ./build-fluidsynth-xp.sh [opcoes]
#
# Opcoes:
#   --tag TAG          compila esta tag em vez da ultima release (ex.: v2.6.2)
#   --variant V        prescott (defeito), generic ou all
#   --jobs N           numero de processos de compilacao (defeito: nproc)
#   --no-lto           nao tenta LTO (por defeito tenta e, se falhar, repete sem)
#   --zip              cria tambem build/release/fluidsynth-<tag>-xp_<variante>.zip
#   --install-deps     instala sem perguntar os pacotes em falta (apt)
#   --skip-xp-check    nao falha se o exe importar DLLs/APIs pos-XP
#   --clean            apaga a pasta build/ antes de comecar
#   --verbose          mostra o output completo (defeito: so em build/logs/)
#   -h, --help         esta ajuda
#
# Saida:  build/release/xp_<variante>/fluidsynth.exe (+ licencas e BUILD-INFO.txt)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_ROOT="$SCRIPT_DIR/build"
RELEASE_DIR="$BUILD_ROOT/release"
LOG_DIR="$BUILD_ROOT/logs"
DL_DIR="$BUILD_ROOT/downloads"
SRC_DIR="$BUILD_ROOT/src"
TC_BIN="$BUILD_ROOT/toolchain/bin"
UPSTREAM_REPO="FluidSynth/fluidsynth"
TARGET="i686-w64-mingw32"

# Bibliotecas de audio (versao | url | sha256)
OGG_VER=1.3.5
OGG_URL="https://github.com/xiph/ogg/releases/download/v${OGG_VER}/libogg-${OGG_VER}.tar.gz"
OGG_SHA=0eb4b4b9420a0f51db142ba3f9c64b333f826532dc0f48c6410ae51f4799b664
VORBIS_VER=1.3.7
VORBIS_URL="https://github.com/xiph/vorbis/releases/download/v${VORBIS_VER}/libvorbis-${VORBIS_VER}.tar.gz"
VORBIS_SHA=0e982409a9c3fc82ee06e08205b1355e5c6aa4c36bca58146ef399621b0ce5ab
FLAC_VER=1.4.3
FLAC_URL="https://github.com/xiph/flac/releases/download/${FLAC_VER}/flac-${FLAC_VER}.tar.xz"
FLAC_SHA=6c58e69cd22348f441b861092b825e591d0b822e106de6eb0ee4d05d27205b70
OPUS_VER=1.5.2
OPUS_URL="https://github.com/xiph/opus/releases/download/v${OPUS_VER}/opus-${OPUS_VER}.tar.gz"
OPUS_SHA=65c1d2f78b9f2fb20082c38cbe47c951ad5839345876e46941612ee87f9a7ce1
SNDFILE_VER=1.2.2
SNDFILE_URL="https://github.com/libsndfile/libsndfile/releases/download/${SNDFILE_VER}/libsndfile-${SNDFILE_VER}.tar.xz"
SNDFILE_SHA=3799ca9924d3125038880367bf1468e53a1b7e3686a934f098b7e1d286cdb80e
# Incrementar quando mudar a receita das bibliotecas (invalida a cache)
DEPS_REV=2

# Pacotes (Debian/antiX/Ubuntu)
PKGS="gcc-mingw-w64-i686-posix g++-mingw-w64-i686-posix binutils-mingw-w64-i686 mingw-w64-i686-dev cmake make git curl ca-certificates tar gzip xz-utils"

# Verificacao XP: DLLs permitidas e APIs proibidas (pos-XP)
XP_DLL_ALLOW="kernel32.dll msvcrt.dll user32.dll winmm.dll ws2_32.dll dsound.dll advapi32.dll shell32.dll ole32.dll oleaut32.dll gdi32.dll comctl32.dll shlwapi.dll wsock32.dll iphlpapi.dll"
XP_API_DENY="GetTickCount64|InitializeConditionVariable|SleepConditionVariableCS|SleepConditionVariableSRW|WakeConditionVariable|WakeAllConditionVariable|InitializeSRWLock|AcquireSRWLockExclusive|AcquireSRWLockShared|ReleaseSRWLockExclusive|ReleaseSRWLockShared|TryAcquireSRWLockExclusive|TryAcquireSRWLockShared|InitOnceExecuteOnce|InitOnceBeginInitialize|InitOnceComplete|GetSystemTimePreciseAsFileTime|CreateSymbolicLinkA|CreateSymbolicLinkW|GetFinalPathNameByHandleA|GetFinalPathNameByHandleW|WaitOnAddress|WakeByAddressSingle|WakeByAddressAll|SetThreadDescription|GetLogicalProcessorInformationEx|CreateFile2|CancelIoEx|GetThreadId|GetCurrentProcessorNumber|GetUserDefaultLocaleName|GetLocaleInfoEx|LCMapStringEx|CompareStringEx|InitializeCriticalSectionEx|CreateEventExW|CreateMutexExW|CreateSemaphoreExW|CreateWaitableTimerExW|SetFileInformationByHandle|GetFileInformationByHandleEx|QueryUnbiasedInterruptTime|RegGetValueA|RegGetValueW|inet_ntop|inet_pton|InetNtopW|InetPtonW|WSAPoll"

TAG=""
VARIANTS="prescott"
JOBS="$(nproc 2>/dev/null || echo 2)"
LTO=auto
MAKE_ZIP=0
INSTALL_DEPS=0
XP_CHECK=1
CLEAN=0
VERBOSE=0

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
die()  { echo "ERRO: $*" >&2; exit 1; }
info() { echo "== $* =="; }

while [ $# -gt 0 ]; do
  case "$1" in
    --tag)          [ $# -ge 2 ] || die "--tag precisa de um valor"; TAG="$2"; shift ;;
    --variant)      [ $# -ge 2 ] || die "--variant precisa de um valor"; VARIANTS="$2"; shift ;;
    --jobs)         [ $# -ge 2 ] || die "--jobs precisa de um valor"; JOBS="$2"; shift ;;
    --no-lto)       LTO=off ;;
    --zip)          MAKE_ZIP=1 ;;
    --install-deps) INSTALL_DEPS=1 ;;
    --skip-xp-check) XP_CHECK=0 ;;
    --clean)        CLEAN=1 ;;
    --verbose)      VERBOSE=1 ;;
    -h|--help)      usage; exit 0 ;;
    *)              die "opcao desconhecida: $1 (usa --help)" ;;
  esac
  shift
done

case "$VARIANTS" in
  prescott|generic) ;;
  all) VARIANTS="prescott generic" ;;
  *) die "variante invalida: $VARIANTS (prescott, generic ou all)" ;;
esac
[ "$MAKE_ZIP" = 1 ] && PKGS="$PKGS zip"
case "$JOBS" in ''|*[!0-9]*) die "--jobs invalido: $JOBS" ;; esac
if [ -n "$TAG" ]; then
  case "$TAG" in *[!A-Za-z0-9._-]*) die "tag invalida: $TAG" ;; esac
fi

# ---------------------------------------------------------------- dependencias
as_root() { if [ "$(id -u)" -eq 0 ]; then "$@"; elif command -v sudo >/dev/null 2>&1; then sudo "$@"; else su -c "$(printf '%q ' "$@")"; fi; }

check_deps() {
  info "A verificar dependencias"
  local missing=() p
  if command -v dpkg-query >/dev/null 2>&1; then
    for p in $PKGS; do
      dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' || missing+=("$p")
    done
    if [ ${#missing[@]} -gt 0 ]; then
      echo "Pacotes em falta: ${missing[*]}"
      local cmd="apt-get install -y --no-install-recommends ${missing[*]}"
      local ans=n
      if [ "$INSTALL_DEPS" = 1 ]; then
        ans=s
      elif [ -t 0 ]; then
        read -r -p "Instalar agora com '$cmd'? [s/N] " ans || ans=n
      fi
      case "$ans" in
        s|S|y|Y) as_root apt-get install -y --no-install-recommends "${missing[@]}" \
                   || die "a instalacao falhou; tenta 'apt-get update' e repete" ;;
        *) die "instala os pacotes em falta:  sudo $cmd" ;;
      esac
    fi
  else
    echo "AVISO: sem dpkg; so verifico os comandos (nao os pacotes)."
  fi
  local c
  for c in cmake make git curl tar xz sha256sum "${TARGET}-gcc-posix" "${TARGET}-g++-posix" \
           "${TARGET}-gcc-ar-posix" "${TARGET}-windres" "${TARGET}-objdump" "${TARGET}-strip"; do
    command -v "$c" >/dev/null 2>&1 || die "comando em falta: $c"
  done
  [ "$MAKE_ZIP" = 1 ] && { command -v zip >/dev/null 2>&1 || die "comando em falta: zip"; }
  local cv; cv="$(cmake --version | sed -n '1s/[^0-9]*//p')"
  [ "$(printf '%s\n3.24\n' "$cv" | sort -V | head -n1)" = "3.24" ] \
    || die "CMake $cv e demasiado antigo (preciso de >= 3.24)"
  echo "OK: cmake $cv, $(${TARGET}-gcc-posix -dumpfullversion 2>/dev/null || ${TARGET}-gcc-posix -dumpversion)"
}

# ------------------------------------------------------------------- utilidades
run() { # run NOME comando...  (log em build/logs/NOME.log)
  local name="$1"; shift
  mkdir -p "$LOG_DIR"
  if [ "$VERBOSE" = 1 ]; then
    echo "+ $*"
    "$@" 2>&1 | tee "$LOG_DIR/$name.log"
    return "${PIPESTATUS[0]}"
  fi
  if ! "$@" >"$LOG_DIR/$name.log" 2>&1; then
    echo "FALHOU: $name  (log completo: $LOG_DIR/$name.log)" >&2
    tail -n 40 "$LOG_DIR/$name.log" >&2
    return 1
  fi
}

latest_tag() {
  local url
  url="$(curl -fsSIL --retry 3 -o /dev/null -w '%{url_effective}' "https://github.com/$UPSTREAM_REPO/releases/latest")" \
    || die "nao consegui consultar a ultima release"
  local t="${url##*/}"
  case "$t" in [vV][0-9]*|[0-9]*) echo "$t" ;; *) die "tag inesperada: $url" ;; esac
}

fetch_lib() { # nome versao url sha256
  local name="$1" ver="$2" url="$3" sha="$4"
  local file="$DL_DIR/$(basename "$url")" dir="$SRC_DIR/$name-$ver"
  mkdir -p "$DL_DIR" "$SRC_DIR"
  if [ ! -f "$file" ]; then
    echo "A descarregar $name $ver"
    curl -fsSL --retry 3 -o "$file.part" "$url" || die "falhou o download de $url"
    mv "$file.part" "$file"
  fi
  echo "$sha  $file" | sha256sum -c --quiet - || { rm -f "$file"; die "SHA256 invalido: $file"; }
  if [ ! -f "$dir/.extracted" ]; then
    rm -rf "$dir"; mkdir -p "$dir"
    tar -xf "$file" -C "$dir" --strip-components=1
    touch "$dir/.extracted"
  fi
}

setup_toolchain() {
  # Symlinks sem sufixo -posix, para o CMake encontrar gcc-ar & co. pelo nome
  mkdir -p "$TC_BIN"
  local t
  for t in gcc g++ gcc-ar gcc-ranlib gcc-nm; do
    ln -sf "$(command -v "${TARGET}-${t}-posix")" "$TC_BIN/${TARGET}-${t}"
  done
  for t in windres ar ranlib strip objdump; do
    ln -sf "$(command -v "${TARGET}-${t}")" "$TC_BIN/${TARGET}-${t}"
  done
  export PATH="$TC_BIN:$PATH"
}

# ------------------------------------------------------------------ compilacao
variant_flags() {
  case "$1" in
    prescott) ARCH_FLAGS="-march=prescott -mtune=prescott -mfpmath=sse" ;;
    generic)  ARCH_FLAGS="-march=i686 -mtune=generic" ;;
  esac
}

write_toolchain_file() {
  cat > "$TC_FILE" <<TCEOF
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_VERSION 5.1)
set(CMAKE_SYSTEM_PROCESSOR i686)
set(CMAKE_C_COMPILER   ${TC_BIN}/${TARGET}-gcc)
set(CMAKE_CXX_COMPILER ${TC_BIN}/${TARGET}-g++)
set(CMAKE_RC_COMPILER  ${TC_BIN}/${TARGET}-windres)
set(CMAKE_FIND_ROOT_PATH ${DEPS_DIR} /usr/${TARGET})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
set(CMAKE_C_FLAGS_INIT   "${ARCH_FLAGS} ${XP_DEFS}")
set(CMAKE_CXX_FLAGS_INIT "${ARCH_FLAGS} ${XP_DEFS}")
set(CMAKE_C_FLAGS_RELEASE_INIT   "-O2 -DNDEBUG -ffunction-sections -fdata-sections")
set(CMAKE_CXX_FLAGS_RELEASE_INIT "-O2 -DNDEBUG -ffunction-sections -fdata-sections")
TCEOF
}

cmake_dep() { # nome srcdir args-extra...
  local name="$1" src="$2"; shift 2
  local bdir="$WORK_DIR/$name"
  rm -rf "$bdir"
  run "$VARIANT-$name-configure" cmake -S "$src" -B "$bdir" -G "Unix Makefiles" \
      -DCMAKE_TOOLCHAIN_FILE="$TC_FILE" -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX="$DEPS_DIR" -DCMAKE_PREFIX_PATH="$DEPS_DIR" \
      -DBUILD_SHARED_LIBS=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5 "$@"
  run "$VARIANT-$name-build"   cmake --build "$bdir" -j "$JOBS"
  run "$VARIANT-$name-install" cmake --install "$bdir"
}

strip_resources() {
  # A libFLAC.a traz um recurso VERSION que colide com o do fluidsynth.exe
  # (".rsrc merge failure: duplicate leaf"). Remove dos .a os membros com .rsrc.
  local a m members
  for a in "$DEPS_DIR"/lib/*.a; do
    members="$("${TARGET}-objdump" -h "$a" 2>/dev/null \
      | awk '/file format/ {m=$1; sub(/:$/,"",m)} /\.rsrc/ {print m}' | sort -u)"
    for m in $members; do
      echo "a remover recurso '$m' de $(basename "$a")"
      "${TARGET}-ar" d "$a" "$m"
    done
  done
}

build_deps() {
  info "[$VARIANT] Bibliotecas de audio (estaticas)"
  local stamp="$DEPS_DIR/.deps-ok-r${DEPS_REV}-${OGG_VER}-${VORBIS_VER}-${FLAC_VER}-${OPUS_VER}-${SNDFILE_VER}"
  if [ -f "$stamp" ]; then echo "ja compiladas (cache)"; return; fi
  rm -rf "$DEPS_DIR" "$WORK_DIR"; mkdir -p "$DEPS_DIR" "$WORK_DIR"

  echo "libogg $OGG_VER"
  cmake_dep ogg "$SRC_DIR/libogg-$OGG_VER" -DINSTALL_DOCS=OFF -DBUILD_TESTING=OFF
  echo "libvorbis $VORBIS_VER"
  cmake_dep vorbis "$SRC_DIR/libvorbis-$VORBIS_VER" -DBUILD_TESTING=OFF
  echo "flac $FLAC_VER"
  cmake_dep flac "$SRC_DIR/flac-$FLAC_VER" -DBUILD_CXXLIBS=OFF -DBUILD_PROGRAMS=OFF \
      -DBUILD_EXAMPLES=OFF -DBUILD_TESTING=OFF -DBUILD_DOCS=OFF -DINSTALL_MANPAGES=OFF \
      -DWITH_OGG=ON -DWITH_ASM=OFF -DWITH_STACK_PROTECTOR=OFF -DWITH_FORTIFY_SOURCE=OFF
  echo "opus $OPUS_VER"
  cmake_dep opus "$SRC_DIR/opus-$OPUS_VER" -DOPUS_BUILD_SHARED_LIBRARY=OFF -DOPUS_BUILD_TESTING=OFF \
      -DOPUS_BUILD_PROGRAMS=OFF -DOPUS_STACK_PROTECTOR=OFF -DOPUS_FORTIFY_SOURCE=OFF
  echo "libsndfile $SNDFILE_VER"
  cmake_dep sndfile "$SRC_DIR/libsndfile-$SNDFILE_VER" -DBUILD_PROGRAMS=OFF -DBUILD_EXAMPLES=OFF \
      -DBUILD_TESTING=OFF -DBUILD_REGTEST=OFF -DENABLE_EXTERNAL_LIBS=ON -DENABLE_MPEG=OFF \
      -DENABLE_CPACK=OFF -DINSTALL_MANPAGES=OFF
  strip_resources
  touch "$stamp"
}

build_xp_shim() {
  # A libwinpthread.a do mingw-w64 11 (Debian/Ubuntu) importa GetTickCount64
  # (Vista+), o que impede o exe de arrancar no XP. Este objecto define o
  # ponteiro de import com uma implementacao baseada em GetTickCount, ligada
  # antes das bibliotecas, de modo que o import real deixa de existir.
  local dir="$BUILD_ROOT/shim"
  mkdir -p "$dir"
  cat > "$dir/xp_shim.c" <<'SHIMEOF'
#include <windows.h>
static LONG  g_lock  = 0;
static DWORD g_last  = 0;
static DWORD g_wraps = 0;
static ULONGLONG WINAPI xp_GetTickCount64(void)
{
    DWORD now = GetTickCount();
    ULONGLONG r;
    while (InterlockedExchange(&g_lock, 1)) Sleep(0);
    if (now < g_last) g_wraps++;
    g_last = now;
    r = ((ULONGLONG)g_wraps << 32) | now;
    InterlockedExchange(&g_lock, 0);
    return r;
}
void *xp_imp_GetTickCount64 __asm__("__imp__GetTickCount64@0") = (void *)xp_GetTickCount64;
SHIMEOF
  SHIM_OBJ="$dir/xp_shim-$VARIANT.o"
  run "$VARIANT-shim" "${TARGET}-gcc" $ARCH_FLAGS $XP_DEFS -O2 -c "$dir/xp_shim.c" -o "$SHIM_OBJ"
}

build_fluidsynth() { # ipo(ON|OFF)
  local ipo="$1" bdir="$BUILD_ROOT/fluidsynth-$VARIANT"
  rm -rf "$bdir"
  local opt="-O3 -DNDEBUG -ffunction-sections -fdata-sections"
  local ldf="$SHIM_OBJ -static -s -Wl,--gc-sections ${ARCH_FLAGS} -O3"
  info "[$VARIANT] FluidSynth $TAG (LTO=$ipo)"
  run "$VARIANT-fluidsynth-configure" cmake -S "$FS_SRC" -B "$bdir" -G "Unix Makefiles" \
      -DCMAKE_TOOLCHAIN_FILE="$TC_FILE" -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_PREFIX_PATH="$DEPS_DIR" -DCMAKE_FIND_PACKAGE_PREFER_CONFIG=ON \
      "-DCMAKE_C_FLAGS_RELEASE=$opt" "-DCMAKE_CXX_FLAGS_RELEASE=$opt" \
      "-DCMAKE_EXE_LINKER_FLAGS=$ldf" \
      "-DCMAKE_INTERPROCEDURAL_OPTIMIZATION=$ipo" \
      -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
      -DBUILD_SHARED_LIBS=OFF -Dosal=cpp11 -Denable-floats=OFF \
      -Denable-libsndfile=ON -Denable-signalsmith=ON \
      -Denable-dsound=ON -Denable-waveout=ON -Denable-winmidi=ON -Denable-network=ON \
      -Denable-threads=ON -Denable-aufile=ON \
      -Denable-wasapi=OFF -Denable-sdl3=OFF -Denable-portaudio=OFF -Denable-readline=OFF \
      -Denable-dbus=OFF -Denable-pulseaudio=OFF -Denable-pipewire=OFF -Denable-jack=OFF \
      -Denable-openmp=OFF
  grep -E "Found libSndFile|SF3 files|Limiter:|OS abstraction" "$LOG_DIR/$VARIANT-fluidsynth-configure.log" | sort -u || true
  run "$VARIANT-fluidsynth-build" cmake --build "$bdir" -j "$JOBS"
  FS_EXE="$(find "$bdir" -name fluidsynth.exe | head -n 1)"
  [ -n "$FS_EXE" ] || { echo "fluidsynth.exe nao encontrado" >&2; return 1; }
}

# ------------------------------------------------------------ verificacao e pack
xp_check() { # exe
  local exe="$1" d bad=0 dump
  dump="$("${TARGET}-objdump" -p "$exe")"
  echo "DLLs importadas:"
  for d in $(printf '%s\n' "$dump" | sed -n 's/^[[:space:]]*DLL Name: //p'); do
    echo "  $d"
    case " $XP_DLL_ALLOW " in
      *" $(printf '%s' "$d" | tr 'A-Z' 'a-z') "*) ;;
      *) echo "  ^ DLL fora da lista permitida para XP" >&2; bad=1 ;;
    esac
  done
  local hits
  hits="$(printf '%s\n' "$dump" | grep -E -w "$XP_API_DENY" || true)"
  if [ -n "$hits" ]; then
    echo "APIs pos-XP importadas:" >&2; printf '%s\n' "$hits" >&2; bad=1
  fi
  if [ "$bad" = 1 ]; then
    if [ "$XP_CHECK" = 1 ]; then return 1; fi
    echo "AVISO: verificacao XP falhou (ignorado por --skip-xp-check)"
  else
    echo "Verificacao XP: OK (heuristica; nao substitui um teste no XP)"
  fi
}

package_variant() {
  local out="$RELEASE_DIR/xp_$VARIANT" lic d
  rm -rf "$out"; mkdir -p "$out/licenses"
  cp "$FS_EXE" "$out/fluidsynth.exe"
  for d in "$FS_SRC" "$SRC_DIR"/libogg-$OGG_VER "$SRC_DIR"/libvorbis-$VORBIS_VER \
           "$SRC_DIR"/flac-$FLAC_VER "$SRC_DIR"/opus-$OPUS_VER "$SRC_DIR"/libsndfile-$SNDFILE_VER \
           "$FS_SRC/gcem" "$FS_SRC/signalsmith-audio-basics"; do
    lic="licenses/$(basename "$d" | sed "s/-$TAG\$//")"
    mkdir -p "$out/$lic"
    find "$d" -maxdepth 1 -type f \( -name 'COPYING*' -o -name 'LICENSE*' -o -name 'NOTICE*' \) \
         -exec cp {} "$out/$lic/" \;
  done
  {
    echo "FluidSynth $TAG - build para Windows XP (32 bits), variante: $VARIANT"
    echo "Data da compilacao: $(date -u '+%Y-%m-%d %H:%M UTC')"
    echo "Fontes: https://github.com/$UPSTREAM_REPO/releases/tag/$TAG  (commit $(git -C "$FS_SRC" rev-parse HEAD))"
    echo "Compilador: $(${TARGET}-gcc-posix --version | head -n1)"
    echo "Flags de arquitectura: $ARCH_FLAGS"
    echo "LTO: $LTO_USED"
    echo "Estaticas dentro do exe: libsndfile $SNDFILE_VER, libogg $OGG_VER, libvorbis $VORBIS_VER, flac $FLAC_VER, opus $OPUS_VER, winpthreads/libstdc++/libgcc (mingw-w64)"
    echo "Drivers de audio: dsound, waveout, winmidi (sem WASAPI)"
    echo "Nota: GetTickCount64 (usado pela winpthreads) e substituido por um shim baseado em GetTickCount"
    echo "Tamanho do exe: $(stat -c %s "$out/fluidsynth.exe") bytes"
    echo "SHA256 do exe: $(sha256sum "$out/fluidsynth.exe" | cut -d' ' -f1)"
  } > "$out/BUILD-INFO.txt"
  if [ "$MAKE_ZIP" = 1 ]; then
    local zipf="$RELEASE_DIR/fluidsynth-${TAG}-xp_${VARIANT}.zip"
    rm -f "$zipf"
    ( cd "$out" && zip -q -r -9 "$zipf" . )
    echo "Pacote: $zipf"
  fi
  echo "Pronto: $out/fluidsynth.exe"
}

# ------------------------------------------------------------------------ main
[ "$CLEAN" = 1 ] && { info "A apagar $BUILD_ROOT"; rm -rf "$BUILD_ROOT"; }
check_deps
setup_toolchain

[ -n "$TAG" ] || { TAG="$(latest_tag)"; echo "Ultima release: $TAG"; }

FS_SRC="$SRC_DIR/fluidsynth-$TAG"
if [ ! -d "$FS_SRC/.git" ]; then
  info "A obter FluidSynth $TAG"
  mkdir -p "$SRC_DIR"
  git clone -q --depth 1 --branch "$TAG" "https://github.com/$UPSTREAM_REPO.git" "$FS_SRC" \
    || die "nao consegui clonar a tag $TAG"
fi
git -C "$FS_SRC" submodule update --init --depth 1 gcem signalsmith-audio-basics \
  || die "falhou a obtencao dos submodulos (gcem, signalsmith-audio-basics)"

fetch_lib libogg    "$OGG_VER"     "$OGG_URL"     "$OGG_SHA"
fetch_lib libvorbis "$VORBIS_VER"  "$VORBIS_URL"  "$VORBIS_SHA"
fetch_lib flac      "$FLAC_VER"    "$FLAC_URL"    "$FLAC_SHA"
fetch_lib opus      "$OPUS_VER"    "$OPUS_URL"    "$OPUS_SHA"
fetch_lib libsndfile "$SNDFILE_VER" "$SNDFILE_URL" "$SNDFILE_SHA"

# FLAC__NO_DLL: sem isto a libsndfile referencia a libFLAC como DLL (dllimport)
XP_DEFS="-D_WIN32_WINNT=0x0501 -DWINVER=0x0501 -DFLAC__NO_DLL"
mkdir -p "$RELEASE_DIR"
for VARIANT in $VARIANTS; do
  variant_flags "$VARIANT"
  DEPS_DIR="$BUILD_ROOT/deps-$VARIANT"
  WORK_DIR="$BUILD_ROOT/work-$VARIANT"
  TC_FILE="$BUILD_ROOT/toolchain-$VARIANT.cmake"
  write_toolchain_file
  build_deps
  build_xp_shim

  LTO_USED=off
  if [ "$LTO" = auto ]; then
    if build_fluidsynth ON; then LTO_USED=on
    else echo "AVISO: falhou com LTO; a repetir sem LTO"; build_fluidsynth OFF || die "falhou a compilacao do FluidSynth"
    fi
  else
    build_fluidsynth OFF || die "falhou a compilacao do FluidSynth"
  fi

  info "[$VARIANT] Verificacao"
  xp_check "$FS_EXE" || die "o exe nao passou a verificacao XP (ver acima; --skip-xp-check para ignorar)"
  package_variant
done

if [ "$MAKE_ZIP" = 1 ]; then
  ( cd "$RELEASE_DIR" && sha256sum fluidsynth-"$TAG"-xp_*.zip > SHA256SUMS && cat SHA256SUMS )
fi
info "Concluido. Resultado em $RELEASE_DIR"
