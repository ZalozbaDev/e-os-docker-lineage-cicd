FROM debian:buster
MAINTAINER Romain Hunault <romain.hunault@e.email>

# Environment variables
#######################

ENV SRC_DIR /srv/src
ENV CCACHE_DIR /srv/ccache
ENV ZIP_DIR /srv/zips
ENV LMANIFEST_DIR /srv/local_manifests
ENV DELTA_DIR /srv/delta
ENV KEYS_DIR /srv/keys
ENV LOGS_DIR /srv/logs
ENV USERSCRIPTS_DIR /srv/userscripts

ENV DEBIAN_FRONTEND noninteractive
ENV USER root

# Configurable environment variables
####################################

# By default we want to use CCACHE, you can disable this
# WARNING: disabling this may slow down a lot your builds!
ENV USE_CCACHE 1

# ccache maximum size. It should be a number followed by an optional suffix: k,
# M, G, T (decimal), Ki, Mi, Gi or Ti (binary). The default suffix is G. Use 0
# for no limit.
ENV CCACHE_SIZE 50G

# Environment for the /e/ branches name
# See https://github.com/LineageOS/android_vendor_cm/branches for possible options
ENV BRANCH_NAME 'v1-pie'

# Environment for the device
# eg. DEVICE=hammerhead
ENV DEVICE ''

# Release type string
ENV RELEASE_TYPE 'UNOFFICIAL'

# Repo use for build
ENV REPO 'https://gitlab.e.foundation/e/os/android.git'

# User identity
ENV USER_NAME '/e/ robot'
ENV USER_MAIL 'erobot@e.email'

# Include proprietary files, downloaded automatically from github.com/TheMuppets/
# Only some branches are supported
ENV INCLUDE_PROPRIETARY true

# If you want to preserve old ZIPs set this to 'false'
ENV CLEAN_OUTDIR false

# Change this cron rule to what fits best for you
# Use 'now' to start the build immediately
# For example, '0 10 * * *' means 'Every day at 10:00 UTC'
ENV CRONTAB_TIME 'now'

# Clean artifacts output after each build
ENV CLEAN_AFTER_BUILD true

# Provide a default JACK configuration in order to avoid out-of-memory issues
ENV ANDROID_JACK_VM_ARGS "-Dfile.encoding=UTF-8 -XX:+TieredCompilation -Xmx4G"

# Custom packages to be installed
ENV CUSTOM_PACKAGES ''

# Sign the builds with the keys in $KEYS_DIR
ENV SIGN_BUILDS false

# When SIGN_BUILDS = true but no keys have been provided, generate a new set with this subject
ENV KEYS_SUBJECT '/C=US/ST=California/L=Mountain View/O=Android/OU=Android/CN=Android/emailAddress=android@android.com'

# Move the resulting zips to $ZIP_DIR/$codename instead of $ZIP_DIR/
ENV ZIP_SUBDIR true

# Write the verbose logs to $LOGS_DIR/$codename instead of $LOGS_DIR/
ENV LOGS_SUBDIR true

# Backup the .img in addition to zips
ENV BACKUP_IMG false

# Generate delta files
ENV BUILD_DELTA false

# Delete old zips in $ZIP_DIR, keep only the N latest one (0 to disable)
ENV DELETE_OLD_ZIPS 0

# Delete old deltas in $DELTA_DIR, keep only the N latest one (0 to disable)
ENV DELETE_OLD_DELTAS 0

# Delete old logs in $LOGS_DIR, keep only the N latest one (0 to disable)
ENV DELETE_OLD_LOGS 0

# Create a JSON file that indexes the build zips at the end of the build process
# (for the updates in OpenDelta). The file will be created in $ZIP_DIR with the
# specified name; leave empty to skip it.
# Requires ZIP_SUBDIR.
ENV OPENDELTA_BUILDS_JSON ''

# Save recovery image
ENV RECOVERY_IMG false

# Ship with Minimal Apps
ENV MINIMAL_APPS false

# You can optionally specify a USERSCRIPTS_DIR volume containing these scripts:
#  * begin.sh, run at the very beginning
#  * before.sh, run after the syncing and patching, before starting the builds
#  * pre-build.sh, run before the build of every device
#  * post-build.sh, run after the build of every device
#  * end.sh, run at the very end
# Each script will be run in $SRC_DIR and must be owned and writeable only by
# root

# Create Volume entry points
############################
VOLUME $SRC_DIR
VOLUME $CCACHE_DIR
VOLUME $ZIP_DIR
VOLUME $LMANIFEST_DIR
VOLUME $DELTA_DIR
VOLUME $KEYS_DIR
VOLUME $LOGS_DIR
VOLUME $USERSCRIPTS_DIR
VOLUME /root/.ssh

# Copy required files
#####################
COPY src/ /root/

# Create missing directories
############################
RUN mkdir -p $SRC_DIR
RUN mkdir -p $CCACHE_DIR
RUN mkdir -p $ZIP_DIR
RUN mkdir -p $LMANIFEST_DIR
RUN mkdir -p $DELTA_DIR
RUN mkdir -p $KEYS_DIR
RUN mkdir -p $LOGS_DIR
RUN mkdir -p $USERSCRIPTS_DIR

# Install build dependencies
############################
COPY apt_preferences /etc/apt/preferences

RUN echo 'deb http://deb.debian.org/debian sid main' >> /etc/apt/sources.list
RUN echo 'deb http://deb.debian.org/debian experimental main' >> /etc/apt/sources.list
RUN apt-get -qq update
RUN apt-get -qqy upgrade

RUN apt-get install -y bc bison bsdmainutils build-essential ccache cgpt cron \
      curl flex g++-multilib gcc-multilib git gnupg gperf imagemagick kmod \
      lib32ncurses5-dev libncurses5 lib32readline-dev lib32z1-dev libtinfo5 liblz4-tool \
      libncurses5-dev libsdl1.2-dev libssl-dev libwxgtk3.0-dev libxml2 \
      libxml2-utils lsof lzop maven pngcrush \
      procps python python3 rsync schedtool squashfs-tools software-properties-common wget xdelta3 xsltproc yasm \
      zip zlib1g-dev

RUN curl https://storage.googleapis.com/git-repo-downloads/repo > /usr/local/bin/repo
RUN chmod a+x /usr/local/bin/repo
RUN ln -fs /usr/bin/python3 /usr/bin/python

# Use adoptopenjdk.net to be able to use OpeJDK8 on debian:buster
RUN curl -q https://adoptopenjdk.jfrog.io/adoptopenjdk/api/gpg/key/public | apt-key add -
RUN add-apt-repository --yes https://adoptopenjdk.jfrog.io/adoptopenjdk/deb/
RUN apt-get -qq update && apt-get install -y adoptopenjdk-8-hotspot
RUN update-alternatives --set java /usr/lib/jvm/adoptopenjdk-8-hotspot-amd64/bin/java

# Download and build delta tools
################################
RUN cd /root/ && \
        mkdir delta && \
        git clone --depth=1 https://gitlab.e.foundation/e/os/android_packages_apps_OpenDelta.git OpenDelta && \
        gcc -o delta/zipadjust OpenDelta/jni/zipadjust.c OpenDelta/jni/zipadjust_run.c -lz && \
        cp OpenDelta/server/minsignapk.jar OpenDelta/server/opendelta.sh delta/ && \
        chmod +x delta/opendelta.sh && \
        rm -rf OpenDelta/ && \
        sed -i -e 's|^\s*HOME=.*|HOME=/root|; \
                   s|^\s*BIN_XDELTA=.*|BIN_XDELTA=xdelta3|; \
                   s|^\s*FILE_MATCH=.*|FILE_MATCH=lineage-\*.zip|; \
                   s|^\s*PATH_CURRENT=.*|PATH_CURRENT=$SRC_DIR/out/target/product/$DEVICE|; \
                   s|^\s*PATH_LAST=.*|PATH_LAST=$SRC_DIR/delta_last/$DEVICE|; \
                   s|^\s*KEY_X509=.*|KEY_X509=$KEYS_DIR/releasekey.x509.pem|; \
                   s|^\s*KEY_PK8=.*|KEY_PK8=$KEYS_DIR/releasekey.pk8|; \
                   s|publish|$DELTA_DIR|g' /root/delta/opendelta.sh

# Set the work directory
########################
WORKDIR $SRC_DIR

# Allow redirection of stdout to docker logs
############################################
RUN ln -sf /proc/1/fd/1 /var/log/docker.log

# Set the entry point to init.sh
################################
ENTRYPOINT /root/init.sh
