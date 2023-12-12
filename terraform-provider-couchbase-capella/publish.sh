#!/bin/bash -ex

function usage() {
  echo
  echo "$0 -p <product> -v <version> -r <release> -b <build-number>"
  echo "where:"
  echo "  -p: product"
  echo "  -r: release"
  echo "  -v: version number"
  echo "  -b: build number"
  echo
}

function gh_auth() {
  # github_token is a predefined variable either from jenkins or from command line
  echo "${github_token}" | gh auth login --with-token
}

function publish() {
  SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
  ${SCRIPT_DIR}/../utilities/sync_historic_manifest \
    ${PRODUCT} ${RELEASE} ${VERSION} ${BLD_NUM} ./src

  pushd src/${PRODUCT}
  # generate changelog
  docker run --rm -v /tmp:/usr/local/src/your-app githubchangeloggenerator/github-changelog-generator \
    --user couchbasecloud \
    --project ${PRODUCT} \
    -t ${github_token} \
    --future-release ${VERSION}
  mv /tmp/CHANGELOG.md .
  SHA=$(git rev-list HEAD | head -1)
  LATESTBUILD_URL="https://latestbuilds.service.couchbase.com/builds/latestbuilds"
  for plat in darwin_amd64 darwin_arm64 linux_amd64 linux_arm64 windows_amd64; do
    src_file=${PRODUCT}_${VERSION}_${BLD_NUM}_${plat}.zip
    tgt_file=${PRODUCT}_${VERSION}_${plat}.zip
    curl --fail ${LATESTBUILD_URL}/${PRODUCT}/${VERSION}/${BLD_NUM}/${src_file} \
      -o ${tgt_file}
    zip -u ${tgt_file} CHANGELOG.md
  done
  shasum -a 256 *.zip > ${PRODUCT}_${VERSION}_SHA256SUMS
  gpg --no-tty --detach-sign ${PRODUCT}_${VERSION}_SHA256SUMS
  files=$(ls *.zip *_SHA256SUMS *.sig)
  gh release create v${VERSION} ${files} --generate-notes --target ${SHA}
  popd
}

## main
while getopts "b:p:r:v:" opt; do
  case $opt in
    b) BLD_NUM=$OPTARG;;
    p) PRODUCT=$OPTARG;;
    r) RELEASE=$OPTARG;;
    v) VERSION=$OPTARG;;
    *) echo "Invalid argument $opt"
      usage
      exit 1;;
  esac
done

if [[ -z ${PRODUCT} || -z ${VERSION} || -z ${RELEASE} || -z ${BLD_NUM} ]]; then
    usage
    exit 1
fi

gh_auth
publish
