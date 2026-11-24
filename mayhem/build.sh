#!/usr/bin/env bash
#
# mayhem/build.sh — build bowtie2's fuzz targets and its functional-test binaries.
#
# Runs as `mayhem` in /mayhem (the repo root). Upstream builds each tool with ONE compiler call over
# every .cpp (plain GNU Makefile), so we drive upstream's own Makefile targets three times:
#   (1) the oracle build: upstream's `make all` with its normal release flags, in the tree — run
#       by mayhem/test.sh (upstream's pytest suite) and used to build the fixed index;
#   (2) the fuzz build: the same Makefile targets in mayhem/build-san/ with $SANITIZER_FLAGS
#       (ASan+UBSan, halting) + SanCov (-fsanitize=fuzzer-no-link) + $DEBUG_FLAGS (DWARF 3), and
#       NOASSERT_FLAGS= so upstream's assert()s stay live (its -s rules otherwise pass -DNDEBUG);
#   (3) the wrapped build: align/build/inspect again in mayhem/build-idx/, main() renamed to
#       bt2_original_main and mayhem/index_wrapper_main.cpp linked in (see that file): it puts a
#       fuzzed index file beside the fixed sibling files, and runs every input in a private scratch
#       cwd that is removed afterwards, so outputs a fuzzed input names cannot outlive it.
# The fixed indexes the targets read, and the installed binaries, are made read-only at the end so
# an absolute output path in a fuzzed -A args file cannot overwrite them either.
# Outputs land in mayhem/out/ (gitignored via mayhem/.gitignore). Re-runnable and offline: the
# only dependency is zlib, from apt in the base image.
set -euo pipefail
umask 022
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export CC CXX
# The base image's own CFLAGS/CXXFLAGS (if any) must not leak into upstream's Makefile, which
# appends to CXXFLAGS; each build below passes its flags explicitly.
unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS

SRC="${SRC:-/mayhem}"
cd "$SRC"
OUT="$SRC/mayhem/out"
mkdir -p "$OUT"
# A previous build left its outputs read-only (see the end of this script).
chmod -R u+w "$OUT"

# Copy the sources into a separate build dir so the sanitized and the oracle builds (which
# share upstream's fixed output names) coexist. cp -p keeps mtimes, so make stays incremental.
stage() {
  local d="$1"
  mkdir -p "$d"
  find . -maxdepth 1 -type f \( -name '*.cpp' -o -name '*.h' -o -name '*.c' \
       -o -name Makefile -o -name BOWTIE2_VERSION \) -exec cp -p {} "$d/" \;
  ln -sfn "$SRC/third_party" "$d/third_party"
}

# Asserts are on in the fuzz builds (NOASSERT_FLAGS= below). That compiles in the debug-only
# `ASSERT_ONLY(BTDnaString drd)` member of AlnRes (aligner_result.h), whose copy in
# AlnRes::operator= runs SDnaStringExpandable::install -> memcpy(NULL, NULL, 0) (sstring.h) on
# every reported alignment, so UBSan's nonnull-attribute check alone would halt every align
# input. Only that one check is relaxed; ASan and the rest of UBSan stay on and halting. It is in
# LDFLAGS too: upstream compiles and links in one command, LDFLAGS last, and a later
# -fsanitize=undefined would turn the check back on.
RELAX_FLAGS="-fno-sanitize=nonnull-attribute"
FUZZ_FLAGS="-O1 $SANITIZER_FLAGS ${SANITIZER_FLAGS:+$RELAX_FLAGS} -fsanitize=fuzzer-no-link $DEBUG_FLAGS"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o "$OUT/lsan_off.o"
# As an archive pulled in by --undefined: upstream's build-s rule repeats $(LDFLAGS), and a
# plain .o listed twice would be a duplicate definition.
rm -f "$OUT/liblsan_off.a"; ar rcs "$OUT/liblsan_off.a" "$OUT/lsan_off.o"
LSAN_OFF="-Wl,--undefined=__lsan_is_turned_off $OUT/liblsan_off.a"

stage mayhem/build-san
stage mayhem/build-idx
$CXX $FUZZ_FLAGS -std=c++11 -DMAIN_ARGV_T='const char **' -c mayhem/index_wrapper_main.cpp -o "$OUT/wrap_align.o"
$CXX $FUZZ_FLAGS -std=c++11 -DMAIN_ARGV_T='const char **' -c mayhem/index_wrapper_main.cpp -o "$OUT/wrap_build.o"
$CXX $FUZZ_FLAGS -std=c++11 -DMAIN_ARGV_T='char **'       -c mayhem/index_wrapper_main.cpp -o "$OUT/wrap_inspect.o"
# Archives pulled in by --undefined=main, for the same duplicate-$(LDFLAGS) reason as lsan_off.
for t in align build inspect; do
  rm -f "$OUT/libwrap_$t.a"; ar rcs "$OUT/libwrap_$t.a" "$OUT/wrap_$t.o"
done

# Upstream sets BUILD_HOST/BUILD_TIME from the host clock; harmless for fuzzing, so left alone.
pids=()
# Oracle: upstream's `allall` (release, -debug and -sanitized -s/-l tools; the suite runs all three),
# upstream's own flags, in the tree where upstream's pytest suite (scripts/test) looks for them.
make -C "$SRC" -j8 allall \
  CXX="$CXX" CC="$CC" ${COVERAGE_FLAGS:+CPPFLAGS="$COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS"} &
pids+=($!)
make -C mayhem/build-san -j3 bowtie2-align-s bowtie2-build-s bowtie2-inspect-s \
  CXX="$CXX" CC="$CC" RELEASE_FLAGS="$FUZZ_FLAGS" NOASSERT_FLAGS= \
  LDFLAGS="$SANITIZER_FLAGS ${SANITIZER_FLAGS:+$RELAX_FLAGS} -fsanitize=fuzzer-no-link $DEBUG_FLAGS $LSAN_OFF" &
pids+=($!)
for t in align build inspect; do
  make -C mayhem/build-idx bowtie2-$t-s \
    CXX="$CXX" CC="$CC" RELEASE_FLAGS="$FUZZ_FLAGS -Dmain=bt2_original_main" NOASSERT_FLAGS= \
    LDFLAGS="$SANITIZER_FLAGS ${SANITIZER_FLAGS:+$RELAX_FLAGS} -fsanitize=fuzzer-no-link $DEBUG_FLAGS $LSAN_OFF -Wl,--undefined=main $OUT/libwrap_$t.a" &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p"; done

for b in bowtie2-align-s bowtie2-build-s bowtie2-inspect-s; do
  install -m 0755 "mayhem/build-san/$b" "$OUT/$b"
done
install -m 0755 mayhem/build-idx/bowtie2-align-s   "$OUT/bowtie2-align-s-idxwrap"
install -m 0755 mayhem/build-idx/bowtie2-build-s   "$OUT/bowtie2-build-s-idxwrap"
install -m 0755 mayhem/build-idx/bowtie2-inspect-s "$OUT/bowtie2-inspect-s-idxwrap"

# The fixed small index the index-fuzz targets load their other five files from (and whose
# .1.bt2 seeds them), built by the oracle bowtie2-build-s from a committed reference.
# Small offrate/ftab keep the .bt2 files a few hundred bytes.
rm -rf "$OUT/idx"; mkdir -p "$OUT/idx"
./bowtie2-build-s --threads 1 -q -o 2 -t 2 --seed 1 mayhem/fixtures/tiny.fa "$OUT/idx/tiny" >/dev/null
# The align-argsfile seeds load upstream's example index from this copy, not from example/.
rm -rf "$OUT/lambda"; mkdir -p "$OUT/lambda"
cp example/index/lambda_virus.*.bt2 "$OUT/lambda/"

# Read-only outputs: the fuzz targets run as the owner of /mayhem, so an output path chosen by a
# fuzzed input (e.g. -S <file> in an -A args file) could otherwise truncate a fixed index or a
# binary that later inputs depend on. Files only: dirs stay writable so `git clean` still works.
find "$OUT" -type f -exec chmod a-w {} +

ls -l "$OUT"
