#!/usr/bin/env bash

# -----------------------------------------------------------------------------
# Safety settings (see https://gist.github.com/ilg-ul/383869cbb01f61a51c4d).

if [[ ! -z ${DEBUG} ]]
then
  set ${DEBUG} # Activate the expand mode if DEBUG is anything but empty.
else
  DEBUG=""
fi

set -o errexit # Exit if command failed.
set -o pipefail # Exit if pipe failed.
set -o nounset # Exit if variable not set.

# Remove the initial space and instead use '\n'.
IFS=$'\n\t'

# -----------------------------------------------------------------------------

# Inner script to run inside Docker containers to build the 
# GNU MCU Eclipse ARM Embedded GCC distribution packages.

# For native builds, it runs on the host (macOS build cases,
# and development builds for GNU/Linux).

# -----------------------------------------------------------------------------

# ----- Identify helper scripts. -----

build_script_path=$0
if [[ "${build_script_path}" != /* ]]
then
  # Make relative path absolute.
  build_script_path=$(pwd)/$0
fi

script_folder_path="$(dirname ${build_script_path})"
script_folder_name="$(basename ${script_folder_path})"

defines_script_path="${script_folder_path}/defs-source.sh"
echo "Definitions source script: \"${defines_script_path}\"."
source "${defines_script_path}"

TARGET_OS=""
TARGET_BITS=""
HOST_UNAME=""

# Be sure the changes in the build.git are commited.
# otherwise the copied git may use the previous version.

RELEASE_VERSION=${RELEASE_VERSION:-"${gcc_version}-1"}

echo
echo "Preparing release ${RELEASE_VERSION}..."

# This file is generated by the host build script.
host_defines_script_path="${script_folder_path}/host-defs-source.sh"
echo "Host definitions source script: \"${host_defines_script_path}\"."
source "${host_defines_script_path}"

container_lib_functions_script_path="${script_folder_path}/${CONTAINER_LIB_FUNCTIONS_SCRIPT_NAME}"
echo "Container lib functions source script: \"${container_lib_functions_script_path}\"."
source "${container_lib_functions_script_path}"

container_app_functions_script_path="${script_folder_path}/${CONTAINER_APP_FUNCTIONS_SCRIPT_NAME}"
echo "Container app functions source script: \"${container_app_functions_script_path}\"."
source "${container_app_functions_script_path}"

container_functions_script_path="${script_folder_path}/helper/container-functions-source.sh"
echo "Container helper functions source script: \"${container_functions_script_path}\"."
source "${container_functions_script_path}"

# -----------------------------------------------------------------------------

WITH_STRIP="y"
MULTILIB_FLAGS="--with-multilib-list=rmprofile"
WITH_PDF="y"
WITH_HTML="n"
IS_DEVELOP=""
IS_DEBUG=""
LINUX_INSTALL_PATH=""

while [ $# -gt 0 ]
do

  case "$1" in

    --disable-strip)
      WITH_STRIP="n"
      shift
      ;;

    --without-pdf)
      WITH_PDF="n"
      shift
      ;;

    --with-pdf)
      WITH_PDF="y"
      shift
      ;;

    --without-html)
      WITH_HTML="n"
      shift
      ;;

    --with-html)
      WITH_HTML="y"
      shift
      ;;

    --disable-multilib)
      MULTILIB_FLAGS="--disable-multilib"
      shift
      ;;

    --jobs)
      JOBS="--jobs=$2"
      shift 2
      ;;

    --develop)
      IS_DEVELOP="y"
      shift
      ;;

    --debug)
      IS_DEBUG="y"
      shift
      ;;

    --linux-install-path)
      LINUX_INSTALL_PATH="$2"
      shift 2
      ;;

    *)
      echo "Unknown action/option $1"
      exit 1
      ;;

  esac

done

# -----------------------------------------------------------------------------

start_timer

detect

# Fix the texinfo path in XBB v1.
if [ -f "/.dockerenv" -a -f "/opt/xbb/xbb.sh" ]
then
  if [ "${TARGET_BITS}" == "64" ]
  then
    sed -e "s|texlive/bin/\$\(uname -p\)-linux|texlive/bin/x86_64-linux|" /opt/xbb/xbb.sh > /opt/xbb/xbb-source.sh
  elif [ "${TARGET_BITS}" == "32" ]
  then
    sed -e "s|texlive/bin/[$][(]uname -p[)]-linux|texlive/bin/i386-linux|" /opt/xbb/xbb.sh > /opt/xbb/xbb-source.sh
  fi

  echo /opt/xbb/xbb-source.sh
  cat /opt/xbb/xbb-source.sh
fi

prepare_prerequisites

if [ -f "/.dockerenv" ]
then
  (
    xbb_activate

    # Remove references to libfl.so, to force a static link and
    # avoid references to unwanted shared libraries in binutils.
    sed -i -e "s/dlname=.*/dlname=''/" -e "s/library_names=.*/library_names=''/" "${XBB_FOLDER}"/lib/libfl.la

    echo "${XBB_FOLDER}"/lib/libfl.la
    cat "${XBB_FOLDER}"/lib/libfl.la
  )
fi

if [ -x "${WORK_FOLDER_PATH}/${LINUX_INSTALL_PATH}/bin/${GCC_TARGET}-gcc" ]
then
  PATH="${WORK_FOLDER_PATH}/${LINUX_INSTALL_PATH}/bin":${PATH}
  echo ${PATH}
fi

# -----------------------------------------------------------------------------

UNAME="$(uname)"

# Make all tools choose gcc, not the old cc.
if [ "${UNAME}" == "Darwin" ]
then
  export CC=clang
  export CXX=clang++
elif [ "${TARGET_OS}" == "linux" ]
then
  export CC=gcc
  export CXX=g++
fi

EXTRA_CFLAGS="-ffunction-sections -fdata-sections -m${TARGET_BITS} -pipe -O2"
EXTRA_CXXFLAGS="-ffunction-sections -fdata-sections -m${TARGET_BITS} -pipe -O2"

if [ "${IS_DEBUG}" == "y" ]
then
  EXTRA_CFLAGS+=" -g"
  EXTRA_CXXFLAGS+=" -g"
fi

EXTRA_CPPFLAGS="-I${INSTALL_FOLDER_PATH}"/include
EXTRA_LDFLAGS_LIB="-L${INSTALL_FOLDER_PATH}"/lib
EXTRA_LDFLAGS="${EXTRA_LDFLAGS_LIB}"
EXTRA_LDFLAGS_APP="${EXTRA_LDFLAGS} -static-libstdc++"
if [ "${UNAME}" == "Darwin" ]
then
  EXTRA_LDFLAGS_APP+=" -Wl,-dead_strip"
else
  EXTRA_LDFLAGS_APP+=" -Wl,--gc-sections"
fi

export PKG_CONFIG=pkg-config-verbose
export PKG_CONFIG_LIBDIR="${INSTALL_FOLDER_PATH}"/lib/pkgconfig

APP_PREFIX="${INSTALL_FOLDER_PATH}/${APP_LC_NAME}"
APP_PREFIX_DOC="${APP_PREFIX}"/share/doc

APP_PREFIX_NANO="${INSTALL_FOLDER_PATH}/${APP_LC_NAME}"-nano

# The \x2C is a comma in hex; without this trick the regular expression
# that processes this string in the Makefile, silently fails and the 
# bfdver.h file remains empty.
BRANDING="${BRANDING}\x2C ${TARGET_BITS}-bits"
CFLAGS_OPTIMIZATIONS_FOR_TARGET="-ffunction-sections -fdata-sections -O2"

# Keep them updated with combo archive content.
if [[ "${RELEASE_VERSION}" =~ 7\.2\.1-* ]]
then

  GCC_COMBO_VERSION_MAJOR="7"
  GCC_COMBO_VERSION_YEAR="2017"
  GCC_COMBO_VERSION_QUARTER="q4"
  GCC_COMBO_VERSION="${GCC_COMBO_VERSION_MAJOR}-${GCC_COMBO_VERSION_YEAR}-${GCC_COMBO_VERSION_QUARTER}-major"
  GCC_COMBO_FOLDER_NAME="gcc-arm-none-eabi-${GCC_COMBO_VERSION}"
  GCC_COMBO_ARCHIVE="${GCC_COMBO_FOLDER_NAME}-src.tar.bz2"

  # https://developer.arm.com/-/media/Files/downloads/gnu-rm/7-2017q4/gcc-arm-none-eabi-7-2017-q4-major-src.tar.bz2
  GCC_COMBO_URL="https://developer.arm.com/-/media/Files/downloads/gnu-rm/${GCC_COMBO_VERSION_MAJOR}-${GCC_COMBO_VERSION_YEAR}${GCC_COMBO_VERSION_QUARTER}/${GCC_COMBO_ARCHIVE}"

  BINUTILS_VERSION="2.29"
  GCC_VERSION="7.2.1"
  NEWLIB_VERSION="2.5.0"
  GDB_VERSION="8.0"

  ZLIB_VERSION="1.2.8"
  GMP_VERSION="6.1.0"
  MPFR_VERSION="3.1.4"
  MPC_VERSION="1.0.3"
  ISL_VERSION="0.15"
  LIBELF_VERSION="0.8.13"
  EXPAT_VERSION="2.1.1"
  LIBICONV_VERSION="1.14"
  XZ_VERSION="5.2.3"

  PYTHON_WIN_VERSION="2.7.13"
fi

if [ "${TARGET_BITS}" == "32" ]
then
  PYTHON_WIN=python-"${PYTHON_WIN_VERSION}"
else
  PYTHON_WIN=python-"${PYTHON_WIN_VERSION}".amd64
fi

PYTHON_WIN_PACK="${PYTHON_WIN}".msi
PYTHON_WIN_URL="https://www.python.org/ftp/python/${PYTHON_WIN_VERSION}/${PYTHON_WIN_PACK}"

# -----------------------------------------------------------------------------
# Libraries

# For just in case, usually it should pick the lib packed inside the archive.
do_zlib

# The classical GCC libraries.
do_gmp
do_mpfr
do_mpc
do_isl

do_libelf
do_expat
do_libiconv
do_xz

# -----------------------------------------------------------------------------

# Download the combo package from ARM.
do_gcc_download

# The task numbers are from the ARM build script.

# Task [III-0] /$HOST_NATIVE/binutils/
do_binutils
# copy_dir to libs included above

# Task [III-1] /$HOST_NATIVE/gcc-first/
do_gcc_first

# Task [III-2] /$HOST_NATIVE/newlib/
do_newlib ""
# Task [III-3] /$HOST_NATIVE/newlib-nano/
do_newlib "-nano"

# Task [III-4] /$HOST_NATIVE/gcc-final/
do_gcc_final ""

# Task [III-5] /$HOST_NATIVE/gcc-size-libstdcxx/
do_gcc_final "-nano"

# Task [III-6] /$HOST_NATIVE/gdb/
do_gdb ""
do_gdb "-py"

# Task [III-7] /$HOST_NATIVE/build-manual

# Task [III-8] /$HOST_NATIVE/pretidy/
do_pretidy

# Task [III-9] /$HOST_NATIVE/strip_host_objects/
do_strip_binaries

# Task [III-10] /$HOST_NATIVE/strip_target_objects/
do_strip_libs

do_check_binaries
do_copy_license_files
do_copy_scripts

# Task [III-11] /$HOST_NATIVE/package_tbz2/
do_create_archive

# Change ownership to non-root Linux user.
fix_ownership

# Copy install to shared folder.
copy_install

# -----------------------------------------------------------------------------

stop_timer

exit 0

# -----------------------------------------------------------------------------
