#!/bin/bash -ex

# Simple script for building terraform-provider-couchbase-capella

function usage() {
  echo
  echo "$0 -p <product> -v <version> -b <build-number>"
  echo "where:"
  echo "  -p: product"
  echo "  -v: version number"
  echo "  -b: build number"
  echo
}

function install_deps() {
  SERVER_ARCH=$(uname -m)
  curl -L https://packages.couchbase.com/cbdep/cbdep-linux-${SERVER_ARCH} -o cbdep
  chmod +x cbdep
  TERRAFORM_VER=$(curl -s https://checkpoint-api.hashicorp.com/v1/check/terraform \
    | jq -r -M '.current_version')
  GO_MIN_VER=$(cat go.mod | grep ^go |awk '{print $2}')
  GO_VER=$(echo -e "1.21.3\n${GO_MIN_VER}" |sort -r | head -1)
  ./cbdep install golang ${GO_VER} -d ${WORKSPACE}/extra
  ./cbdep install terraform ${TERRAFORM_VER} -d ${WORKSPACE}/extra
  export PATH=${WORKSPACE}/extra/go${GO_VER}/bin:${WORKSPACE}/extra/terraform-${TERRAFORM_VER}/bin:$PATH
}

function build() {
  export TF_CLI_CONFIG_FILE=${WORKSPACE}/.terraformrc
cat <<EOT >> ${TF_CLI_CONFIG_FILE}
provider_installation {
dev_overrides {
"hashicorp.com/couchabasecloud/capella" = "${WORKSPACE}/extra/go${GO_VER}/bin/"
}
direct {}
}
EOT

  OSTYPES="linux darwin windows"
  for OSTYPE in ${OSTYPES}; do
    case "${OSTYPE}" in
      linux)
        for ARCH in amd64 arm64; do
          GOOS=${OSTYPE} GOARCH=${ARCH} go build -o ${PRODUCT}_v${VERSION}
          zip ${PRODUCT}_${VERSION}_${BLD_NUM}_${OSTYPE}_${ARCH}.zip ${PRODUCT}_v${VERSION} README.md LICENSE
        done
        GOARM=6 GOARCH=arm GOOS=${OSTYPE} go build -o ${PRODUCT}_v${VERSION}
        zip ${PRODUCT}_${VERSION}_${BLD_NUM}_${OSTYPE}_${ARCH}.zip ${PRODUCT}_v${VERSION} README.md LICENSE
        ;;
      darwin)
        for ARCH in amd64 arm64; do
          GOOS=${OSTYPE} GOARCH=${ARCH} go build -o ${PRODUCT}_v${VERSION}
          zip ${PRODUCT}_${VERSION}_${BLD_NUM}_${OSTYPE}_${ARCH}.zip ${PRODUCT}_v${VERSION} README.md LICENSE
        done
        ;;
      windows)
        ARCH=amd64
        GOOS=${OSTYPE} GOARCH=${ARCH} go build -o ${PRODUCT}_v${VERSION}
        zip ${PRODUCT}_${VERSION}_${BLD_NUM}_${OSTYPE}_${ARCH}.zip ${PRODUCT}_v${VERSION} README.md LICENSE
        ;;
      *)
        echo "unknown: $OSTYPE"
        exit 1
        ;;
    esac
  done
}

## main
while getopts "b:p:v:" opt; do
  case $opt in
    b) BLD_NUM=$OPTARG;;
    p) PRODUCT=$OPTARG;;
    v) VERSION=$OPTARG;;
    *) echo "Invalid argument $opt"
      usage
      exit 1;;
  esac
done

if [[ -z ${PRODUCT} || -z ${VERSION} || -z ${BLD_NUM} ]]; then
    usage
    exit 1
fi

pushd ${WORKSPACE}/${PRODUCT}
install_deps
build
popd
