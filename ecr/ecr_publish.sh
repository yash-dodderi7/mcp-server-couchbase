#!/bin/bash
set -x
# ECR Image Publishing Script
# This script builds and pushes Docker images to AWS ECR

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


# Function to build Docker image
build_and_push_images() {
    case ${PRODUCT} in
        vulcan)
            declare -A vulcan_image_registries=(
                [Docling]="avengers/vulcan-core-docling"
                [JsonLoader]="avengers/vulcan-core-jsonloader"
                [Unstructured]="avengers/vulcan-core-unstructured"
                [ListFiles]="avengers/vulcan-task-list-files"
                [UpdateWorkflowStatus]="avengers/vulcan-task-update-workflow-status"
            )
            pushd vulcan-core
            for image in ${!vulcan_image_registries[@]}; do
                docker_file="docker/${image}.Dockerfile"
                TAG="${ECR_REGISTRY}/${vulcan_image_registries[${image}]}:amd64-${RELEASE}"
                echo "Building ${TAG}..."
                docker build \
                    --no-cache \
                    -f ${docker_file} \
                    --platform=linux/amd64 \
                    -t ${TAG} .
                if [[ "$dry_run" != true ]]; then
                    echo "Pushing ${image} to ${TAG}"
                    docker push ${TAG}
                fi
            done
            popd
           ;;
        *)
            echo "Unknown product: ${PRODUCT}"
            exit 1
           ;;
    esac
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
            popd
           ;;
        *)
            echo "Unknown product: ${PRODUCT}"
            exit 1
           ;;
    esac
}

# Function to prepare environment
prepare_environment() {
    if [[ "${dry_run}" != true ]]; then
        aws ecr get-login-password --region ${AWS_REGION} | \
            docker login --username AWS --password-stdin ${ECR_REGISTRY}
    else
        echo "Dry run: Skipping push"
    fi
}

# Main
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
OPTIND=1
while getopts de:p:r: opt
do
    case ${opt} in
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

if [[ -z ${ENVIRONMENT} || -z ${PRODUCT} || -z ${RELEASE} ]]; then
    usage
fi

if [[ ! -f ${SCRIPT_DIR}/../utilities/environments.json ]]; then
    echo "Error: Missing environments.json"
    echo "Unable to obtain AWS account information"
    exit 1
fi

AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_ACCOUNT=$(jq -r .${ENVIRONMENT}.aws.ACCOUNT "${SCRIPT_DIR}/../utilities/environments.json")
ECR_REGISTRY=${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com

prepare_environment
get_source
build_and_push_images
