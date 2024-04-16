#!/bin/bash -e

function usage
{
    echo "Usage: $0 -p <Product> -r <Release> -v <Version> -b <Build Number> -e <environment>-i <Image Factory Project ID>"
    echo "  -p Product:  direct-nabula|couchbase-data-api"
    echo "  -r RELEASE: elixir"
    echo "  -v Version: i.e. 7.5.0, 3.1.0"
    echo "  -b Build Number: i.e. 123"
    echo "  -e Environment: test|nonprod|prod"
    echo "  -i Image Factory Project ID"
    exit 1
}

function download_files
{
    curl --fail -LO ${PRODUCT_PKG_URL}
    cp -rp ${WORKSPACE}/cloud-build-tools/utilities/agents .
}

function create_image
{
    # GCP image does not allow dot
    IMAGE_VERSION=$(echo ${VERSION}|sed 's/\./-/g')
    IMAGE_NAME=${PRODUCT}-${IMAGE_VERSION}-${BLD_NUM}
    if [[ ! -z ${IMAGE_NAME_OVERWRITE} ]]; then
        IMAGE_NAME=${IMAGE_NAME_OVERWRITE}
    fi
    if [[ ! -z ${IMAGE_VERSION_OVERWRITE} ]]; then
        IMAGE_VERSION=${IMAGE_VERSION_OVERWRITE}
    fi

#set environment variables used by packer file
#make sure .env is created fresh
    rm .env-${IMAGE_NAME}-${ARCH}-${ENV}
cat <<EOT >> .env-${IMAGE_NAME}-${ARCH}-${ENV}
export PKR_VAR_product_pkg_name=${PRODUCT_PKG_NAME}
export PKR_VAR_product_version=${VERSION}
export PKR_VAR_product_bld_num=${BLD_NUM}
export PKR_VAR_product_arch=${ARCH}
export PKR_VAR_image_name=${IMAGE_NAME}
export PKR_VAR_image_version=${IMAGE_VERSION}
export PKR_VAR_zone=${ZONE}
export PKR_VAR_project_id=${IMAGE_FACTORY_PROJECT_ID}
export PKR_VAR_network_id=$(echo ${IMAGE_FACTORY_PROJECT_ID}|sed 's/rcif-/image-factory-vpc-/g')
export PKR_VAR_access_token=$(cat ${WORKSPACE}/cloud-build-tools/utilities/.gcp/${ENV})
export PKR_VAR_agent_sha=${AGENT_SHA}
EOT

    #packer variables specific for couchbase-server
    case ${PRODUCT} in
        couchbase-cloud-server*)
            echo "export PKR_VAR_ns_server_profile=provisioned" >> .env-${IMAGE_NAME}-${ARCH}-${ENV}
            echo "export PKR_VAR_dp_service=dp-agent" >> .env-${IMAGE_NAME}-${ARCH}-${ENV}
           ;;
        couchbase-cloud-backup*)
            echo "export PKR_VAR_ns_server_profile=provisioned" >> .env-${IMAGE_NAME}-${ARCH}-${ENV}
            echo "export PKR_VAR_dp_service=dp-backup" >> .env-${IMAGE_NAME}-${ARCH}-${ENV}
           ;;
        couchbase-columnar)
            echo "export PKR_VAR_ns_server_profile=columnar" >> .env-${IMAGE_NAME}-${ARCH}-${ENV}
            echo "export PKR_VAR_dp_service=dp-agent" >> .env-${IMAGE_NAME}-${ARCH}-${ENV}
           ;;
        *)
           ;;
    esac

    source .env-${IMAGE_NAME}-${ARCH}-${ENV}
    echo "checking ${IMAGE_NAME}"

    check_image=$(gcloud compute images describe ${IMAGE_NAME} \
        --project ${IMAGE_FACTORY_PROJECT_ID} \
        --access-token-file ${WORKSPACE}/cloud-build-tools/utilities/.gcp/${ENV})
    if [[ -z $check_image ]]; then
        echo "Creating ${IMAGE_NAME}..."
        packer init ${PACKER_FILE} || { echo "Failed to initiate ${PACKER_FILE}" ; exit 1; }
        packer build ${PACKER_FILE} || { echo "Failed to create IMAGE ${IMAGE_NAME}" ; exit 1; }
        # Keep a list of IMAGES created.
        # It is currently used to determinie if we should trigger qe-jenkins sanity_tests
        echo "${IMAGE_NAME}" >> ${WORKSPACE}/IMAGES_CREATED
    else
        echo "${IMAGE_NAME} already exist"
    fi
}


#Main

#default config
ARCH="amd64"
DP_REVISION=1
PLATFORM="linux"
ZONE="us-central1-a"
AGENT_SHA="latest"

while getopts b:d:e:g:i:o:p:r:v: opt
do
    case ${opt} in
        o) IMAGE_NAME_OVERWRITE=${OPTARG}
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
        e) ENV=${OPTARG}
           ;;
        g) AGENT_SHA=${OPTARG}
           ;;
        i) IMAGE_FACTORY_PROJECT_ID=${OPTARG}
           ;;
        *) usage
           ;;
    esac
done

if [[ -z ${PRODUCT} || -z ${RELEASE} || -z ${VERSION} || -z ${BLD_NUM} || -z ${IMAGE_FACTORY_PROJECT_ID} || -z ${ENV} ]]; then
    usage
fi

IMAGE_DEFINITION=${PRODUCT}-${VERSION}

# Current Supported Products:
# 	couchbase-cloud-server couchbase-cloud-backup couchbase-serverless-server couchbase-serverless-backup
#       direct-nebula
#       couchbase-data-api

case ${PRODUCT} in
    couchbase-cloud-server|couchbase-cloud-backup)
        PACKER_FILE="couchbase-server.pkr.hcl"
        PRODUCT_PKG_NAME="couchbase-server-enterprise_${VERSION}-${BLD_NUM}-linux_${ARCH}.deb"
        PRODUCT_PKG_URL="http://latestbuilds.service.couchbase.com/builds/latestbuilds/couchbase-server/${RELEASE}/${BLD_NUM}/${PRODUCT_PKG_NAME}"
        cd ${WORKSPACE}/cloud-build-tools/couchbase-server/gcp
        ;;
    couchbase-columnar)
        PACKER_FILE="couchbase-server.pkr.hcl"
        PRODUCT_PKG_NAME="couchbase-columnar-enterprise_${VERSION}-${BLD_NUM}-linux_${ARCH}.deb"
        PRODUCT_PKG_URL="http://latestbuilds.service.couchbase.com/builds/latestbuilds/couchbase-columnar/${RELEASE}/${BLD_NUM}/${PRODUCT_PKG_NAME}"
        cd ${WORKSPACE}/cloud-build-tools/couchbase-server/gcp
        ;;
    couchbase-cloud-sync-gateway)
        ARCH="x86_64"
        PACKER_FILE="couchbase-sync-gateway.pkr.hcl"
        PRODUCT_PKG_NAME="couchbase-sync-gateway-enterprise_${VERSION}-${BLD_NUM}_${ARCH}.deb"
        PRODUCT_PKG_URL="http://latestbuilds.service.couchbase.com/builds/latestbuilds/sync_gateway/${RELEASE}/${BLD_NUM}/${PRODUCT_PKG_NAME}"
        cd ${WORKSPACE}/cloud-build-tools/couchbase-sync-gateway/gcp
        ;;
    *)
        echo "${PRODUCT} is not supported"
        exit -1
        ;;
esac

download_files
create_image ${PRODUCT} ${PACKER_FILE}
