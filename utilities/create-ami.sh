#!/bin/bash -e

function usage
{
    echo "Usage: $0 -p <Product> -v <Version> -b <Build Number> -a <AMI Name> -c <AWS Config File> -s <AWS Shred Credentials File> -n"
    echo "  -p Product:  direct-nabula|couchbase-data-api"
    echo "  -v Version: i.e. 7.5.0, 3.1.0"
    echo "  -b Build Number: i.e. 123"
    echo "  -e AWS_PROFILE: profile name specified in aws config"
    echo "  optional:"
    echo "  -a AMI Name: couchbase-data-api-test"
    echo "  -r ARCH: x86_64 or aarch64"
    echo "  -c AWS Config File: ~/.aws/config"
    echo "  -s AWS Shared Credentials File: ~/.aws/credentials"
    exit 1
}

function download_files
{
    curl --fail -LO ${PRODUCT_PKG_URL}
    # https://couchbasecloud.atlassian.net/browse/AV-47166
    # Add debug rpm to serverless AMI temporarily.  This will be removed once the product is more stable.
    if [[ ${PRODUCT} == "couchbase-serverless-"* ]]; then
        PRODUCT_DEBUG_PKG_URL="http://latestbuilds.service.couchbase.com/builds/latestbuilds/couchbase-server/${RELEASE}/${BLD_NUM}/couchbase-server-enterprise-debuginfo-${VERSION}-${BLD_NUM}-amzn2.${ARCH}.rpm"
        curl --fail -LO ${PRODUCT_DEBUG_PKG_URL}
    fi
    cp -rp ${WORKSPACE}/cloud-build-tools/utilities/agents .
}

function create_ami
{
    local AMI_PRODUCT="${1}"
    local PACKER_FILE="${2}"
    if [[ -z ${AMI_NAME_OVERWRITE} ]]; then
        AMI_NAME=${AMI_PRODUCT}-${VERSION}-${BLD_NUM}
    else
        AMI_NAME=${AMI_NAME_OVERWRITE}
    fi

#set environment variables used by packer file
#make sure .env is created fresh
rm .env-${AMI_NAME}-${ARCH}-${AWS_PROFILE}
cat <<EOT >> .env-${AMI_NAME}-${ARCH}-${AWS_PROFILE}
export PKR_VAR_region=us-east-1
export PKR_VAR_product_name=${AMI_PRODUCT}
export PKR_VAR_product_version=${VERSION}
export PKR_VAR_product_bld_num=${BLD_NUM}
export PKR_VAR_ami_name=${AMI_NAME}
export PKR_VAR_product_platform=linux
export PKR_VAR_product_arch=${ARCH}
EOT

    #packer variables specific for couchbase-server
    case ${AMI_PRODUCT} in
        couchbase-serverless-server*) 
            echo "export PKR_VAR_enableServerless=true" >> .env-${AMI_NAME}-${ARCH}-${AWS_PROFILE}
            echo "export PKR_VAR_dp_service=dp-agent" >> .env-${AMI_NAME}-${ARCH}-${AWS_PROFILE}
            echo "export PKR_VAR_dp_service_file=../utilities/agents/${ARCH}/dp-serverless.gz" >> .env-${AMI_NAME}-${ARCH}-${AWS_PROFILE}
           ;;
        couchbase-serverless-backup*)
            echo "export PKR_VAR_enableServerless=true" >> .env-${AMI_NAME}-${ARCH}-${AWS_PROFILE}
            echo "export PKR_VAR_dp_service=dp-backup" >> .env-${AMI_NAME}-${ARCH}-${AWS_PROFILE}
            echo "export PKR_VAR_dp_service_file=../utilities/agents/${ARCH}/dp-backup.gz" >> .env-${AMI_NAME}-${ARCH}-${AWS_PROFILE}
           ;;
        couchbase-cloud-server*)
            echo "export PKR_VAR_enableServerless=false" >> .env-${AMI_NAME}-${ARCH}-${AWS_PROFILE}
            echo "export PKR_VAR_dp_service=dp-agent" >> .env-${AMI_NAME}-${ARCH}-${AWS_PROFILE}
            echo "export PKR_VAR_dp_service_file=../utilities/agents/${ARCH}/dp-agent.gz" >> .env-${AMI_NAME}-${ARCH}-${AWS_PROFILE}
           ;;
        couchbase-cloud-backup*)
            echo "export PKR_VAR_enableServerless=false" >> .env-${AMI_NAME}-${ARCH}-${AWS_PROFILE}
            echo "export PKR_VAR_dp_service=dp-agent" >> .env-${AMI_NAME}-${ARCH}-${AWS_PROFILE}
            echo "export PKR_VAR_dp_service_file=../utilities/agents/${ARCH}/dp-backup.gz" >> .env-${AMI_NAME}-${ARCH}-${AWS_PROFILE}
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
        AWS_PROFILE=${AWS_PROFILE} packer build ${PACKER_FILE} || { echo "Failed to create AMI ${AMI_NAME}" ; exit 1; }

        # Keep a list of AMIs created.
        # It is currently used to determinie if we should trigger qe-jenkins sanity_tests
        echo "${AMI_NAME}" >> ${WORKSPACE}/AMIS_CREATED
    else
        echo "${AMI_NAME} already exist on ${AWS_PROFILE}"
    fi
}

#default config
ARCH="aarch64"
AWS_SHARED_CREDENTIALS_FILE=${WORKSPACE}/cloud-build-tools/utilities/.aws/credentials
AWS_CONFIG_FILE=${WORKSPACE}/cloud-build-tools/utilities/.aws/config

while getopts a:b:c:e:p:r:s:v: opt
do
    case ${opt} in
        a) AMI_NAME_OVERWRITE=${OPTARG}
           ;;
        b) BUILD_NUM=${OPTARG}
           ;;
        c) AWS_CONFIG_FILE=${OPTARG}
           ;;
        e) AWS_PROFILE=${OPTARG}
           ;;
        p) PRODUCT=${OPTARG}
           ;;
        r) ARCH=${OPTARG}
           ;;
        s) AWS_SHARED_CREDENTIALS_FILE=${OPTARG}
           ;;
        v) VERSION=${OPTARG}
           ;;
        *) usage
           ;;
    esac
done

if [[ -z ${PRODUCT} || -z ${VERSION} || -z ${BUILD_NUM} || -z ${AWS_PROFILE} ]]; then
    usage
fi

# Current Supported Products:
# 	couchbase-cloud-server couchbase-cloud-backup couchbase-serverless-server couchbase-serverless-backup
#       couchbase-cloud-server-perf couchbase-cloud-backup-perf couchbase-serverless-server-perf couchbase-serverless-backup-perf
#       direct-nebula
#       couchbase-data-api

case ${PRODUCT} in
    couchbase-cloud*)
        packer_file="couchbase-server.pkr.hcl"
        PRODUCT_PKG_URL="http://latestbuilds.service.couchbase.com/builds/latestbuilds/couchbase-server/${RELEASE}/${BLD_NUM}/couchbase-server-enterprise-${VERSION}-${BLD_NUM}-amzn2.${ARCH}.rpm"
        cd ${WORKSPACE}/cloud-build-tools/couchbase-server
        download_files
        create_ami ${PRODUCT} ${packer_file}
        ;;
    couchbase-serverless*)
        if [[ ${PRODUCT} == *"perf" ]]; then
            packer_file="couchbase-server-perf.pkr.hcl"
        else
            packer_file="couchbase-server.pkr.hcl"
        fi
        PRODUCT_PKG_URL="http://latestbuilds.service.couchbase.com/builds/latestbuilds/couchbase-server/${RELEASE}/${BLD_NUM}/couchbase-server-enterprise-${VERSION}-${BLD_NUM}-amzn2.${ARCH}.rpm"
        cd ${WORKSPACE}/cloud-build-tools/couchbase-server
        download_files

        #Temporarily add "x86_64" to AMI name for Intel.
        #Per discussion with the team, we will stop building x86_64 after offically switch over to arm64.
        if [[ ${ARCH} == "x86_64" ]]; then
            AMI_NAME_OVERWRITE=${PRODUCT}-${VERSION}-${BLD_NUM}-x86_64
        fi
        create_ami ${PRODUCT} ${packer_file}
        ;;
    direct-nebula|couchbase-data-api)
        PRODUCT_PKG_URL="http://latestbuilds.service.couchbase.com/builds/latestbuilds/${PRODUCT}/${RELEASE}/${BLD_NUM}/${PRODUCT}_${VERSION}-${BLD_NUM}-linux.${ARCH}.tar.gz"
        cd ${WORKSPACE}/cloud-build-tools/${PRODUCT}
        download_files
        create_ami ${PRODUCT} ${PRODUCT}.pkr.hcl
        ;;
    *)
        echo "${PRODUCT} is not supported"
        exit -1
        ;;
esac
