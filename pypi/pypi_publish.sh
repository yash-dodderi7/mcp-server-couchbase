#!/bin/bash
# PyPI Package Publishing Script
# This script installs twine using uv, then publishes packages to PyPI or Test PyPI.
# Two mutually exclusive modes:
#   -v VERSION : download pre-built artifacts from a GitHub release and upload them.
#   -b BRANCH  : clone the source branch, build a wheel, then upload it.

set -e  # Exit on any error

# Help function
usage() {
    echo "PyPI Publishing Script"
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  -b, Branch name; build from branch (required for branch mode)"
    echo "  -d, Dry run"
    echo "  -p, Product name: agent-catalog|agentmemory-sdk|mcp-server-couchbase (required)"
    echo "  -r, PyPI Repo: testpypi|pypi (required)"
    echo "  -v, Version; download from a GitHub release"
    echo ""
    echo "  -b and -v are mutually exclusive; exactly one is required."
    exit 1
}

# Map a product to its GitHub repo.
repo_for_product() {
    case ${PRODUCT} in
        agent-catalog)         echo "couchbaselabs/agent-catalog" ;;
        agentmemory-sdk)       echo "couchbaselabs/agentmemory-sdk" ;;
        mcp-server-couchbase)  echo "couchbase/mcp-server-couchbase" ;;
        *)
            echo "Unknown product: ${PRODUCT}" >&2
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

# Function to get source
get_source() {
    echo "Getting source..."
    local repo
    repo=$(repo_for_product)
    rm -rf ${DIST_DIR}

    if [[ "${MODE}" == "branch" ]]; then
        gh repo clone ${repo} ${DIST_DIR} -- --branch ${BRANCH} --depth 1
    else
        mkdir ${DIST_DIR}
        if [[ "${VERSION}" != v* ]]; then
            VERSION="v${VERSION}"
        fi
        gh release download ${VERSION} --repo ${repo} -D ${DIST_DIR}
    fi
}

# Function to build packages (branch mode only)
build_packages() {
    echo "Building packages..."
    pushd ${DIST_DIR}
    uv build --wheel
    popd
}

# Function to upload to PyPI
upload_packages() {
    pushd ${DIST_DIR}
    if [[ "${MODE}" == "branch" ]]; then
        UPLOAD_GLOB="${DIST_DIR}/dist/*.whl"
    else
        UPLOAD_GLOB="${DIST_DIR}/dist/*.whl"
    fi
    for package in ${UPLOAD_GLOB}; do
        if [[ "${dry_run}" != true ]]; then
            echo "Uploading ${package} to ${PYPI_REPO}..."
            twine upload --repository "${PYPI_REPO}" ${package}
        else
            if [[ "${PYPI_REPO}" != "testpypi" ]]; then
                echo "Error: dry run validation is only supported against testpypi"
                exit 1
            fi
            echo "Dry run: Validating ${package}..."
            twine check ${package}
        fi
    done
    popd
}

# Main
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
OPTIND=1
while getopts ":b:dp:r:v:" opt
do
    case ${opt} in
        b) MODE=branch
            if [[ "${OPTARG}" == -* ]]; then   # next token is another flag, not a branch
                echo "Error: -b requires a branch name"
                usage
            else
                BRANCH=${OPTARG}
            fi
            ;;
        d) dry_run=true
            ;;
        p) PRODUCT=${OPTARG}
            ;;
        r) PYPI_REPO=${OPTARG}
            ;;
        v) MODE=release
            VERSION=${OPTARG}
            if [[ "${VERSION}" == -* ]]; then
                echo "Error: -v requires a version value, got ${VERSION}"
                usage
            fi
            ;;
        :) # option missing its argument (silent error mode)
            echo "Error: -${OPTARG} requires a value"
            usage
            ;;
        \?) usage
            ;;
    esac
done

if [[ -z "${PRODUCT}" ]]; then
    usage
fi

if [[ -n "${VERSION}" && -n "${BRANCH}" ]]; then
    echo "Error: -b and -v are mutually exclusive"
    usage
fi

if [[ -z "${MODE}" ]]; then
    echo "Error: one of -b or -v is required"
    usage
fi

if [[ "${PYPI_REPO}" != "pypi" && "${PYPI_REPO}" != "testpypi" ]]; then
    echo "PYPI_REPO ${PYPI_REPO} is invalid"
    usage
fi

PYTHON_VERSION=${PYTHON_VERSION:-3.12} # default Python version to 3.12 if not set.
GH_VERSION=${GH_VERSION:-2.79.0} # default gh version if not set.
DIST_DIR=${SCRIPT_DIR}/dist
prepare_environment
get_source
if [[ "${MODE}" == "branch" ]]; then
    build_packages
fi
upload_packages
