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
    echo "  -d, Dry run"
    echo "  -e, Environment: sandbox|stage|production (required)"
    echo "  -p, Product name (required)"
    echo "  -r, Release (required)"
    exit 1
}

# Function to validate variable against allowed values
validate_variable() {
    local var_name=${1}
    local var_value=${2}
    local allowed_pattern=${3}

    IFS='|' read -ra allowed_values <<< "${allowed_pattern}"
    for allowed in "${allowed_values[@]}"; do
        if [[ "${var_value}" == "${allowed}" ]]; then
            return 0
        fi
    done

    echo "Invalid ${var_name}: ${var_value}" >&2
    echo "Allowed values: ${allowed_pattern}" >&2
    usage
}

# Function to get image configuration
get_image_config() {
    local image=$1
    local key=$2
    jq -r ".${PRODUCT}.${image}.${key}" "${IMAGES_JSON}"
}

# Function to get full image reference
get_image_reference() {
    local image=$1
    local ecr=$2
    local registry=$(get_image_config "${image}" "registry")
    echo "${ecr}/${registry}:${RELEASE}"
}

create_arch_tags() {
    local image_tag="${1}"
    local base_repo="${image_tag%:*}"
    local manifest_json
    local amd64_digest
    local arm64_digest

    manifest_json="$(docker buildx imagetools inspect --raw "${image_tag}")"
    amd64_digest="$(echo "${manifest_json}" | jq -r \
        '.manifests[] | select(.platform.os=="linux" and .platform.architecture=="amd64") | .digest' \
        | head -n 1)"
    arm64_digest="$(echo "${manifest_json}" | jq -r \
        '.manifests[] | select(.platform.os=="linux" and .platform.architecture=="arm64") | .digest' \
        | head -n 1)"

    if [[ -z "${amd64_digest}" || -z "${arm64_digest}" ]]; then
        echo "Error: Unable to resolve amd64/arm64 digests for ${image_tag}"
        exit 1
    fi

    docker buildx imagetools create \
        --tag "${base_repo}:amd64-${RELEASE}" \
        "${base_repo}@${amd64_digest}"
    docker buildx imagetools create \
        --tag "${base_repo}:arm64-${RELEASE}" \
        "${base_repo}@${arm64_digest}"
}

# Function to build Docker image
build_and_push_images() {
    local images=$1
    local image_reference
    local docker_file
    local buildx_args

    pushd "${SRC_DIR}"
    for image in ${images}; do
        image_reference=$(get_image_reference "${image}" "${TARGET_ECR_REGISTRY}")
        docker_file=$(get_image_config "${image}" "docker_file")
        echo "Building ${image_reference}..."
        buildx_args=(
            -f "${docker_file}"
            --platform "${PLATFORMS}"
            -t "${image_reference}"
        )

        if [[ "${dry_run}" == true ]]; then
            docker buildx build "${buildx_args[@]}" --load .
        else
            echo "Pushing ${image} to ${image_reference}"
            docker buildx build "${buildx_args[@]}" --push .
            create_arch_tags "${image_reference}"
        fi
    done
    popd
}

publish_from_sandbox() {
    local images=$1
    local source_reference
    local target_reference

    for image in ${images}; do
        source_reference=$(get_image_reference "${image}" "${SANDBOX_ECR_REGISTRY}")
        target_reference=$(get_image_reference "${image}" "${TARGET_ECR_REGISTRY}")

        if [[ "${dry_run}" == true ]]; then
            echo "Dry run: promote ${source_reference} -> ${target_reference}"
            echo "Dry run: create arch tags from ${target_reference}"
        else
            docker buildx imagetools create \
                --tag "${target_reference}" \
                "${source_reference}"
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
            export SRC_DIR=`pwd`
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

    if [[ "${dry_run}" == true ]]; then
        PLATFORMS="linux/amd64"
    else
        PLATFORMS="linux/amd64,linux/arm64"

        if [[ "${ENVIRONMENT}" != "sandbox" ]]; then
            aws ecr get-login-password \
                --region "${AWS_REGION}" \
                --profile "${SANDBOX_AWS_PROFILE}" | \
                docker login --username AWS --password-stdin ${SANDBOX_ECR_REGISTRY}
        fi

        aws ecr get-login-password \
            --region "${AWS_REGION}" \
            --profile "${TARGET_AWS_PROFILE}" | \
            docker login --username AWS --password-stdin ${TARGET_ECR_REGISTRY}
    fi
}

# Main
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
OPTIND=1
AWS_REGION="us-east-1"  # ECR is always in us-east-1
ENVIRONMENT="sandbox"
IMAGES_JSON="${SCRIPT_DIR}/images.json"
while getopts de:p:r: opt
do
    case ${opt} in
        d) dry_run=true ;;
        e) ENVIRONMENT=${OPTARG} ;;
        p) PRODUCT=${OPTARG} ;;
        r) RELEASE=${OPTARG} ;;
        *) usage ;;
    esac
done

if [[ -z ${PRODUCT} || -z ${RELEASE} ]]; then
    usage
fi

validate_variable "ENVIRONMENT" "${ENVIRONMENT}" "sandbox|stage|production"
images_list=$(jq -r ".${PRODUCT} | keys[]" "${IMAGES_JSON}" | tr '\n' ' ')

SANDBOX_AWS_PROFILE=$(jq -r .sandbox.aws.ROLE_SESSION_NAME "${SCRIPT_DIR}/../utilities/environments.json")
SANDBOX_AWS_ACCOUNT=$(jq -r .sandbox.aws.ACCOUNT "${SCRIPT_DIR}/../utilities/environments.json")
SANDBOX_ECR_REGISTRY=${SANDBOX_AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com
TARGET_AWS_PROFILE=$(jq -r .${ENVIRONMENT}.aws.ROLE_SESSION_NAME "${SCRIPT_DIR}/../utilities/environments.json")
TARGET_AWS_ACCOUNT=$(jq -r .${ENVIRONMENT}.aws.ACCOUNT "${SCRIPT_DIR}/../utilities/environments.json")
TARGET_ECR_REGISTRY=${TARGET_AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com

prepare_environment
if [[ "${ENVIRONMENT}" == "sandbox" ]]; then
    get_source
    build_and_push_images "${images_list}"
else
    publish_from_sandbox "${images_list}"
fi
