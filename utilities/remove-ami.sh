#!/bin/bash -e

function aws_filter_images {
    start_date="$1"
    image_pattern="$2"
    if [[ -z "${start_date}" || -z ${image_pattern} ]]; then
        echo "Both \$start_date and \$image_pattern must be set!"
        exit 1
    fi
    local result=$(aws ec2 describe-images \
        --filters "Name=name,Values=${image_pattern}" "Name=tag:creator,Values=build-team" \
        --query "Images[?CreationDate<\`${start_date}\`].[ImageId, BlockDeviceMappings[0].Ebs.SnapshotId]" \
        --output text)
    echo "${result}"
}

function aws_filter_instances {
    ami_name="$1"
    if [[ -z "${ami_name}" ]]; then
        echo "\$ami_name must be set!"
        exit 1
    fi
    local result=$(aws ec2 describe-instances \
        --filters "Name=image-id,Values=${ami_name}" \
        --query 'Reservations[*].Instances[*].{Instance:InstanceId}' \
        --output text)
    echo "${result}"
}

function usage
{
  echo "\nUsage: $0 -p <Product> -v <Version> \n"
  echo "  -p Product:  couchbase-cloud|couchbase-serverless|direct-nebula|couchase-data-api \n"
  echo "  -v Version: i.e. 7.2.0, 0.1 \n"
}

older_than=$(date +"%Y-%m-%d" -d "14 day ago")
VERSION="7.2.0"
PRODUCT="couchbase-cloud"

while getopts a:b:e:p:r:v:nd opt
do
  case ${opt} in
    p) PRODUCT=${OPTARG}
      ;;
    v) VERSION=${OPTARG}
      ;;
    *)
      usgae
      ;;
    esac
done

set -x
images=$(aws_filter_images ${older_than} ${PRODUCT}-*${VERSION}*)
echo "${images}" | while read -r ami snapshot; do
    echo "ami:$ami"
    echo "snapshot:$snapshot"
    instances=$(aws_filter_instances ${ami})
    if [[ $instances == "" ]]; then
        echo "No instance is using ${ami}.  Assume it is safe to remove.\n"
        aws ec2 deregister-image --image-id $ami
        aws ec2 delete-snapshot --snapshot-id $snapshot
    else
        echo "found instances: \n"
        echo $instances
        echo "Will not remove image ${ami}.\n"
    fi
done
