#!/bin/bash -e

function usage
{
    echo "\nUsage: $0 -p <Product> -v <Version> -b <Build Number> -a <AMI Name> -c <AWS Config File> -s <AWS Shred Credentials File> -n\n"
    echo "  -p Product:  direct-nabula|couchbase-data-api \n"
    echo "  -v Version: i.e. 7.2.0, 3.1.0 \n"
    echo "  -b Build Number: i.e. 123 \n"
    echo "  -e AWS_PROFILE: profile name specified in aws config\n"
    echo "  optional: \n"
    echo "  -a AMI Name: couchbase-data-api-test\n"
    echo "  -c AWS Config File: ~/.aws/config\n"
    echo "  -s AWS Shared Credentials File: ~/.aws/credentials\n"
    echo "  -P if generating perf AMIs.  This option is specific to couchbse-server.\n"
    exit 1
}

function download_files
{
    if [ ! -f packer ]; then
        curl --fail -L https://releases.hashicorp.com/packer/1.8.1/packer_1.8.1_linux_amd64.zip -o packer.zip
        unzip packer.zip
        chmod +x packer
    fi
    export PATH=`pwd`:$PATH

    cp ${WORKSPACE}/cloud-build-tools/utilities/dp-*.gz .

    curl --fail -LO ${PRODUCT_PKG_URL}
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
rm .env
cat <<EOT >> .env
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
            echo "export PKR_VAR_enableServerless=true" >> .env
            echo "export PKR_VAR_dp_service=dp-agent" >> .env
           ;;
        couchbase-serverless-backup*)
            echo "export PKR_VAR_enableServerless=true" >> .env
            echo "export PKR_VAR_dp_service=dp-backup" >> .env
           ;;
        couchbase-cloud-server*)
            echo "export PKR_VAR_enableServerless=false" >> .env
            echo "export PKR_VAR_dp_service=dp-agent" >> .env
           ;;
        couchbase-cloud-backup*)
            echo "export PKR_VAR_enableServerless=false" >> .env
            echo "export PKR_VAR_dp_service=dp-agent" >> .env
           ;;
        *)
           ;;
    esac

    source .env
    echo "checking AMI on ${AWS_PROFILE}"
    check_image=$(AWS_PROFILE=${AWS_PROFILE} aws ec2 describe-images \
        --owners self \
        --filters "Name=name,Values=${AMI_NAME}" \
        --query "Images[].[ImageId]" \
        --output text)
    if [[ -z $check_image ]]; then
        echo "Creating ${AMI_NAME}..."
        AWS_PROFILE=${AWS_PROFILE} packer build ${PACKER_FILE}
    else
        echo "${AMI_NAME} already exist on ${AWS_PROFILE}"
    fi
}

#default config
ARCH="aarch64"
AWS_SHARED_CREDENTIALS_FILE=${WORKSPACE}/cloud-build-tools/utilities/.aws/credentials
AWS_CONFIG_FILE=${WORKSPACE}/cloud-build-tools/utilities/.aws/config
PERF=false

while getopts a:b:c:e:p:s:v:P opt
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
        s) AWS_SHARED_CREDENTIALS_FILE=${OPTARG}
           ;;
        v) VERSION=${OPTARG}
           ;;
        P) PERF=true
           ;;
        *) usgae
           ;;
    esac
done

if [[ -z ${PRODUCT} || -z ${VERSION} || -z ${BUILD_NUM} || -z ${AWS_PROFILE} ]]; then
    usage
fi


#https://docs.aws.amazon.com/STS/latest/APIReference/API_AssumeRole.html
#Role chaining limits has a max of one hour.
#We need to make sure AMIs are created within an hour.  Hence, server AMIs need to be broken into groups

cd ${WORKSPACE}/cloud-build-tools/${PRODUCT}
if [[ ${PRODUCT} == "couchbase-server" ]]; then
    PRODUCT_PKG_URL="http://latestbuilds.service.couchbase.com/builds/latestbuilds/${PRODUCT}/${RELEASE}/${BLD_NUM}/${PRODUCT}-enterprise-${VERSION}-${BLD_NUM}-amzn2.x86_64.rpm"
    if [[ ${PERF} == "true" ]]; then
        products="couchbase-cloud-server-perf couchbase-cloud-backup-perf couchbase-serverless-server-perf couchbase-serverless-backup-perf"
        packer_file="couchbase-server-perf.pkr.hcl"
    else
        products="couchbase-cloud-server couchbase-cloud-backup couchbase-serverless-server couchbase-serverless-backup"
        packer_file="couchbase-server.pkr.hcl"
    fi
    download_files
    for p in ${products}; do
        create_ami ${p} ${packer_file}
    done
else
    PRODUCT_PKG_URL="http://latestbuilds.service.couchbase.com/builds/latestbuilds/${PRODUCT}/${RELEASE}/${BLD_NUM}/${PRODUCT}_${VERSION}-${BLD_NUM}-linux.${ARCH}.tar.gz"
    download_files
    create_ami ${PRODUCT} ${PRODUCT}.pkr.hcl
fi
