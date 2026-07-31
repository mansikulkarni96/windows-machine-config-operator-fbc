#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

# This script cuts a new patch release in an FBC catalog template: it registers a new version in the
# `stable` channel and promotes the currently staged candidate `olm.bundle` image(s) to the production
# registry, re-staging a copy of the candidate so `hack/release-snapshot.sh` can keep updating it.
#
# Usage:
#   ./hack/promote-release.sh <TARGET_BRANCH>
#
# Parameters:
# - TARGET_BRANCH (required): The release branch whose catalog template should be updated.
#
# Example:
# ./hack/promote-release.sh release-4.22
#
# This will:
# 1. Look up the catalog directory for release-4.22 (v10.22).
# 2. Add the next patch version (e.g. v10.22.2) to the `stable` channel, replacing the previous version.
# 3. Promote all currently staged (registry.stage.redhat.io) olm.bundle images to registry.redhat.io.
# 4. Re-stage a copy of the cut candidate image so future snapshots have a slot to update.
# 5. Commit the updated catalog-template.json.

# import the release catalog map script
source hack/release_catalog_map.sh

# use the first argument as the target branch
TARGET_BRANCH=${1:-}
if [[ -z ${TARGET_BRANCH} ]]; then
  echo "Error: TARGET_BRANCH is required"
  echo "Usage: ./hack/promote-release.sh <TARGET_BRANCH>"
  exit 1
fi

# get the catalog version based on the target branch
CATALOG_TEMPLATE_PATH=$(get_catalog "${TARGET_BRANCH}")
TEMPLATE_FILE="${CATALOG_TEMPLATE_PATH}/catalog-template.json"
echo ""
echo "Catalog template: ${TEMPLATE_FILE}"

if [[ ! -f "${TEMPLATE_FILE}" ]]; then
  echo "Error: ${TEMPLATE_FILE} does not exist"
  exit 1
fi

# refuse to run with unrelated pending changes to the template already staged/unstaged
if [[ -n "$(git status --porcelain -- "${TEMPLATE_FILE}")" ]]; then
  echo "Error: ${TEMPLATE_FILE} has uncommitted changes. Commit or stash them before running this script."
  exit 1
fi

# the package name is derived from the olm.package entry rather than hardcoded
PACKAGE_NAME=$(jq -r '(.entries[] | select(.schema == "olm.package") | .name)' "${TEMPLATE_FILE}")
if [[ -z "${PACKAGE_NAME}" || "${PACKAGE_NAME}" == "null" ]]; then
  echo "Error: cannot find olm.package name in ${TEMPLATE_FILE}"
  exit 1
fi

# the stable channel is the one that keeps growing across patch releases (any preview channel is legacy)
PREV_NAME=$(jq -r '(.entries[] | select(.schema == "olm.channel" and .name == "stable") | .entries[-1].name)' "${TEMPLATE_FILE}")
PREV_SKIPRANGE=$(jq -r '(.entries[] | select(.schema == "olm.channel" and .name == "stable") | .entries[-1].skipRange)' "${TEMPLATE_FILE}")
if [[ -z "${PREV_NAME}" || "${PREV_NAME}" == "null" ]]; then
  echo "Error: cannot find a stable olm.channel with entries in ${TEMPLATE_FILE}"
  exit 1
fi
echo "Latest released version: ${PREV_NAME}"

# read the catalog template file and extract the image value for the last olm.bundle entry
LAST_BUNDLE_IMAGE=$(jq -r 'last(.entries[] | select(.schema == "olm.bundle")) | .image' "${TEMPLATE_FILE}")
if [[ -z "${LAST_BUNDLE_IMAGE}" || "${LAST_BUNDLE_IMAGE}" == "null" ]]; then
  echo "Error: cannot find olm.bundle image entry in ${TEMPLATE_FILE}"
  exit 1
fi
echo "Catalog template last olm.bundle image: ${LAST_BUNDLE_IMAGE}"

# the last olm.bundle entry must be a staged candidate; otherwise there's nothing new to cut
if [[ "${LAST_BUNDLE_IMAGE}" != registry.stage.redhat.io/* ]]; then
  echo "Error: no staged candidate bundle found (last olm.bundle image is not on registry.stage.redhat.io)"
  echo "Run hack/release-snapshot.sh ${TARGET_BRANCH} first"
  exit 1
fi

# compute the new version by bumping the patch number of the previous version
PREV_VERSION="${PREV_NAME#"${PACKAGE_NAME}".v}"
IFS='.' read -r MAJOR MINOR PATCH <<< "${PREV_VERSION}"
NEW_VERSION="${MAJOR}.${MINOR}.$((PATCH + 1))"

# sanity check that the computed version matches the directory this template lives in
CATALOG_VERSION="${CATALOG_TEMPLATE_PATH#v}"
if [[ "${MAJOR}.${MINOR}" != "${CATALOG_VERSION}" ]]; then
  echo "Error: computed version ${MAJOR}.${MINOR} does not match catalog directory ${CATALOG_TEMPLATE_PATH}"
  exit 1
fi

# the skipRange lower bound is carried over unchanged from the previous version
LOWER_BOUND=$(echo "${PREV_SKIPRANGE}" | sed -E 's/^>=([0-9]+\.[0-9]+\.[0-9]+) <.*/\1/')
if [[ -z "${LOWER_BOUND}" ]]; then
  echo "Error: cannot parse lower bound out of skipRange '${PREV_SKIPRANGE}'"
  exit 1
fi

NEW_NAME="${PACKAGE_NAME}.v${NEW_VERSION}"
NEW_SKIPRANGE=">=${LOWER_BOUND} <${NEW_VERSION}"
echo ""
echo "Adding new version: ${NEW_NAME}"
echo "Replaces: ${PREV_NAME}"
echo "skipRange: ${NEW_SKIPRANGE}"

# append the new channel entry, promote every staged olm.bundle image to the production registry, and
# re-stage a copy of the cut candidate so release-snapshot.sh still has a slot to update next time
jq --indent 4 \
  --arg name "${NEW_NAME}" \
  --arg replaces "${PREV_NAME}" \
  --arg skiprange "${NEW_SKIPRANGE}" \
  --arg staged_image "${LAST_BUNDLE_IMAGE}" \
  '
  (.entries[] | select(.schema == "olm.channel" and .name == "stable") | .entries) += [{name: $name, replaces: $replaces, skipRange: $skiprange}]
  | .entries |= map(if .schema == "olm.bundle" then .image |= sub("^registry\\.stage\\.redhat\\.io"; "registry.redhat.io") else . end)
  | .entries += [{schema: "olm.bundle", image: $staged_image}]
  ' "${TEMPLATE_FILE}" > tmp.json && mv tmp.json "${TEMPLATE_FILE}"

echo ""
echo "Promoted staged olm.bundle images to registry.redhat.io"
echo "Re-staged candidate slot with image: ${LAST_BUNDLE_IMAGE}"
echo "Updated ${TEMPLATE_FILE}"

# commit the change
git add "${TEMPLATE_FILE}"
git commit -m "${TARGET_BRANCH}: add v${NEW_VERSION}" \
  -m "This commit was generated using hack/promote_release.sh"

echo ""
echo "Committed ${TARGET_BRANCH}: add v${NEW_VERSION}"

# offer to immediately re-stage the next candidate build for this branch
echo ""
read -r -p "Run hack/release-snapshot.sh ${TARGET_BRANCH} now? [y/N] " RUN_SNAPSHOT || RUN_SNAPSHOT="n"
if [[ "${RUN_SNAPSHOT}" =~ ^[Yy]$ ]]; then
  ./hack/release-snapshot.sh "${TARGET_BRANCH}"
fi

# success
exit 0
