#!/bin/bash

# ECR Image Publishing Script
# This script builds and pushes Docker images to AWS ECR
# Sandbox: images are built and publish
#          create_arch_tags is used to produce ARCH specific tags
# Stage|Prod: images are copied from Sandbox
#          create_arch_tags is used to produce ARCH specific tags
set -e  # Exit on any error

# Help function
usage() {
    echo "ECR Image Publishing Script"
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  -d        Dry run"
    echo "  -s        Source environment: sandbox|stage|production (required)"
    echo "  -t        Target environment: sandbox|stage|production (required)"
    echo "  -p        Product name (required)"
    echo "  -r        Release (required)"
    exit 1
}

# Function to get image configuration
get_image_config() {
    local image=${1}
    local key=${2}
    jq -r --arg product "$PRODUCT" --arg image "$image" --arg key "$key" \
        '.[$product][$image][$key]' "${IMAGES_JSON}"
}

# Function to get full image reference
get_image_reference() {
    local image=${1}
    local ecr=${2}
    local repository=$(get_image_config "${image}" "repository")
    echo "${ecr}/${repository}:${RELEASE}"
}

create_arch_tags() {
    local image_ref="${1}"
    local base_repo="${image_ref%:*}"
    local manifest_json
    local arch_digest


    manifest_json=$(docker buildx imagetools inspect --raw "${image_ref}")
    if [[ -z "${manifest_json}" ]]; then
        ERR_IMAGES+=("${image_ref}")
        echo "Error: Unable to inspect manifest for ${image_ref}"
        return
    fi
    for platform in amd64 arm64; do
        arch_digest="$(echo "${manifest_json}" | jq -r \
        ".manifests[] | select(.platform.os==\"linux\" and .platform.architecture==\"${platform##*/}\") | .digest" \
        | head -n 1)"
        if [[ -z "${arch_digest}" ]]; then
            ERR_IMAGES+=("${base_repo}:${platform}-${RELEASE}")
            echo "Error: Unable to resolve ${platform} digest for ${image_ref}"
        else
            docker buildx imagetools create \
                --tag "${base_repo}:${platform}-${RELEASE}" \
                "${base_repo}@${arch_digest}"
        fi
    done
}

# Function to build Docker image
build_and_push_images() {
    local image_reference
    local docker_file
    local buildx_args

    pushd "${SRC_DIR}"
    for image in "${IMAGES_ARRAY[@]}"; do
        image_reference=$(get_image_reference "${image}" "${TARGET_ECR_REGISTRY}")
        docker_file=$(get_image_config "${image}" "docker_file")
        echo "Building ${image_reference}..."
        buildx_args=(
            -f "${docker_file}"
            --platform "${PLATFORMS}"
            -t "${image_reference}"
        )

        if [[ "${DRY_RUN}" == true ]]; then
            docker buildx build "${buildx_args[@]}" --load .
        else
            echo "Pushing ${image} to ${image_reference}"
            docker buildx build "${buildx_args[@]}" --push .
            # Skip creating multi arch tags if RELEASE starts with amd64 or arm64
            [[ "${RELEASE}" =~ ^amd64.* || "${RELEASE}" =~ ^arm64.* ]] && continue
            create_arch_tags "${image_reference}"
        fi
    done
    popd
}

publish_images() {
    local source_reference
    local target_reference
    for image in "${IMAGES_ARRAY[@]}"; do
        source_reference=$(get_image_reference "${image}" "${SOURCE_ECR_REGISTRY}")
        target_reference=$(get_image_reference "${image}" "${TARGET_ECR_REGISTRY}")
        buildx_args=(
            imagetools create
            --tag "${target_reference}"
            "${source_reference}"
        )
        if [[ "${DRY_RUN}" == true ]]; then
            printf 'docker buildx %s\n' "${buildx_args[@]}"
            continue
        else
            docker buildx "${buildx_args[@]}"
            # Skip creating multi arch tags if RELEASE starts with amd64 or arm64
            [[ "${RELEASE}" =~ ^amd64.* || "${RELEASE}" =~ ^arm64.* ]] && continue
            create_arch_tags "${target_reference}"
        fi
    done
}


# Function to get source code
get_source() {
    echo "Getting source..."
    case ${PRODUCT} in
        vulcan)
            rm -rf vulcan-core
            git clone git@github.com:couchbaselabs/vulcan-core.git
            pushd vulcan-core
            git checkout ${RELEASE}
            export SRC_DIR="$(pwd)"
            popd
           ;;
        *)
            echo "Unknown product: ${PRODUCT}"
            exit 1
            ;;
    esac
}

prepare_environment() {
    if ! docker buildx version >/dev/null 2>&1; then
        echo "Error: docker buildx is required for multi-arch builds"
        exit 1
    fi

    if [[ "${DRY_RUN}" == true ]]; then
        PLATFORMS="linux/amd64"
    else
        PLATFORMS="linux/amd64,linux/arm64"
    fi
    TARGET_AWS_PROFILE=$(jq -r .${TGT_ENV}.aws.ROLE_SESSION_NAME "${SCRIPT_DIR}/../utilities/environments.json")
    TARGET_AWS_ACCOUNT=$(jq -r .${TGT_ENV}.aws.ACCOUNT "${SCRIPT_DIR}/../utilities/environments.json")
    TARGET_ECR_REGISTRY=${TARGET_AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com
    aws ecr get-login-password \
        --region "${AWS_REGION}" \
        --profile "${TARGET_AWS_PROFILE}" | \
        docker login --username AWS --password-stdin "${TARGET_ECR_REGISTRY}"

    if [[ "${SRC_ENV}" != "local" ]]; then
        SOURCE_AWS_PROFILE=$(jq -r .${SRC_ENV}.aws.ROLE_SESSION_NAME "${SCRIPT_DIR}/../utilities/environments.json")
        SOURCE_AWS_ACCOUNT=$(jq -r .${SRC_ENV}.aws.ACCOUNT "${SCRIPT_DIR}/../utilities/environments.json")
        SOURCE_ECR_REGISTRY=${SOURCE_AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com
        aws ecr get-login-password \
            --region "${AWS_REGION}" \
            --profile "${SOURCE_AWS_PROFILE}" | \
            docker login --username AWS --password-stdin "${SOURCE_ECR_REGISTRY}"
    fi
}

# Main
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
source "${SCRIPT_DIR}/../utilities/shell-utils.sh"
DRY_RUN=false
OPTIND=1
AWS_REGION="us-east-1"  # ECR is always in us-east-1
IMAGES_JSON="${SCRIPT_DIR}/images.json"
ERR_IMAGES=()
while getopts dp:r:s:t: opt
do
    case ${opt} in
        d) DRY_RUN=true ;;
        p) PRODUCT=${OPTARG} ;;
        r) RELEASE=${OPTARG} ;;
        s) SRC_ENV=${OPTARG} ;;
        t) TGT_ENV=${OPTARG} ;;
        *) usage ;;
    esac
done

chk_set SRC_ENV TGT_ENV PRODUCT RELEASE
prepare_environment
readarray -t IMAGES_ARRAY < <(jq -r --arg prod "$PRODUCT" '.[$prod] | keys[]' "$IMAGES_JSON")
if [[ "${SRC_ENV}" == "local" ]]; then
    get_source
    build_and_push_images
else
    publish_images
fi
