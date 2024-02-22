#!/usr/bin/env python3

# This script is used by cb-robot in data center to manage images on AWS.
# It is unlikely an individual can run this script since she/he may not have
# proper permissions.

import boto3
import botocore
import argparse
import logging
import os
import sys
from aws_utils import AWSUtils
import common_utils

# Make boto3 less verbose
logging.getLogger('boto3').setLevel(logging.WARN)
logging.getLogger('botocore').setLevel(logging.WARN)

logger = logging.getLogger()
if not logger.handlers:
    logger.setLevel(logging.INFO)
    console_handler = logging.StreamHandler(stream=sys.stdout)
    logger.addHandler(console_handler)


def build_ami(aws_profile, aws_region, packer_script, env_file):
    couchbaseaws = AWSUtils(aws_profile, aws_region)
    packer_env = common_utils.load_packer_env(env_file, 'ami_name')

    ami_name = packer_env['ami_name']
    # Check if AMI already exist
    logger.info(
        f'Checking if {ami_name} exist.')
    find_ami = couchbaseaws.search_ami_by_pattern(ami_name)
    if len(find_ami) != 0:
        logger.info(
            f'{ami_name} already exist.  It will not be created again.')
    else:
        logger.info(
            f'Building {ami_name}.')
        common_utils.run_cmd(["packer", "build", packer_script])
        # Jenkins job will use this to decide if it is necessary to call QE
        # validation pipeline.
        common_utils.run_cmd(["touch", "IMAGES_CREATED"])


def copy_ami(ami_name, source, source_profile,
             source_region, dest_profile, dest_region):
    if not source:
        source = AWSUtils(source_profile, source_region)
    destination = AWSUtils(dest_profile, dest_region)
    # Check if AMI already exist on destination
    dest_amis = destination.search_ami_by_pattern(ami_name)
    if len(dest_amis) != 0:
        logger.info(
            f'{ami_name} is already on {destination.aws_account_id} '
            f'{destination.client.meta.region_name}.  It will not be copied.'
        )
        return

    # Get AMI detail
    source_amis = source.search_ami_by_pattern(ami_name)
    if len(source_amis) == 1:
        source_ami = source_amis[0]
    else:
        sys.exit(
            f'Unable to identify the source image.  '
            f'{len(source_amis)} AMIs found on {source_profile}'
        )

    # Copy AMI to destiation account
    logger.info(
        f'Copying {ami_name} to {destination.client.meta.region_name} '
        f'on {destination.aws_account_id}.'
    )
    description = f"Copy from {source_ami['ImageId']} on {source.aws_account_id}"
    dest_ami = destination.client.copy_image(
        Name=source_ami['Name'],
        Description=description,
        SourceImageId=source_ami['ImageId'],
        SourceRegion=source.session.region_name
    )

    # Make sure AMI is ready before moving on to the next step.
    destination.wait_for_ami(dest_ami['ImageId'])

    # boto3 copy_image with CopyImageTags doesn't copy image tags across accounts
    # Hence, create_tags is used to recreate the tags.
    destination.client.create_tags(
        Resources=[dest_ami['ImageId']],
        Tags=source_ami['Tags']
    )


def delete_ami(ami_name_pattern, aws_profile, aws_region):
    couchbaseaws = AWSUtils(aws_profile, aws_region)
    amis = couchbaseaws.search_ami_by_pattern(ami_name_pattern)
    if len(amis) == 0:
        logger.info(
            f'No AMI named, {ami_name}, is found on {aws_profile} {aws_region}.  '
            f'Nothing to delete.'
        )
        return
    for ami in amis:
        logger.info(f"Removing {ami['ImageLocation']} from {aws_region}.")
        couchbaseaws.client.deregister_image(ImageId=ami['ImageId'])
        for device in ami['BlockDeviceMappings']:
            if 'Ebs' in device:
                snapshot_id = device['Ebs']['SnapshotId']
                logger.info(f"Removing {snapshot_id} of {ami['ImageId']}.")
                couchbaseaws.client.delete_snapshot(SnapshotId=snapshot_id)


if __name__ == "__main__":
    # Current supported regions
    regions = ['af-south-1', 'ap-east-1', 'ap-northeast-1',
               'ap-northeast-2', 'ap-south-1', 'ap-south-2', 'ap-southeast-1',
               'ap-southeast-2', 'ap-southeast-3', 'ap-southeast-4', 'ca-central-1',
               'eu-central-1', 'eu-central-2', 'eu-north-1', 'eu-south-1',
               'eu-south-2', 'eu-west-1', 'eu-west-2', 'eu-west-3', 'il-central-1',
               'me-central-1', 'me-south-1', 'sa-east-1', 'us-east-1', 'us-east-2',
               'us-west-2']

    parser = argparse.ArgumentParser('Couchbase AWS Cloud', allow_abbrev=False)
    subparsers = parser.add_subparsers(help='sub-command help', dest='cmd')

    subparser_build_ami = subparsers.add_parser(
        'build_ami', help='Build an AMI')
    subparser_build_ami.add_argument(
        '--packer_script',
        type=str,
        required=True,
        help='Path of the packer script')
    subparser_build_ami.add_argument(
        '--packer_var_files',
        type=str,
        default='.env',
        help='Comma separated files containing variables needed by the packer script')
    subparser_build_ami.add_argument(
        '--skip_copy',
        action='store_true',
        help='Skip copy AMIs to other regions')

    subparser_copy_ami = subparsers.add_parser(
        'copy_ami', help='Promote(Copy) an AMI to another aws account')
    subparser_copy_ami.add_argument(
        '--ami_name', type=str, required=True, help='AMI name')
    subparser_copy_ami.add_argument(
        '--source_profile',
        type=str,
        default=os.getenv('AWS_PROFILE'),
        help='AWS account profile where AMI is copied from')
    subparser_copy_ami.add_argument(
        '--source_region',
        type=str,
        default='us-east-1',
        help='AWS account region where AMI is copied from')
    subparser_copy_ami.add_argument(
        '--dest_profile',
        type=str,
        required=True,
        help='AWS account profile where AMI is copied to')
    subparser_copy_ami.add_argument(
        '--dest_regions',
        type=str,
        help='Comma separated regions where AMI is copied to')

    subparser_delete_ami = subparsers.add_parser(
        'delete_ami', help='Deregister an AMI from all regions of an aws account')
    subparser_delete_ami.add_argument(
        '--ami_name', type=str, required=True, help='AMI name')

    subparser_get_secret = subparsers.add_parser(
        'get_secret', help='Pull secret from AWS Secret Manager')
    subparser_get_secret.add_argument(
        '--secret_name', type=str, required=True, help='secret name')

    args = parser.parse_args()

    if args.cmd == 'build_ami':
        var_files = args.packer_var_files.split(',')
        packer_script = args.packer_script
        aws_region = os.getenv('AWS_REGION', 'us-east-1')
        aws_profile = os.getenv('AWS_PROFILE')
        common_utils.concurrent_executor(build_ami, 4, aws_profile,
                                         aws_region, packer_script, items=var_files)
        if not args.skip_copy:
            ami_list = []
            for var_file in var_files:
                vars = common_utils.load_packer_env(var_file, 'ami_name')
                ami_name = vars['ami_name']
                ami_list.append(ami_name)
            common_utils.concurrent_executor_two_lists(
                copy_ami,
                25,
                '',
                aws_profile,
                aws_region,
                aws_profile,
                items1=ami_list,
                items2=regions)

    if args.cmd == 'copy_ami':
        if not args.dest_regions:
            dest_regions = regions
        else:
            args.dest_regions.split(',')
        couchbaseaws = AWSUtils(args.source_profile, args.source_region)
        target_session = boto3.Session(profile_name=args.dest_profile)
        target_sts = target_session.client('sts')
        target_aws_account_id = target_sts.get_caller_identity()['Account']

        # Share the image with the destination account so that it can be
        # copied.
        couchbaseaws.share_image(args.ami_name, 'Add', target_aws_account_id)
        common_utils.concurrent_executor(copy_ami, 25, args.ami_name, '', args.source_profile,
                                         args.source_region, args.dest_profile, items=dest_regions)

        # For security purpose, make sure the image is no longer shared with
        # the destination account.
        couchbaseaws.share_image(
            args.ami_name,
            'Remove',
            target_aws_account_id)

    if args.cmd == 'delete_ami':
        aws_profile = os.getenv('AWS_PROFILE')
        ami_name = args.ami_name
        common_utils.concurrent_executor(delete_ami, 25, ami_name,
                                         aws_profile, items=regions)

    if args.cmd == 'get_secret':
        aws_profile = os.getenv('AWS_PROFILE')
        couchbaseaws = AWSUtils(aws_profile, 'us-east-1')
        response = couchbaseaws.get_secret(args.secret_name)
        logger.info(f'{response}')
