#!/bin/bash

# Docker build script
# Copyright (c) 2017 Julian Xhokaxhiu
# Copyright (C) 2017-2018 Nicola Corna <nicola@corna.info>
# Copyright (C) 2020 eCorp Romain HUNAULT <romain.hunaul@e.email>
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

repo_log="$LOGS_DIR/repo-$(date +%Y%m%d).log"

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

# Treat DEVICE_LIST as DEVICE_LIST_<first_branch>
first_branch=$(cut -d ',' -f 1 <<< "$BRANCH_NAME")
if [ -n "$DEVICE_LIST" ]; then
  device_list_first_branch="DEVICE_LIST_$(sed 's/.*-\([a-zA-Z]*\)$/\1/' <<< $first_branch)"
  device_list_first_branch=${device_list_first_branch^^}
  read $device_list_first_branch <<< "$DEVICE_LIST,${!device_list_first_branch}"
fi

sync_successful=true

if [ "$LOCAL_MIRROR" = true ]; then

  cd "$MIRROR_DIR"

  if [ ! -d .repo ]; then
    echo ">> [$(date)] Initializing mirror repository" | tee -a "$repo_log"
    yes | repo init -u "$MIRROR" --mirror --no-clone-bundle -p linux &>> "$repo_log"
  fi

  # Copy local manifests to the appropriate folder in order take them into consideration
  echo ">> [$(date)] Copying '$LMANIFEST_DIR/*.xml' to '.repo/local_manifests/'"
  mkdir -p .repo/local_manifests
  rsync -a --delete --include '*.xml' --exclude '*' "$LMANIFEST_DIR/" .repo/local_manifests/

  rm -f .repo/local_manifests/proprietary.xml
  if [ "$INCLUDE_PROPRIETARY" = true ]; then
    wget -q -O .repo/local_manifests/proprietary.xml "https://raw.githubusercontent.com/TheMuppets/manifests/mirror/default.xml"
  fi

  echo ">> [$(date)] Syncing mirror repository" | tee -a "$repo_log"
  repo sync --force-sync --no-clone-bundle &>> "$repo_log"

  if [ $? != 0 ]; then
    sync_successful=false
  fi
fi

for branch in ${BRANCH_NAME//,/ }; do
  branch_dir=$(sed 's/.*-\([a-zA-Z]*\)$/\1/' <<< $branch)
  branch_dir=${branch_dir^^}
  device_list_cur_branch="DEVICE_LIST_$branch_dir"
  devices=${!device_list_cur_branch}

  if [ -n "$branch" ] && [ -n "$devices" ]; then

    mkdir -p "$SRC_DIR/$branch_dir"
    cd "$SRC_DIR/$branch_dir"

    echo ">> [$(date)] Branch:  $branch"
    echo ">> [$(date)] Devices: $devices"

    # Remove previous changes of vendor/cm, vendor/lineage and frameworks/base (if they exist)
    for path in "vendor/cm" "vendor/lineage" "frameworks/base"; do
      if [ -d "$path" ]; then
        cd "$path"
        git reset -q --hard
        git clean -q -fd
        cd "$SRC_DIR/$branch_dir"
      fi
    done

    echo ">> [$(date)] (Re)initializing branch repository" | tee -a "$repo_log"
    if [ "$LOCAL_MIRROR" = true ]; then
      yes | repo init -u "$REPO" --reference "$MIRROR_DIR" -b "$branch" &>> "$repo_log"
    else
      TAG_PREFIX=""
      curl https://gitlab.e.foundation/api/v4/projects/659/repository/tags | grep "\"name\":\"$branch\""
      if [ $? == 0 ]
      then
        echo "Branch name $branch is a tag on e/os/releases, prefix with refs/tags/ for 'repo init'"
        TAG_PREFIX="refs/tags/"
      fi

      yes | repo init -u "$REPO" -b "${TAG_PREFIX}$branch" &>> "$repo_log"
    fi

    # Copy local manifests to the appropriate folder in order take them into consideration
    echo ">> [$(date)] Copying '$LMANIFEST_DIR/*.xml' to '.repo/local_manifests/'"
    mkdir -p .repo/local_manifests
    rsync -a --delete --include '*.xml' --exclude '*' "$LMANIFEST_DIR/" .repo/local_manifests/

    rm -f .repo/local_manifests/proprietary.xml
    if [ "$INCLUDE_PROPRIETARY" = true ]; then
      if [[ $branch =~ nougat$ ]]; then
        themuppets_branch=cm-14.1
        echo ">> [$(date)] Use branch $themuppets_branch on github.com/TheMuppets"
      elif [[ $branch =~ oreo$ ]]; then
        themuppets_branch=lineage-15.1
        echo ">> [$(date)] Use branch $themuppets_branch on github.com/TheMuppets"
      elif [[ $branch =~ pie$ ]]; then
        themuppets_branch=lineage-16.0
        echo ">> [$(date)] Use branch $themuppets_branch on github.com/TheMuppets"
      elif [[ $branch =~ q$ ]]; then
        themuppets_branch=lineage-17.1
        echo ">> [$(date)] Use branch $themuppets_branch on github.com/TheMuppets"
      else
        themuppets_branch=cm-14.1
        echo ">> [$(date)] Can't find a matching branch on github.com/TheMuppets, using $themuppets_branch"
      fi
      wget -q -O .repo/local_manifests/proprietary.xml "https://raw.githubusercontent.com/TheMuppets/manifests/$themuppets_branch/muppets.xml"
    fi

    echo ">> [$(date)] Syncing branch repository" | tee -a "$repo_log"
    builddate=$(date +%Y%m%d)
    repo sync -c --force-sync &>> "$repo_log"

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

    # Set up our overlay
    mkdir -p "vendor/$vendor/overlay/microg/"
    sed -i "1s;^;PRODUCT_PACKAGE_OVERLAYS := vendor/$vendor/overlay/microg\n;" "vendor/$vendor/config/common.mk"

    los_ver_major=$(sed -n -e 's/^\s*PRODUCT_VERSION_MAJOR = //p' "vendor/$vendor/config/common.mk")
    los_ver_minor=$(sed -n -e 's/^\s*PRODUCT_VERSION_MINOR = //p' "vendor/$vendor/config/common.mk")
    los_ver="$los_ver_major.$los_ver_minor"

    echo ">> [$(date)] Setting \"$RELEASE_TYPE\" as release type"
    sed -i "/\$(filter .*\$(${vendor^^}_BUILDTYPE)/,+2d" "vendor/$vendor/config/common.mk"

    # Set a custom updater URI if a OTA URL is provided
    echo ">> [$(date)] Adding OTA URL overlay (for custom URL $OTA_URL)"
    if ! [ -z "$OTA_URL" ]; then
      updater_url_overlay_dir="vendor/$vendor/overlay/microg/packages/apps/Updater/res/values/"
      mkdir -p "$updater_url_overlay_dir"

      if [ -n "$(grep updater_server_url packages/apps/Updater/res/values/strings.xml)" ]; then
        # "New" updater configuration: full URL (with placeholders {device}, {type} and {incr})
        sed "s|{name}|updater_server_url|g; s|{url}|$OTA_URL/v1/{device}/{type}/{incr}|g" /root/packages_updater_strings.xml > "$updater_url_overlay_dir/strings.xml"
      elif [ -n "$(grep conf_update_server_url_def packages/apps/Updater/res/values/strings.xml)" ]; then
        # "Old" updater configuration: just the URL
        sed "s|{name}|conf_update_server_url_def|g; s|{url}|$OTA_URL|g" /root/packages_updater_strings.xml > "$updater_url_overlay_dir/strings.xml"
      else
        echo ">> [$(date)] ERROR: no known Updater URL property found"
        exit 1
      fi
    fi

    if [ "$SIGN_BUILDS" = true ]; then
      echo ">> [$(date)] Adding keys path ($KEYS_DIR)"
      # Soong (Android 9+) complains if the signing keys are outside the build path
      ln -sf "$KEYS_DIR" user-keys
      sed -i "1s;^;PRODUCT_DEFAULT_DEV_CERTIFICATE := user-keys/releasekey\nPRODUCT_OTA_PUBLIC_KEYS := user-keys/releasekey\nPRODUCT_EXTRA_RECOVERY_KEYS := user-keys/releasekey\n\n;" "vendor/$vendor/config/common.mk"
    fi

    if [ "$android_version_major" -ge "7" ]; then
      jdk_version=8
    elif [ "$android_version_major" -ge "5" ]; then
      jdk_version=7
    else
      echo ">> [$(date)] ERROR: $branch requires a JDK version too old (< 7); aborting"
      exit 1
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

    for codename in ${devices//,/ }; do
      build_device=true
      if ! [ -z "$codename" ]; then

        currentdate=$(date +%Y%m%d)
        if [ "$builddate" != "$currentdate" ]; then
          # Sync the source code
          builddate=$currentdate

          if [ "$LOCAL_MIRROR" = true ]; then
            echo ">> [$(date)] Syncing mirror repository" | tee -a "$repo_log"
            cd "$MIRROR_DIR"
            repo sync --force-sync --no-clone-bundle &>> "$repo_log"

            if [ $? != 0 ]; then
              sync_successful=false
              build_device=false
            fi
          fi

          echo ">> [$(date)] Syncing branch repository" | tee -a "$repo_log"
          cd "$SRC_DIR/$branch_dir"
          repo sync -c --force-sync &>> "$repo_log"

          if [ $? != 0 ]; then
            sync_successful=false
            build_device=false
          fi
        fi

        if [ "$BUILD_OVERLAY" = true ]; then
          mkdir -p "$TMP_DIR/device" "$TMP_DIR/workdir" "$TMP_DIR/merged"
          mount -t overlay overlay -o lowerdir="$SRC_DIR/$branch_dir",upperdir="$TMP_DIR/device",workdir="$TMP_DIR/workdir" "$TMP_DIR/merged"
          source_dir="$TMP_DIR/merged"
        else
          source_dir="$SRC_DIR/$branch_dir"
        fi
        cd "$source_dir"

        if [ "$ZIP_SUBDIR" = true ]; then
          zipsubdir=$codename
          mkdir -p "$ZIP_DIR/$zipsubdir"
        else
          zipsubdir=
        fi
        if [ "$LOGS_SUBDIR" = true ]; then
          logsubdir=$codename
          mkdir -p "$LOGS_DIR/$logsubdir"
        else
          logsubdir=
        fi

        DEBUG_LOG="$LOGS_DIR/$logsubdir/eelo-$los_ver-$builddate-$RELEASE_TYPE-$codename.log"

        if [ -f /root/userscripts/pre-build.sh ]; then
          echo ">> [$(date)] Running pre-build.sh for $codename" >> "$DEBUG_LOG"
          /root/userscripts/pre-build.sh $codename &>> "$DEBUG_LOG"

          if [ $? != 0 ]; then
            build_device=false
          fi
        fi

        if [ "$build_device" = false ]; then
          echo ">> [$(date)] No build for $codename" >> "$DEBUG_LOG"
          continue
        fi

        # Start the build
        echo ">> [$(date)] Starting build for $codename, $branch branch" | tee -a "$DEBUG_LOG"
        build_successful=false
        echo "ANDROID_JACK_VM_ARGS=${ANDROID_JACK_VM_ARGS}"
        echo "Switch to Python2"
        ln -fs /usr/bin/python2 /usr/bin/python
        if brunch $codename &>> "$DEBUG_LOG"; then
          currentdate=$(date +%Y%m%d)
          if [ "$builddate" != "$currentdate" ]; then
            find out/target/product/$codename -maxdepth 1 -name "e-*-$currentdate-*.zip*" -type f -exec sh /root/fix_build_date.sh {} $currentdate $builddate \; &>> "$DEBUG_LOG"
          fi

          if [ "$BUILD_DELTA" = true ]; then
            if [ -d "delta_last/$codename/" ]; then
              # If not the first build, create delta files
              echo ">> [$(date)] Generating delta files for $codename" | tee -a "$DEBUG_LOG"
              cd /root/delta
              if ./opendelta.sh $codename &>> "$DEBUG_LOG"; then
                echo ">> [$(date)] Delta generation for $codename completed" | tee -a "$DEBUG_LOG"
              else
                echo ">> [$(date)] Delta generation for $codename failed" | tee -a "$DEBUG_LOG"
              fi
              if [ "$DELETE_OLD_DELTAS" -gt "0" ]; then
                /usr/bin/python /root/clean_up.py -n $DELETE_OLD_DELTAS -V $los_ver -N 1 "$DELTA_DIR/$codename" &>> $DEBUG_LOG
              fi
              cd "$source_dir"
            else
              # If the first build, copy the current full zip in $source_dir/delta_last/$codename/
              echo ">> [$(date)] No previous build for $codename; using current build as base for the next delta" | tee -a "$DEBUG_LOG"
              mkdir -p delta_last/$codename/ &>> "$DEBUG_LOG"
              find out/target/product/$codename -maxdepth 1 -name 'e-*.zip' -type f -exec cp {} "$source_dir/delta_last/$codename/" \; &>> "$DEBUG_LOG"
            fi
          fi
          # Move produced ZIP files to the main OUT directory
          echo ">> [$(date)] Moving build artifacts for $codename to '$ZIP_DIR/$zipsubdir'" | tee -a "$DEBUG_LOG"
          cd out/target/product/$codename
          for build in e-*.zip; do
            sha256sum "$build" > "$ZIP_DIR/$zipsubdir/$build.sha256sum"
          done
          find . -maxdepth 1 -name 'e-*.zip*' -type f -exec mv {} "$ZIP_DIR/$zipsubdir/" \; &>> "$DEBUG_LOG"
          cd "$source_dir"
          build_successful=true
        else
          echo ">> [$(date)] Failed build for $codename" | tee -a "$DEBUG_LOG"
        fi

        # Remove old zips and logs
        if [ "$DELETE_OLD_ZIPS" -gt "0" ]; then
          if [ "$ZIP_SUBDIR" = true ]; then
            /usr/bin/python /root/clean_up.py -n $DELETE_OLD_ZIPS -V $los_ver -N 1 "$ZIP_DIR/$zipsubdir"
          else
            /usr/bin/python /root/clean_up.py -n $DELETE_OLD_ZIPS -V $los_ver -N 1 -c $codename "$ZIP_DIR"
          fi
        fi
        if [ "$DELETE_OLD_LOGS" -gt "0" ]; then
          if [ "$LOGS_SUBDIR" = true ]; then
            /usr/bin/python /root/clean_up.py -n $DELETE_OLD_LOGS -V $los_ver -N 1 "$LOGS_DIR/$logsubdir"
          else
            /usr/bin/python /root/clean_up.py -n $DELETE_OLD_LOGS -V $los_ver -N 1 -c $codename "$LOGS_DIR"
          fi
        fi
        if [ -f /root/userscripts/post-build.sh ]; then
          echo ">> [$(date)] Running post-build.sh for $codename" >> "$DEBUG_LOG"
          /root/userscripts/post-build.sh $codename $build_successful &>> "$DEBUG_LOG"
        fi
        echo ">> [$(date)] Finishing build for $codename" | tee -a "$DEBUG_LOG"

        if [ "$BUILD_OVERLAY" = true ]; then
          # The Jack server must be stopped manually, as we want to unmount $TMP_DIR/merged
          cd "$TMP_DIR"
          if [ -f "$TMP_DIR/merged/prebuilts/sdk/tools/jack-admin" ]; then
            "$TMP_DIR/merged/prebuilts/sdk/tools/jack-admin kill-server" &> /dev/null || true
          fi
          lsof | grep "$TMP_DIR/merged" | awk '{ print $2 }' | sort -u | xargs -r kill &> /dev/null

          while [ -n "$(lsof | grep $TMP_DIR/merged)" ]; do
            sleep 1
          done

          umount "$TMP_DIR/merged"
        fi

        if [ "$CLEAN_AFTER_BUILD" = true ]; then
          echo ">> [$(date)] Cleaning source dir for device $codename" | tee -a "$DEBUG_LOG"
          if [ "$BUILD_OVERLAY" = true ]; then
            cd "$TMP_DIR"
            rm -rf ./*
          else
            cd "$source_dir"
            mka clean &>> "$DEBUG_LOG"
          fi
        fi

        echo "Switch back to Python3"
        ln -fs /usr/bin/python3 /usr/bin/python
      fi
    done
  fi
done

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