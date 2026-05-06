#!/bin/bash -e

GH_VERSION=2.79.0

usage() {
    echo "Script to build and upload Agent memory Python wheel to GitHub releases"
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  -d,           Dry run"
    echo "  -s,           Build SDK wheel instead of Agent memory wheel"
    echo "  -v <version>, Version (required)"
    exit 1
}

prepare_environment() {
    echo "Preparing environment..."
    cbdep install gh ${GH_VERSION}
    export PATH=`pwd`/install/gh-${GH_VERSION}/bin:${PATH}
    export PATH="/home/couchbase/.rye/shims:${PATH}"
}

get_release_source() {
    echo "Getting source code..."

    rm -rf ${DIST_DIR}
    mkdir -p ${DIST_DIR}

    if [[ "${VERSION}" != v* ]]; then
        VERSION="v${VERSION}"
    fi

    if [[ "${sdk}" == true ]]; then
        echo "Downloading SDK release ${VERSION}..."
        gh release download ${VERSION} --repo couchbaselabs/agentmem-sdk -D ${DIST_DIR} --archive=tar.gz
    else
        echo "Downloading Agent memory release ${VERSION}..."
        gh release download ${VERSION} --repo couchbaselabs/agentmem -D ${DIST_DIR} --archive=tar.gz
    fi

    tar -xzf ${DIST_DIR}/*.tar.gz -C ${DIST_DIR} --strip-components=1
    rm ${DIST_DIR}/*.tar.gz
}

build_wheels() {
    echo "Building wheels..."
    cd ${DIST_DIR}
    uv build --wheel
}

upload_wheels() {
    for wheel in ${DIST_DIR}/dist/*.whl; do
        echo "Uploading ${wheel} to GitHub release ${VERSION}..."
        if [[ "${sdk}" == true ]]; then
            gh release upload ${VERSION} ${wheel} --repo couchbaselabs/agentmem-sdk --clobber
        else
            gh release upload ${VERSION} ${wheel} --repo couchbaselabs/agentmem --clobber
        fi
    done
}

# Main
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
OPTIND=1
while getopts dsv: opt
do
    case ${opt} in
        d) dry_run=true
            ;;
        s) sdk=true
            ;;
        v) VERSION=${OPTARG}
            ;;
        *) usage
            ;;
    esac
done

if [[ -z "${VERSION}" ]]; then
    usage
fi

DIST_DIR=${SCRIPT_DIR}/dist
prepare_environment
get_release_source
build_wheels

if [[ "${dry_run}" != true ]]; then
    upload_wheels
fi
