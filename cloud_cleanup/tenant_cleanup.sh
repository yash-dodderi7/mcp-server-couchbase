#!/bin/bash
function set_cloud_env {
    pushd ${WORKSPACE}/cloud-build-tools/utilities
    py_venv="${WORKSPACE}/cloud-build-tools/utilities/.venv"
    uv venv "${py_venv}" --clear
    export PATH="${py_venv}/bin:${PATH}"
    uv pip install --quiet -r requirements.txt
    uv pip install --quiet azure-cli --prerelease=allow
    export ENVIRONMENT="sandbox"
    init_aws_config -p "cbc-main" \
        -i "${CBROBOT_AWS_ACCESS_KEY_ID}" \
        -k "${CBROBOT_AWS_SECRET_ACCESS_KEY}" \
        -w "${WORKSPACE}/cloud-build-tools/utilities/.aws"
    python3 aws_assume_role.py -e ${ENVIRONMENT} -t dummy
    export AWS_PROFILE=$(jq -r \
        ".${ENVIRONMENT}.aws.ROLE_SESSION_NAME" \
        "${REPO_DIR}/utilities/environments.json")
    AZURE_SECRET=$(python3 couchbase_cloud_aws.py get_secret --secret_name ${AZURE_SECRET_NAME})
    AZURE_CI_BOT_SERVICE_PRINCIPAL=$(echo ${AZURE_SECRET} | jq -r '.'SERVICE_PRINCIPAL)
    AZURE_CI_BOT_PASSWORD=$(echo ${AZURE_SECRET} | jq -r '.PASSWORD')
    AZURE_TENANT_ID=$(echo ${AZURE_SECRET} | jq -r '.TENANT_ID')
    az login --service-principal \
        -u "${AZURE_CI_BOT_SERVICE_PRINCIPAL}" \
        -p="${AZURE_CI_BOT_PASSWORD}" \
        --tenant "${AZURE_TENANT_ID}"
    az account set --subscription "${AZURE_SUBSCRIPTION}"
    python3 couchbase_cloud_aws.py get_secret \
        --secret_name "${GCP_SECRET_NAME}" \
        | jq > "${REPO_DIR}/utilities/gcp_token.json"
    echo "Y" | gcloud auth login --cred-file="${REPO_DIR}/utilities/gcp_token.json"
    gcloud config set project "${GCP_PROJECT_ID}"
    export GOOGLE_APPLICATION_CREDENTIALS="${REPO_DIR}/utilities/gcp_token.json"
}

function cleanup_resources {
    local cloud_provider="${1}"
    local target_regions

    if [[ "${cleanup_type}" == "cluster" ]]; then
        target_regions=$(echo "${cluster_regions}" | jq -r --arg p "$cloud_provider" '.[$p]')
        for region in ${target_regions}; do
            echo "Removing ${cleanup_type} ${cleanup_value} resources" \
                "from ${cloud_provider} in region ${region}"
            cleanup-cli resource \
                --provider "${cloud_provider}" \
                --env "${ENVIRONMENT}" \
                --type "${cleanup_type}" \
                --id "${cleanup_value}" \
                --region "${region}"
        done
    else
        echo "Removing ${cleanup_type} ${cleanup_value} resources from ${cloud_provider}"
        cleanup-cli resource \
            --provider "${cloud_provider}" \
            --env "${ENVIRONMENT}" \
            --type "${cleanup_type}" \
            --id "${cleanup_value}"
    fi
}

function compile_cleanup_cli {
    local action_yml="${WORKSPACE}/couchbase-cloud/.github/actions/setup-go/action.yml"
    local go_version
    go_version=$(awk -F': *' \
        '/go-version:/{flag=1;next} flag && /default:/{print $2;exit}' \
        "${action_yml}" | tr -d '"')
    if [[ -z "${go_version}" ]]; then
        echo "Error: Go version not found in action.yml"
        exit 1
    fi
    if [[ ! -f /home/couchbase/go/go${go_version}/bin/go ]]; then
        cbdep install golang ${go_version} -d /home/couchbase/go
    fi
    export PATH=/home/couchbase/go/go${go_version}/bin:$PATH
    pushd ${WORKSPACE}/couchbase-cloud
    go build -o /home/couchbase/go/go${go_version}/bin/cleanup-cli ./cmd/cleanup-cli
    popd
}

function install_gcp_sdk {
    local gcp_sdk_dir="$(pwd)/google-cloud-sdk"
    local components_url="https://dl.google.com/dl/cloudsdk/channels/rapid/components-2.json"
    local gcp_sdk_version
    gcp_sdk_version="$(curl -fsSL "${components_url}" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')"
    local gcp_sdk_download_base_url="https://dl.google.com/dl/cloudsdk/channels/rapid/downloads"
    if [[ -z "${gcp_sdk_version}" ]]; then
        echo "Unable to detect latest Google Cloud SDK version"
        exit 1
    fi

    if [[ -x "${gcp_sdk_dir}/bin/gcloud" ]]; then
        ${gcp_sdk_dir}/bin/gcloud components update --quiet
    else
        local gcp_sdk_pkg="google-cloud-cli-${gcp_sdk_version}-linux-x86_64.tar.gz"
        local gcp_sdk_url="${gcp_sdk_download_base_url}/${gcp_sdk_pkg}"
        curl --fail --silent --show-error --location "${gcp_sdk_url}" -o "google-cloud-cli.tar.gz"
        tar -xzf "google-cloud-cli.tar.gz"
        rm -rf "${gcp_sdk_dir}" google-cloud-cli.tar.gz
    fi
    export PATH="${gcp_sdk_dir}/bin:${PATH}"
}

function usage() {
    echo "Usage: provide type and value"
    echo "Examples:"
    echo "  $0 -t tenant -v <tenantId>"
    echo "  $0 -t cluster -v <clusterId> [-r <cluster_regions_json>]"
    echo "  $0 -t user -v <userId>"
    exit 1
}

function validate_environment {
    chk_set AZURE_SECRET_NAME
    chk_set GCP_SECRET_NAME
    chk_set AZURE_SUBSCRIPTION
    chk_set GCP_PROJECT_ID
    chk_set cleanup_type
    chk_set cleanup_value
    if [[ "${cleanup_type}" == "cluster" ]]; then
        chk_set cluster_regions
    fi
    if [[ ! -f ${WORKSPACE}/cloud-build-tools/utilities/environments.json ]]; then
        echo "Error: environments.json not found in utilities"
        exit 1
    fi
}

function sync_repo {
    local repo_dir="${1}"
    local repo_url="${2}"
    local branch="${3}"

    if [[ -d "${repo_dir}/.git" ]]; then
        pushd "${repo_dir}"
        git fetch origin "${branch}" --depth 1
        git checkout "${branch}"
        git reset --hard "origin/${branch}"
        popd
    else
        git clone --depth 1 --branch "${branch}" "${repo_url}" "${repo_dir}"
    fi
}

# main
set -e
REPO_DIR=$(git rev-parse --show-toplevel)
. ${REPO_DIR}/utilities/shell-utils.sh

while getopts "t:v:r:" opt; do
    case "${opt}" in
        t) cleanup_type="${OPTARG}" ;;
        v) cleanup_value="${OPTARG}" ;;
        r) cluster_regions="${OPTARG}" ;;
        *) usage ;;
    esac
done

validate_environment
sync_repo "${WORKSPACE}/couchbase-cloud" "git@github.com:couchbasecloud/couchbase-cloud.git" "main"

install_gcp_sdk
set_cloud_env
compile_cleanup_cli

set +e
for cloud_provider in aws gcp azure; do
    cleanup_resources ${cloud_provider}
done
