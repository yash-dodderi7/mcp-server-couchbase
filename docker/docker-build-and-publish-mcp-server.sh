#!/bin/bash -e

usage() {
    echo "mcp-server-couchbase Docker Build and Push Script"
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  -d, Dry run"
    echo "  -i, Publish to internal registry"
    echo "  -l, Tag image as :latest"
    echo "  -v, Version (required)"
    exit 1
}

prepare_environment() {
    echo "Preparing environment..."
    cbdep install gh ${GH_VERSION}
    export PATH=`pwd`/install/gh-${GH_VERSION}/bin:${PATH}
}

get_source() {
    echo "Downloading mcp-server-couchbase source for version ${VERSION}..."

    if [[ "${VERSION}" != v* ]]; then
        VERSION="v${VERSION}"
    fi

    rm -rf ${REPO_DIR}
    mkdir -p ${REPO_DIR}

    gh release download ${VERSION} --repo yash-dodderi7/mcp-server-couchbase -D ${REPO_DIR} --archive=tar.gz
    tar -xz -C ${REPO_DIR} --strip-components=1 -f ${REPO_DIR}/*.tar.gz

    echo "Downloading wheel for version ${VERSION}..."
    cd ${REPO_DIR}
    gh release download ${VERSION} --repo yash-dodderi7/mcp-server-couchbase --pattern "*.whl"

    rm -rf "${WHEEL_CTX}"
    mkdir -p "${WHEEL_CTX}/wheels"
    cp *.whl "${WHEEL_CTX}/wheels/"
}

build_and_push_image() {
    echo "Building Docker image..."
    local args=(
        --progress=plain
        --build-context "wheel-builder=${WHEEL_CTX}"
    )

    if [[ "${internal}" == true ]]; then
        args+=(-t ${IMAGE}:${TAG})
        if [[ "${tag_latest}" == true ]]; then
            args+=(-t ${IMAGE}:latest)
        fi
        if [[ "${dry_run}" != true ]]; then
            args+=(--push)
        fi
        docker buildx build "${args[@]}" \
            --platform linux/amd64,linux/arm64 .
    else
        # Strip any -rc suffix: a QE-certified 1.0.0-rc2 is published to the
        # external registry as the production version 1.0.0.
        local release_version="${VERSION%-rc*}"
        args+=(-t ${IMAGE}:${release_version})
        if [[ "${tag_latest}" == true ]]; then
            args+=(-t ${IMAGE}:latest)
        fi
        if [[ "${dry_run}" != true ]]; then
            args+=(--push)
        fi
        docker buildx build "${args[@]}" \
            --platform linux/amd64,linux/arm64 .
    fi
}

# Main
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
OPTIND=1
while getopts dilv: opt
do
    case ${opt} in
        d) dry_run=true
            ;;
        i) internal=true
            ;;
        l) tag_latest=true
            ;;
        v) VERSION=${OPTARG}
            if [[ "${VERSION}" == -* ]]; then
                echo "Error: -v requires a version value, got ${VERSION}"
                usage
            fi
            ;;
        *) usage
            ;;
    esac
done

if [[ -z "${VERSION}" ]]; then
    usage
fi

GH_VERSION=${GH_VERSION:-2.79.0}
REPO_DIR=${SCRIPT_DIR}/mcp-server-couchbase
WHEEL_CTX=${SCRIPT_DIR}/wheel-ctx
TAG=${VERSION}

if [[ "${internal}" == true ]]; then
    IMAGE="build-docker.couchbase.com/cb-vanilla/mcp-server-couchbase"
else
    IMAGE="couchbase/mcp-server-couchbase"
fi

prepare_environment
get_source
build_and_push_image