#!/bin/bash

# Docker build script
# Copyright (c) 2017 Julian Xhokaxhiu
# Copyright (C) 2017-2018 Nicola Corna <nicola@corna.info>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

# cd to working directory
cd "$SRC_DIR"

if [ -f /root/userscripts/begin.sh ]; then
  echo ">> [$(date)] Running begin.sh"
  /root/userscripts/begin.sh
fi

# If requested, clean the OUT dir in order to avoid clutter
if [ "$CLEAN_OUTDIR" = true ]; then
  echo ">> [$(date)] Cleaning '$ZIP_DIR'"
  rm -rf "$ZIP_DIR/"*
fi

sync_successful=true

branch_dir=$(sed 's/.*-\([a-zA-Z]*\)$/\1/' <<< ${BRANCH_NAME})
branch_dir=${branch_dir^^}

if [ -n "${BRANCH_NAME}" ] && [ -n "${DEVICE}" ]; then

  mkdir -p "$SRC_DIR/$branch_dir"
  cd "$SRC_DIR/$branch_dir"

  echo ">> [$(date)] Branch:  ${BRANCH_NAME}"
  echo ">> [$(date)] Device: ${DEVICE}"

  # Remove previous changes of vendor/cm, vendor/lineage and frameworks/base (if they exist)
  for path in "vendor/cm" "vendor/lineage" "frameworks/base"; do
    if [ -d "$path" ]; then
      cd "$path"
      git reset -q --hard
      git clean -q -fd
      cd "$SRC_DIR/$branch_dir"
    fi
  done

  echo ">> [$(date)] (Re)initializing branch repository"

  TAG_PREFIX=""
  curl https://gitlab.e.foundation/api/v4/projects/659/repository/tags | grep "\"name\":\"${BRANCH_NAME}\""
  if [ $? == 0 ]
  then
    echo "Branch name ${BRANCH_NAME} is a tag on e/os/releases, prefix with refs/tags/ for 'repo init'"
    TAG_PREFIX="refs/tags/"
  fi
  yes | repo init -u "$REPO" -b "${TAG_PREFIX}${BRANCH_NAME}"

  # Copy local manifests to the appropriate folder in order take them into consideration
  echo ">> [$(date)] Copying '$LMANIFEST_DIR/*.xml' to '.repo/local_manifests/'"
  mkdir -p .repo/local_manifests
  rsync -a --delete --include '*.xml' --exclude '*' "$LMANIFEST_DIR/" .repo/local_manifests/

  rm -f .repo/local_manifests/proprietary.xml
  if [ "$INCLUDE_PROPRIETARY" = true ]; then
    if [[ ${BRANCH_NAME} =~ nougat$ ]]; then
      themuppets_branch=cm-14.1
      echo ">> [$(date)] Use branch $themuppets_branch on github.com/TheMuppets"
    elif [[ ${BRANCH_NAME} =~ oreo$ ]]; then
      themuppets_branch=lineage-15.1
      echo ">> [$(date)] Use branch $themuppets_branch on github.com/TheMuppets"
    elif [[ ${BRANCH_NAME} =~ pie$ ]]; then
      themuppets_branch=lineage-16.0
      echo ">> [$(date)] Use branch $themuppets_branch on github.com/TheMuppets"
    else
      themuppets_branch=cm-14.1
      echo ">> [$(date)] Can't find a matching branch on github.com/TheMuppets, using $themuppets_branch"
    fi
    wget -q -O .repo/local_manifests/proprietary.xml "https://raw.githubusercontent.com/TheMuppets/manifests/$themuppets_branch/muppets.xml"
  fi

  echo ">> [$(date)] Syncing branch repository"
  builddate=$(date +%Y%m%d)
  repo sync -c --force-sync

  if [ $? != 0 ]; then
    sync_successful=false
  fi

  android_version=$(sed -n -e 's/^\s*PLATFORM_VERSION\.OPM1 := //p' build/core/version_defaults.mk)
  if [ -z $android_version ]; then
    android_version=$(sed -n -e 's/^\s*PLATFORM_VERSION\.PPR1 := //p' build/core/version_defaults.mk)
    if [ -z $android_version ]; then
      android_version=$(sed -n -e 's/^\s*PLATFORM_VERSION := //p' build/core/version_defaults.mk)
      if [ -z $android_version ]; then
        echo ">> [$(date)] Can't detect the android version"
        exit 1
      fi
    fi
  fi
  android_version_major=$(cut -d '.' -f 1 <<< $android_version)

  if [ "$android_version_major" -ge "8" ]; then
    vendor="lineage"
  else
    vendor="cm"
  fi

  if [ ! -d "vendor/$vendor" ]; then
    echo ">> [$(date)] Missing \"vendor/$vendor\", aborting"
    exit 1
  fi

  los_ver_major=$(sed -n -e 's/^\s*PRODUCT_VERSION_MAJOR = //p' "vendor/$vendor/config/common.mk")
  los_ver_minor=$(sed -n -e 's/^\s*PRODUCT_VERSION_MINOR = //p' "vendor/$vendor/config/common.mk")
  los_ver="$los_ver_major.$los_ver_minor"

  if [ "$SIGN_BUILDS" = true ]; then
    echo ">> [$(date)] Adding keys path ($KEYS_DIR)"
    # Soong (Android 9+) complains if the signing keys are outside the build path
    ln -sf "$KEYS_DIR" user-keys
    sed -i "1s;^;PRODUCT_DEFAULT_DEV_CERTIFICATE := user-keys/releasekey\nPRODUCT_OTA_PUBLIC_KEYS := user-keys/releasekey\nPRODUCT_EXTRA_RECOVERY_KEYS := user-keys/releasekey\n\n;" "vendor/$vendor/config/common.mk"
  fi

  echo ">> [$(date)] Using OpenJDK $jdk_version"
  update-java-alternatives -s java-1.$jdk_version.0-openjdk-amd64 &> /dev/null

  # Prepare the environment
  echo ">> [$(date)] Preparing build environment"
  source build/envsetup.sh > /dev/null

  if [ -f /root/userscripts/before.sh ]; then
    echo ">> [$(date)] Running before.sh"
    /root/userscripts/before.sh
  fi

  build_device=true
  if ! [ -z "${DEVICE}" ]; then

    currentdate=$(date +%Y%m%d)
    if [ "$builddate" != "$currentdate" ]; then
      # Sync the source code
      builddate=$currentdate

      echo ">> [$(date)] Syncing branch repository"
      cd "$SRC_DIR/$branch_dir"
      repo sync -c --force-sync

      if [ $? != 0 ]; then
        sync_successful=false
        build_device=false
      fi
    fi

    source_dir="$SRC_DIR/$branch_dir"
    cd "$source_dir"

    if [ "$ZIP_SUBDIR" = true ]; then
      zipsubdir=${DEVICE}
      mkdir -p "$ZIP_DIR/$zipsubdir"
    else
      zipsubdir=
    fi
    if [ "$LOGS_SUBDIR" = true ]; then
      logsubdir=${DEVICE}
      mkdir -p "$LOGS_DIR/$logsubdir"
    else
      logsubdir=
    fi

    if [ -f /root/userscripts/pre-build.sh ]; then
      echo ">> [$(date)] Running pre-build.sh for ${DEVICE}"
      /root/userscripts/pre-build.sh ${DEVICE}

      if [ $? != 0 ]; then
        build_device=false
      fi
    fi

    if [ "$build_device" = false ]; then
      echo ">> [$(date)] No build for ${DEVICE}"
      continue
    fi

    # Start the build
    echo ">> [$(date)] Starting build for ${DEVICE}, ${BRANCH_NAME} branch"
    build_successful=false
    echo "ANDROID_JACK_VM_ARGS=${ANDROID_JACK_VM_ARGS}"
    echo "Switch to Python2"
    ln -fs /usr/bin/python2 /usr/bin/python
    breakfast $codename
    if mka recoveryimage; then
      currentdate=$(date +%Y%m%d)
      if [ "$builddate" != "$currentdate" ]; then
        find out/target/product/${DEVICE} -maxdepth 1 -name "e-*-$currentdate-*.zip*" -type f -exec sh /root/fix_build_date.sh {} $currentdate $builddate \;
      fi

      if [ "$BUILD_DELTA" = true ]; then
        if [ -d "delta_last/${DEVICE}/" ]; then
          # If not the first build, create delta files
          echo ">> [$(date)] Generating delta files for ${DEVICE}"
          cd /root/delta
          if ./opendelta.sh ${DEVICE}; then
            echo ">> [$(date)] Delta generation for ${DEVICE} completed"
          else
            echo ">> [$(date)] Delta generation for ${DEVICE} failed"
          fi
          if [ "$DELETE_OLD_DELTAS" -gt "0" ]; then
            /usr/bin/python /root/clean_up.py -n $DELETE_OLD_DELTAS -V $los_ver -N 1 "$DELTA_DIR/${DEVICE}"
          fi
          cd "$source_dir"
        else
          # If the first build, copy the current full zip in $source_dir/delta_last/${DEVICE}/
          echo ">> [$(date)] No previous build for ${DEVICE}; using current build as base for the next delta"
          mkdir -p delta_last/${DEVICE}/
          find out/target/product/${DEVICE} -maxdepth 1 -name 'e-*.zip' -type f -exec cp {} "$source_dir/delta_last/${DEVICE}/" \;
        fi
      fi
      # Move produced ZIP files to the main OUT directory
      echo ">> [$(date)] Moving build artifacts for ${DEVICE} to '$ZIP_DIR/$zipsubdir'"
      cd out/target/product/${DEVICE}
      for build in e-*.zip; do
        sha256sum "$build" > "$ZIP_DIR/$zipsubdir/$build.sha256sum"
        find . -name 'recovery.img' -type f -exec mv {} "$ZIP_DIR/$zipsubdir/" \;

        if [ "$BACKUP_IMG" = true ]; then
          find . -maxdepth 1 -name '*.img' -type f -exec zip "$ZIP_DIR/$zipsubdir/IMG-$build" {} \;
          cd $ZIP_DIR/$zipsubdir
          sha256sum "IMG-$build" > "IMG-$build.sha256sum"
          md5sum "IMG-$build" > "IMG-$build.md5sum"
        fi
      done

      cd "$source_dir"
      build_successful=true
    else
      echo ">> [$(date)] Failed build for ${DEVICE}"
    fi

    # Remove old zips and logs
    if [ "$DELETE_OLD_ZIPS" -gt "0" ]; then
      if [ "$ZIP_SUBDIR" = true ]; then
        /usr/bin/python /root/clean_up.py -n $DELETE_OLD_ZIPS -V $los_ver -N 1 "$ZIP_DIR/$zipsubdir"
      else
        /usr/bin/python /root/clean_up.py -n $DELETE_OLD_ZIPS -V $los_ver -N 1 -c ${DEVICE} "$ZIP_DIR"
      fi
    fi
    if [ "$DELETE_OLD_LOGS" -gt "0" ]; then
      if [ "$LOGS_SUBDIR" = true ]; then
        /usr/bin/python /root/clean_up.py -n $DELETE_OLD_LOGS -V $los_ver -N 1 "$LOGS_DIR/$logsubdir"
      else
        /usr/bin/python /root/clean_up.py -n $DELETE_OLD_LOGS -V $los_ver -N 1 -c ${DEVICE} "$LOGS_DIR"
      fi
    fi
    if [ -f /root/userscripts/post-build.sh ]; then
      echo ">> [$(date)] Running post-build.sh for ${DEVICE}"
      /root/userscripts/post-build.sh ${DEVICE} $build_successful
    fi
    echo ">> [$(date)] Finishing build for ${DEVICE}"

    if [ "$CLEAN_AFTER_BUILD" = true ]; then
      echo ">> [$(date)] Cleaning source dir for device ${DEVICE}"
      cd "$source_dir"
      mka clean
    fi

  fi

  echo "Switch back to Python3"
  ln -fs /usr/bin/python3 /usr/bin/python

fi

# Create the OpenDelta's builds JSON file
if ! [ -z "$OPENDELTA_BUILDS_JSON" ]; then
  echo ">> [$(date)] Creating OpenDelta's builds JSON file (ZIP_DIR/$OPENDELTA_BUILDS_JSON)"
  if [ "$ZIP_SUBDIR" != true ]; then
    echo ">> [$(date)] WARNING: OpenDelta requires zip builds separated per device! You should set ZIP_SUBDIR to true"
  fi
  /usr/bin/python /root/opendelta_builds_json.py "$ZIP_DIR" -o "$ZIP_DIR/$OPENDELTA_BUILDS_JSON"
fi

if [ "$DELETE_OLD_LOGS" -gt "0" ]; then
  find "$LOGS_DIR" -maxdepth 1 -name repo-*.log | sort | head -n -$DELETE_OLD_LOGS | xargs -r rm
fi

if [ -f /root/userscripts/end.sh ]; then
  echo ">> [$(date)] Running end.sh"
  /root/userscripts/end.sh
fi

if [ "$build_successful" = false ] || [ "$sync_successful" = false ]; then
  exit 1
fi
