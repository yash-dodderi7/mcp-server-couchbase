#!/bin/bash
# PyPI Package Publishing Script
# This script installs pip and twine using uv, then publishes packages to PyPI or Test PyPI
set -e  # Exit on any error
# Help function
usage() {
    echo "PyPI Publishing Script"
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  -d, Dry run"
    echo "  -p, Product name i.e. agent-catalog (required)"
    echo "  -r, PyPI Repo: testpypi|pypi (required)"
    echo "  -v, Version (required)"
    exit 1
}

# Function to get source
get_source() {
    echo "Getting source..."

    rm -rf ${DIST_DIR}
    mkdir ${DIST_DIR}
    if [[ "${VERSION}" != v* ]]; then
        VERSION="v${VERSION}"
    fi

    case ${PRODUCT} in
        agent-catalog)
            gh release download ${VERSION} --repo couchbaselabs/agent-catalog -D ${DIST_DIR}
            ;;
        agentmem-sdk)
            gh release download ${VERSION} --repo couchbaselabs/agentmem-sdk -D ${DIST_DIR}
            ;;
        *)
            echo "Unknown product: ${PRODUCT}"
            exit 1
            ;;
    esac
}

# Function to prepare environment
prepare_environment() {
    echo "Preparing environment..."
    uv tool install --python ${PYTHON_VERSION} twine
    cbdep install gh ${GH_VERSION}
    export PATH=`pwd`/install/gh-${GH_VERSION}/bin:${PATH}
}

# Function to upload to PyPI
upload_packages() {
    for package in ${DIST_DIR}/*; do
        echo "Uploading ${package} to ${PYPI_REPO}..."
        if [[ "${dry_run}" != true ]]; then
            echo "Uploading ${package} to ${PYPI_REPO}..."
            twine upload --repository "${PYPI_REPO}" ${package}
        else
            echo "Dry run: Validating ${package}..."
            twine check ${package}
        fi
    done
}

# Main
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
OPTIND=1
while getopts dp:r:v: opt
do
    case ${opt} in
        d) dry_run=true
            ;;
        p) PRODUCT=${OPTARG}
            ;;
        r) PYPI_REPO=${OPTARG}
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

if [[ -z "${PRODUCT}" || -z "${VERSION}" ]]; then
    usage
fi

if [[ "${PYPI_REPO}" != "pypi" && "${PYPI_REPO}" != "testpypi" ]]; then
    echo "PYPI_REPO ${PYPI_REPO} is invalid"
    usage
fi


PYTHON_VERSION=${PYTHON_VERSION:-3.12} # default Python version to 3.12 if not set.
GH_VERSION=${GH_VERSION:-2.79.0} # default Python version to 3.12 if not set.
DIST_DIR=${SCRIPT_DIR}/dist
prepare_environment
get_source
upload_packages
