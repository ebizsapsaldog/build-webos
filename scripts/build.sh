#!/bin/bash

# Copyright (c) 2013 LG Electronics, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Uncomment line below for debugging
#set -x

# Some constants
SCRIPT_VERSION="3.2.4"
AUTHORITATIVE_OFFICIAL_BUILD_SITE="svl"

BUILD_REPO="build-webos"
BUILD_LAYERS=("meta-webos"
              "meta-webos-backports")

# Create BOM files, by default disabled
CREATE_BOM=

# Dump signatures, by default disabled
SIGNATURES=

# We assume that script is inside scripts subfolder of build project
# and form paths based on that
CALLDIR=${PWD}

TIMESTAMP_START=`date +%s`
TIMESTAMP_OLD=$TIMESTAMP_START

TIMESTAMP=`date +%s`
TIMEDIFF=`expr $TIMESTAMP - $TIMESTAMP_OLD`
TIMEDIFF_START=`expr $TIMESTAMP - $TIMESTAMP_START`
TIMESTAMP_OLD=$TIMESTAMP
printf "TIME: build.sh start: $TIMESTAMP, +$TIMEDIFF, +$TIMEDIFF_START\n"

TIME_STR="TIME: %e %S %U %P %c %w %R %F %M %x %C"

# We need absolute path for ARTIFACTS
pushd `dirname $0` > /dev/null
SCRIPTDIR=`pwd -P`
popd > /dev/null

# Now let's ensure that:
pushd ${SCRIPTDIR} > /dev/null
if [ ! -d "../scripts" ] ; then
  echo "Make sure that `basename $0` is in scripts folder of project"
  exit 2
fi
popd > /dev/null

cd "${SCRIPTDIR}/.."

BUILD_TOPDIR=`echo "$SCRIPTDIR" | sed 's#/scripts/*##g'`
ARTIFACTS="${BUILD_TOPDIR}/BUILD-ARTIFACTS"
mkdir -p "${ARTIFACTS}"

declare -i RESULT=0

function showusage {
  echo "Usage: `basename $0` -p=path -m=path [OPTION...] [--] BUILD-TARGET..."
  cat <<!
OPTIONS:
  -p, --buildhistory-path  Ignored, for backwards compatibility
  -m, --manifest-path      Ignored, for backwards compatibility
  -I, --images             Images to build
  -T, --targets            Targets to build (unlike images they aren't copied from buildhistory)
  -M, --machines           Machines to build
  -b, --bom                Generate BOM files
  -s, --signatures         Dump sstate signatures, useful to compare why something is rebuilding
  -u, --scp-url            scp will use this path to download and update
                           \${URL}/latest_project_baselines.txt and also
                           \${URL}/history will be populated
  -V, --version            Show script version
  -h, --help               Print this help message
!
  exit 0
}

function check_project {
# Check out appropriate refspec for layer verification based on GERRIT_PROJECT
# or master if we assume other layers stable
  layer=`basename $1`
  if [ -d "${layer}" ] ; then
    pushd "${layer}" >/dev/null
    if [ "$GERRIT_PROJECT" = "$1" ] ; then
      REMOTE=origin
      if [ "${layer}" = "meta-webos" -o "${layer}" = "meta-webos-backports" ]; then
        # We cannot use origin, because by default it points to
        # github.com/openwebos not to g2g and we won't find GERRIT_REFSPEC on github
        REMOTE=ssh://g2g.palm.com/${layer}
      fi
      git fetch $REMOTE $GERRIT_REFSPEC
      echo "NOTE: Checking out $layer in $GERRIT_REFSPEC" >&2
      git checkout FETCH_HEAD
    else
      # for incremental builds we should add "git fetch" here
      echo "NOTE: Checking out $layer in origin/master" >&2
      git checkout remotes/origin/master
    fi
    popd >/dev/null
  fi
}

function check_project_vars {
  # Check out appropriate refspec passed in <layer-name>_commit
  # when requested by use_<layer-name>_commit
  layer=`basename $1`
  use=$(eval echo \$"use_${layer//-/_}_commit")
  ref=$(eval echo "\$${layer//-/_}_commit")
  if [ "$use" = "true" ]; then
    echo "NOTE: Checking out $layer in $ref" >&2
    ldesc=" $layer:$ref"
    if [ -d "${layer}" ] ; then
      pushd "${layer}" >/dev/null
      if echo $ref | grep -q '^refs/changes/'; then
        REMOTE=origin
        if [ "${layer}" = "meta-webos" -o "${layer}" = "meta-webos-backports" ]; then
          # We cannot use origin, because by default it points to
          # github.com/openwebos not to g2g and we won't find GERRIT_REFSPEC on github
          REMOTE=ssh://g2g.palm.com/${layer}
        fi
        git fetch $REMOTE $ref
        git checkout FETCH_HEAD
      else
        # for incremental builds we should add "git fetch" here
        git checkout $ref
      fi
      popd >/dev/null
    else
      echo "ERROR: Layer $layer does not exist!" >&2
    fi
  fi
  echo "$ldesc"
}

TEMP=`getopt -o p:m:I:T:M:bshVu: --long buildhistory-path:,manifest-path:,images:,targets:,machines:,bom,signatures,help,version,scp-url: \
     -n $(basename $0) -- "$@"`

if [ $? != 0 ] ; then echo "Terminating..." >&2 ; exit 2 ; fi

# Note the quotes around `$TEMP': they are essential!
eval set -- "$TEMP"

while true ; do
  case $1 in
    -p|--buildhistory-path) echo "-p|--buildhistory-path is ignored now, you should remove it from your script" ; shift 2 ;;
    -m|--manifest-path) echo "-m|--manifest-path is ignored now, you should remove it from your script" ; shift 2 ;;
    -I|--images) IMAGES="$2" ; shift 2 ;;
    -T|--targets) TARGETS="$2" ; shift 2 ;;
    -M|--machines) MACHINES="$2" ; shift 2 ;;
    -b|--bom) CREATE_BOM="Y" ; shift ;;
    -s|--signatures) SIGNATURES="Y" ; shift ;;
    -h|--help) showusage ; shift ;;
    -u|--scp-url) URL="$2" ; shift 2 ;;
    -V|--version) echo `basename $0` ${SCRIPT_VERSION}; exit ;;
    --) shift ; break ;;
    *) showusage ;;
  esac
done

# Has mcf been run and generated a makefile?
if [ ! -f "Makefile" ] ; then
  echo "Make sure that mcf has been run and Makefile has been generated"
  exit 2
fi

# JENKINS_URL is set by the Jenkins executor. If it's not set or if it's not
# recognized, then the build is, by definition, unofficial.
if [ -n "${JENKINS_URL}" ]; then
  # when we're running with JENKINS_URL set we assume that buildhistory repo is on gerrit server (needs refs/heads/ prefix)
  BUILDHISTORY_BRANCH_PREFIX="refs/heads/"
  case "${JENKINS_URL}" in
    https://gecko.palm.com/jenkins/)
       site="svl"
       ;;

    https://anaconda.palm.com/jenkins/)
       site="svl"
       # we need to prefix branch name, because anaconda as well as gecko have jobs with the same name, e.g. build-webos-verify-qemux86
       BUILDHISTORY_BRANCH_PREFIX="${BUILDHISTORY_BRANCH_PREFIX}anaconda-"
       ;;

    https://anaconda.palm.com/jenkins/)
       # Since anaconda is not intended for official builds
       unset JENKINS_URL
       ;;

    # Add detection of other sites here

    *) echo "Unrecognized JENKINS_URL: '${JENKINS_URL}'"
       unset JENKINS_URL
       ;;
  esac
fi

if [ -z "${JENKINS_URL}" ]; then
  # Let the distro determine the policy on setting WEBOS_DISTRO_BUILD_ID when builds
  # are unofficial
  # Don't unset BUILDHISTORY_BRANCH so that someone can use build.sh to maintain a local buildhistory repo.
  unset WEBOS_DISTRO_BUILD_ID
else
  # JOB_NAME is set by the Jenkins executor
  if [ -z "${JOB_NAME}" ] ; then
    echo "JENKINS_URL set but JOB_NAME isn't"
    exit 1
  fi

  # default is whole job name
  BUILDHISTORY_BRANCH="${JOB_NAME}-${BUILD_NUMBER}"

  # It's not expected that this script would ever be used for Open webOS as is,
  # but the tests for it have been added as a guide for creating that edition.
  case ${JOB_NAME} in
    build-*-official-*)
       job_type="official"
       ;;

    build-*-engineering-*)
       job_type="engr"
       ;;

    clean-engineering-*)
       # it cannot be verf or engr, because clean builds are managing layer checkouts alone
       job_type="clean"
       ;;

    # The build-*-integrate-* jobs are the verification builds done right before
    # the official builds. They have different names so that they can use a
    # separate, special pool of Jenkins slaves.
    build-*-verify-*|build-*-integrate-*)
       job_type="verf"
       ;;

    # Legacy job names

    build-webos-pro|build-webos-nightly|build-webos|build-webos-qemu*)
       job_type="official"
       ;;

    *-layers-verification)
       job_type="verf"
       ;;

    build-webos-*)
       job_type="${JOB_NAME#build-webos-}"
       ;;

    # Add detection of other job types here

    *) echo "Unrecognized JOB_NAME: '${JOB_NAME}'"
       job_type="unrecognized!${JOB_NAME}"
       ;;
    esac

  # Convert job_types we recognize into abbreviations
  case $job_type in
    engineering)
      job_type="engr"
      ;;
  esac

  # If this is an official build, no job_type prefix appears in
  # WEBOS_DISTRO_BUILD_ID regardless of the build site.
  if [ ${job_type} = "official" ]; then
    if [ ${site} = ${AUTHORITATIVE_OFFICIAL_BUILD_SITE} ]; then
      site=""
    fi
    job_type=""
    # checkouts master, pushes to master - We assume that there won't be two slaves
    # doing official build at the same time, second build will fail to push buildhistory
    # when this assumption is broken.
    BUILDHISTORY_BRANCH="master"
  else
    # job_type can not contain any hyphens (except the trailing separator)
    job_type="${job_type//-/}-"
  fi

  if [ -n "${site}" ]; then
    site="${site}:"
  fi

  # BUILD_NUMBER should be set by the Jenkins executor
  if [ -z "${BUILD_NUMBER}" ] ; then
    echo "JENKINS_URL set but BUILD_NUMBER isn't"
    exit 1
  fi
  export WEBOS_DISTRO_BUILD_ID=${site}${job_type}${BUILD_NUMBER}
fi

# Generate BOM files with metadata checked out by mcf (pinned versions)
if [ -n "${CREATE_BOM}" -a -n "${MACHINES}" ]; then
  TIMESTAMP=`date +%s`
  TIMEDIFF=`expr $TIMESTAMP - $TIMESTAMP_OLD`
  TIMEDIFF_START=`expr $TIMESTAMP - $TIMESTAMP_START`
  TIMESTAMP_OLD=$TIMESTAMP
  printf "TIME: build.sh before first bom: $TIMESTAMP, +$TIMEDIFF, +$TIMEDIFF_START\n"

  if [ "$job_type" = "verf-" -o "$job_type" = "engr-" -o "$job_type" = "clean-" ] ; then
    # don't use -before suffix for official builds, because they don't need -after and .diff because
    # there is no logic for using different revisions than weboslayers.py
    BOM_FILE_SUFFIX="-before"
  fi
  for M in ${MACHINES}; do
    if [ ! -d BUILD-${M} ]; then
      echo "ERROR: Build for MACHINE '${M}' was requested in build.sh parameter, but mcf haven't prepared BUILD-${M} directory"
      continue
    fi
    cd BUILD-${M};
    . bitbake.rc
    for I in ${IMAGES} ${TARGETS}; do
      mkdir -p "${ARTIFACTS}/${M}/${I}" || true
      /usr/bin/time -f "$TIME_STR" bitbake ${BBFLAGS} -g ${I}
      grep '^"\([^"]*\)" \[label="\([^ ]*\) :\([^\\]*\)\\n\([^"]*\)"\]$' package-depends.dot |\
        grep -v '^"\([^"]*\)" \[label="\([^ (]*([^ ]*)\) :\([^\\]*\)\\n\([^"]*\)"\]$' |\
          sed 's/^"\([^"]*\)" \[label="\([^ ]*\) :\([^\\]*\)\\n\([^"]*\)"\]$/\1;\2;\3;\4/g' |\
            sed "s#$BUILD_TOPDIR/BUILD-$M/.././##g" |\
              sort > ${ARTIFACTS}/${M}/${I}/bom${BOM_FILE_SUFFIX}.txt
    done
    cd ..
  done
fi

TIMESTAMP=`date +%s`
TIMEDIFF=`expr $TIMESTAMP - $TIMESTAMP_OLD`
TIMEDIFF_START=`expr $TIMESTAMP - $TIMESTAMP_START`
TIMESTAMP_OLD=$TIMESTAMP
printf "TIME: build.sh before verf/engr/clean logic: $TIMESTAMP, +$TIMEDIFF, +$TIMEDIFF_START\n"

# Be aware there is '-' already appended from job_type="${job_type//-/}-" above
if [ "$job_type" = "verf-" -o "$job_type" = "engr-" ] ; then
  if [ "$GERRIT_PROJECT" != "${BUILD_REPO}" ] ; then
    set -e # checkout issues are critical for verification and engineering builds
    for project in "${BUILD_LAYERS[@]}" ; do
      check_project ${project}
    done
    set +e
  fi
  # use -k for verf and engr builds, see [ES-85]
  BBFLAGS="${BBFLAGS} -k"
fi

# Be aware there is '-' already appended from job_type="${job_type//-/}-" above
if [ "$job_type" = "clean-" ] ; then
  set -e # checkout issues are critical for clean build
  desc="[DESC]"
  for project in "${BUILD_LAYERS[@]}" ; do
    desc="${desc}`check_project_vars ${project}`"
  done
  # This is picked by regexp in jenkins config as description of the build
  echo $desc
  set +e
fi

# Generate BOM files again, this time with metadata possibly different for engineering and verification builds
if [ -n "${CREATE_BOM}" -a -n "${MACHINES}" ]; then
  if [ "$job_type" = "verf-" -o "$job_type" = "engr-" -o "$job_type" = "clean-" ] ; then
    TIMESTAMP=`date +%s`
    TIMEDIFF=`expr $TIMESTAMP - $TIMESTAMP_OLD`
    TIMEDIFF_START=`expr $TIMESTAMP - $TIMESTAMP_START`
    TIMESTAMP_OLD=$TIMESTAMP
    printf "TIME: build.sh before 2nd bom: $TIMESTAMP, +$TIMEDIFF, +$TIMEDIFF_START\n"

    for M in ${MACHINES}; do
      if [ ! -d BUILD-${M} ]; then
        echo "ERROR: Build for MACHINE '${M}' was requested in build.sh parameter, but mcf haven't prepared BUILD-${M} directory"
        continue
      fi
      cd BUILD-${M};
      . bitbake.rc
      for I in ${IMAGES} ${TARGETS}; do
        mkdir -p "${ARTIFACTS}/${M}/${I}" || true
        /usr/bin/time -f "$TIME_STR" bitbake ${BBFLAGS} -g ${I}
        grep '^"\([^"]*\)" \[label="\([^ ]*\) :\([^\\]*\)\\n\([^"]*\)"\]$' package-depends.dot |\
          grep -v '^"\([^"]*\)" \[label="\([^ (]*([^ ]*)\) :\([^\\]*\)\\n\([^"]*\)"\]$' |\
            sed 's/^"\([^"]*\)" \[label="\([^ ]*\) :\([^\\]*\)\\n\([^"]*\)"\]$/\1;\2;\3;\4/g' |\
              sed "s#$BUILD_TOPDIR/BUILD-$M/.././##g" |\
                sort > ${ARTIFACTS}/${M}/${I}/bom-after.txt
        diff ${ARTIFACTS}/${M}/${I}/bom-before.txt ${ARTIFACTS}/${M}/${I}/bom-after.txt > ${ARTIFACTS}/${M}/${I}/bom-diff.txt
      done
      cd ..
    done
  fi
fi

TIMESTAMP=`date +%s`
TIMEDIFF=`expr $TIMESTAMP - $TIMESTAMP_OLD`
TIMEDIFF_START=`expr $TIMESTAMP - $TIMESTAMP_START`
TIMESTAMP_OLD=$TIMESTAMP
printf "TIME: build.sh before signatures: $TIMESTAMP, +$TIMEDIFF, +$TIMEDIFF_START\n"

if [ -n "${SIGNATURES}" -a -n "${MACHINES}" ]; then
  for M in ${MACHINES}; do
    if [ ! -d BUILD-${M} ]; then
      echo "ERROR: Build for MACHINE '${M}' was requested in build.sh parameter, but mcf haven't prepared BUILD-${M} directory"
      continue
    fi
    cd BUILD-${M};
    . bitbake.rc
    mkdir -p "${ARTIFACTS}/${M}" || true
    # normally this is executed for all MACHINEs togethere, but we're using MACHINE-specific BSP layers
    ../oe-core/scripts/sstate-diff-machines.sh --tmpdir=. --targets="${IMAGES} ${TARGETS}" --machines="${M}"
    tar cjvf ${ARTIFACTS}/${M}/sstate-diff.tar.bz2 sstate-diff --remove-files
    cd ..
  done
fi

# If there is git checkout in buildhistory dir and we have BUILDHISTORY_BRANCH
# add or replace push repo in webos-local
# Write it this way so that BUILDHISTORY_PUSH_REPO is kept in the same place in webos-local.conf
if [ -d "buildhistory/.git" -a -n "${BUILDHISTORY_BRANCH}" ] ; then
  if [ -f webos-local.conf ] && grep -q ^BUILDHISTORY_PUSH_REPO webos-local.conf ; then
    sed "s#^BUILDHISTORY_PUSH_REPO.*#BUILDHISTORY_PUSH_REPO ?= \"origin master:${BUILDHISTORY_BRANCH_PREFIX}${BUILDHISTORY_BRANCH} 2>/dev/null\"#g" -i webos-local.conf
  else
    echo "BUILDHISTORY_PUSH_REPO ?= \"origin master:${BUILDHISTORY_BRANCH_PREFIX}${BUILDHISTORY_BRANCH} 2>/dev/null\"" >> webos-local.conf
  fi
else
  [ -f webos-local.conf ] && sed "/^BUILDHISTORY_PUSH_REPO.*/d" -i webos-local.conf
fi

TIMESTAMP=`date +%s`
TIMEDIFF=`expr $TIMESTAMP - $TIMESTAMP_OLD`
TIMEDIFF_START=`expr $TIMESTAMP - $TIMESTAMP_START`
TIMESTAMP_OLD=$TIMESTAMP
printf "TIME: build.sh before main build: $TIMESTAMP, +$TIMEDIFF, +$TIMEDIFF_START\n"

FIRST_IMAGE=
if [ -n "${MACHINES}" ]; then
  for M in ${MACHINES}; do
    if [ ! -d BUILD-${M} ]; then
      echo "ERROR: Build for MACHINE '${M}' was requested in build.sh parameter, but mcf haven't prepared BUILD-${M} directory"
      RESULT+=1 # let it continue to build other machines, but in the end report error code
      continue
    fi
    cd BUILD-${M};
    . bitbake.rc
    /usr/bin/time -f "$TIME_STR" bitbake ${BBFLAGS} ${IMAGES} ${TARGETS}

    # Be aware that non-zero exit code from bitbake doesn't always mean that images weren't created.
    # All images were created if it shows "all succeeded" in" Tasks Summary":
    # NOTE: Tasks Summary: Attempted 5450 tasks of which 5205 didn't need to be rerun and all succeeded.

    # Sometimes it's followed by:
    # Summary: There were 2 ERROR messages shown, returning a non-zero exit code.
    # the ERRORs can be from failed setscene tasks or from QA checks, but weren't fatal for build.

    # Collect exit codes to return them from this script.
    RESULT+=$?

    mkdir -p "${ARTIFACTS}/${M}" || true
    # copy webosvbox if we've built vmdk image
    cp qa.log ${ARTIFACTS}/${M} || true
    cp WEBOS_BOM_data.pkl ${ARTIFACTS}/${M} || true
    for I in ${IMAGES}; do
      mkdir -p "${ARTIFACTS}/${M}/${I}" || true
      # we store only tar.gz, vmdk.zip and .epk images
      # and we don't publish kernel images anymore
      if ls deploy/images/${I}-${M}-*.vmdk >/dev/null 2>/dev/null; then
        if type zip >/dev/null 2>/dev/null; then
          # zip vmdk images if they exists
          find deploy/images/${I}-${M}-*.vmdk -exec zip -j {}.zip {} \; || true
          mv deploy/images/${I}-${M}-*.vmdk.zip ${ARTIFACTS}/${M}/${I}/ || true
        else
          # report failure and publish vmdk
          RESULT+=1
          mv deploy/images/${I}-${M}-*.vmdk ${ARTIFACTS}/${M}/${I}/ || true
        fi
        cp ../meta-webos/scripts/webosvbox ${ARTIFACTS}/${M} || true
      else
        mv deploy/images/${I}-${M}-*.tar.gz deploy/images/${I}-${M}-*.epk ${ARTIFACTS}/${M}/${I}/ || true
      fi
      FOUND_IMAGE="false"
      # Add .md5 files for image files, if they are missing or older than image file
      for IMG_FILE in ${ARTIFACTS}/${M}/${I}/*.vmdk* ${ARTIFACTS}/${M}/${I}/*.tar.gz ${ARTIFACTS}/${M}/${I}/*.epk; do
        if echo $IMG_FILE | grep -q "\.md5$"; then
          continue
        fi
        if [ -e ${IMG_FILE} -a ! -h ${IMG_FILE} ] ; then
          FOUND_IMAGE="true"
          if [ ! -e ${IMG_FILE}.md5 -o ${IMG_FILE}.md5 -ot ${IMG_FILE} ] ; then
            echo MD5: ${IMG_FILE}
            md5sum ${IMG_FILE} | sed 's#  .*/#  #g' > ${IMG_FILE}.md5
          fi
        fi
      done

      # copy few interesting buildhistory reports only if the image was really created
      # (otherwise old report from previous build checked out from buildhistory repo could be used)
      if [ "${FOUND_IMAGE}" = "true" ] ; then
        if [ -f ../buildhistory/images/${M}/eglibc/${I}/build-id.txt ]; then
          cp ../buildhistory/images/${M}/eglibc/${I}/build-id.txt ${ARTIFACTS}/${M}/${I}/build-id.txt
        else
          cp ../buildhistory/images/${M}/eglibc/${I}/build-id ${ARTIFACTS}/${M}/${I}/build-id.txt
        fi
        if [ -n "$FIRST_IMAGE" ] ; then
          # store build-id.txt from first IMAGE and first MACHINE as representant of whole build for InfoBadge
          # instead of requiring jenkins job to hardcode MACHINE/IMAGE name in:
          # manager.addInfoBadge("${manager.build.getWorkspace().child('buildhistory/images/qemux86/eglibc/webos-image/build-id.txt').readToString()}")
          # we should be able to use:
          # manager.addInfoBadge("${manager.build.getWorkspace().child('BUILD-ARTIFACTS/build-id.txt').readToString()}")
          # in all builds (making BUILD_IMAGES/BUILD_MACHINE changes less error-prone)
          FIRST_IMAGE="${M}/${I}"
          cp ${ARTIFACTS}/${M}/${I}/build-id.txt ${ARTIFACTS}/build-id.txt
        fi
        cp ../buildhistory/images/${M}/eglibc/${I}/image-info.txt ${ARTIFACTS}/${M}/${I}/image-info.txt
        cp ../buildhistory/images/${M}/eglibc/${I}/files-in-image.txt ${ARTIFACTS}/${M}/${I}/files-in-image.txt
        cp ../buildhistory/images/${M}/eglibc/${I}/installed-packages.txt ${ARTIFACTS}/${M}/${I}/installed-packages.txt
        cp ../buildhistory/images/${M}/eglibc/${I}/installed-package-sizes.txt ${ARTIFACTS}/${M}/${I}/installed-package-sizes.txt
      fi
    done
    cd ..
  done
else
  BUILD_TARGET_FIRST="$1"
  if [ -n "${BUILD_TARGET_FIRST}" ]; then
    echo "Change your scripts to use new -I and -M parameters"
  fi

  shift

  for arg do BUILD_TARGETS="${BUILD_TARGETS} ${arg}" ; done

  # Ugly hack to pass all build targets in one bitbake call
  export BBFLAGS="${BBFLAGS} ${BUILD_TARGETS}"

  make ${BUILD_TARGET_FIRST}
  RESULT+=$?
fi

TIMESTAMP=`date +%s`
TIMEDIFF=`expr $TIMESTAMP - $TIMESTAMP_OLD`
TIMEDIFF_START=`expr $TIMESTAMP - $TIMESTAMP_START`
TIMESTAMP_OLD=$TIMESTAMP
printf "TIME: build.sh before package-src-uris: $TIMESTAMP, +$TIMEDIFF, +$TIMEDIFF_START\n"

# Generate list of SRC_URI and SRCREV values for all components
echo "NOTE: generating package-srcuris.txt"
BUILDHISTORY_PACKAGE_SRCURIS="package-srcuris.txt"
./meta-webos/scripts/buildhistory-collect-srcuris buildhistory >${BUILDHISTORY_PACKAGE_SRCURIS}
./oe-core/scripts/buildhistory-collect-srcrevs buildhistory >>${BUILDHISTORY_PACKAGE_SRCURIS}
cp ${BUILDHISTORY_PACKAGE_SRCURIS} ${ARTIFACTS} || true

TIMESTAMP=`date +%s`
TIMEDIFF=`expr $TIMESTAMP - $TIMESTAMP_OLD`
TIMEDIFF_START=`expr $TIMESTAMP - $TIMESTAMP_START`
TIMESTAMP_OLD=$TIMESTAMP
printf "TIME: build.sh before baselines: $TIMESTAMP, +$TIMEDIFF, +$TIMEDIFF_START\n"

# Don't do these for unofficial builds
if [ -n "${WEBOS_DISTRO_BUILD_ID}" ]; then
  if [ ! -f latest_project_baselines.txt ]; then
    # create dummy, especially useful for verification builds (diff against origin/master)
    echo ". origin/master" > latest_project_baselines.txt
    for project in "${BUILD_LAYERS[@]}" ; do
      layer=`basename ${project}`
      if [ -d "${layer}" ] ; then
        echo "${layer} origin/master" >> latest_project_baselines.txt
      fi
    done
  fi

  command \
    meta-webos/scripts/build-changes/update_build_changes.sh \
      "${BUILD_NUMBER}" \
      "${URL}" 2>&1 || printf "\nChangelog generation failed or script not found.\nPlease check lines above for errors\n"
  cp build_changes.log ${ARTIFACTS} || true
fi

TIMESTAMP=`date +%s`
TIMEDIFF=`expr $TIMESTAMP - $TIMESTAMP_OLD`
TIMEDIFF_START=`expr $TIMESTAMP - $TIMESTAMP_START`
TIMESTAMP_OLD=$TIMESTAMP
printf "TIME: build.sh stop: $TIMESTAMP, +$TIMEDIFF, +$TIMEDIFF_START\n"

cd "${CALLDIR}"

# only the result from bitbake/make is important
exit ${RESULT}

# vim: ts=2 sts=2 sw=2 et
