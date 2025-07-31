#!/bin/bash -e
set -x
function usage
{
    echo "Usage: $0 -p <Product> -r <Release> -v <Version> -b <Build Number> -a <AMI Name> -c <AWS Config File> -s <AWS Shared Credentials File>"
    echo "  -p Product:  direct-nabula|couchbase-data-api"
    echo "  -r RELEASE: elixir"
    echo "  -v Version: i.e. 7.5.0, 3.1.0"
    echo "  -b Build Number: i.e. 123"
    echo "  -e AWS_PROFILE: profile name specified in aws config"
    echo "  optional:"
    echo "  -a AMI Name: couchbase-data-api-test"
    echo "  -d ARCH: aarch64 or x86_64"
    echo "  -c AWS Config File: ~/.aws/config"
    echo "  -s AWS Shared Credentials File: ~/.aws/credentials"
    echo "  -g SHA that agent is built from"
    exit 1
}

function download_files
{
    if [[ -n "${PRODUCT_PKG_URL}" ]]; then
        curl --fail -LO ${PRODUCT_PKG_URL}
    fi
    # vulcan-core is a private repo, use gh cli to download the package
    # GH_TOKEN is set as an environment variable
    if [[ "${PRODUCT}" == "vulcan-metrics-collector" ]]; then
        gh release download ${VERSION} --repo couchbaselabs/vulcan-core --pattern "metrics-collector.zip"
    fi
    cp -rp ${WORKSPACE}/cloud-build-tools/utilities/agents .
}

function create_ami
{
    if [[ -z ${AMI_NAME_OVERWRITE} ]]; then
        AMI_NAME=${PRODUCT}-${VERSION}-${BLD_NUM}
    else
        AMI_NAME=${AMI_NAME_OVERWRITE}
    fi

#set environment variables used by packer file
#make sure .env is created fresh
rm .env-${AMI_NAME}-${ARCH}-${AWS_PROFILE}
cat <<EOT >> .env-${AMI_NAME}-${ARCH}-${AWS_PROFILE}
export PKR_VAR_region=${AWS_REGION}
export PKR_VAR_ami_regions='${AMI_REGIONS}'
export PKR_VAR_product_pkg_name=${PRODUCT_PKG_NAME}
export PKR_VAR_product_version=${VERSION}
export PKR_VAR_product_bld_num=${BLD_NUM}
export PKR_VAR_ami_name=${AMI_NAME}
export PKR_VAR_product_arch=${ARCH}
export PKR_VAR_agent_sha=${AGENT_SHA}
EOT

    #packer variables specific for couchbase-server
    case ${PRODUCT} in
        couchbase-columnar)
            if [[ "${VERSION}" == 1.0.* || "${VERSION}" == 1.1.* ]]; then
                echo "export PKR_VAR_ns_server_profile=columnar" >> .env-${AMI_NAME}-${ARCH}-${AWS_PROFILE}
            else
                echo "export PKR_VAR_ns_server_profile=analytics_provisioned" >> .env-${AMI_NAME}-${ARCH}-${AWS_PROFILE}
            fi
            echo "export PKR_VAR_dp_service=dp-agent" >> .env-${AMI_NAME}-${ARCH}-${AWS_PROFILE}
           ;;
        enterprise-analytics)
            echo "export PKR_VAR_ns_server_profile=analytics_provisioned" >> .env-${AMI_NAME}-${ARCH}-${AWS_PROFILE}
            echo "export PKR_VAR_dp_service=dp-agent" >> .env-${AMI_NAME}-${ARCH}-${AWS_PROFILE}
           ;;
        couchbase-cloud-server*)
            echo "export PKR_VAR_ns_server_profile=provisioned" >> .env-${AMI_NAME}-${ARCH}-${AWS_PROFILE}
            echo "export PKR_VAR_dp_service=dp-agent" >> .env-${AMI_NAME}-${ARCH}-${AWS_PROFILE}
           ;;
        couchbase-cloud-backup*)
            echo "export PKR_VAR_ns_server_profile=provisioned" >> .env-${AMI_NAME}-${ARCH}-${AWS_PROFILE}
            echo "export PKR_VAR_dp_service=dp-backup" >> .env-${AMI_NAME}-${ARCH}-${AWS_PROFILE}
           ;;
        *)
           ;;
    esac

    source .env-${AMI_NAME}-${ARCH}-${AWS_PROFILE}
    echo "checking AMI on ${AWS_PROFILE}"
    check_image=$(AWS_PROFILE=${AWS_PROFILE} aws ec2 describe-images \
        --owners self \
        --filters "Name=name,Values=${AMI_NAME}" \
        --query "Images[].[ImageId]" \
        --output text)
    if [[ -z $check_image ]]; then
        echo "Creating ${AMI_NAME}..."
        packer init ${PACKER_FILE} || { echo "Failed to initiate ${PACKER_FILE}" ; exit 1; }
        AWS_PROFILE=${AWS_PROFILE} packer build ${PACKER_FILE} || { echo "Failed to create AMI ${AMI_NAME}" ; exit 1; }
        # Keep a list of IMAGES created.
        # It is currently used to determinie if we should trigger qe-jenkins sanity_tests
        echo "${AMI_NAME}" >> ${WORKSPACE}/IMAGES_CREATED
    else
        echo "${AMI_NAME} already exist on ${AWS_PROFILE}"
    fi
}

#main
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

#default config
ARCH="aarch64"
AGENT_SHA="latest"
AWS_SHARED_CREDENTIALS_FILE=${AWS_SHARED_CREDENTIALS_FILE:-"${SCRIPT_DIR}/.aws/credentials"}
AWS_CONFIG_FILE=${AWS_CONFIG_FILE:-"${SCRIPT_DIR}/.aws/config"}

AWS_REGION=${AWS_REGION:-"us-east-1"}
# Only call get_regions if AMI_REGIONS is not already defined
if [ -z "${AMI_REGIONS}" ]; then
    echo "Fetching AMI_REGIONS from get_regions..."
    AMI_REGIONS=$(python3 couchbase_cloud_aws.py get_regions | sed "s/'/\"/g")
else
    # Validate JSON array format
    if echo "${AMI_REGIONS}" | jq -e 'type == "array" and all(type == "string")' > /dev/null; then
        echo "Using predefined AMI_REGIONS: ${AMI_REGIONS}"
    else
        echo "ERROR: AMI_REGIONS must be an array of quoted strings"
        echo "Expected: AMI_REGIONS='[\"us-west-1\", \"us-west-2\"]'"
        exit 1
    fi
fi

OPTIND=1
while getopts a:b:d:e:g:p:r:v: opt
do
    case ${opt} in
        a) AMI_NAME_OVERWRITE=${OPTARG}
           ;;
        b) BLD_NUM=${OPTARG}
           ;;
        d) ARCH=${OPTARG}
           ;;
        e) AWS_PROFILE=${OPTARG}
           ;;
        g) AGENT_SHA=${OPTARG}
           ;;
        p) PRODUCT=${OPTARG}
           ;;
        r) RELEASE=${OPTARG}
           ;;
        v) VERSION=${OPTARG}
           ;;
        *) usage
           ;;
    esac
done

if [[ -z ${PRODUCT} || -z ${RELEASE} || -z ${VERSION} || -z ${BLD_NUM} || -z ${AWS_PROFILE} ]]; then
    usage
fi

# Current Supported Products:
# 	couchbase-cloud-server couchbase-cloud-backup couchbase-serverless-server couchbase-serverless-backup
#       couchbase-cloud-server-perf couchbase-cloud-backup-perf couchbase-serverless-server-perf couchbase-serverless-backup-perf
#       direct-nebula
#       couchbase-data-api

case ${PRODUCT} in
    couchbase-cloud-server|couchbase-cloud-backup)
        PACKER_FILE="couchbase-server.pkr.hcl"
        PRODUCT_PKG_NAME="couchbase-server-enterprise-${VERSION}-${BLD_NUM}-linux.${ARCH}.rpm"
        PRODUCT_PKG_URL="http://latestbuilds.service.couchbase.com/builds/latestbuilds/couchbase-server/${RELEASE}/${BLD_NUM}/${PRODUCT_PKG_NAME}"
        cd ${WORKSPACE}/cloud-build-tools/couchbase-server/aws
        ;;
    couchbase-columnar)
        PACKER_FILE="couchbase-server.pkr.hcl"
        PRODUCT_PKG_NAME="${PRODUCT}-enterprise-${VERSION}-${BLD_NUM}-linux.${ARCH}.rpm"
        PRODUCT_PKG_URL="http://latestbuilds.service.couchbase.com/builds/latestbuilds/${PRODUCT}/${RELEASE}/${BLD_NUM}/${PRODUCT_PKG_NAME}"
        cd ${WORKSPACE}/cloud-build-tools/couchbase-server/aws
        ;;
    enterprise-analytics)
        PACKER_FILE="couchbase-server.pkr.hcl"
        PRODUCT_PKG_NAME="${PRODUCT}-${VERSION}-${BLD_NUM}-linux.${ARCH}.rpm"
        PRODUCT_PKG_URL="http://latestbuilds.service.couchbase.com/builds/latestbuilds/${PRODUCT}/${RELEASE}/${BLD_NUM}/${PRODUCT_PKG_NAME}"
        cd ${WORKSPACE}/cloud-build-tools/couchbase-server/aws
        ;;
    ai-gateway|model-serving-agent)
        PACKER_FILE="${PRODUCT}.pkr.hcl"
        PRODUCT_PKG_NAME="${PRODUCT}-${VERSION}-${BLD_NUM}-linux-${ARCH}.gz"
        PRODUCT_PKG_URL="http://latestbuilds.service.couchbase.com/builds/latestbuilds/${PRODUCT}/${RELEASE}/${BLD_NUM}/${PRODUCT_PKG_NAME}"
        cd ${WORKSPACE}/cloud-build-tools/${PRODUCT}/aws
        ;;
    vulcan)
        PACKER_FILE="${PRODUCT}.pkr.hcl"
        PRODUCT_PKG_NAME="${PRODUCT}-${VERSION}-${BLD_NUM}-${ARCH}.tar.gz"
        PRODUCT_PKG_URL="http://latestbuilds.service.couchbase.com/builds/latestbuilds/${PRODUCT}/${RELEASE}/${BLD_NUM}/${PRODUCT_PKG_NAME}"
        cd ${WORKSPACE}/cloud-build-tools/${PRODUCT}/aws
        ;;
    vulcan-metrics-collector)
        PACKER_FILE="${PRODUCT}.pkr.hcl"
        cd ${WORKSPACE}/cloud-build-tools/${PRODUCT}/aws
        ;;
    couchbase-cloud-sync-gateway)
        PACKER_FILE="couchbase-sync-gateway.pkr.hcl"
        PRODUCT_PKG_NAME="couchbase-sync-gateway-enterprise_${VERSION}-${BLD_NUM}_${ARCH}.deb"
        PRODUCT_PKG_URL="http://latestbuilds.service.couchbase.com/builds/latestbuilds/sync_gateway/${RELEASE}/${BLD_NUM}/${PRODUCT_PKG_NAME}"
        cd ${WORKSPACE}/cloud-build-tools/couchbase-sync-gateway/aws
        ;;
    *)
        echo "${PRODUCT} is not supported"
        exit 1
        ;;
esac

download_files
create_ami ${PRODUCT_PKG_NAME} ${PACKER_FILE}
