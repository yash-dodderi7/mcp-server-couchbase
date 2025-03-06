#!/usr/bin/env python3

# This script is used by cb-robot in data center to manage images on AWS.
# It is unlikely an individual can run this script since she/he may not have
# proper permissions.

import argparse
import logging
import os
import sys
import boto3
import botocore
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


def cleanup_unattached_snapshots(aws_profile, aws_region):
    couchbaseaws = AWSUtils(aws_profile, aws_region)
    snapshots = couchbaseaws.get_all_resources(
        'describe_snapshots', 'Snapshots', OwnerIds=['self'])
    volumes = couchbaseaws.get_all_resources('describe_volumes', 'Volumes')
    volume_ids = set(volume['VolumeId'] for volume in volumes)
    amis = couchbaseaws.get_all_resources(
        'describe_images',
        'Images',
        Owners=['self'],
        IncludeDisabled=True)
    ami_snapshot_ids = {
        mapping.get('Ebs', {}).get('SnapshotId')
        for ami in amis
        for mapping in ami.get('BlockDeviceMappings', [])
        if mapping.get('Ebs', {}).get('SnapshotId')
    }
    unattached_snapshots = [snapshot['SnapshotId']
                            for snapshot in snapshots
                            if snapshot['VolumeId'] not in volume_ids
                            and snapshot['SnapshotId'] not in ami_snapshot_ids
                            ]
    for snapshot in unattached_snapshots:
        couchbaseaws.client.delete_snapshot(SnapshotId=snapshot)


if __name__ == "__main__":
    parser = argparse.ArgumentParser('Couchbase AWS Cloud', allow_abbrev=False)
    subparsers = parser.add_subparsers(help='sub-command help', dest='cmd')

    subparser_copy_ami = subparsers.add_parser(
        'copy_ami', help='Promote(Copy) an AMI to another AWS account')
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
        'delete_ami', help='Deregister an AMI from all regions of an AWS account')
    subparser_delete_ami.add_argument(
        '--ami_name', type=str, required=True, help='AMI name')

    subparser_get_secret = subparsers.add_parser(
        'get_secret', help='Pull secret from AWS Secret Manager')
    subparser_get_secret.add_argument(
        '--secret_name', type=str, required=True, help='secret name')

    subparser_get_regoins = subparsers.add_parser(
        'get_regions', help='Get a list of regions that are enabled for an account')

    subparser_release_ami = subparsers.add_parser(
        'release_ami', help='Add a release tag to an ami after its released')
    subparser_release_ami.add_argument(
        '--ami_name', type=str, required=True, help='AMI name')

    subparser_cleanup_snapshots = subparsers.add_parser(
        'cleanup_snapshots', help='Remove Snapshots that are not associated with any volume')

    if len(sys.argv) == 1:
        parser.print_help(sys.stderr)
        sys.exit(1)

    args = parser.parse_args()

    # Create base AWS client for commands that need it
    if args.cmd in ['delete_ami', 'cleanup_snapshots', 'get_secret',
                    'get_regions', 'release_ami']:
        default_aws_profile = os.getenv('AWS_PROFILE')
        default_aws_region = os.getenv('AWS_REGION', 'us-east-1')
        aws_session = AWSUtils(default_aws_profile, default_aws_region)
        regions = aws.get_regions()

    if args.cmd == 'copy_ami':
        couchbaseaws = AWSUtils(args.source_profile, args.source_region)
        target_session = boto3.Session(profile_name=args.dest_profile)
        target_sts = target_session.client('sts')
        target_aws_account_id = target_sts.get_caller_identity()['Account']
        if not args.dest_regions:
            # In Capella, identical regions are enabled across all accounts.
            # Hence, getting them from the source account is the same as getting
            # the destination account.
            dest_regions = couchbaseaws.get_regions()
        else:
            dest_regions = args.dest_regions.split(',')

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
        ami_name = args.ami_name
        common_utils.concurrent_executor(delete_ami, 25, ami_name,
                                         aws_profile, items=regions)
    if args.cmd == 'cleanup_snapshots':
        common_utils.concurrent_executor(
            cleanup_unattached_snapshots, 25, aws_profile, items=regions)

    if args.cmd == 'get_secret':
        response = couchbaseaws.get_secret(args.secret_name)
        logger.info(f'{response}')

    if args.cmd == 'get_regions':
        logger.info(f'{regions}')

    if args.cmd == 'release_ami':
        couchbaseaws.release_image(args.ami_name)
