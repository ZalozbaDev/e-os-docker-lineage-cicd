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
cd "$SRC_DIR" || return 1

if [ -f /root/userscripts/begin.sh ]; then
  echo ">> [$(date)] Running begin.sh"
  /root/userscripts/begin.sh
fi

# If requested, clean the OUT dir in order to avoid clutter
if [ "$CLEAN_OUTDIR" = true ]; then
  echo ">> [$(date)] Cleaning '$ZIP_DIR'"
  rm -rf "${ZIP_DIR:?}/*"
fi

sync_successful=true

use_openjdk_from_ubuntu=false
branch_dir=$(sed -E 's/^v[0-9](\.[0-9]*){0,2}(-(beta|alpha|rc)(\.[0-9]*){0,1}){0,1}-(nougat|oreo|pie|q|r)(-[a-zA-Z0-9_]*)*$/\5/' <<< "${BRANCH_NAME}")
branch_dir=${branch_dir^^}

if [ -n "${BRANCH_NAME}" ] && [ -n "${DEVICE}" ]; then
  vendor=lineage
  case "$BRANCH_NAME" in
    *nougat*)
      vendor="cm"
      themuppets_branch="cm-14.1"
      android_version="7.1.2"
      use_openjdk_from_ubuntu=true
      ;;
    *oreo*)
      themuppets_branch="lineage-15.1"
      android_version="8.1"
      use_openjdk_from_ubuntu=true
      ;;
    *pie*)
      themuppets_branch="lineage-16.0"
      android_version="9"
      ;;
    *q*)
      themuppets_branch="lineage-17.1"
      android_version="10"
      ;;
    *r*)
      themuppets_branch="lineage-18.1"
      android_version="11"
      ;;
    *)
      echo ">> [$(date)] Building branch $branch is not (yet) suppported"
      exit 1
      ;;
    esac

  android_version_major=$(cut -d '.' -f 1 <<< $android_version)

  mkdir -p "$SRC_DIR/$branch_dir"
  cd "$SRC_DIR/$branch_dir" || return 1

  echo ">> [$(date)] Branch:  ${BRANCH_NAME}"
  echo ">> [$(date)] Device: ${DEVICE}"

  # Remove previous changes of vendor/cm, vendor/lineage and frameworks/base (if they exist)
  for path in "vendor/cm" "vendor/lineage" "frameworks/base"; do
    if [ -d "$path" ]; then
      cd "$path" || return 1
      git reset -q --hard
      git clean -q -fd
      cd "$SRC_DIR/$branch_dir" || return 1
    fi
  done

  echo ">> [$(date)] (Re)initializing branch repository"

  TAG_PREFIX=""
  if curl https://gitlab.e.foundation/api/v4/projects/659/repository/tags | grep "\"name\":\"${BRANCH_NAME}\""
  then
    echo "Branch name ${BRANCH_NAME} is a tag on e/os/releases, prefix with refs/tags/ for 'repo init'"
    TAG_PREFIX="refs/tags/"
  fi
  if [ -n ${REPO_INIT_DEPTH} ] && [ ${REPO_INIT_DEPTH} -gt 0 ]; then
    REPO_INIT_PARAM="--depth ${REPO_INIT_DEPTH}"
  fi
  yes | repo init $REPO_INIT_PARAM -u "$REPO" -b "${TAG_PREFIX}${BRANCH_NAME}"

  # Copy local manifests to the appropriate folder in order take them into consideration
  echo ">> [$(date)] Copying '$LMANIFEST_DIR/*.xml' to '.repo/local_manifests/'"
  mkdir -p .repo/local_manifests
  rsync -a --delete --include '*.xml' --exclude '*' "$LMANIFEST_DIR/" .repo/local_manifests/

  rm -f .repo/local_manifests/proprietary.xml
  if [ "$INCLUDE_PROPRIETARY" = true ]; then
    wget -q -O .repo/local_manifests/proprietary.xml "https://raw.githubusercontent.com/TheMuppets/manifests/$themuppets_branch/muppets.xml"
    /root/build_manifest.py --remote "https://gitlab.com" --remotename "gitlab_https" \
  "https://gitlab.com/the-muppets/manifest/raw/$themuppets_branch/muppets.xml" .repo/local_manifests/proprietary_gitlab.xml

  fi

  echo ">> [$(date)] Syncing branch repository"
  builddate=$(date +%Y%m%d)
  repo_out=$(repo sync -c --force-sync 2>&1 > /dev/null)
  repo_status=$?
  echo -e $repo_out

  if [ "$repo_status" != "0" ];  then
    if [ -f /root/userscripts/clean.sh ]; then
      if [[ "$repo_out" == *"Failing repos:"* ]]; then
        list_line=`echo -e $repo_out | sed 's/.*Failing repos: //'`
      fi
      if [[ "$repo_out" == *"Cannot remove project"* ]]; then
        list_line=`echo -e $repo_out | grep "Cannot remove project" | sed -e 's/.*error: \(.*\): Cannot.*/\1/'`
      fi
      echo ">> [$(date)] Running clean.sh"
      /root/userscripts/clean.sh $list_line
      if ! repo sync -c --force-sync ; then
        sync_successful=false
      fi
    else
      sync_successful=false
    fi
  fi

  if [ "$sync_successful" = true ]; then
    repo forall -c 'git lfs pull'
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
    if [ "$android_version_major" -lt "10" ]; then
      sed -i "1s;^;PRODUCT_DEFAULT_DEV_CERTIFICATE := user-keys/releasekey\nPRODUCT_OTA_PUBLIC_KEYS := user-keys/releasekey\nPRODUCT_EXTRA_RECOVERY_KEYS := user-keys/releasekey\n\n;" "vendor/$vendor/config/common.mk"
    fi

    if [ "$android_version_major" -ge "10" ]; then
      sed -i "1s;^;PRODUCT_DEFAULT_DEV_CERTIFICATE := user-keys/releasekey\nPRODUCT_OTA_PUBLIC_KEYS := user-keys/releasekey\n\n;" "vendor/$vendor/config/common.mk"
    fi
  fi

  # Prepare the environment
  echo ">> [$(date)] Preparing build environment"
  source build/envsetup.sh > /dev/null

  if [ -f /root/userscripts/before.sh ]; then
    echo ">> [$(date)] Running before.sh"
    /root/userscripts/before.sh
  fi

  build_device=true
  if [ -n "${DEVICE}" ]; then

    currentdate=$(date +%Y%m%d)
    if [ "$builddate" != "$currentdate" ]; then
      # Sync the source code
      builddate=$currentdate

      echo ">> [$(date)] Syncing branch repository"
      cd "$SRC_DIR/$branch_dir" || return 1


      if ! repo sync -c --force-sync; then
        sync_successful=false
        build_device=false
      fi
    fi

    source_dir="$SRC_DIR/$branch_dir"
    cd "$source_dir" || return 1

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


      if ! /root/userscripts/pre-build.sh "${DEVICE}"; then
        build_device=false
      fi
    fi

    if [ "$build_device" = false ]; then
      echo ">> [$(date)] No build for ${DEVICE}"
    fi

    if [ "$use_openjdk_from_ubuntu" = true ]; then
      update-java-alternatives -s java-1.8.0-openjdk-amd64
    fi

    # Start the build
    echo ">> [$(date)] Starting build for ${DEVICE}, ${BRANCH_NAME} branch"
    build_successful=false
    echo "ANDROID_JACK_VM_ARGS=${ANDROID_JACK_VM_ARGS}"
    echo "Switch to Python2"
    ln -fs /usr/bin/python2 /usr/bin/python

    BRUNCH_DEVICE=${DEVICE}

    if [ "${ENG_BUILD}" = true ]; then
      BRUNCH_DEVICE=lineage_${DEVICE}-eng
    elif [ "${USER_BUILD}" = true ]; then
      BRUNCH_DEVICE=lineage_${DEVICE}-user
    fi

    build_success=false
    if [ "${BUILD_ONLY_SYSTEMIMAGE}" = true ]; then
      breakfast "${BRUNCH_DEVICE}"
      if make systemimage; then
        build_success=true
      fi
    elif [ "${IS_EMULATOR}" = true ]; then
      if lunch "${BRUNCH_DEVICE}" && mka sdk_addon ; then
        build_success=true
      fi
    elif [ "${BUILD_SUPER_IMAGE}" = true ]; then
      if breakfast "${BRUNCH_DEVICE}" && mka bacon superimage; then
        build_success=true
      fi
    elif brunch "${BRUNCH_DEVICE}"; then
        build_success=true
    fi

    if [ "$build_success" = true ]; then
      currentdate=$(date +%Y%m%d)
      if [ "$builddate" != "$currentdate" ]; then
        find "${OUT}" -maxdepth 1 -name "e-*-$currentdate-*.zip*" -type f -exec sh /root/fix_build_date.sh {} "$currentdate" "$builddate" \;
      fi

      # Move produced ZIP files to the main OUT directory
      echo ">> [$(date)] Moving build artifacts for ${DEVICE} to '$ZIP_DIR/$zipsubdir'"
      cd "${OUT}" || return 1
      for build in $(ls e-*.zip); do
        sha256sum "$build" > "$ZIP_DIR/$zipsubdir/$build.sha256sum"
        find . -maxdepth 1 -name 'e-*.zip*' -type f -exec mv {} "$ZIP_DIR/$zipsubdir/" \;

        SKIP_DYNAMIC_IMAGES="odm.img product.img system.img system_ext.img vendor.img"
        if [ "$BACKUP_IMG" = true ]; then
          if [ "$BUILD_SUPER_IMAGE" = true ]; then
	    find . -maxdepth 1 -name '*.img' -type f $(printf "! -name %s " $(echo "$SKIP_DYNAMIC_IMAGES")) -exec zip "$ZIP_DIR/$zipsubdir/IMG-$build" {} \;
          elif [ "$SPARSE_PREBUILT_VENDOR_IMAGE" = true ]; then
            echo "Sparsing prebuilt vendor image"
            img2simg vendor.img vendor-sparsed.img || return 1
            find . -maxdepth 1 -name '*.img' -type f ! -name vendor.img -exec zip "$ZIP_DIR/$zipsubdir/IMG-$build" {} \;
          else
            find . -maxdepth 1 -name '*.img' -type f -exec zip "$ZIP_DIR/$zipsubdir/IMG-$build" {} \;
	  fi
          cd "$ZIP_DIR/$zipsubdir" || return 1
          sha256sum "IMG-$build" > "IMG-$build.sha256sum"
          md5sum "IMG-$build" > "IMG-$build.md5sum"
          cd "${OUT}" || return 1
        fi
        if [ "$BACKUP_INTERMEDIATE_SYSTEM_IMG" = true ]; then
          mv obj/PACKAGING/target_files_intermediates/lineage*/IMAGES/system.img ./
          zip "$ZIP_DIR/$zipsubdir/IMG-$build" system.img
          cd $ZIP_DIR/$zipsubdir
          sha256sum "IMG-$build" > "IMG-$build.sha256sum"
          md5sum "IMG-$build" > "IMG-$build.md5sum"
          cd "${OUT}" || return 1
        fi
        if [ "$EDL_RAW_SUPER_IMAGE" = true ]; then
          echo "Unsparsing super image"
          simg2img super.img super.raw.img || return 1
          find . -maxdepth 1 -name '*.img' -type f ! -name super.img $(printf "! -name %s " $(echo "$SKIP_DYNAMIC_IMAGES")) -exec zip "$ZIP_DIR/$zipsubdir/EDL-$build" {} \;
          cd "$ZIP_DIR/$zipsubdir" || return 1
          sha256sum "EDL-$build" > "EDL-$build.sha256sum"
          md5sum "EDL-$build" > "EDL-$build.md5sum"
          cd "${OUT}" || return 1
        fi

      	if [ "$RECOVERY_IMG" = true ]; then

          RECOVERY_IMG_NAME="recovery-${build%.*}.img"

      	  if [ -f "recovery.img" ]; then
      	    cp -a recovery.img "$RECOVERY_IMG_NAME"
      	  else
      	    cp -a boot.img "$RECOVERY_IMG_NAME"
      	  fi

          sha256sum "$RECOVERY_IMG_NAME" > "$RECOVERY_IMG_NAME.sha256sum"
          mv "$RECOVERY_IMG_NAME"* "$ZIP_DIR/$zipsubdir/"
      	fi
      done

      #with only systemimage, we don't have a e-*.zip
      if [ "${BUILD_ONLY_SYSTEMIMAGE}" = true ]; then
        build=e-`grep lineage.version system/build.prop | sed s/#.*// | sed s/.*=// | tr -d \\n`.zip
        if [ "$BACKUP_INTERMEDIATE_SYSTEM_IMG" = true ]; then
          mv obj/PACKAGING/target_files_intermediates/lineage*/IMAGES/system.img ./
          zip "$ZIP_DIR/$zipsubdir/IMG-$build" system.img
          cd $ZIP_DIR/$zipsubdir
          sha256sum "IMG-$build" > "IMG-$build.sha256sum"
          md5sum "IMG-$build" > "IMG-$build.md5sum"
          cd "${OUT}" || return 1
        fi
      fi

      if [ "$IS_EMULATOR" = true -a "$BACKUP_EMULATOR" = true ]; then
        EMULATOR_ARCHIVE="e-android$android_version-eng-$currentdate-linux-x86-img.zip"
        mv ../../../host/linux-x86/sdk_addon/*-img.zip "$ZIP_DIR/$zipsubdir/$EMULATOR_ARCHIVE"
        pushd "$ZIP_DIR/$zipsubdir"
        sha256sum "$EMULATOR_ARCHIVE" > "$EMULATOR_ARCHIVE.sha256sum"
        popd
      fi

      cd "$source_dir" || return 1
      echo ">> [$(date)] backup manifest for ${DEVICE}"
      repo manifest -r -o "$ZIP_DIR/$zipsubdir"/${build%???}xml
      build_successful=true
    else
      echo ">> [$(date)] Failed build for ${DEVICE}"
    fi

    # Remove old zips and logs
    if [ "$DELETE_OLD_ZIPS" -gt "0" ]; then
      if [ "$ZIP_SUBDIR" = true ]; then
        /usr/bin/python /root/clean_up.py -n "$DELETE_OLD_ZIPS" -V "$los_ver" -N 1 "$ZIP_DIR/$zipsubdir"
      else
        /usr/bin/python /root/clean_up.py -n "$DELETE_OLD_ZIPS" -V "$los_ver" -N 1 -c "${DEVICE}" "$ZIP_DIR"
      fi
    fi
    if [ "$DELETE_OLD_LOGS" -gt "0" ]; then
      if [ "$LOGS_SUBDIR" = true ]; then
        /usr/bin/python /root/clean_up.py -n "$DELETE_OLD_LOGS" -V "$los_ver" -N 1 "$LOGS_DIR/$logsubdir"
      else
        /usr/bin/python /root/clean_up.py -n "$DELETE_OLD_LOGS" -V "$los_ver" -N 1 -c "${DEVICE}" "$LOGS_DIR"
      fi
    fi
    if [ -f /root/userscripts/post-build.sh ]; then
      echo ">> [$(date)] Running post-build.sh for ${DEVICE}"
      /root/userscripts/post-build.sh "${DEVICE}" "$build_successful"
    fi
    echo ">> [$(date)] Finishing build for ${DEVICE}"

    if [ "$CLEAN_AFTER_BUILD" = true ]; then
      echo ">> [$(date)] Cleaning source dir for device ${DEVICE}"
      cd "$source_dir" || return 1
      mka clean
    fi

  fi

  echo "Switch back to Python3"
  ln -fs /usr/bin/python3 /usr/bin/python

fi

if [ "$DELETE_OLD_LOGS" -gt "0" ]; then
  find "$LOGS_DIR" -maxdepth 1 -name "repo-*.log" | sort | head -n -"$DELETE_OLD_LOGS" | xargs -r rm
fi

if [ -f /root/userscripts/end.sh ]; then
  echo ">> [$(date)] Running end.sh"
  /root/userscripts/end.sh
fi

if [ "$build_successful" = false ] || [ "$sync_successful" = false ]; then
  exit 1
fi
