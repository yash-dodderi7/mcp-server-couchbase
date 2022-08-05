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

    if [[ -f ${WORKSPACE}/cloud-build-tools/utilities/dp-serverless.gz ]]; then
        cp ${WORKSPACE}/cloud-build-tools/utilities/dp-serverless.gz .
    else
        echo "${WORKSPACE}/cloud-build-tools/utilities/dp-serverless.gz doesn't exist."
        echo "Please check to ensure it exists on s3 and it has been properly download by cloudutilities.py."
        exit 1
    fi

    curl --fail -LO http://latestbuilds.service.couchbase.com/builds/latestbuilds/${PRODUCT}/${RELEASE}/${BLD_NUM}/${PRODUCT}_${VERSION}-${BLD_NUM}-linux.${ARCH}.tar.gz
}

function set_config
{
    if [[ -z ${AMI_NAME_OVERWRITE} ]]; then
        AMI_NAME=${PRODUCT}-${VERSION}-${BLD_NUM}-robot
    else
        AMI_NAME=${AMI_NAME_OVERWRITE}
    fi

cat <<EOT >> .env
export PKR_VAR_region=us-east-1
export PKR_VAR_product_name=${PRODUCT}
export PKR_VAR_product_version=${VERSION}
export PKR_VAR_product_bld_num=${BLD_NUM}
export PKR_VAR_ami_name=${AMI_NAME}
export PKR_VAR_product_platform=linux
export PKR_VAR_product_arch=${ARCH}
EOT

}

#default config
ARCH="aarch64"
AWS_SHARED_CREDENTIALS_FILE=${WORKSPACE}/cloud-build-tools/utilities/.aws/credentials
AWS_CONFIG_FILE=${WORKSPACE}/cloud-build-tools/utilities/.aws/config

while getopts a:b:c:e:p:s:v: opt
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
        *) usgae
           ;;
    esac
done

if [[ -z ${PRODUCT} || -z ${VERSION} || -z ${BUILD_NUM} || -z ${AWS_PROFILE} ]]; then
    usage
fi

cd ${WORKSPACE}/cloud-build-tools/${PRODUCT}
download_files
set_config

source .env


echo "checking AMI on ${AWS_PROFILE}"
check_image=$(AWS_PROFILE=${AWS_PROFILE} aws ec2 describe-images \
    --owners self \
    --filters "Name=name,Values=${AMI_NAME}" \
    --query "Images[].[ImageId]" \
    --output text)
if [[ -z $check_image ]]; then
    echo "Creating ${AMI_NAME}..."
    AWS_PROFILE=${AWS_PROFILE} packer build ${PRODUCT}.pkr.hcl
else
    echo "${AMI_NAME} already exist on ${AWS_PROFILE}"
fi
