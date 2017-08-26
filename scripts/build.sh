#!/usr/bin/env bash

# -----------------------------------------------------------------------------
# Safety settings (see https://gist.github.com/ilg-ul/383869cbb01f61a51c4d).

if [[ ! -z ${DEBUG} ]]
then
  set ${DEBUG} # Activate the expand mode if DEBUG is -x.
else
  DEBUG=""
fi

set -o errexit # Exit if command failed.
set -o pipefail # Exit if pipe failed.
set -o nounset # Exit if variable not set.

# Remove the initial space and instead use '\n'.
IFS=$'\n\t'

# -----------------------------------------------------------------------------

# Script to build the GNU MCU Eclipse OpenOCD distribution packages.
#
# Developed on OS X 10.12 Sierra.
# Also tested on:
#   GNU/Linux Arch (Manjaro 16.08)
#
# The Windows and GNU/Linux packages are build using Docker containers.
# The build is structured in 2 steps, one running on the host machine
# and one running inside the Docker container.
#
# At first run, Docker will download/build 3 relatively large
# images (1-2GB) from Docker Hub.
#
# Prerequisites:
#
#   Docker
#   curl, git, automake, patch, tar, unzip, zip
#
# When running on OS X, a custom Homebrew is required to provide the 
# missing libraries and TeX binaries.
#
# To resume a crashed build with the same timestamp, set
# DISTRIBUTION_FILE_DATE='yyyymmdd-HHMM' in the environment.

# Mandatory definition.
APP_NAME="OpenOCD"

# Used as part of file/folder paths.
APP_UC_NAME="OpenOCD"
APP_LC_NAME="openocd"

# On Parallels virtual machines, prefer host Work folder.
# Second choice are Work folders on secondary disks.
# Final choice is a Work folder in HOME.
if [ -d /media/psf/Home/Work ]
then
  WORK_FOLDER_PATH=${WORK_FOLDER_PATH:-"/media/psf/Home/Work/${APP_LC_NAME}"}
elif [ -d /media/${USER}/Work ]
then
  WORK_FOLDER_PATH=${WORK_FOLDER_PATH:-"/media/${USER}/Work/${APP_LC_NAME}"}
elif [ -d /media/Work ]
then
  WORK_FOLDER_PATH=${WORK_FOLDER_PATH:-"/media/Work/${APP_LC_NAME}"}
else
  # Final choice, a Work folder in HOME.
  WORK_FOLDER_PATH=${WORK_FOLDER_PATH:-"${HOME}/Work/${APP_LC_NAME}"}
fi

BUILD_FOLDER_PATH="${WORK_FOLDER_PATH}/build"

PROJECT_GIT_FOLDER_NAME="openocd-build.git"
PROJECT_GIT_FOLDER_PATH="${WORK_FOLDER_PATH}/${PROJECT_GIT_FOLDER_NAME}"
PROEJCT_GIT_URL="https://github.com/gnu-mcu-eclipse/${PROJECT_GIT_FOLDER_NAME}"

# ----- Create Work folder. -----

echo
echo "Work folder: \"${WORK_FOLDER_PATH}\"."

mkdir -p "${WORK_FOLDER_PATH}"

# ----- Parse actions and command line options. -----

ACTION=""
DO_BUILD_WIN32=""
DO_BUILD_WIN64=""
DO_BUILD_DEB32=""
DO_BUILD_DEB64=""
DO_BUILD_OSX=""
helper_script_path=""
do_no_strip=""
do_no_pdf=""
do_develop=""

while [ $# -gt 0 ]
do
  case "$1" in

    clean|cleanall|pull|checkout-dev|checkout-stable|build-images|preload-images|bootstrap)
      ACTION="$1"
      shift
      ;;

    --win32|--window32)
      DO_BUILD_WIN32="y"
      shift
      ;;
    --win64|--windows64)
      DO_BUILD_WIN64="y"
      shift
      ;;
    --deb32|--debian32)
      DO_BUILD_DEB32="y"
      shift
      ;;
    --deb64|--debian64)
      DO_BUILD_DEB64="y"
      shift
      ;;
    --osx)
      DO_BUILD_OSX="y"
      shift
      ;;

    --all)
      DO_BUILD_WIN32="y"
      DO_BUILD_WIN64="y"
      DO_BUILD_DEB32="y"
      DO_BUILD_DEB64="y"
      DO_BUILD_OSX="y"
      shift
      ;;

    --helper-script)
      helper_script_path=$2
      shift 2
      ;;

    --no-strip)
      do_no_strip="y"
      shift
      ;;

    --no-pdf)
      do_no_pdf="y"
      shift
      ;;

    --develop)
      do_develop="y"
      shift
      ;;

    --help)
      echo "Build the GNU MCU Eclipse ${APP_NAME} distributions."
      echo "Usage:"
      echo "    bash $0 helper_script [--win32] [--win64] [--deb32] [--deb64] [--osx] [--all] [clean|cleanall|pull|checkout-dev|checkout-stable|build-images] [--help]"
      echo
      exit 1
      ;;

    *)
      echo "Unknown action/option $1"
      exit 1
      ;;
  esac

done

# ----- Prepare build scripts. -----

build_script_path=$0
if [[ "${build_script_path}" != /* ]]
then
  # Make relative path absolute.
  build_script_path=$(pwd)/$0
fi

# Copy the current script to Work area, to later copy it into the install folder.
mkdir -p "${WORK_FOLDER_PATH}/scripts"
cp "${build_script_path}" "${WORK_FOLDER_PATH}/scripts/build-${APP_LC_NAME}.sh"

# ----- Build helper. -----

if [ -z "${helper_script_path}" ]
then
  script_folder_path="$(dirname ${build_script_path})"
  script_folder_name="$(basename ${script_folder_path})"
  if [ \( "${script_folder_name}" == "scripts" \) \
    -a \( -f "${script_folder_path}/helper/build-helper.sh" \) ]
  then
    helper_script_path="${script_folder_path}/helper/build-helper.sh"
  elif [ \( "${script_folder_name}" == "scripts" \) \
    -a \( -d "${script_folder_path}/helper" \) ]
  then
    (
      cd "$(dirname ${script_folder_path})"
      git submodule update --init --recursive --remote
    )
    helper_script_path="${script_folder_path}/helper/build-helper.sh"
  elif [ -f "${WORK_FOLDER_PATH}/scripts/build-helper.sh" ]
  then
    helper_script_path="${WORK_FOLDER_PATH}/scripts/build-helper.sh"
  fi
else
  if [[ "${helper_script_path}" != /* ]]
  then
    # Make relative path absolute.
    helper_script_path="$(pwd)/${helper_script_path}"
  fi
fi

# Copy the current helper script to Work area, to later copy it into the install folder.
mkdir -p "${WORK_FOLDER_PATH}/scripts"
if [ "${helper_script_path}" != "${WORK_FOLDER_PATH}/scripts/build-helper.sh" ]
then
  cp "${helper_script_path}" "${WORK_FOLDER_PATH}/scripts/build-helper.sh"
fi

echo "Helper script: \"${helper_script_path}\"."
source "${helper_script_path}"


# ----- Libraries sources. -----

# For updates, please check the corresponding pages.

# The custom OpenOCD branch is available from the dedicated Git repository
# which is part of the GNU MCU Eclipse project hosted on GitHub.
# Generally this branch follows the official OpenOCD master branch,
# with updates after every OpenOCD public release.

OPENOCD_FOLDER_NAME="openocd.git"
OPENOCD_GIT_URL="https://github.com/gnu-mcu-eclipse/openocd.git"
OPENOCD_GIT_BRANCH="gnu-mcu-eclipse"
OPENOCD_GIT_BRANCH_DEV="gnu-mcu-eclipse-dev"
OPENOCD_GIT_COMMIT="HEAD"

# https://sourceforge.net/projects/libusb/files/libusb-1.0/
# 1.0.20 from 2015-09-14
LIBUSB1_VERSION="1.0.20"
LIBUSB1_FOLDER="libusb-${LIBUSB1_VERSION}"
LIBUSB1="${LIBUSB1_FOLDER}"
LIBUSB1_ARCHIVE="${LIBUSB1}.tar.bz2"


# https://sourceforge.net/projects/libusb/files/libusb-compat-0.1/
# 0.1.5 from 2013-05-21
LIBUSB0_VERSION="0.1.5"
LIBUSB0_FOLDER="libusb-compat-${LIBUSB0_VERSION}"
LIBUSB0="${LIBUSB0_FOLDER}"
LIBUSB0_ARCHIVE="${LIBUSB0_FOLDER}.tar.bz2"


# https://sourceforge.net/projects/libusb-win32/files/libusb-win32-releases/
# 1.2.6.0 from 2012-01-17
LIBUSB_W32_PREFIX="libusb-win32"
LIBUSB_W32_VERSION="1.2.6.0"
LIBUSB_W32="${LIBUSB_W32_PREFIX}-${LIBUSB_W32_VERSION}"
LIBUSB_W32_FOLDER="${LIBUSB_W32_PREFIX}-src-${LIBUSB_W32_VERSION}"
LIBUSB_W32_ARCHIVE="${LIBUSB_W32_FOLDER}.zip"


# http://www.intra2net.com/en/developer/libftdi/download.php
# 1.2 (no date)
LIBFTDI_VERSION="1.2"
LIBFTDI_FOLDER="libftdi1-${LIBFTDI_VERSION}"
LIBFTDI_ARCHIVE="${LIBFTDI_FOLDER}.tar.bz2"
LIBFTDI="${LIBFTDI_FOLDER}"


# https://github.com/signal11/hidapi/downloads
# Oct 26, 2011
# HIDAPI_VERSION="0.7.0"

# https://github.com/signal11/hidapi/archive/hidapi-0.8.0-rc1.zip
# Oct 7, 2013

HIDAPI_VERSION="0.8.0-rc1"
HIDAPI_FOLDER="hidapi-hidapi-${HIDAPI_VERSION}"
HIDAPI="hidapi-${HIDAPI_VERSION}"
HIDAPI_ARCHIVE="${HIDAPI}.zip"

# ----- Define build constants. -----

DOWNLOAD_FOLDER_PATH="${WORK_FOLDER_PATH}/download"
DEPLOY_FOLDER_NAME="deploy"

# ----- Process actions. -----

if [ \( "${ACTION}" == "clean" \) -o \( "${ACTION}" == "cleanall" \) ]
then
  # Remove most build and temporary folders.
  echo
  if [ "${ACTION}" == "cleanall" ]
  then
    echo "Remove all the build folders..."
  else
    echo "Remove most of the build folders (except output)..."
  fi

  rm -rf "${BUILD_FOLDER_PATH}"
  rm -rf "${WORK_FOLDER_PATH}/install"

  rm -rf "${WORK_FOLDER_PATH}/${LIBUSB1_FOLDER}"
  rm -rf "${WORK_FOLDER_PATH}/${LIBUSB0_FOLDER}"
  rm -rf "${WORK_FOLDER_PATH}/${LIBUSB_W32_FOLDER}"
  rm -rf "${WORK_FOLDER_PATH}/${LIBFTDI_FOLDER}"
  rm -rf "${WORK_FOLDER_PATH}/${HIDAPI_FOLDER}"

  rm -rf "${WORK_FOLDER_PATH}/scripts"

  if [ "${ACTION}" == "cleanall" ]
  then
    rm -rf "${PROJECT_GIT_FOLDER_PATH}"
    rm -rf "${WORK_FOLDER_PATH}/${OPENOCD_FOLDER_NAME}"
    rm -rf "${WORK_FOLDER_PATH}/${DEPLOY_FOLDER_NAME}"
  fi

  echo
  echo "Clean completed. Proceed with a regular build."

  exit 0
fi

# ----- Start build. -----

do_host_start_timer

do_host_detect

# ----- Prepare prerequisites. -----

do_host_prepare_prerequisites

# ----- Process "preload-images" action. -----

if [ "${ACTION}" == "preload-images" ]
then
  do_host_prepare_docker

  echo
  echo "Check/Preload Docker images..."

  echo
  docker run --interactive --tty ilegeul/debian32:8-gnuarm-gcc-x11-v3 \
  lsb_release --description --short

  echo
  docker run --interactive --tty ilegeul/debian:8-gnuarm-gcc-x11-v3 \
  lsb_release --description --short

  echo
  docker run --interactive --tty ilegeul/debian:8-gnuarm-mingw \
  lsb_release --description --short

  echo
  docker images

  do_host_stop_timer

  exit 0
fi

do_host_bootstrap() {

  # Prepare autotools.
  echo
  echo "bootstrap..."

  cd "${WORK_FOLDER_PATH}/${OPENOCD_FOLDER_NAME}"
  rm -f aclocal.m4
  ./bootstrap

}

if [ \( "${ACTION}" == "bootstrap" \) ]
then

  do_host_bootstrap

  do_host_stop_timer

  exit 0

fi

# ----- Process "build-images" action. -----

if [ "${ACTION}" == "build-images" ]
then
  do_host_prepare_docker

  # Remove most build and temporary folders.
  echo
  echo "Build Docker images..."

  # Be sure it will not crash on errors, in case the images are already there.
  set +e

  docker build --tag "ilegeul/debian32:8-gnuarm-gcc-x11-v3" \
  https://github.com/ilg-ul/docker/raw/master/debian32/8-gnuarm-gcc-x11-v3/Dockerfile

  docker build --tag "ilegeul/debian:8-gnuarm-gcc-x11-v3" \
  https://github.com/ilg-ul/docker/raw/master/debian/8-gnuarm-gcc-x11-v3/Dockerfile

  docker build --tag "ilegeul/debian:8-gnuarm-mingw" \
  https://github.com/ilg-ul/docker/raw/master/debian/8-gnuarm-mingw/Dockerfile

  docker images

  do_host_stop_timer

  exit 0
fi

# ----- Prepare Docker, if needed. -----

if [ -n "${DO_BUILD_WIN32}${DO_BUILD_WIN64}${DO_BUILD_DEB32}${DO_BUILD_DEB64}" ]
then
  do_host_prepare_docker
fi

# ----- Check some more prerequisites. -----

echo
echo "Checking host automake..."
automake --version 2>/dev/null | grep automake

echo
echo "Checking host patch..."
patch --version | grep patch

echo
echo "Checking host tar..."
tar --version

echo
echo "Checking host unzip..."
unzip | grep UnZip

echo
echo "Checking host makeinfo..."
makeinfo --version | grep 'GNU texinfo'
makeinfo_ver=$(makeinfo --version | grep 'GNU texinfo' | sed -e 's/.*) //' -e 's/\..*//')
if [ "${makeinfo_ver}" -lt "6" ]
then
  echo "makeinfo too old, abort."
  exit 1
fi

if which libtoolize > /dev/null; then
    libtoolize="libtoolize"
elif which glibtoolize >/dev/null; then
    libtoolize="glibtoolize"
else
    echo "$0: Error: libtool is required" >&2
    exit 1
fi

# ----- Get the project git repository. -----

if [ ! -d "${PROJECT_GIT_FOLDER_PATH}" ]
then

  cd "${WORK_FOLDER_PATH}"

  echo "If asked, enter ${USER} GitHub password for git clone"
  git clone "${PROEJCT_GIT_URL}" "${PROJECT_GIT_FOLDER_PATH}"

fi

# ----- Process "pull|checkout-dev|checkout-stable" actions. -----

do_repo_action() {

  # $1 = action (pull, checkout-dev, checkout-stable)

  # Update current branch and prepare autotools.
  echo
  if [ "${ACTION}" == "pull" ]
  then
    echo "Running git pull..."
  elif [ "${ACTION}" == "checkout-dev" ]
  then
    echo "Running git checkout gnu-mcu-eclipse-dev & pull..."
  elif [ "${ACTION}" == "checkout-stable" ]
  then
    echo "Running git checkout gnu-mcu-eclipse & pull..."
  fi

  if [ -d "${PROJECT_GIT_FOLDER_PATH}" ]
  then
    echo
    if [ "${USER}" == "ilg" ]
    then
      echo "If asked, enter ${USER} GitHub password for git pull"
    fi

    cd "${PROJECT_GIT_FOLDER_PATH}"

    if [ "${ACTION}" == "checkout-dev" ]
    then
      git checkout gnu-mcu-eclipse-dev
    elif [ "${ACTION}" == "checkout-stable" ]
    then
      git checkout gnu-mcu-eclipse
    fi

    if false
    then

      git pull --recurse-submodules
      git submodule update --init --recursive --remote

      git branch

      do_host_bootstrap

      rm -rf "${BUILD_FOLDER_PATH}/${APP_LC_NAME}"

      echo
      if [ "${ACTION}" == "pull" ]
      then
        echo "Pull completed. Proceed with a regular build."
      else
        echo "Checkout completed. Proceed with a regular build."
      fi

    else

      echo "Not implemented."
      exit 1

    fi

    exit 0
  else
	echo "No git folder."
    exit 1
  fi

}

# For this to work, the following settings are required:
# git branch --set-upstream-to=origin/gnu-mcu-eclipse-dev gnu-mcu-eclipse-dev
# git branch --set-upstream-to=origin/gnu-mcu-eclipse gnu-mcu-eclipse

case "${ACTION}" in
  pull|checkout-dev|checkout-stable)
    do_repo_action "${ACTION}"
    ;;
esac

# ----- Get the current Git branch name. -----

# Get the current Git branch name, to know if we are building the stable or
# the development release.
do_host_get_git_head

# ----- Get current date. -----

# Use the UTC date as version in the name of the distribution file.
do_host_get_current_date

# ----- Get OPENOCD. -----

if [ ! -d "${WORK_FOLDER_PATH}/${OPENOCD_FOLDER_NAME}" ]
then

  echo
  echo "Cloning '${OPENOCD_GIT_URL}'..."

  cd "${WORK_FOLDER_PATH}"
  git clone --branch "${OPENOCD_GIT_BRANCH_DEV}" "${OPENOCD_GIT_URL}" "${OPENOCD_FOLDER_NAME}"
  cd "${OPENOCD_FOLDER_NAME}"
  git checkout -qf "${OPENOCD_GIT_COMMIT}"

  git submodule update --init --recursive --remote

  git branch

  do_host_bootstrap

fi

# ----- Get the USB libraries. -----

# Both USB libraries are available from a single project LIBUSB
# 	http://www.libusb.info
# with source files ready to download from SourceForge
# 	https://sourceforge.net/projects/libusb/files

# Download the new USB library.
if [ ! -f "${DOWNLOAD_FOLDER_PATH}/${LIBUSB1_ARCHIVE}" ]
then
  mkdir -p "${DOWNLOAD_FOLDER_PATH}"

  echo
  echo "Downloading \"${LIBUSB1_ARCHIVE}\"..."

  cd "${DOWNLOAD_FOLDER_PATH}"
  curl -L "http://sourceforge.net/projects/libusb/files/libusb-1.0/${LIBUSB1_FOLDER}/${LIBUSB1_ARCHIVE}" \
    --output "${LIBUSB1_ARCHIVE}"
fi

# Unpack the new USB library.
if [ ! -d "${WORK_FOLDER_PATH}/${LIBUSB1_FOLDER}" ]
then
  cd "${WORK_FOLDER_PATH}"
  tar -xjvf "${DOWNLOAD_FOLDER_PATH}/${LIBUSB1_ARCHIVE}"
fi

# http://www.libusb.org

# Download the old USB library.
if [ ! -f "${DOWNLOAD_FOLDER_PATH}/${LIBUSB0_ARCHIVE}" ]
then
  mkdir -p "${DOWNLOAD_FOLDER_PATH}"

  echo
  echo "Downloading \"${LIBUSB0_ARCHIVE}\"..."

  cd "${DOWNLOAD_FOLDER_PATH}"
  curl -L "http://sourceforge.net/projects/libusb/files/libusb-compat-0.1/${LIBUSB0_FOLDER}/${LIBUSB0_ARCHIVE}" \
    --output "${LIBUSB0_ARCHIVE}"
fi

# Unpack the old USB library.
if [ ! -d "${WORK_FOLDER_PATH}/${LIBUSB0_FOLDER}" ]
then
  cd "${WORK_FOLDER_PATH}"
  tar -xjvf "${DOWNLOAD_FOLDER_PATH}/${LIBUSB0_ARCHIVE}"
fi

# https://sourceforge.net/projects/libusb-win32

# Download the old Win32 USB library.
if [ ! -f "${DOWNLOAD_FOLDER_PATH}/${LIBUSB_W32_ARCHIVE}" ]
then
  mkdir -p "${DOWNLOAD_FOLDER_PATH}"

  echo
  echo "Downloading \"${LIBUSB_W32_ARCHIVE}\"..."

  cd "${DOWNLOAD_FOLDER_PATH}"
  curl -L "http://sourceforge.net/projects/libusb-win32/files/libusb-win32-releases/${LIBUSB_W32_VERSION}/${LIBUSB_W32_ARCHIVE}" \
    --output "${LIBUSB_W32_ARCHIVE}"
fi

# Unpack the old Win32 USB library.
if [ ! -d "${WORK_FOLDER_PATH}/${LIBUSB_W32_FOLDER}" ]
then
  cd "${WORK_FOLDER_PATH}"
  unzip "${DOWNLOAD_FOLDER_PATH}/${LIBUSB_W32_ARCHIVE}"
fi


# ----- Get the FTDI library. -----

# There are two versions of the FDDI library; we recommend using the
# open source one, available from intra2net.
#	http://www.intra2net.com/en/developer/libftdi/

# Download the FTDI library.
if [ ! -f "${DOWNLOAD_FOLDER_PATH}/${LIBFTDI_ARCHIVE}" ]
then
  mkdir -p "${DOWNLOAD_FOLDER_PATH}"

  echo
  echo "Downloading \"${LIBFTDI_ARCHIVE}\"..."

  cd "${DOWNLOAD_FOLDER_PATH}"
  curl -L "http://www.intra2net.com/en/developer/libftdi/download/${LIBFTDI_ARCHIVE}" \
    --output "${LIBFTDI_ARCHIVE}"
fi

# Unpack the FTDI library.
if [ ! -d "${WORK_FOLDER_PATH}/${LIBFTDI_FOLDER}" ]
then
  echo
  echo "Unpacking \"${LIBFTDI_ARCHIVE}\"..."

  cd "${WORK_FOLDER_PATH}"
  tar -xjvf "${DOWNLOAD_FOLDER_PATH}/${LIBFTDI_ARCHIVE}"

  echo
  echo "Patching \"${LIBFTDI_FOLDER}\"..."

  cd "${WORK_FOLDER_PATH}/${LIBFTDI_FOLDER}"
  # Patch to prevent the use of system libraries and force the use of local ones.
  patch -p0 < "${PROJECT_GIT_FOLDER_PATH}/gnu-mcu-eclipse/patches/${LIBFTDI}-cmake-FindUSB1.patch"
fi

# ----- Get the HDI library. -----

# This is just a simple wrapper over libusb.
# http://www.signal11.us/oss/hidapi/

# Download the HDI library.
if [ ! -f "${DOWNLOAD_FOLDER_PATH}/${HIDAPI_ARCHIVE}" ]
then
  mkdir -p "${DOWNLOAD_FOLDER_PATH}"

  cd "${DOWNLOAD_FOLDER_PATH}"
  echo
  echo "Downloading \"${HIDAPI_ARCHIVE}\"..."

  # https://github.com/downloads/signal11/hidapi
  # https://github.com/signal11/hidapi/archive/
  curl -L "https://github.com/signal11/hidapi/archive//${HIDAPI_ARCHIVE}" \
    --output "${HIDAPI_ARCHIVE}"
fi

# Unpack the HDI library.
if [ ! -d "${WORK_FOLDER_PATH}/${HIDAPI_FOLDER}" ]
then
  cd "${WORK_FOLDER_PATH}"
  unzip "${DOWNLOAD_FOLDER_PATH}/${HIDAPI_ARCHIVE}"
fi


# v===========================================================================v
# Create the build script (needs to be separate for Docker).

script_name="build.sh"
script_file_path="${WORK_FOLDER_PATH}/scripts/${script_name}"

rm -f "${script_file_path}"
mkdir -p "$(dirname ${script_file_path})"
touch "${script_file_path}"

# Note: EOF is quoted to prevent substitutions here.
cat <<'EOF' >> "${script_file_path}"
#!/usr/bin/env bash

# -----------------------------------------------------------------------------
# Safety settings (see https://gist.github.com/ilg-ul/383869cbb01f61a51c4d).

if [[ ! -z ${DEBUG} ]]
then
  set -x # Activate the expand mode if DEBUG is anything but empty.
else
  DEBUG=""
fi

set -o errexit # Exit if command failed.
set -o pipefail # Exit if pipe failed.
set -o nounset # Exit if variable not set.

# Remove the initial space and instead use '\n'.
IFS=$'\n\t'

# -----------------------------------------------------------------------------

EOF
# The above marker must start in the first column.

# Note: EOF is not quoted to allow local substitutions.
cat <<EOF >> "${script_file_path}"

APP_NAME="${APP_NAME}"
APP_LC_NAME="${APP_LC_NAME}"
APP_UC_NAME="${APP_UC_NAME}"
GIT_HEAD="${GIT_HEAD}"
DISTRIBUTION_FILE_DATE="${DISTRIBUTION_FILE_DATE}"
PROJECT_GIT_FOLDER_NAME="${PROJECT_GIT_FOLDER_NAME}"
OPENOCD_FOLDER_NAME="${OPENOCD_FOLDER_NAME}"

LIBUSB1_FOLDER="${LIBUSB1_FOLDER}"
LIBUSB0_FOLDER="${LIBUSB0_FOLDER}"
LIBUSB_W32="${LIBUSB_W32}"
LIBUSB_W32_FOLDER="${LIBUSB_W32_FOLDER}"
LIBFTDI_FOLDER="${LIBFTDI_FOLDER}"
HIDAPI_FOLDER="${HIDAPI_FOLDER}"
HIDAPI="${HIDAPI}"

do_no_strip="${do_no_strip}"

EOF
# The above marker must start in the first column.

# Propagate DEBUG to guest.
set +u
if [[ ! -z ${DEBUG} ]]
then
  echo "DEBUG=${DEBUG}" "${script_file_path}"
  echo
fi
set -u

# Note: EOF is quoted to prevent substitutions here.
cat <<'EOF' >> "${script_file_path}"

PKG_CONFIG_LIBDIR=${PKG_CONFIG_LIBDIR:-""}

# For just in case.
export LC_ALL="C"
export CONFIG_SHELL="/bin/bash"

jobs="--jobs=8"

script_name="$(basename "$0")"
args="$@"
docker_container_name=""

while [ $# -gt 0 ]
do
  case "$1" in
    --build-folder)
      build_folder_path="$2"
      shift 2
      ;;
    --docker-container-name)
      docker_container_name="$2"
      shift 2
      ;;
    --target-name)
      target_name="$2"
      shift 2
      ;;
    --target-bits)
      target_bits="$2"
      shift 2
      ;;
    --work-folder)
      work_folder_path="$2"
      shift 2
      ;;
    --output-folder)
      output_folder_path="$2"
      shift 2
      ;;
    --distribution-folder)
      distribution_folder="$2"
      shift 2
      ;;
    --install-folder)
      install_folder="$2"
      shift 2
      ;;
    --download-folder)
      download_folder="$2"
      shift 2
      ;;
    --helper-script)
      helper_script_path="$2"
      shift 2
      ;;
    --group-id)
      group_id="$2"
      shift 2
      ;;
    --user-id)
      user_id="$2"
      shift 2
      ;;
    --host-uname)
      host_uname="$2"
      shift 2
      ;;
    *)
      echo "Unknown option $1, exit."
      exit 1
  esac
done

git_folder_path="${work_folder_path}/${PROJECT_GIT_FOLDER_NAME}"

echo
uname -a

# Run the helper script in this shell, to get the support functions.
source "${helper_script_path}"

target_folder=${target_name}${target_bits:-""}

if [ "${target_name}" == "win" ]
then

  # For Windows targets, decide which cross toolchain to use.
  if [ ${target_bits} == "32" ]
  then
    cross_compile_prefix="i686-w64-mingw32"
  elif [ ${target_bits} == "64" ]
  then
    cross_compile_prefix="x86_64-w64-mingw32"
  fi

elif [ "${target_name}" == "osx" ]
then

  target_bits="64"

fi

mkdir -p "${build_folder_path}"
cd "${build_folder_path}"

# ----- Test if various tools are present -----

echo
echo "Checking automake..."
automake --version 2>/dev/null | grep automake

echo "Checking cmake..."
cmake --version | grep cmake

echo "Checking pkg-config..."
pkg-config --version

if [ "${target_name}" != "osx" ]
then
  echo "Checking readelf..."
  readelf --version | grep readelf
fi

if [ "${target_name}" == "win" ]
then
  echo "Checking ${cross_compile_prefix}-gcc..."
  ${cross_compile_prefix}-gcc --version 2>/dev/null | egrep -e 'gcc|clang'

  echo "Checking unix2dos..."
  unix2dos --version 2>&1 | grep unix2dos

  echo "Checking makensis..."
  echo "makensis $(makensis -VERSION)"

  apt-get --yes install zip

  echo "Checking zip..."
  zip -v | grep "This is Zip"
else
  echo "Checking gcc..."
  gcc --version 2>/dev/null | egrep -e 'gcc|clang'
fi

if [ "${target_name}" == "debian" ]
then
  echo "Checking patchelf..."
  patchelf --version
fi

echo "Checking shasum..."
shasum --version

# ----- Recreate the output folder. -----

# rm -rf "${output_folder_path}"
mkdir -p "${output_folder_path}"

# ----- Build and install the new USB library. -----

libusb1_stamp_file="${build_folder_path}/${LIBUSB1_FOLDER}/stamp-install-completed"

# if [ ! \( -f "${install_folder}/lib/libusb-1.0.a" -o \
#          -f "${install_folder}/lib64/libusb-1.0.a" \) ]
if [ ! -f "${libusb1_stamp_file}" ]
then

  rm -rfv "${build_folder_path}/${LIBUSB1_FOLDER}"
  mkdir -p "${build_folder_path}/${LIBUSB1_FOLDER}"

  mkdir -p "${install_folder}"

  echo
  echo "Running configure libusb1..."

  cd "${build_folder_path}/${LIBUSB1_FOLDER}"

  if [ "${target_name}" == "win" ]
  then
    CFLAGS="-Wno-non-literal-null-conversion -m${target_bits} -pipe" \
    PKG_CONFIG="${git_folder_path}/gnu-mcu-eclipse/scripts/cross-pkg-config" \
    "${work_folder_path}/${LIBUSB1_FOLDER}/configure" \
      --host="${cross_compile_prefix}" \
      --prefix="${install_folder}"
  else
    CFLAGS="-Wno-non-literal-null-conversion -Wno-deprecated-declarations -m${target_bits} -pipe" \
    PKG_CONFIG="${git_folder_path}/gnu-mcu-eclipse/scripts/cross-pkg-config" \
    "${work_folder_path}/${LIBUSB1_FOLDER}/configure" \
      --prefix="${install_folder}"
  fi

  echo
  echo "Running make libusb1..."

  # Build.
  make "${jobs}" clean install

  if [ "${target_name}" == "win" ]
  then
    # Remove DLLs to force static link for final executable.
    rm -f "${install_folder}/bin/libusb-1.0.dll"
    rm -f "${install_folder}/lib/libusb-1.0.dll.a"
    rm -f "${install_folder}/lib/libusb-1.0.la"
  fi

  touch "${libusb1_stamp_file}"
fi

# ----- Build and install the old USB library. -----

libusb0_stamp_file="${build_folder_path}/${LIBUSB0_FOLDER}/stamp-install-completed"

# if [ \( "${target_name}" != "win" \) -a \
#     ! \( -f "${install_folder}/lib/libusb.a" -o \
#          -f "${install_folder}/lib64/libusb.a" \) ]
if [ \( "${target_name}" != "win" \) -a \
    ! \( -f "${libusb0_stamp_file}" \) ]
then

  rm -rf "${build_folder_path}/${LIBUSB0_FOLDER}"
  mkdir -p "${build_folder_path}/${LIBUSB0_FOLDER}"

  mkdir -p "${install_folder}"

  echo
  echo "Running configure libusb0..."

  cd "${build_folder_path}/${LIBUSB0_FOLDER}"

  CFLAGS="-Werror -m${target_bits} -pipe" \
  \
  PKG_CONFIG_LIBDIR=\
"${install_folder}/lib/pkgconfig":\
"${install_folder}/lib64/pkgconfig" \
  \
  "${work_folder_path}/${LIBUSB0_FOLDER}/configure" \
    --prefix="${install_folder}"

  echo
  echo "Running make libusb0..."

  # Build.
  make "${jobs}" clean install

  touch "${libusb0_stamp_file}"
fi

# ----- Build and install the old Win32 USB library. -----

libusb_w32_stamp_file="${build_folder_path}/${LIBUSB_W32}/stamp-install-completed"

# if [ \( "${target_name}" == "win" \) -a \
#      ! \( -f "${install_folder}/lib/libusb.a" -o \
#           -f "${install_folder}/lib64/libusb.a" \)  ]
if [ \( "${target_name}" == "win" \) -a \
     ! \( -f "${libusb_w32_stamp_file}" \)  ]
then

  mkdir -p "${build_folder_path}/${LIBUSB_W32}"

  cd "${build_folder_path}/${LIBUSB_W32}"
  cp -r "${work_folder_path}/${LIBUSB_W32_FOLDER}/"* \
    "${build_folder_path}/${LIBUSB_W32}"

  echo
  echo "Running make libusb-win32..."

  cd "${build_folder_path}/${LIBUSB_W32}"

  # Patch from:
  # https://gitorious.org/jtag-tools/openocd-mingw-build-scripts

  # The conversions are needed to avoid errors like:
  # 'Hunk #1 FAILED at 31 (different line endings).'
  dos2unix src/install.c
  dos2unix src/install_filter_win.c
  dos2unix src/registry.c
  patch -p1 < "${git_folder_path}/gnu-mcu-eclipse/patches/${LIBUSB_W32}-mingw-w64.patch"

  # Build.
  CFLAGS="-Wno-unknown-pragmas -Wno-unused-variable -Wno-pointer-sign -Wno-unused-but-set-variable -Werror -m${target_bits} -pipe" \
  make host_prefix=${cross_compile_prefix} host_prefix_x86=i686-w64-mingw32 dll

  mkdir -p "${install_folder}/bin"
  cp -v "${build_folder_path}/${LIBUSB_W32}/libusb0.dll" \
     "${install_folder}/bin"

  mkdir -p "${install_folder}/lib"
  cp -v "${build_folder_path}/${LIBUSB_W32}/libusb.a" \
     "${install_folder}/lib"

  mkdir -p "${install_folder}/lib/pkgconfig"
  sed -e "s|XXX|${install_folder}|" \
    "${git_folder_path}/gnu-mcu-eclipse/pkgconfig/${LIBUSB_W32}.pc" \
    > "${install_folder}/lib/pkgconfig/libusb.pc"

  mkdir -p "${install_folder}/include/libusb"
  cp -v "${build_folder_path}/${LIBUSB_W32}/src/lusb0_usb.h" \
     "${install_folder}/include/libusb/usb.h"

  touch "${libusb_w32_stamp_file}"
fi

# ----- Build and install the FTDI library. -----

libftdi_stamp_file="${build_folder_path}/${LIBFTDI_FOLDER}/stamp-install-completed"

# if [ ! \( -f "${install_folder}/lib/libftdi1.a" -o \
#            -f "${install_folder}/lib64/libftdi1.a" \)  ]
if [ ! -f "${libftdi_stamp_file}" ]
then

  rm -rfv "${build_folder_path}/${LIBFTDI_FOLDER}"
  mkdir -p "${build_folder_path}/${LIBFTDI_FOLDER}"

  mkdir -p "${install_folder}"

  echo
  echo "Running cmake libftdi..."

  cd "${build_folder_path}/${LIBFTDI_FOLDER}"

  if [ "${target_name}" == "win" ]
  then

    # Configure.
    CFLAGS="-Werror -m${target_bits} -pipe" \
    \
    PKG_CONFIG_LIBDIR=\
"${install_folder}/lib/pkgconfig":\
"${install_folder}/lib64/pkgconfig" \
    \
    cmake \
    -DPKG_CONFIG_EXECUTABLE="${git_folder_path}/gnu-mcu-eclipse/scripts/cross-pkg-config" \
    -DCMAKE_TOOLCHAIN_FILE="${work_folder_path}/${LIBFTDI_FOLDER}/cmake/Toolchain-${cross_compile_prefix}.cmake" \
    -DCMAKE_INSTALL_PREFIX="${install_folder}" \
    -DLIBUSB_INCLUDE_DIR="${install_folder}/include/libusb-1.0" \
    -DLIBUSB_LIBRARIES="${install_folder}/lib/libusb-1.0.a" \
    -DBUILD_TESTS:BOOL=off \
    -DFTDIPP:BOOL=off \
    -DPYTHON_BINDINGS:BOOL=off \
    -DEXAMPLES:BOOL=off \
    -DDOCUMENTATION:BOOL=off \
    -DFTDI_EEPROM:BOOL=off \
    "${work_folder_path}/${LIBFTDI_FOLDER}"

  else

    CFLAGS="-Werror -m${target_bits} -pipe" \
    \
    PKG_CONFIG_LIBDIR=\
"${install_folder}/lib/pkgconfig":\
"${install_folder}/lib64/pkgconfig" \
    \
    cmake \
    -DCMAKE_INSTALL_PREFIX="${install_folder}" \
    -DBUILD_TESTS:BOOL=off \
    -DFTDIPP:BOOL=off \
    -DPYTHON_BINDINGS:BOOL=off \
    -DEXAMPLES:BOOL=off \
    -DDOCUMENTATION:BOOL=off \
    -DFTDI_EEPROM:BOOL=off \
    "${work_folder_path}/${LIBFTDI_FOLDER}"

  fi

  echo
  echo "Running make libftdi..."

  # Build.
  make "${jobs}" clean install

  if [ "${target_name}" == "win" ]
  then
    # Remove DLLs to force static link for final executable.
    rm -f "${install_folder}/bin/libftdi1.dll"
    rm -f "${install_folder}/bin/libftdi1-config"
    rm -f "${install_folder}/lib/libftdi1.dll.a"
    rm -f "${install_folder}/lib/pkgconfig/libftdipp1.pc"
  fi

  touch "${libftdi_stamp_file}"
fi


# ----- Build the new HDI library. -----

libhdi_stamp_file="${build_folder_path}/${HIDAPI_FOLDER}/stamp-install-completed"

if [ "${target_name}" == "win" ]
then
  HIDAPI_TARGET="windows"
  HIDAPI_OBJECT="hid.o"
  HIDAPI_A="libhid.a"
elif [ "${target_name}" == "osx" ]
then
  HIDAPI_TARGET="mac"
  HIDAPI_A="libhidapi.a"
elif [ "${target_name}" == "debian" ]
then
  HIDAPI_TARGET="linux"
  HIDAPI_A="libhidapi-hidraw.a"
fi

# if [ ! -f "${install_folder}/lib/${HIDAPI_A}" ]
if [ ! -f "${libhdi_stamp_file}" ]
then

  rm -rfv "${build_folder_path}/${HIDAPI_FOLDER}"
  mkdir -p "${build_folder_path}/${HIDAPI_FOLDER}"

  cp -r "${work_folder_path}/${HIDAPI_FOLDER}/"* \
    "${build_folder_path}/${HIDAPI_FOLDER}"

  echo
  echo "Running make libhid..."

  if [ "${target_name}" == "win" ]
  then

    cd "${build_folder_path}/${HIDAPI_FOLDER}/${HIDAPI_TARGET}"

    CFLAGS="-Werror -m${target_bits} -pipe" \
    \
    PKG_CONFIG_LIBDIR="${install_folder}/lib/pkgconfig":"${install_folder}/lib64/pkgconfig" \
    \
    make -f Makefile.mingw \
    CC=${cross_compile_prefix}-gcc \
    "${HIDAPI_OBJECT}"

    # Make just compiles the file. Create the archive and convert it to library.
    # No dynamic/shared libs involved.
    ar -r  libhid.a "${HIDAPI_OBJECT}"
    ${cross_compile_prefix}-ranlib libhid.a

    mkdir -p "${install_folder}/lib"
    cp -v libhid.a \
      "${install_folder}/lib"

    mkdir -p "${install_folder}/lib/pkgconfig"
    sed -e "s|XXX|${install_folder}|" \
      "${git_folder_path}/gnu-mcu-eclipse/pkgconfig/${HIDAPI}-${HIDAPI_TARGET}.pc" \
      > "${install_folder}/lib/pkgconfig/hidapi.pc"

    mkdir -p "${install_folder}/include/hidapi"
    cp -v "${work_folder_path}/${HIDAPI_FOLDER}/hidapi/hidapi.h" \
      "${install_folder}/include/hidapi"

  elif [ "${target_name}" == "debian" ]
  then

    if [ ${target_bits} == "64" ]
    then
      cp /usr/include/libudev.h "${install_folder}/include"
      cp /usr/lib/x86_64-linux-gnu/libudev.so  "${install_folder}/lib"
      cp /usr/lib/x86_64-linux-gnu/pkgconfig/libudev.pc "${install_folder}/lib/pkgconfig"
    elif [ ${target_bits} == "32" ] 
    then
      cp /usr/include/libudev.h "${install_folder}/include"
      cp /lib/i386-linux-gnu/libudev.so  "${install_folder}/lib"
      cp /usr/lib/i386-linux-gnu/pkgconfig/libudev.pc "${install_folder}/lib/pkgconfig"
    fi

    cd "${build_folder_path}/${HIDAPI_FOLDER}"

    ./bootstrap

    CFLAGS="-Werror -m${target_bits} -pipe" \
    \
    PKG_CONFIG_LIBDIR="${install_folder}/lib/pkgconfig":"${install_folder}/lib64/pkgconfig" \
    \
    ./configure --prefix="${install_folder}"

    make "${jobs}" 
    make "${jobs}" install

  elif [ "${target_name}" == "osx" ]
  then

    cd "${build_folder_path}/${HIDAPI_FOLDER}"

    ./bootstrap

    CFLAGS="-Werror -m${target_bits} -pipe" \
    \
    PKG_CONFIG_LIBDIR="${install_folder}/lib/pkgconfig":"${install_folder}/lib64/pkgconfig" \
    \
    ./configure --prefix="${install_folder}"

    make "${jobs}"
    make "${jobs}" install

  fi

  touch "${libhdi_stamp_file}"
fi

# Create the build folder.
mkdir -p "${build_folder_path}/openocd"

# ----- Configure OpenOCD. Use the same options as Freddie Chopin. -----

if [ ! -f "${build_folder_path}/${APP_LC_NAME}/config.h" ]
then

  echo
  echo "Running configure OpenOCD..."

  # Deprecated:
  # --enable-ioutil
  # --enable-oocd_trace
  # --enable-zy1000
  # --enable-legacy-ft2232_libftdi

  if [ "${target_name}" == "win" ]
  then

    cd "${build_folder_path}/openocd"

    # --enable-minidriver-dummy -> configure error
    # --enable-buspirate -> not supported on mingw
    # --enable-zy1000 -> netinet/tcp.h: No such file or directory
    # --enable-sysfsgpio -> available only on Linux

    # --enable-openjtag_ftdi -> --enable-openjtag
    # --enable-presto_libftdi -> --enable-presto
    # --enable-usb_blaster_libftdi -> --enable-usb_blaster

    # All variables below are passed on the command line before 'configure'.
    # Be sure all these lines end in '\' to ensure lines are concatenated.
    OUTPUT_DIR="${build_folder_path}" \
    \
    CPPFLAGS="-Werror -m${target_bits} -pipe" \
    PKG_CONFIG="${git_folder_path}/gnu-mcu-eclipse/scripts/cross-pkg-config" \
    PKG_CONFIG_LIBDIR="${install_folder}/lib/pkgconfig" \
    PKG_CONFIG_PREFIX="${install_folder}" \
    \
    bash "${work_folder_path}/${OPENOCD_FOLDER_NAME}/configure" \
    --build="$(uname -m)-linux-gnu" \
    --host="${cross_compile_prefix}" \
    --prefix="${install_folder}/openocd"  \
    --datarootdir="${install_folder}" \
    --infodir="${install_folder}/${APP_LC_NAME}/info"  \
    --localedir="${install_folder}/${APP_LC_NAME}/locale"  \
    --mandir="${install_folder}/${APP_LC_NAME}/man"  \
    --docdir="${install_folder}/${APP_LC_NAME}/doc"  \
    --disable-wextra \
    --disable-werror \
    --enable-dependency-tracking \
    \
    --enable-branding="GNU MCU Eclipse" \
    \
    --enable-aice \
    --enable-amtjtagaccel \
    --enable-armjtagew \
    --enable-at91rm9200 \
    --enable-bcm2835gpio \
    --disable-buspirate \
    --enable-cmsis-dap \
    --enable-dummy \
    --enable-ep93xx \
    --enable-ftdi \
    --enable-gw16012 \
    --disable-ioutil \
    --enable-jlink \
    --enable-jtag_vpi \
    --disable-minidriver-dummy \
    --disable-oocd_trace \
    --enable-opendous \
    --enable-openjtag \
    --enable-osbdm \
    --enable-parport \
    --disable-parport-ppdev \
    --enable-parport-giveio \
    --enable-presto \
    --enable-remote-bitbang \
    --enable-riscv \
    --enable-rlink \
    --enable-stlink \
    --disable-sysfsgpio \
    --enable-ti-icdi \
    --enable-ulink \
    --enable-usb_blaster \
    --enable-usb-blaster-2 \
    --enable-usbprog \
    --enable-vsllink \
    --disable-zy1000-master \
    --disable-zy1000 \
    | tee "${output_folder_path}/configure-output.txt"
    # Note: don't forget to update the INFO.txt file after changing these.

  elif [ "${target_name}" == "debian" ]
  then

    LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-""}

    cd "${build_folder_path}/openocd"

    # --enable-minidriver-dummy -> configure error

    # --enable-openjtag_ftdi -> --enable-openjtag
    # --enable-presto_libftdi -> --enable-presto
    # --enable-usb_blaster_libftdi -> --enable-usb_blaster

    # All variables below are passed on the command line before 'configure'.
    # Be sure all these lines end in '\' to ensure lines are concatenated.
    # On some machines libftdi ends in lib64, so we refer both lib & lib64
    CPPFLAGS="-m${target_bits} -pipe" \
    LDFLAGS='-Wl,-lpthread' \
    \
    PKG_CONFIG_LIBDIR="${install_folder}/lib/pkgconfig":"${install_folder}/lib64/pkgconfig" \
    \
    LD_LIBRARY_PATH="${install_folder}/lib":"${install_folder}/lib64":"${LD_LIBRARY_PATH}" \
    \
    bash "${work_folder_path}/${OPENOCD_FOLDER_NAME}/configure" \
    --prefix="${install_folder}/openocd"  \
    --datarootdir="${install_folder}" \
    --infodir="${install_folder}/${APP_LC_NAME}/info"  \
    --localedir="${install_folder}/${APP_LC_NAME}/locale"  \
    --mandir="${install_folder}/${APP_LC_NAME}/man"  \
    --docdir="${install_folder}/${APP_LC_NAME}/doc"  \
    --disable-wextra \
    --disable-werror \
    --enable-dependency-tracking \
    \
    --enable-branding="GNU MCU Eclipse" \
    \
    --enable-aice \
    --enable-amtjtagaccel \
    --enable-armjtagew \
    --enable-at91rm9200 \
    --enable-bcm2835gpio \
    --enable-buspirate \
    --enable-cmsis-dap \
    --enable-dummy \
    --enable-ep93xx \
    --enable-ftdi \
    --enable-gw16012 \
    --disable-ioutil \
    --enable-jlink \
    --enable-jtag_vpi \
    --disable-minidriver-dummy \
    --disable-oocd_trace \
    --enable-opendous \
    --enable-openjtag \
    --enable-osbdm \
    --enable-parport \
    --disable-parport-ppdev \
    --enable-parport-giveio \
    --enable-presto \
    --enable-remote-bitbang \
    --enable-riscv \
    --enable-rlink \
    --enable-stlink \
    --enable-sysfsgpio \
    --enable-ti-icdi \
    --enable-ulink \
    --enable-usb_blaster \
    --enable-usb-blaster-2 \
    --enable-usbprog \
    --enable-vsllink \
    --disable-zy1000-master \
    --disable-zy1000 \
    | tee "${output_folder_path}/configure-output.txt"
    # Note: don't forget to update the INFO.txt file after changing these.

  elif [ "${target_name}" == "osx" ]
  then

    DYLD_LIBRARY_PATH=${DYLD_LIBRARY_PATH:-""}

    cd "${build_folder_path}/openocd"

    # --enable-minidriver-dummy -> configure error
    # --enable-sysfsgpio -> available only on Linux
    # --enable-amtjtagaccel -> 'sys/io.h' file not found
    # --enable-gw16012 -> 'sys/io.h' file not found

    # --enable-openjtag_ftdi -> --enable-openjtag
    # --enable-presto_libftdi -> --enable-presto
    # --enable-usb_blaster_libftdi -> --enable-usb_blaster

    # All variables below are passed on the command line before 'configure'.
    # Be sure all these lines end in '\' to ensure lines are concatenated.
    CPPFLAGS="-Werror -m${target_bits} -pipe" \
    \
    PKG_CONFIG_LIBDIR="${install_folder}/lib/pkgconfig":"${install_folder}/lib64/pkgconfig" \
    \
    DYLD_LIBRARY_PATH="${install_folder}/lib":"${DYLD_LIBRARY_PATH}" \
    \
    bash "${work_folder_path}/${OPENOCD_FOLDER_NAME}/configure" \
    --prefix="${install_folder}/openocd"  \
    --datarootdir="${install_folder}" \
    --infodir="${install_folder}/${APP_LC_NAME}/info"  \
    --localedir="${install_folder}/${APP_LC_NAME}/locale"  \
    --mandir="${install_folder}/${APP_LC_NAME}/man"  \
    --docdir="${install_folder}/${APP_LC_NAME}/doc"  \
    --disable-wextra \
    --disable-werror \
    --enable-dependency-tracking \
    \
    --enable-branding="GNU MCU Eclipse" \
    \
    --enable-aice \
    --disable-amtjtagaccel \
    --enable-armjtagew \
    --enable-at91rm9200 \
    --enable-bcm2835gpio \
    --enable-buspirate \
    --enable-cmsis-dap \
    --enable-dummy \
    --enable-ep93xx \
    --enable-ftdi \
    --disable-gw16012 \
    --disable-ioutil \
    --enable-jlink \
    --enable-jtag_vpi \
    --disable-minidriver-dummy \
    --disable-oocd_trace \
    --enable-opendous \
    --enable-openjtag \
    --enable-osbdm \
    --disable-parport \
    --disable-parport-ppdev \
    --disable-parport-giveio \
    --enable-presto \
    --enable-remote-bitbang \
    --enable-riscv \
    --enable-rlink \
    --enable-stlink \
    --disable-sysfsgpio \
    --enable-ti-icdi \
    --enable-ulink \
    --enable-usb-blaster \
    --enable-usb_blaster_2 \
    --enable-usbprog \
    --enable-vsllink \
    --disable-zy1000-master \
    --disable-zy1000 \
    | tee "${output_folder_path}/configure-output.txt"
    # Note: don't forget to update the INFO.txt file after changing these.

  fi

  cd "${build_folder_path}/${APP_LC_NAME}"
  cp config.* "${output_folder_path}"

fi

# ----- Full build, with documentation. -----

openocd_stamp_file="${build_folder_path}/${APP_LC_NAME}/stamp-install-completed"

# if [ ! \( -f "${build_folder_path}/${APP_LC_NAME}/src/openocd" \) -a \
#     ! \( -f "${build_folder_path}/${APP_LC_NAME}/src/openocd.exe" \) ]
if [ ! -f "${openocd_stamp_file}" ]
then

  # The bindir and pkgdatadir are required to configure bin and scripts folders
  # at the same level in the hierarchy.

  echo
  echo "Running make all..."

  cd "${build_folder_path}/${APP_LC_NAME}"
  make "${jobs}" bindir="bin" pkgdatadir="" all pdf html \
    | tee "${output_folder_path}/make-all-output.txt"

  echo
  echo "Running make install..."

  make "${jobs}" install install-pdf install-html install-man \
    | tee "${output_folder_path}/make-install-output.txt"

  touch "${openocd_stamp_file}"
fi


# ----- Copy dynamic libraries to the install bin folder. -----

checking_stamp_file="${build_folder_path}/stamp_check_completed"

if [ ! -f "${checking_stamp_file}" ]
then

if [ "${target_name}" == "win" ]
then

  if [ -z "${do_no_strip}" ]
  then
    ${cross_compile_prefix}-strip \
      "${install_folder}/${APP_LC_NAME}/bin/openocd.exe"
  fi

  echo
  echo "Copying DLLs..."

  # Identify the current cross gcc version, to locate the specific dll folder.
  CROSS_GCC_VERSION=$(${cross_compile_prefix}-gcc --version | grep 'gcc' | sed -e 's/.*\s\([0-9]*\)[.]\([0-9]*\)[.]\([0-9]*\).*/\1.\2.\3/')
  CROSS_GCC_VERSION_SHORT=$(echo $CROSS_GCC_VERSION | sed -e 's/\([0-9]*\)[.]\([0-9]*\)[.]\([0-9]*\).*/\1.\2/')
  SUBLOCATION="-win32"

  echo "${CROSS_GCC_VERSION}" "${CROSS_GCC_VERSION_SHORT}" "${SUBLOCATION}"

  if [ "${target_bits}" == "32" ]
  then
    do_container_win_copy_gcc_dll "libgcc_s_sjlj-1.dll"
  elif [ "${target_bits}" == "64" ]
  then
    do_container_win_copy_gcc_dll "libgcc_s_seh-1.dll"
  fi

  do_container_win_copy_libwinpthread_dll

  # Copy possible DLLs. Currently only libusb0.dll is dynamic, all other
  # are also compiled as static.
  cp -v "${install_folder}/bin/"*.dll "${install_folder}/${APP_LC_NAME}/bin"

  if [ -z "${do_no_strip}" ]
  then
    ${cross_compile_prefix}-strip "${install_folder}/${APP_LC_NAME}/bin/"*.dll
  fi

elif [ "${target_name}" == "debian" ]
then

  if [ -z "${do_no_strip}" ]
  then
    strip "${install_folder}/${APP_LC_NAME}/bin/openocd"
  fi

  # This is a very important detail: 'patchelf' sets "runpath"
  # in the ELF file to $ORIGIN, telling the loader to search
  # for the libraries first in LD_LIBRARY_PATH (if set) and, if not found there,
  # to look in the same folder where the executable is located -- where
  # this build script installs the required libraries. 
  # Note: LD_LIBRARY_PATH can be set by a developer when testing alternate 
  # versions of the openocd libraries without removing or overwriting 
  # the installed library files -- not done by the typical user. 
  # Note: patchelf changes the original "rpath" in the executable (a path 
  # in the docker container) to "runpath" with the value "$ORIGIN". rpath 
  # instead or runpath could be set to $ORIGIN but rpath is searched before
  # LD_LIBRARY_PATH which requires an installed library be deleted or
  # overwritten to test or use an alternate version. In addition, the usage of
  # rpath is deprecated. See man ld.so for more info.  
  # Also, runpath is added to the installed library files using patchelf, with 
  # value $ORIGIN, in the same way. See patchelf usage in build-helper.sh.
  #
  patchelf --set-rpath '$ORIGIN' "${install_folder}/${APP_LC_NAME}/bin/openocd"

  echo
  echo "Copying shared libs..."

  if [ "${target_bits}" == "64" ]
  then
    distro_machine="x86_64"
  elif [ "${target_bits}" == "32" ]
  then
    distro_machine="i386"
  fi

  do_container_linux_copy_user_so libusb-1.0
  do_container_linux_copy_user_so libusb-0.1
  do_container_linux_copy_user_so libftdi1
  do_container_linux_copy_user_so libhidapi-hidraw

  do_container_linux_copy_system_so libudev
  do_container_linux_copy_librt_so

elif [ "${target_name}" == "osx" ]
then

  if [ -z "${do_no_strip}" ]
  then
    strip "${install_folder}/${APP_LC_NAME}/bin/openocd"
  fi

  echo
  echo "Copying dynamic libs..."

  # Post-process dynamic libraries paths to be relative to executable folder.

  ILIB=openocd
  # otool -L "${install_folder}/${APP_LC_NAME}/bin/openocd"

  install_name_tool -change "libftdi1.2.dylib" "@executable_path/libftdi1.2.dylib" \
    "${install_folder}/${APP_LC_NAME}/bin/openocd"
  do_container_mac_change_built_lib libusb-1.0.0.dylib
  do_container_mac_change_built_lib libusb-0.1.4.dylib
  do_container_mac_change_built_lib libhidapi.0.dylib
  do_container_mac_check_libs

  do_container_mac_copy_built_lib libftdi1.2.dylib
  do_container_mac_change_built_lib libusb-1.0.0.dylib
  do_container_mac_check_libs

  do_container_mac_copy_built_lib libusb-0.1.4.dylib
  do_container_mac_change_built_lib libusb-1.0.0.dylib
  do_container_mac_check_libs

  do_container_mac_copy_built_lib libusb-1.0.0.dylib
  do_container_mac_check_libs

  do_container_mac_copy_built_lib libhidapi.0.dylib
  do_container_mac_check_libs

fi

touch "${checking_stamp_file}"
fi

# ----- Copy the license files. -----

license_stamp_file="${build_folder_path}/stamp_license_completed"

if [ ! -f "${license_stamp_file}" ]
then

  echo
  echo "Copying license files..."

  do_container_copy_license "${git_folder_path}" "openocd"
  do_container_copy_license "${work_folder_path}/${HIDAPI_FOLDER}" "${HIDAPI_FOLDER}"
  do_container_copy_license "${work_folder_path}/${LIBFTDI_FOLDER}" "${LIBFTDI_FOLDER}"
  do_container_copy_license "${work_folder_path}/${LIBUSB1_FOLDER}" "${LIBUSB1_FOLDER}"

  if [ "${target_name}" == "win" ]
  then
    do_container_copy_license "${work_folder_path}/${LIBUSB_W32_FOLDER}" "${LIBUSB_W32}"
  else
    do_container_copy_license "${work_folder_path}/${LIBUSB0_FOLDER}" "${LIBUSB0_FOLDER}"
  fi

  if [ "${target_name}" == "win" ]
  then
    # Copy the LICENSE to be used by nsis.
    /usr/bin/install -v -c -m 644 "${git_folder_path}/LICENSE" "${install_folder}/${APP_LC_NAME}/licenses"

    # For Windows, process cr lf
    find "${install_folder}/${APP_LC_NAME}/licenses" -type f \
      -exec unix2dos {} \;
  fi

  touch "${license_stamp_file}"

fi


# ----- Copy the GNU MCU Eclipse info files. -----

info_stamp_file="${build_folder_path}/stamp_info_completed"

if [ ! -f "${info_stamp_file}" ]
then

  do_container_copy_info

  touch "${info_stamp_file}"

fi

# ----- Create the distribution package. -----

mkdir -p "${output_folder_path}"

if false
then

if [ "${GIT_HEAD}" == "gnu-mcu-eclipse" ]
then
  distribution_file_version=$(cat "${git_folder_path}/gnu-mcu-eclipse/VERSION")-${DISTRIBUTION_FILE_DATE}
elif [ "${GIT_HEAD}" == "gnu-mcu-eclipse-dev" ]
then
  distribution_file_version=$(cat "${git_folder_path}/gnu-mcu-eclipse/VERSION-dev")-${DISTRIBUTION_FILE_DATE}-dev
fi

fi

distribution_file_version=$(cat "${git_folder_path}/gnu-mcu-eclipse/VERSION-dev")-${DISTRIBUTION_FILE_DATE}-dev

do_container_create_distribution

do_check_application "openocd" --version

# Requires ${distribution_file} and ${result}
do_container_completed

exit 0

EOF
# The above marker must start in the first column.
# ^===========================================================================^


# ----- Build the OS X distribution. -----

if [ "${HOST_UNAME}" == "Darwin" ]
then
  if [ "${DO_BUILD_OSX}" == "y" ]
  then
    do_host_build_target "Creating the OS X distribution..." \
      --target-name osx
  fi
fi

# ----- Build the Debian 64-bits distribution. -----

if [ "${DO_BUILD_DEB64}" == "y" ]
then
  do_host_build_target "Creating the Debian 64-bits distribution..." \
    --target-name debian \
    --target-bits 64 \
    --docker-image "ilegeul/debian:9-gnu-mcu-eclipse"
fi

# ----- Build the Windows 64-bits distribution. -----

if [ "${DO_BUILD_WIN64}" == "y" ]
then
  do_host_build_target "Creating the Windows 64-bits distribution..." \
    --target-name win \
    --target-bits 64 \
    --docker-image "ilegeul/debian:9-gnu-mcu-eclipse" 
fi

# ----- Build the Debian 32-bits distribution. -----

if [ "${DO_BUILD_DEB32}" == "y" ]
then
  do_host_build_target "Creating the Debian 32-bits distribution..." \
    --target-name debian \
    --target-bits 32 \
    --docker-image "ilegeul/debian32:9-gnu-mcu-eclipse"
fi

# ----- Build the Windows 32-bits distribution. -----

# Since the actual container is a 32-bits, use the debian32 binaries.
if [ "${DO_BUILD_WIN32}" == "y" ]
then
  do_host_build_target "Creating the Windows 32-bits distribution..." \
    --target-name win \
    --target-bits 32 \
    --docker-image "ilegeul/debian32:9-gnu-mcu-eclipse" 
fi

do_host_show_sha

do_host_stop_timer

# ----- Done. -----
exit 0
