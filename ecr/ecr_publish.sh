#!/bin/bash
# ECR Image Publishing Script
# This script builds and pushes Docker images to AWS ECR
set -e  # Exit on any error

# Help function
usage() {
    echo "ECR Image Publishing Script"
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  -a, Action: build|publish (required)"
    echo "  -d, Dry run"
    echo "  -e, Environment: sandbox|stage|production (default: sandbox)"
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
    if [[ "${key}" == "tag" ]]; then
        # Replace {RELEASE} placeholder in tag_template
        local tag=$(jq -r ".${PRODUCT}.${image}.tag" "${IMAGES_JSON}")
        echo "${tag}" | envsubst
    else
        jq -r ".${PRODUCT}.${image}.${key}" "${IMAGES_JSON}"
    fi
}

# Function to get full image reference
get_image_reference() {
    local image=$1
    local ecr=$2
    local registry=$(get_image_config ${image} "registry")
    local tag=$(get_image_config ${image} "tag")
    echo "${ecr}/${registry}:${tag}"
}

# Function to get images from sandbox environment
get_images_from_sandbox() {
    local images=$1
    aws ecr get-login-password --region ${AWS_REGION} --profile ${SBX_AWS_PROFILE} | \
        docker login --username AWS --password-stdin ${SBX_ECR_REGISTRY}
    for image in ${images}; do
        local sbx_image_reference=$(get_image_reference ${image} ${SBX_ECR_REGISTRY})
        local target_image_reference=$(get_image_reference ${image} ${TARGET_ECR_REGISTRY})
        if docker image inspect ${sbx_image_reference} > /dev/null 2>&1; then
            echo "Image ${sbx_image_reference} already exists"
            docker tag ${sbx_image_reference} ${target_image_reference}
        else
            echo "Pulling ${sbx_image_reference}..."
            docker pull ${sbx_image_reference}
            docker tag ${sbx_image_reference} ${target_image_reference}
        fi
    done
}

# Function to publish Docker images
push_images() {
    local images=$1
    get_images_from_sandbox "${images}"
    aws ecr get-login-password --region ${AWS_REGION} --profile ${TARGET_AWS_PROFILE} | \
        docker login --username AWS --password-stdin ${TARGET_ECR_REGISTRY}
    for image in ${images}; do
        local image_reference=$(get_image_reference ${image} ${TARGET_ECR_REGISTRY})
        if [[ "${dry_run}" == "true" ]]; then
            echo "Dry run: Would push ${image_reference}"
        else
            echo "Pushing ${image_reference}..."
            docker push "${image_reference}"
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

# Function to build Docker images
build_images() {
    local images=$1
    for image in ${images}; do
        get_image_reference ${image} ${TARGET_ECR_REGISTRY}
        local image_reference=$(get_image_reference ${image} ${TARGET_ECR_REGISTRY})
        local docker_file=$(get_image_config ${image} "docker_file")
        echo "Building ${image_reference}..."
        pushd ${SRC_DIR}
        docker build \
            -f ${docker_file} \
            --platform=linux/amd64 \
            -t ${image_reference} .
        popd
    done
}

# Main
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
OPTIND=1
AWS_REGION="us-east-1"  # ECR is always in us-east-1
ENVIRONMENT="sandbox"
IMAGES_JSON="${SCRIPT_DIR}/images.json"
while getopts a:de:p:r: opt
do
    case ${opt} in
        a) ACTION=${OPTARG}
           ;;
        d) dry_run=true
           ;;
        e) ENVIRONMENT=${OPTARG}
           ;;
        p) PRODUCT=${OPTARG}
           ;;
        r) RELEASE=${OPTARG}
           ;;
        *) usage
           ;;
    esac
done

if [[ -z ${PRODUCT} || -z ${RELEASE} || -z ${ACTION} ]]; then
    usage
fi
validate_variable "ACTION" "${ACTION}" "build|publish"
validate_variable "ENVIRONMENT" "${ENVIRONMENT}" "sandbox|stage|production"

# Store images list
images_list=$(jq -r ".${PRODUCT} | keys[]" "${IMAGES_JSON}" | tr '\n' ' ')
TARGET_AWS_ACCOUNT=$(jq -r ".${ENVIRONMENT}.aws.ACCOUNT" "${SCRIPT_DIR}/../utilities/environments.json")
TARGET_AWS_PROFILE=$(jq -r ".${ENVIRONMENT}.aws.ROLE_SESSION_NAME" "${SCRIPT_DIR}/../utilities/environments.json")
TARGET_ECR_REGISTRY=${TARGET_AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com
SBX_AWS_ACCOUNT=$(jq -r .sandbox.aws.ACCOUNT "${SCRIPT_DIR}/../utilities/environments.json")
SBX_AWS_PROFILE=$(jq -r .sandbox.aws.ROLE_SESSION_NAME "${SCRIPT_DIR}/../utilities/environments.json")
SBX_ECR_REGISTRY=${SBX_AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com

# Build or get images
if [[ "${ACTION}" == "build" ]]; then
    get_source
    build_images "${images_list}"
fi
if [[ "${ACTION}" == "publish" ]]; then
    push_images "${images_list}"
fi
