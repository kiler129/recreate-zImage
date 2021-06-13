#!/bin/bash
#set -x to print all commands
set -euo pipefail

# Usage: extract_bzImage BZIMAGE KERNEL_SRC_ROOT
# Example: extract_bzImage ~/foo/bzImage /root/build/linux-3.10
extract_bzImage () {
  # Technically speaking extract-vmlinux creates more than vmlinux.bin - it's a vmlinux.bin + vmlinux.relocs
  # I have no idea how to separate these two, but AFAIK you don't have too
  # ....and AkHcuHaly that script seems to be broken and extract EVEN MORE than that: https://lkml.org/lkml/2021/6/7/64
  echo -n "Extracting \"$1\" to \"$2/arch/x86/boot/compressed/vmlinux.bin\"... "
  "$2/scripts/extract-vmlinux" "$1" > "$2/arch/x86/boot/compressed/vmlinux.bin" || (echo " [ERR]" ; return 1)
  echo " [OK]"

  echo -n "Generating fake \"arch/x86/boot/compressed/vmlinux.relocs\"... "
  touch "$2/arch/x86/boot/compressed/vmlinux.relocs" || (echo " [ERR]" ; return 1)
  echo " [OK]"

  echo -n "Packing vmlinux.bin to vmlinux.bin.lzma... "
  cmd_lzma "$2/arch/x86/boot/compressed/vmlinux.bin" > "$2/arch/x86/boot/compressed/vmlinux.bin.lzma" \
    || (echo " [ERR]" ; return 1)
  echo " [OK]"
}

# Compiles mkpiggy tool. Technically it can be compiled using make but it compiles waaaayyy too much things
# Usage: compile_mkpiggy KERNEL_SRC_ROOT
# Example: compile_mkpiggy /root/build/linux-3.10
compile_mkpiggy () {
  echo -n "Compiling mkpiggy... "
  gcc \
    -I "$1/tools/include/" \
    "$1/arch/x86/boot/compressed/mkpiggy.c" \
    -o "$1/arch/x86/boot/compressed/mkpiggy" \
  || (echo " [ERR]" ; return 1)
  echo " [OK]"
}

# Usage: create_piggy_object KERNEL_SRC_ROOT KERN_FORMAT
# Example: create_piggy_object /root/build/linux-3.10 lzma
create_piggy_object () {
  # v4 series kernels have a safety patch which requires run size:
  #  Initially introduced in: https://github.com/torvalds/linux/commit/e6023367d779060fddc9a52d1f474085b2b36298#diff-b73467fb35cb93ce8a6b2177fe03803835d9682d6f42db9987bb75cd431fc50a
  #  Changed from perl to sh quickly in: https://github.com/torvalds/linux/commit/d69911a68c865b152a067feaa45e98e6bb0f655b
  # Normally this is ran on non-stripped arch/x86/boot/compressed/vmlinux file but it also works on the stripped one :)
  if [[ -f "$1/arch/x86/tools/calc_run_size.sh" ]]; then
    echo -n "Calculating vmlinux run_size for piggy..."
    RUN_SIZE=$(objdump -h "$1/arch/x86/boot/compressed/vmlinux.bin" | "$SHELL" "$1/arch/x86/tools/calc_run_size.sh")
    if [[ $? == 0 ]]; then echo " [OK]"; else (echo " [ERR]" ; return 1); fi;

    echo -n "Creating piggy.S... "
    "$1/arch/x86/boot/compressed/mkpiggy" "$1/arch/x86/boot/compressed/vmlinux.bin.$2" "$RUN_SIZE" \
      > "$1/arch/x86/boot/compressed/piggy.S" || (echo " [ERR]" ; return 1)
  else
    echo -n "Creating piggy.S... "
    "$1/arch/x86/boot/compressed/mkpiggy" "$1/arch/x86/boot/compressed/vmlinux.bin.$2" \
      > "$1/arch/x86/boot/compressed/piggy.S" || (echo " [ERR]" ; return 1)
  fi
  echo " [OK]"


  echo -n "Compiling piggy.S => piggy.o... "
  gcc \
    -c "$1/arch/x86/boot/compressed/piggy.S" \
    -o "$1/arch/x86/boot/compressed/piggy.o" \
   || (echo " [ERR]" ; return 1)
  echo " [OK]"
}

#################################

# Adapted from: scripts/Makefile.lib
# Usage: size_append FILE [FILE2] [FILEn]...
# Output: LE HEX with size of file in bytes (to STDOUT)
size_append () {
  printf $(
    dec_size=0;
    for F in "${@}"; do
      fsize=$(stat -c "%s" $F);
      dec_size=$(expr $dec_size + $fsize);
    done;
    printf "%08x\n" $dec_size |
      sed 's/\(..\)/\1 /g' | {
        read ch0 ch1 ch2 ch3;
        for ch in $ch3 $ch2 $ch1 $ch0; do
          printf '%s%03o' '\' $((0x$ch));
        done;
      }
  )
}

# Adapted from: scripts/Makefile.lib, scripts/xz_wrap.sh
# Usage: cmd_{gzip|bzip2|lzma|xzkern|lzo} SOURCE [SOURCE2] [SOURCEn]...
# Output: compressed data (to STDOUT)
cmd_gzip () {
  cat "${@}" | gzip -n -f -9
}
cmd_bzip2 () {
  cat "${@}" | bzip2 -9 && size_append "${@}"
}
cmd_lzma () {
  cat "${@}" | lzma -9 && size_append "${@}"
}
cmd_xzkern () {
  cat "${@}" | xz --check=crc32 --x86 --lzma2=dict=32MiB && size_append "${@}"
}
cmd_lzo () {
  cat "${@}" | lzop -9 && size_append "${@}"
}

#############################

# Usage: crate_early_objects KERNEL_SRC_ROOT
# Example: crate_early_objects /root/build/linux-3.10
# Note: before executing this you must have relocs! (or fake of it)
crate_early_objects () {
  cd "$1" || return 1
  echo "Make-ing early/80386 code..."
  make \
   arch/x86/boot/compressed/head_64.o \
   arch/x86/boot/compressed/misc.o \
   arch/x86/boot/compressed/string.o \
   arch/x86/boot/compressed/cmdline.o \
   arch/x86/boot/compressed/early_serial_console.o \
  || (echo "Failed to create early/80386 code!" ; return 1)
  echo "Early/80386 code [OK]"

  #TODO: there SHOULD be a way to do it with make.... but it doesn't work :D
  echo -n "Processing arch/x86/boot/compressed/vmlinux.lds... "
  gcc -E \
    -Wp,-MD,arch/x86/boot/compressed/.vmlinux.lds.d \
    -I./arch/x86/include -I./arch/x86/include/generated -I./include \
    -include ./include/linux/kconfig.h \
    -D__KERNEL__ -P -Ux86 -D__ASSEMBLY__ -DLINKER_SCRIPT \
    -o arch/x86/boot/compressed/vmlinux.lds \
    arch/x86/boot/compressed/vmlinux.lds.S \
  || (echo '[ERR]' ; return 1)
  echo '[OK]'
}

# Usage: ld_piggy_to_compressed_vmlinux KERNEL_SRC_ROOT
# Example: ld_piggy_to_compressed_vmlinux /root/build/linux-3.10
# Note: technically this should be done by "make arch/x86/boot/vmlinux.bin" or sth but it doesn't work
ld_piggy_to_compressed_vmlinux () {
  echo -n "Linking early/80386 code to arch/x86/boot/compressed/vmlinux... "

  #TODO
  # Before the process kernel build does check on every .o linked here using "do readelf -S $obj | grep -qF .rel.local"
  # and errors-out if it finds something... this may be important if something goes sideways

  # It's not my monster! Look in boot/compressed/Makefile
  # ...but the hack for grep is mine ;P
  set +e
  LDFLAGS=$(ld --help 2>&1 | grep -q "\-z noreloc-overflow" && echo "-z noreloc-overflow -pie --no-dynamic-linker")
  set -e
  echo $LDFLAGS

  echo 'EXECUTING LD'
  ld -m elf_x86_64 $LDFLAGS \
    -T "$1/arch/x86/boot/compressed/vmlinux.lds" \
    "$1/arch/x86/boot/compressed/head_64.o" \
    "$1/arch/x86/boot/compressed/misc.o" \
    "$1/arch/x86/boot/compressed/string.o" \
    "$1/arch/x86/boot/compressed/cmdline.o" \
    "$1/arch/x86/boot/compressed/early_serial_console.o" \
    "$1/arch/x86/boot/compressed/piggy.o" \
    -o "$1/arch/x86/boot/compressed/vmlinux" \
  || (echo '[ERR]' ; return 1)
  echo '[OK]'
}

# Usage: create_compressed_vmlinux_bin KERNEL_SRC_ROOT
# Example: create_compressed_vmlinux_bin /root/build/linux-3.10
create_compressed_vmlinux_bin () {
  echo -n 'Creating arch/x86/boot/vmlinux.bin from arch/x86/boot/compressed/vmlinux... '
  objcopy  -O binary -R .note -R .comment -S \
    arch/x86/boot/compressed/vmlinux \
    arch/x86/boot/vmlinux.bin \
  || (echo '[ERR]' ; return 1)
  echo '[OK]'
}

#####################

# Usage: generate_zoffset SRC TARGET
# Example: generate_zoffset arch/x86/boot/compressed/vmlinux arch/x86/boot/zoffset.h
generate_zoffset () {
 echo -n "Generating zoffsets... "
 nm "$1" | \
   sed -n -e 's/^\([0-9a-fA-F]*\) [a-zA-Z] \(startup_32\|startup_64\|efi32_stub_entry\|efi64_stub_entry\|efi_pe_entry\|efi32_pe_entry\|input_data\|kernel_info\|_end\|_ehead\|_text\|z_.*\)$/\#define ZO_\2 0x\1/p' \
   > "$2" \
 || (echo '[ERR]' ; return 1)
 echo '[OK]'
}

# Usage: generate_voffset SRC TARGET
# Example: generate_voffset vmlinux arch/x86/boot/zoffset.h arch/x86/boot/voffset.h
generate_voffset () {
  nm "$1" | \
    sed -n -e 's/^\([0-9a-fA-F]*\) [ABCDGRSTVW] \(_text\|__bss_start\|_end\)$/\#define VO_\2 _AC(0x\1,UL)/p' \
  > "$2"
}

# Usage: generate_fuzzy_voffset inputZOffset outputFuzzyVOffset
# Example: generate_fuzzy_voffset arch/x86/boot/zoffset.h arch/x86/boot/voffset.h
generate_fuzzy_voffset () {
  echo -n "Shimming voffset.h from zoffset.h... "
  printf "#define VO__end 0x%X\n#define VO__text 0x0\n" "$(( \
    4 * ( \
      $(grep -oP 'ZO__end\s+\K([A-Fa-f0-9x]+)$' "$1") - \
      $(grep -oP 'ZO_startup_32\s+\K([A-Fa-f0-9x]+)$' "$1") + \
      $(grep -oP 'ZO_z_extract_offset\s+\K([A-Fa-f0-9x]+)$' "$1" || echo 0x0) \
    )
  ))" > "$2" || (echo '[ERR]' ; return 1)
  echo '[OK]'
}

#####################

# Usage: create_boot_setup_bin KERNEL_SRC_ROOT
# Example: create_boot_setup_bin /root/build/linux-3.10
create_boot_setup_bin () {
  ### We first need to fake some environment so make will not explode angrily while making files for setup.elf (=>bin)
  cd "$1" || return 1

  # this is mainly to create capflags.c (used by mkcpustr.c which is needed to build setup.elf)
  # bash "$1/arch/x86/kernel/cpu/mkcapflags.sh" \
  #  "$1/arch/x86/include/asm/cpufeature.h" "$1/arch/x86/kernel/cpu/capflags.c"
  echo "Generating CPU capflags..."
  make arch/x86/kernel/cpu/ || (echo 'CAPFLAGS failed to generate [ERR]' ; return 1)
  echo 'CAPFLAGS created [OK]'


  # create zoffset.h & fake voffset.h (see <zoffset & voffset> for details why)
  # normally if we had /vmlinux [ELF before first stripping] voffset can be generated using generate_voffset()
  generate_zoffset "$1/arch/x86/boot/compressed/vmlinux" "$1/arch/x86/boot/zoffset.h"
  generate_fuzzy_voffset "$1/arch/x86/boot/zoffset.h" "$1/arch/x86/boot/voffset.h"


  # create fake /vmlinux so that make doesn't complain building header:
  #  header.o =dep=>
  #   ( voffset.h =dep=> /vmlinux +
  #     zoffset.h =dep=> /arch/x86/boot/compressed/vmlinux )
  # This file will not be used as the voffset.h is nulled
  echo "FAKE VMLINUX FOR header.o MAKEFILE" > vmlinux

  echo -n "Extracting setup.elf components list..."
  SETUP_ELF_OBJS=$(grep '^setup-y' arch/x86/boot/Makefile | sed --regexp-extended --null-data \
    -e 's/\n/ /g' -e 's/setup-y\s+\+=\s//g' -e 's#(^|\s+)([a-z0-9_\-]+\.o)#arch/x86/boot/\2 #g')
  if [[ $? == 0 ]]; then echo " [OK]"; else (echo " [ERR]" ; return 1); fi;

  echo $SETUP_ELF_OBJS;

  # create components linked into setup.elf [taken from x86/boot/Makefile, setup-y variable]
  # Sadly you cannot do make arch/x86/boot/setup.elf
  # First we need to patch makefile - normally it FORCEs compressed/, zoffsets, and voffsets to rebuild which will
  # remove our unpacked kernel and clear voffsets file (as the vmlinux is a fake, see above)
  echo "Compiling setup.elf components..."

  make $SETUP_ELF_OBJS || (echo 'Some components of setup.elf failed to compile [ERR]' ; return 1)
  echo 'Components for setup.elf compiled [OK]'

  # The order of linking of video-* is crucial according to arch/x86/boot/Makefile; it is kept the same as make /\ here
  echo -n "Linking setup.elf components to arch/x86/boot/setup.elf... "
  ld -m elf_x86_64 -z max-page-size=0x200000 -m elf_i386 \
   -T arch/x86/boot/setup.ld $SETUP_ELF_OBJS -o arch/x86/boot/setup.elf || (echo '[ERR]' ; return 1)
  echo '[OK]'

  echo -n 'Creating setup.bin from setup.elf... '
  objcopy -O binary arch/x86/boot/setup.elf arch/x86/boot/setup.bin || (echo '[ERR]' ; return 1)
  echo '[OK]'
}

# Usage: create_bzImage_build_tool KERNEL_SRC_ROOT
# Example: create_bzImage_build_tool /root/build/linux-3.10
create_bzImage_build_tool () {
  echo -n "Compiling arch/x86/boot/tools/build... "
  if [[ -f "$1/arch/x86/boot/tools/build" ]]; then echo '[SKIP]'; return 0; fi
  gcc \
    -Wp,-MD,$1/arch/x86/boot/tools/.build.d -Wall -Wmissing-prototypes -Wstrict-prototypes -O2 -fomit-frame-pointer \
    -std=gnu89  -I$1/tools/include -include $1/include/generated/autoconf.h -D__EXPORTED_HEADERS__ \
    -o $1/arch/x86/boot/tools/build $1/arch/x86/boot/tools/build.c \
  || (echo '[ERR]' ; return 1)
  echo '[OK]'
}

# Usage: build_bzImage KERNEL_SRC_ROOT OUT_BZIMAGE_LOCATION
# Example: build_bzImage /root/build/linux-3.10 /root/build/linux-3.10/arch/x86/boot/bzImage
# Note: you can pick any location for the output bzImage
build_bzImage () {
  create_bzImage_build_tool "$1"

  # Syntax for this tool changed somewhere in 4.x (last param is the path to bzImage)
  echo "Making final bzImage..."

  BUILD_USAGE=$("$1/arch/x86/boot/tools/build" 2>&1 || true)
  if echo "$BUILD_USAGE" | grep -q -F 'build setup system [zoffset.h] [> image]'; then # Linux v3
    "$1/arch/x86/boot/tools/build" \
      "$1/arch/x86/boot/setup.bin" \
      "$1/arch/x86/boot/vmlinux.bin" \
      "$1/arch/x86/boot/zoffset.h" \
    > "$2" || (echo '[ERR]' ; return 1)
  elif echo "$BUILD_USAGE" | grep -q -F 'build setup system zoffset.h image'; then # Linux v4-ish
    "$1/arch/x86/boot/tools/build" \
      "$1/arch/x86/boot/setup.bin" \
      "$1/arch/x86/boot/vmlinux.bin" \
      "$1/arch/x86/boot/zoffset.h" \
      "$2" || (echo '[ERR]' ; return 1)
  else
    echo '[ERR] Failed to recognize "build" version w/invocation: $BUILD_USAGE'
    return 1
  fi;

  echo "Your GNU/Linux kernel is (probably) ready in $2"
}


###################################################################
# Usage: patch_makefiles KERNEL_SRC_ROOT
# Example: patch_makefiles /root/build/linux-3.10
patch_makefiles()
{
   echo -n "Patching kernel Makefiles..."
   cp "$1/arch/x86/boot/Makefile" "$1/arch/x86/boot/Makefile.org"
   sed \
    -e 's#voffset.h: vmlinux FORCE#voffset.h: vmlinux#' \
    -e 's#zoffset.h: $(obj)/compressed/vmlinux FORCE#zoffset.h: $(obj)/compressed/vmlinux#' \
    -e 's#$(obj)/compressed/vmlinux: FORCE#$(obj)/compressed/vmlinux:#' \
    -e 's#$(obj)/compressed/vmlinux FORCE#$(obj)/compressed/vmlinux#' \
   "$1/arch/x86/boot/Makefile.org" > "$1/arch/x86/boot/Makefile" \
   || (echo " [ERR]" ; return 1)
   echo " [OK]"
}

# Usage: restore_makefiles KERNEL_SRC_ROOT
# Example: restore_makefiles /root/build/linux-3.10
restore_makefiles()
{
  echo -n "Restoring kernel Makefiles..."
  cp "$1/arch/x86/boot/Makefile.org" "$1/arch/x86/boot/Makefile" || (echo " [ERR]" ; return 1)
  echo " [OK]"
}

# Usage: prepare_kernel_tree KERNEL_SRC_ROOT
# Example: prepare_kernel_tree /root/build/linux-3.10
prepare_kernel_tree() {
  echo "Verifying kernel..."

  if [ ! -d "$1" ]; then
      echo "KERNEL_SRC_ROOT of \"$1\" does NOT exist!"
      return 1
  fi
  cd "$1" || return 1

  if [ ! -f '.config' ]; then
    echo "Kernel .config does not exist, create it (or copy an existing one to $1/.config)"
    return 1
  fi

  echo "Cleaning up..."
  make clean

  patch_makefiles "$1"

  echo "Preparing for compilation..."
  make oldconfig
  make prepare
  make init/version.o

  echo "The source tree reported version: $(make kernelrelease)"
}
###################################################################

# Usage: impossibly_rebuild_zImage KERNEL_SRC_ROOT IN_BZIMAGE_LOCATION|IN_VMLINUX_LOCATION OUT_BZIMAGE_LOCATION
# Example: impossibly_rebuild_zImage /root/build/experiment/zImage /root/build/linux-3.10 /root/build/linux-3.10/arch/x86/boot/bzImage
# Note: you can pick any location for the output bzImage
impossibly_rebuild_zImage () {
  # Prepare kernel binary (to get piggy.o)
  extract_bzImage "$2" "$1"
  compile_mkpiggy "$1"
  create_piggy_object "$1" lzma

  # Prepare loader files & create compressed vmlinux
  crate_early_objects "$1"
  ld_piggy_to_compressed_vmlinux "$1"
  create_compressed_vmlinux_bin "$1"

  # Create setup [wrapper] and bzImage
  create_boot_setup_bin "$1"
  build_bzImage "$1" "$3"

  # Restore original Makefiles
  restore_makefiles "$1"
}

if [ $# -ne 3 ]; then
  echo "Usage $0 KERNEL_SRC_ROOT IN_BZIMAGE_LOCATION|IN_VMLINUX_LOCATION OUT_BZIMAGE_LOCATION"
  exit 1
fi

KERNEL_SRC_ROOT=$(realpath "$1")
IN_IMAGE_LOCATION=$(realpath "$2")
OUT_IMAGE_LOCATION=$(realpath "$3")

# This will also "cd" to the kernel dir
prepare_kernel_tree "$1"

echo "Kernel Source: $KERNEL_SRC_ROOT"
echo "Input image: $IN_IMAGE_LOCATION"
echo "Output image: $OUT_IMAGE_LOCATION"

impossibly_rebuild_zImage "$KERNEL_SRC_ROOT" "$IN_IMAGE_LOCATION" "$OUT_IMAGE_LOCATION"
