#!/bin/bash -e

function usage
{
    echo "Usage: $0 -p <Product> -r <Release> -v <Version> -t <TOY Build Number> -e"
    echo "  -p Product:  i.e. couchbase-serverless-server, couchbase-cloud-server"
    echo "  -r RELEASE: elixir"
    echo "  -v Version: i.e. 7.5.0, 3.1.0"
    echo "  -t Toy Build Number: i.e. 123"
    echo "  optional:"
    echo "  -a ARCH: x86_64 or aarch64"
    echo "  -e AWS_PROFILE: dbaas-test-0005-temp or dbaas-stage-0001-temp"
    echo "  -g REGION: i.e. us-east-1"
    echo "  -s SHA that agent is built from"
    exit -1
}

function create_ami
{
    local PRODUCT="${1}"
    local PACKER_FILE="${2}"
    AMI_NAME=Toy-${PRODUCT}-${VERSION}-${TOY_BLD_NUM}

#set environment variables used by packer file
#make sure .env is created fresh
rm .env-${AMI_NAME}-${ARCH}-${AWS_PROFILE}
cat <<EOT >> .env-${AMI_NAME}-${ARCH}-${AWS_PROFILE}
export PKR_VAR_region=${REGION}
export PKR_VAR_product_name=${PRODUCT}
export PKR_VAR_product_version=${VERSION}
export PKR_VAR_product_bld_num=${TOY_BLD_NUM}
export PKR_VAR_ami_name=${AMI_NAME}
export PKR_VAR_product_platform=linux
export PKR_VAR_product_arch=${ARCH}
export PKR_VAR_agent_sha=${AGENT_SHA}
EOT

    #packer variables specific for couchbase-server
    case ${PRODUCT} in
        couchbase-serverless-server*)
            echo "export PKR_VAR_enableServerless=true" >> .env-${AMI_NAME}-${ARCH}-${AWS_PROFILE}
            echo "export PKR_VAR_dp_service=dp-agent" >> .env-${AMI_NAME}-${ARCH}-${AWS_PROFILE}
           ;;
        couchbase-serverless-backup*)
            echo "export PKR_VAR_enableServerless=true" >> .env-${AMI_NAME}-${ARCH}-${AWS_PROFILE}
            echo "export PKR_VAR_dp_service=dp-backup" >> .env-${AMI_NAME}-${ARCH}-${AWS_PROFILE}
           ;;
        couchbase-cloud-server*)
            echo "export PKR_VAR_enableServerless=false" >> .env-${AMI_NAME}-${ARCH}-${AWS_PROFILE}
            echo "export PKR_VAR_dp_service=dp-agent" >> .env-${AMI_NAME}-${ARCH}-${AWS_PROFILE}
           ;;
        couchbase-cloud-backup*)
            echo "export PKR_VAR_enableServerless=false" >> .env-${AMI_NAME}-${ARCH}-${AWS_PROFILE}
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
        AWS_PROFILE=${AWS_PROFILE} packer build ${PACKER_FILE} || { echo "Failed to create AMI ${AMI_NAME}" ; exit -1; }
    else
        echo "${AMI_NAME} already exist on ${AWS_PROFILE}"
    fi
}

#default config
ARCH="aarch64"
AWS_SHARED_CREDENTIALS_FILE=${WORKSPACE}/cloud-build-tools/utilities/.aws/credentials
AWS_CONFIG_FILE=${WORKSPACE}/cloud-build-tools/utilities/.aws/config
AWS_PROFILE=dbaas-test-0005-temp
REGION="us-east-1"
AGENT_SHA="latest"

while getopts p:r:v:t:a:g:e:s: opt
do
    case ${opt} in
        p) PRODUCT=${OPTARG}
           ;;
        r) RELEASE=${OPTARG}
           ;;
        v) VERSION=${OPTARG}
           ;;
        t) TOY_BLD_NUM=${OPTARG}
           ;;
        a) ARCH=${OPTARG}
           ;;
        g) REGION=${OPTARG}
           ;;
        e) AWS_PROFILE=${OPTARG}
           ;;
        s) AGENT_SHA=${OPTARG}
           ;;
        *) usage
           ;;
    esac
done

if [[ -z ${PRODUCT} || -z ${RELEASE} || -z ${VERSION} || -z ${TOY_BLD_NUM} ]]; then
    usage
fi

if [[ ! -d ${WORKSPACE}/cloud-build-tools/utilities/agents ]]; then
   echo "Data plane agents not found."
   exit -1
fi

# Only couchbase-server is supported right now since DN and DAPI don't have toy build capabilities.
# Neo: couchbase-cloud-server, couchbase-cloud-backup
# Elixir+: couchbase-serverless-server, couchbase-serverless-backup

case ${PRODUCT} in
    couchbase-cloud*|couchbase-serverless*)
        packer_file="couchbase-server.pkr.hcl"
        PRODUCT_PKG_URL="http://latestbuilds.service.couchbase.com/builds/latestbuilds/couchbase-server/toybuilds/${TOY_BLD_NUM}/couchbase-server-enterprise-${VERSION}-${TOY_BLD_NUM}-amzn2.${ARCH}.rpm"
        cd ${WORKSPACE}/cloud-build-tools/couchbase-server/aws
        curl --fail -LO ${PRODUCT_PKG_URL} || exit -1
        cp -rp ${WORKSPACE}/cloud-build-tools/utilities/agents .
        create_ami ${PRODUCT} ${packer_file}
        ;;
    *)
        echo "${PRODUCT} is not supported"
        exit -1
        ;;
esac
