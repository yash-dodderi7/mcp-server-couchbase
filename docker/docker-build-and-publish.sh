#!/bin/bash -e

usage() {
    echo "agentmemory Docker Build and Push Script"
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
    echo "Downloading agentmemory source for version ${VERSION}..."

    if [[ "${VERSION}" != v* ]]; then
        VERSION="v${VERSION}"
    fi

    rm -rf ${REPO_DIR}
    mkdir -p ${REPO_DIR}

    gh release download ${VERSION} --repo couchbaselabs/agentmemory -D ${REPO_DIR} --archive=tar.gz
    tar -xz -C ${REPO_DIR} --strip-components=1 -f ${REPO_DIR}/*.tar.gz

    echo "Downloading wheel for version ${VERSION}..."
    cd ${REPO_DIR}
    gh release download ${VERSION} --repo couchbaselabs/agentmemory --pattern "*.whl"

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
        # Strip any -rc suffix: a QE-certified 1.0.0-rc2 is published to S3 as the
        # production version 1.0.0 (source artifacts still come from the rc tag).
        local release_version="${VERSION%-rc*}"
        args+=(-t ${IMAGE}:${release_version})
        if [[ "${tag_latest}" == true ]]; then
            args+=(-t ${IMAGE}:latest)
        fi
        # A single multi-platform buildx build cannot write a type=docker
        # tarball, so build and export each architecture separately.
        rm -rf "${EXPORT_DIR}"
        mkdir -p "${EXPORT_DIR}"
        for arch in amd64 arm64; do
            local tarball="${EXPORT_DIR}/agentmemory-server-${arch}-${release_version}.tar"
            echo "Building linux/${arch} -> ${tarball}..."
            docker buildx build "${args[@]}" \
                --platform "linux/${arch}" \
                --output "type=docker,dest=${tarball}" .
        done
        if [[ "${dry_run}" == true ]]; then
            echo "Dry run: skipping S3 upload."
        else
            publish_to_s3 "${release_version}"
        fi
    fi
}

publish_to_s3() {
    local version=$1
    echo "Assuming role and publishing tarballs to S3..."

    # set AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY in the Jenkins environment.

    local creds
    creds=$(aws sts assume-role \
        --role-arn "${ROLE_ARN}" \
        --role-session-name "agentmemory-publish" \
        --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
        --output text)

    export AWS_ACCESS_KEY_ID=$(echo "${creds}" | awk '{print $1}')
    export AWS_SECRET_ACCESS_KEY=$(echo "${creds}" | awk '{print $2}')
    export AWS_SESSION_TOKEN=$(echo "${creds}" | awk '{print $3}')

    for arch in amd64 arm64; do
        local tarball="agentmemory-server-${arch}-${version}.tar"
        echo "Uploading ${tarball} to ${S3_BUCKET}/..."
        aws s3 cp "${EXPORT_DIR}/${tarball}" "${S3_BUCKET}/${tarball}"
    done
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
REPO_DIR=${SCRIPT_DIR}/agentmemory
WHEEL_CTX=${SCRIPT_DIR}/wheel-ctx
EXPORT_DIR=${SCRIPT_DIR}/export
TAG=${VERSION}

if [[ "${internal}" == true ]]; then
    IMAGE="build-docker.couchbase.com/cb-vanilla/agentmemory-server"
else
    IMAGE="agentmemory-server"
fi

prepare_environment
get_source
build_and_push_image
