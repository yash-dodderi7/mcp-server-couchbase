#!/usr/bin/env python3

# AWS helper functions

import logging
import sys
import time
import boto3
import botocore

# Make boto3 less verbose
logging.getLogger("boto3").setLevel(logging.WARN)
logging.getLogger("botocore").setLevel(logging.WARN)

logger = logging.getLogger("awsutils")
logger.setLevel(logging.INFO)
console_handler = logging.StreamHandler(stream=sys.stdout)
logger.addHandler(console_handler)


class AWSUtils:
    def __init__(self, profile_name=None, region_name=None):
        self.session = boto3.Session(profile_name=profile_name)
        self.client = self.session.client('ec2', region_name=region_name)
        self.sts = self.session.client('sts')
        self.aws_account_id = self.sts.get_caller_identity()['Account']

    def get_regions(self):
        '''
        Return available regions of the AWS account
        '''
        response = self.client.describe_regions()
        regions = [region['RegionName'] for region in response['Regions']]
        return regions

    def get_ami_by_id(self, ami_id):
        '''
        Return AMI details for a given AMI Id
        '''
        response = self.client.describe_images(ImageIds=[ami_id])
        return response['Images']

    def search_ami_by_pattern(self, ami_filters, exclude_tags=None):
        '''
        Search for AMIs using filter.
        Use exclusion filter to exclude unneeded AMIs.
        Example:
            ami_filters = {'name': 'my-ami'}
            exclude_tags = {'released': 'true'}
        '''
        # Base filters that are always applied
        base_filters = [
            {'Name': 'tag:creator', 'Values': ['build-team']}
        ]

        # Process inclusion filters (required)
        include_filters = [
            {'Name': k, 'Values': [v]} if isinstance(
                v, str) else {'Name': k, 'Values': v}
            for k, v in ami_filters.items()
        ]
        base_filters.extend(include_filters)

        # Get initial results with inclusion filters
        response = self.client.describe_images(
            Filters=base_filters,
            Owners=['self']
        )

        filtered_images = response['Images']

        # If no exclusion filters, return the results
        if not exclude_tags:
            return filtered_images

        # Apply exclusion filters
        final_images = []
        for image in filtered_images:
            exclude_image = False
            for key, value in exclude_tags.items():
                values = [value] if isinstance(value, str) else value
                if key == 'name':
                    if any(val in image.get('Name', '').lower()
                           for val in values):
                        exclude_image = True
                        break
                else:
                    tags = {tag['Key']: tag['Value']
                            for tag in image.get('Tags', [])}
                    if key in tags and any(
                            val in tags[key].lower() for val in values):
                        exclude_image = True
                        break

            if not exclude_image:
                final_images.append(image)

        return final_images

    def get_instances_by_ami_id(self, ami_id):
        '''
        Return EC2 instances that are launched from specified AMI ID
        '''
        response = self.client.describe_instances(
            Filters=[{'Name': 'image-id', 'Values': [ami_id]}]
        )
        return response['Reservations']

    def get_secret(self, secret_name):
        '''
        Retrieve a secret from AWS Secrets Manager.
        '''
        client = self.session.client('secretsmanager')
        return client.get_secret_value(SecretId=secret_name)['SecretString']

    def wait_for_ami(self, ami_id):
        '''
        Wait for an AMI to become available.
        '''
        attempts = 0
        max_attempts = 300
        ami = self.get_ami_by_id(ami_id)
        while ami[0]['State'] != 'available':
            attempts += 1
            time.sleep(10)
            if attempts <= max_attempts:
                ami = self.get_ami_by_id(ami_id)
                if ami[0]['State'] == 'failed':
                    logger.info(f'AMI {ami_id} failed.')
            else:
                logger.error(
                    f'AMI {ami_id} is still not available after 50 minutes.'
                    f'  It might be stuck.'
                )
                return
        logger.info(f'AMI {ami_id} is now available.')

    def share_image(self, ami_name, operation, account_id):
        '''
        Share or unshare an AMI with another AWS account.
        '''
        amis = self.search_ami_by_pattern({'name': ami_name})
        if len(amis) == 0:
            sys.exit(
                f'AMI {ami_name} is NOT found on {self.aws_account_id} '
                f'{self.session.region_name}'
            )
        else:
            ami = amis[0]
        self.client.modify_image_attribute(
            ImageId=ami['ImageId'],
            Attribute='launchPermission',
            OperationType=operation,
            LaunchPermission={
                operation: [{'UserId': account_id}]
            }
        )
        devices = ami['BlockDeviceMappings']
        for device in devices:
            if 'Ebs' in device:
                snapshot_id = device['Ebs']['SnapshotId']
                self.client.modify_snapshot_attribute(
                    SnapshotId=snapshot_id,
                    Attribute='createVolumePermission',
                    OperationType=operation,
                    CreateVolumePermission={
                        operation: [{'UserId': account_id}]
                    },
                )


    def update_image_tags(self, ami_name, tags):
        '''
        Update or add tags to an AMI and its associated snapshots.
        '''
        # Search for the AMI
        images = self.search_ami_by_pattern({'name': ami_name})
        if len(images) != 1:
            raise SystemExit(
                f"{len(images)} AMIs found matching '{ami_name}' in {self.client.meta.region_name}."
                "Expected exactly one match."
            )
        image = images[0]
        image_id = image['ImageId']
        snapshot_id = image['BlockDeviceMappings'][0]['Ebs']['SnapshotId']

        # Create tag list format required by AWS API
        aws_tags = [{'Key': k, 'Value': v} for k, v in tags.items()]

        # Update tags on both AMI and snapshot
        self.client.create_tags(
            Resources=[image_id, snapshot_id],
            Tags=aws_tags
        )


    def get_all_resources(self, api, key, **params):
        '''
        Retrieve all resources from a paginated AWS API.
        Example:
            describe_snapshots
            describe_volumes
        '''
        paginator = self.client.get_paginator(api)
        resources = []
        for page in paginator.paginate(**params):
            resources.extend(page[key])
        return resources
