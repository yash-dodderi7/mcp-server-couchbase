#!/usr/bin/env python3

# AWS helper functions

import boto3
import botocore
import sys
import time
import logging

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

    def get_ami_by_id(self, ami_id):
        response = self.client.describe_images(ImageIds=[ami_id])
        return response['Images']

    def search_ami_by_pattern(self, name_pattern):
        response = self.client.describe_images(
            Filters=[
                {'Name': 'name', 'Values': [name_pattern]},
                {'Name': 'tag:creator', 'Values': ['build-team']}
            ],
            Owners=['self']
        )
        return response['Images']

    def get_instances_by_ami_id(self, ami_id):
        response = self.client.describe_instances(
            Filters=[{'Name': 'image-id', 'Values': [ami_id]}]
        )
        return response['Reservations']

    def get_secret(self, secret_name):
        client = self.session.client('secretsmanager')
        return client.get_secret_value(SecretId=secret_name)['SecretString']

    def wait_for_ami(self, ami_id):
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
        amis = self.search_ami_by_pattern(ami_name)
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
