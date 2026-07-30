#!/bin/bash -e

GH_VERSION=2.79.0

usage() {
    echo "Script to build and upload Python wheels for couchbase python packages to GitHub releases"
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  -d,           Dry run"
    echo "  -p <product>, Product to build (agentmemory-sdk | agentmemory | mcp-server-couchbase)"
    echo "  -v <version>, Version (required)"
    exit 1
}

prepare_environment() {
    echo "Preparing environment..."
    cbdep install gh ${GH_VERSION}
    export PATH=$(pwd)/install/gh-${GH_VERSION}/bin:${PATH}
    export PATH="/home/couchbase/.rye/shims:${PATH}"
}

get_release_source() {
    echo "Getting source code..."

    rm -rf ${DIST_DIR}
    mkdir -p ${DIST_DIR}

    if [[ "${VERSION}" != v* ]]; then
        VERSION="v${VERSION}"
    fi

    case "${product}" in
        agentmem-sdk)
            echo "Downloading SDK release ${VERSION}..."
            gh release download ${VERSION} --repo couchbaselabs/agentmem-sdk -D ${DIST_DIR} --archive=tar.gz
            ;;
        agentmem)
            echo "Downloading Agent memory release ${VERSION}..."
            gh release download ${VERSION} --repo couchbaselabs/agentmem -D ${DIST_DIR} --archive=tar.gz
            ;;
        mcp-server-couchbase)
            echo "Downloading MCP server release ${VERSION}..."
            gh release download ${VERSION} --repo couchbase/mcp-server-couchbase -D ${DIST_DIR} --archive=tar.gz
            ;;
        *)
            echo "Unknown product: ${product}"
            usage
            ;;
    esac

    tar -xzf ${DIST_DIR}/*.tar.gz -C ${DIST_DIR} --strip-components=1
    rm ${DIST_DIR}/*.tar.gz
}

build_wheels() {
    echo "Building wheels..."
    pushd ${DIST_DIR}
    uv build --wheel
    popd
}

upload_wheels() {
    for wheel in ${DIST_DIR}/dist/*.whl; do
        echo "Uploading ${wheel} to GitHub release ${VERSION}..."
        case "${product}" in
            agentmem-sdk)
                gh release upload ${VERSION} ${wheel} --repo couchbaselabs/agentmem-sdk --clobber
                ;;
            agentmem)
                gh release upload ${VERSION} ${wheel} --repo couchbaselabs/agentmem --clobber
                ;;
            mcp-server-couchbase)
                gh release upload ${VERSION} ${wheel} --repo couchbase/mcp-server-couchbase --clobber
                ;;
            *)
                echo "Unknown product: ${product}"
                usage
                ;;
        esac
    done
}

# Main
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
OPTIND=1
while getopts dp:v: opt
do
    case ${opt} in
        d) dry_run=true
            ;;
        p) product=${OPTARG}
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

if [[ -z "${product}" ]]; then
    usage
fi

DIST_DIR=${SCRIPT_DIR}/dist
prepare_environment
get_release_source
build_wheels

if [[ "${dry_run}" != true ]]; then
    upload_wheels
fi
