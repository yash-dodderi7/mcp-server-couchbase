#!/usr/bin/env python3

# Simple script to cleanup aws resources.
##
# 1. remove KMS based on input cluster id.
# More will be added later
##
# Usage:
# python3 aws_cleanup.py -c <cluster_id>
##

import argparse
import boto3
import logging
from pprint import pprint

logging.basicConfig(
    level=logging.INFO,
    handlers=[
        logging.StreamHandler()
    ]
)

def get_kms_by_clusters(region, cluster_id):
    session = boto3.Session()
    client = session.client('resourcegroupstaggingapi',region_name=region)
    key_list = (
        client.get_paginator('get_resources')
        .paginate(
            ResourceTypeFilters=[
                'kms',
            ],
            TagFilters=[
                {
                    'Key': 'couchbase-cloud-cluster-id',
                    'Values': [
                        cluster_id,
                    ]
                }
            ]
        )
        .build_full_result()
    )
    return key_list

def delete_kms(key_list,region):
    session = boto3.Session()
    client = session.client('kms', region_name=region)
    for key in key_list['ResourceTagMappingList']:
        pprint(f"deleting {key['ResourceARN']}")
        response = client.schedule_key_deletion(
            KeyId=key['ResourceARN'],
            PendingWindowInDays=30
        )
       # pprint(response)

if __name__ == "__main__":
    parser = argparse.ArgumentParser('AWS Assume Role')
    parser.add_argument(
        '-c',
        '--cluster_id',
        type=str,
        required=True,
        help='cluster id')

    args = parser.parse_args()
    session = boto3.Session()
    client = session.client('sts')
    user = client.get_caller_identity()
    pprint(user)

    ec2 = boto3.client('ec2')
    regions = ec2.describe_regions()['Regions']
    for region in regions:
        key_list=get_kms_by_clusters(region['RegionName'], args.cluster_id)
        delete_kms(key_list, region['RegionName'])
