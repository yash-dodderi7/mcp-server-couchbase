#!/bin/bash -e

function usage
{
    echo "Usage: $0 -p <Product> -r <Release> -v <Version> -b <Build Number> -c <Client ID> -s <Client Secret> -i <Subscription ID> -t <Tenant ID>"
    echo "  -p Product:  direct-nabula|couchbase-data-api"
    echo "  -r RELEASE: elixir"
    echo "  -v Version: i.e. 7.5.0, 3.1.0"
    echo "  -b Build Number: i.e. 123"
    echo "  -c Client ID"
    echo "  -s Client Secret"
    echo "  -i Subscription ID"
    echo "  -t Tenant ID"
    exit 1
}

function download_files
{
    curl --fail -LO ${PRODUCT_PKG_URL}
    cp -rp ${WORKSPACE}/cloud-build-tools/utilities/agents .
}

function create_image
{
    local IMAGE_PRODUCT="${1}"
    local PACKER_FILE="${2}"
    IMAGE_VERSION=${BLD_NUM}.0.${DP_REVISION}
    IMAGE_NAME=${IMAGE_PRODUCT}-${VERSION}-${BLD_NUM}-${DP_REVISION}
    if [[ ! -z ${IMAGE_NAME_OVERWRITE} ]]; then
        IMAGE_NAME=${IMAGE_NAME_OVERWRITE}
    fi
    if [[ ! -z ${IMAGE_VERSION_OVERWRITE} ]]; then
        IMAGE_VERSION=${IMAGE_VERSION_OVERWRITE}
    fi

#set environment variables used by packer file
#make sure .env is created fresh
    rm .env-${IMAGE_NAME}-${ARCH}-${SUBSCRIPTION_ID}
cat <<EOT >> .env-${IMAGE_NAME}-${ARCH}-${SUBSCRIPTION_ID}
export PKR_VAR_product_name=${IMAGE_PRODUCT}
export PKR_VAR_product_version=${VERSION}
export PKR_VAR_product_bld_num=${BLD_NUM}
export PKR_VAR_product_arch=${ARCH}
export PKR_VAR_subscription_id=${SUBSCRIPTION_ID}
export PKR_VAR_client_id=${CLIENT_ID}
export PKR_VAR_client_secret=${CLIENT_SECRET}
export PKR_VAR_resource_group=${RESOURCE_GROUP}
export PKR_VAR_image_gallery=${GALLERY_NAME}
export PKR_VAR_image_definition=${IMAGE_DEFINITION}
export PKR_VAR_image_name=${IMAGE_NAME}
export PKR_VAR_image_version=${IMAGE_VERSION}
export PKR_VAR_region=${REGION}
export PKR_VAR_replication_regions='${REPLICATION_REGIONS}'
EOT

    #packer variables specific for couchbase-server
    case ${IMAGE_PRODUCT} in
        couchbase-serverless-server*)
            echo "export PKR_VAR_enableServerless=true" >> .env-${IMAGE_NAME}-${ARCH}-${SUBSCRIPTION_ID}
            echo "export PKR_VAR_dp_service=dp-agent" >> .env-${IMAGE_NAME}-${ARCH}-${SUBSCRIPTION_ID}
           ;;
        couchbase-serverless-backup*)
            echo "export PKR_VAR_enableServerless=true" >> .env-${IMAGE_NAME}-${ARCH}-${SUBSCRIPTION_ID}
            echo "export PKR_VAR_dp_service=dp-backup" >> .env-${IMAGE_NAME}-${ARCH}-${SUBSCRIPTION_ID}
           ;;
        couchbase-cloud-server*)
            echo "export PKR_VAR_enableServerless=false" >> .env-${IMAGE_NAME}-${ARCH}-${SUBSCRIPTION_ID}
            echo "export PKR_VAR_dp_service=dp-agent" >> .env-${IMAGE_NAME}-${ARCH}-${SUBSCRIPTION_ID}
           ;;
        couchbase-cloud-backup*)
            echo "export PKR_VAR_enableServerless=false" >> .env-${IMAGE_NAME}-${ARCH}-${SUBSCRIPTION_ID}
            echo "export PKR_VAR_dp_service=dp-backup" >> .env-${IMAGE_NAME}-${ARCH}-${SUBSCRIPTION_ID}
           ;;
        *)
           ;;
    esac

    source .env-${IMAGE_NAME}-${ARCH}-${SUBSCRIPTION_ID}
    echo "checking ${IMAGE_NAME}"

    # When secret starts with "-", "-p ${CLIENT_SECRET}" will failure.
    # Hence "-p=${CLIENT_SECRET}" is used instead.
    az login --service-principal -u ${CLIENT_ID} -p=${CLIENT_SECRET} --tenant ${TENANT_ID}
    check_image=$(az image show --name ${IMAGE_NAME} \
        --resource-group ${RESOURCE_GROUP})
    if [[ -z $check_image ]]; then
        echo "Creating ${IMAGE_NAME}..."
        packer init ${PACKER_FILE} || { echo "Failed to initiate ${PACKER_FILE}" ; exit 1; }
        packer build ${PACKER_FILE} || { echo "Failed to create IMAGE ${IMAGE_NAME}" ; exit 1; }
    else
        echo "${IMAGE_NAME} already exist"
    fi
}


#Main

#default config
ARCH="amd64"
DP_REVISION=1
RESOURCE_GROUP="image-factory"
GALLERY_NAME="capella"
PLATFORM="ubuntu20.04"
REGION="eastus"
REPLICATION_REGIONS='["australiaeast", "brazilsouth", "centralindia", "centralus", "canadacentral", "eastus2", "eastus", "francecentral", "germanywestcentral", "swedencentral", "japaneast", "koreacentral", "northeurope", "norwayeast", "southeastasia", "uksouth", "westeurope", "westus2", "westus3"]'

while getopts p:r:v:b:c:d:s:i:t:o:w: opt
do
    case ${opt} in
        o) IMAGE_NAME_OVERWRITE=${OPTARG}
           ;;
        w)IMAGE_VERSION_OVERWRITE=${OPTARG}
           ;;
        p) PRODUCT=${OPTARG}
           ;;
        r) RELEASE=${OPTARG}
           ;;
        v) VERSION=${OPTARG}
           ;;
        b) BLD_NUM=${OPTARG}
           ;;
        d) DP_REVISION=${OPTARG}
           ;;
        c) CLIENT_ID=${OPTARG}
           ;;
        s) CLIENT_SECRET=${OPTARG}
           ;;
        i) SUBSCRIPTION_ID=${OPTARG}
           ;;
        t) TENANT_ID=${OPTARG}
           ;;
        *) usage
           ;;
    esac
done

if [[ -z ${PRODUCT} || -z ${RELEASE} || -z ${VERSION} || -z ${BLD_NUM} || -z ${CLIENT_ID} ||  -z ${CLIENT_SECRET} || -z ${SUBSCRIPTION_ID} || -z ${TENANT_ID} ]]; then
    echo "p is ${PRODUCT}"
    echo "r is ${RELEASE}"
    echo "v is ${VERSION}"
    echo "b is ${BLD_NUM}"
    echo "c is ${CLIENT_ID}"
    echo "s is ${CLIENT_SECRET}"
    echo "s is ${SUBSCRIPTION_ID}"
    echo "t is ${TENANT_ID}"
    usage
fi

IMAGE_DEFINITION=${PRODUCT}-${VERSION}

# Current Supported Products:
# 	couchbase-cloud-server couchbase-cloud-backup couchbase-serverless-server couchbase-serverless-backup
#       direct-nebula
#       couchbase-data-api

case ${PRODUCT} in
    couchbase-cloud*)
        packer_file="couchbase-server.pkr.hcl"
        PRODUCT_PKG_URL="http://latestbuilds.service.couchbase.com/builds/latestbuilds/couchbase-server/${RELEASE}/${BLD_NUM}/couchbase-server-enterprise_${VERSION}-${BLD_NUM}-${PLATFORM}_${ARCH}.deb"
        cd ${WORKSPACE}/cloud-build-tools/couchbase-server/azure
        download_files
        create_image ${PRODUCT} ${packer_file}
        ;;
    couchbase-serverless*)
        packer_file="couchbase-server.pkr.hcl"
        PRODUCT_PKG_URL="http://latestbuilds.service.couchbase.com/builds/latestbuilds/couchbase-server/${RELEASE}/${BLD_NUM}/couchbase-server-enterprise_${VERSION}-${BLD_NUM}-${PLATFORM}_${ARCH}.deb"
        cd ${WORKSPACE}/cloud-build-tools/couchbase-server/azure
        download_files
        create_image ${PRODUCT} ${packer_file}
        ;;
    direct-nebula|couchbase-data-api)
        PRODUCT_PKG_URL="http://latestbuilds.service.couchbase.com/builds/latestbuilds/${PRODUCT}/${RELEASE}/${BLD_NUM}/${PRODUCT}_${VERSION}-${BLD_NUM}-linux.${ARCH}.tar.gz"
        cd ${WORKSPACE}/cloud-build-tools/${PRODUCT}/azure
        download_files
        create_image ${PRODUCT} ${PRODUCT}.pkr.hcl
        ;;
    *)
        echo "${PRODUCT} is not supported"
        exit -1
        ;;
esac
