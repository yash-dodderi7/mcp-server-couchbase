#!/usr/bin/env python3

import boto3
import botocore
import os
import json
import argparse
import sys
from datetime import datetime, timedelta
import time
from botocore.config import Config
import logging

logging.basicConfig(format='%(asctime)s:%(levelname)s:%(message)s', stream=sys.stderr, level=logging.INFO)

class CouchbaseCloud:
    def __init__(self,profile):
        config =json.loads(open('config.json').read())
        self.session = boto3.session.Session(profile_name=profile)
        self.s3=config['s3']
        self.roles=config['roles']

    #https://docs.aws.amazon.com/STS/latest/APIReference/API_AssumeRole.html
    #Role chaining limits has a max of one hour.  Duration larger than 3600 sec will fail.
    def assume_role (self, env):
        client = self.session.client('sts')
        result = client.assume_role(
            RoleArn=self.roles[env]['ROLE_ARN'],
            RoleSessionName=self.roles[env]['ROLE_SESSION_NAME'],
            DurationSeconds=3600,
            ExternalId=self.roles[env]['EXTERNALID']
        )
        credentials = result['Credentials']
        return credentials

    def write_configs (self, credentials):

        with open('.aws/config', 'r+') as file:
            for env in credentials:
                for line in file:
                    if self.roles[env]['ROLE_SESSION_NAME'] in line: # Skip writing if it already exists.
                        break
                else: # not found at the eof
                    file.write(f"[profile {self.roles[env]['ROLE_SESSION_NAME']}]\n")
                    file.write('region=us-east-1\n')
                    file.write('output=json\n')

        with open('.aws/credentials', 'r+') as file:
            for env in credentials:
                for line in file:
                    if self.roles[env]['ROLE_SESSION_NAME'] in line:  # Skip writing if it already exists.
                        break
                else: # not found at the eof
                    file.write(f"[{self.roles[env]['ROLE_SESSION_NAME']}]\n")
                    file.write('aws_access_key_id     = %s\n' %(credentials[env]['AccessKeyId']))
                    file.write('aws_secret_access_key = %s\n' %(credentials[env]['SecretAccessKey']))
                    file.write('aws_session_token     = %s\n' %(credentials[env]['SessionToken']))

    def download_agents (self):
        s3_session = boto3.Session(profile_name=self.s3['profile'])
        s3_resource = s3_session.resource('s3')
        for file in self.s3['files']:
            name=os.path.basename(self.s3['files'][file])
            path=self.s3['files'][file]
            try:
                s3_resource.Bucket(self.s3['bucket']).download_file(path, name)
            except botocore.exceptions.ClientError as e:
                if e.response['Error']['Code'] == '404':
                    logging.error(f'{path} does not exist.')
                else:
                    raise

    def get_ami_by_id (self, client, ami_id):
        response = client.describe_images(ImageIds = [ ami_id ])
        return response['Images']

    def search_ami_by_pattern (self, client, name_pattern):
        response = client.describe_images(
            Filters=[
                { 'Name': 'name', 'Values': [ name_pattern ] },
                { 'Name': 'tag:creator', 'Values': [ 'build-team' ] }
            ],
            Owners=['self']
        )
        return response['Images']

    def get_instances_by_ami_id (self, client, ami_id):
        response = client.describe_instances(
                Filters=[ { 'Name': 'image-id', 'Values': [ ami_id ] } ]
        )
        return response['Reservations']

    def wait_for_ami_to_be_available(self, client, ami_id):
        # It takes some time for newly created AMI to become available.
        attempts = 0
        max_attempts = 20
        ami = self.get_ami_by_id(client, ami_id)
        while ami[0]['State'] != 'available':
            attempts += 1
            time.sleep(30)
            if attempts <= max_attempts:
                ami = self.get_ami_by_id(client, ami_id)
                if ami[0]['State'] == 'failed':
                    sys.exit('AMI promotion(copy) failed.')
            else:
                sys.exit('AMI promotion(copy) might be stuck.')

    def tag_ami (self, profile, region, ami_name, tag_name, tag_value):
        session = boto3.Session(profile_name=profile)
        client = session.client('ec2', region_name=region)

        # Get AMI detail
        amis=self.search_ami_by_pattern(client, ami_name)
        if len(amis) == 1:
            ami=amis[0]
        else:
            sys.exit(f"{len(amis)} image(s) were found for {ami_name}.")

        client.create_tags(
            Resources=[ ami['ImageId'] ],
            Tags=[ { 'Key': tag_name, 'Value': tag_value }, ]
        )

    def remove_ami (self, profile, region, ami_name_pattern, age):
        session = boto3.Session(profile_name=profile)
        client = session.client('ec2', region_name=region)

        now = datetime.now()
        timelimit = now - timedelta(days=age)

        # Search AMIs
        images=self.search_ami_by_pattern(client, ami_name_pattern)
        images.sort(key = lambda ami: datetime.strptime(ami['CreationDate'], '%Y-%m-%dT%H:%M:%S.%f%z'), reverse=True)

        # Service tag is only created after QE validates an AMI.  Control plane uses the newest AMI with service tag.
        # We keep at least two just in case.
        # If service doesn't exist, QE either has not run the validation against it or the image failed the validation.
        # Hence, it is safe to remove these based on date
        validated_images=[]
        unvalidated_images=[]
        for image in images:
            if 'service' in [t['Key'] for t in image['Tags']]:
                validated_images.append(image)
            else:
                unvalidated_images.append(image)
   
        if len(validated_images) > 2:
            del validated_images[:2]

        validated_images = [ image for image in validated_images if datetime.strptime(image['CreationDate'],'%Y-%m-%dT%H:%M:%S.%f%z').replace(tzinfo=None) <= timelimit ]
        unvalidated_images = [ image for image in unvalidated_images if datetime.strptime(image['CreationDate'],'%Y-%m-%dT%H:%M:%S.%f%z').replace(tzinfo=None) <= timelimit ]

        for image in unvalidated_images:
            logging.info(f"Removing {image['Name']} {image['ImageId']} {image['CreationDate']}.")
            client.deregister_image(ImageId=image['ImageId'])
            for device in image['BlockDeviceMappings']:
                if 'Ebs' in device:
                    snapshot_id = device['Ebs']['SnapshotId']
                    logging.info(f"Removing {snapshot_id} of {image['ImageId']}.")
                    client.delete_snapshot(SnapshotId=snapshot_id)

        # Don't remove a service AMI if it is being used. 
        for image in validated_images:
            found_instance = False
            reservations=self.get_instances_by_ami_id(client, image['ImageId'])
            for reservation in reservations:
                if len(reservation['Instances']) > 0:
                    logging.info(f"{image['Name']} ({image['ImageId']}) is still being used.  Don't remove it.")
                    found_instance = True
                    break
            if not found_instance:
                logging.info(f"Removing {image['Name']} {image['ImageId']} {image['CreationDate']}.")
                client.deregister_image(ImageId=image['ImageId'])
                for device in image['BlockDeviceMappings']:
                    if 'Ebs' in device:
                        snapshot_id = device['Ebs']['SnapshotId']
                        logging.info(f"Removing {snapshot_id} of {image['ImageId']}.")
                        client.delete_snapshot(SnapshotId=snapshot_id)

    def copy_ami (self, source_profile, source_region, dest_profile, dest_region, ami_name):
        # retries are mainly useful for waiting for AMI to become available
        config = Config(
            retries = {
            'max_attempts': 10,
            'mode': 'standard'
            }
        )
        source_session = boto3.Session(profile_name=source_profile)
        source_client = source_session.client('ec2', region_name=source_region)
        dest_session = boto3.Session(profile_name=dest_profile)
        dest_client = dest_session.client('ec2', region_name=dest_region, config=config)

        dest_sts = dest_session.client('sts')
        dest_account_id = dest_sts.get_caller_identity()['Account']

        # Check if AMI already exist on destination
        dest_amis=self.search_ami_by_pattern(dest_client, ami_name)
        if len(dest_amis) != 0:
            logging.info(f"{ami_name} is already on {dest_profile}.  It will not be copied.")
            exit(0)

        # Get AMI detail
        source_amis=self.search_ami_by_pattern(source_client, ami_name)
        if len(source_amis) == 1:
            source_image=source_amis[0]
        else:
            sys.exit(f"{len(source_amis)} is found on {source_profile}")

        # Share the image with the destination account
        source_client.modify_image_attribute(
            ImageId = source_image['ImageId'],
            Attribute = 'launchPermission',
            OperationType = 'add',
            LaunchPermission = {
                'Add' : [{ 'UserId': dest_account_id }]
            }
        )
        # Snapshots associated with the AMI need to be shared as well
        devices = source_image['BlockDeviceMappings']
        for device in devices:
            if 'Ebs' in device:
                snapshot_id = device['Ebs']['SnapshotId']
                source_client.modify_snapshot_attribute(
                    SnapshotId = snapshot_id,
                    Attribute = 'createVolumePermission',
                    CreateVolumePermission = {
                        'Add' : [{ 'UserId': dest_account_id }]
                    },
                    OperationType = 'add',
                )
        # Copy AMI to destiation account
        logging.info(f"Copying {source_image['Name']} from {source_profile} to {dest_profile}.")
        description = f"Copy from {source_image['ImageId']} from {source_profile}"
        dest_image = dest_client.copy_image(
            Name = source_image['Name'],
            Description= description,
            SourceImageId = source_image['ImageId'],
            SourceRegion = dest_region
        )
        # Make sure AMI is ready before moving on to the next step.
        self.wait_for_ami_to_be_available(dest_client, dest_image['ImageId'])

        # Recreate tags since copy_image doesn't copy them
        for tag in source_image['Tags']:
            dest_client.create_tags(
                Resources = [ dest_image['ImageId'] ],
                Tags = [ { 'Key': tag['Key'], 'Value': tag['Value']} ]
            )

        # Unshare the image in source account
        source_client.modify_image_attribute(
            ImageId = source_image['ImageId'],
            Attribute = 'launchPermission',
            OperationType = 'remove',
            LaunchPermission = {
                'Remove' : [{ 'UserId': dest_account_id }]
            }
        )

        # Unshare snapshots associated with the AMI
        devices = source_image['BlockDeviceMappings']
        for device in devices:
            if 'Ebs' in device:
                snapshot_id = device['Ebs']['SnapshotId']
                source_client.modify_snapshot_attribute(
                    SnapshotId = snapshot_id,
                    Attribute = 'createVolumePermission',
                    CreateVolumePermission = {
                        'Remove' : [{ 'UserId': dest_account_id }]
                    },
                    OperationType = 'remove',
                )

if __name__ == "__main__":
    couchbasecloud=CouchbaseCloud('CBROBOT')
    credentials=dict()
    for env in couchbasecloud.roles.keys():
        credentials[env]=couchbasecloud.assume_role(env)
    couchbasecloud.write_configs(credentials)

    parser = argparse.ArgumentParser('AWS Cloud Utilities', allow_abbrev=False)
    parser.add_argument('--download_agents', action='store_true', help='Download DP Agents.')
    parser.add_argument('--write_configs', action='store_true', help='Generate .aws configs.')
    subparsers = parser.add_subparsers(help='sub-command help', dest='cmd')

    subparser_tag_ami = subparsers.add_parser('tag_ami', help='Add tag to an AMI.')
    subparser_tag_ami.add_argument('--ami_name', type=str, required=True, help='AMI name.')
    subparser_tag_ami.add_argument('--tag_name', type=str, required=True, help='Tag name to be added.')
    subparser_tag_ami.add_argument('--tag_value', type=str, required=True, help='Tag value to be added.')
    subparser_tag_ami.add_argument('--profile', type=str, required=True, help='AWS profile for the account where AMI belongs to.')
    subparser_tag_ami.add_argument('--region', type=str, default='us-east-1', nargs='?', help='AWS region where AMI is located.')

    subparser_copy_ami = subparsers.add_parser('copy_ami', help='Promote(Copy) an AMI to another aws account.')
    subparser_copy_ami.add_argument('--ami_name', type=str, required=True, help='AMI name.')
    subparser_copy_ami.add_argument('--source_profile', type=str, required=True, help='AWS account profile where AMI is copied from.')
    subparser_copy_ami.add_argument('--source_region', type=str, default='us-east-1', nargs='?', help='AWS account region where AMI is copied from.')
    subparser_copy_ami.add_argument('--dest_profile', type=str, required=True, help='AWS account profile where AMI is copied to.')
    subparser_copy_ami.add_argument('--dest_region', type=str, default='us-east-1', nargs='?', help='AWS account region where AMI is copied to.')

    subparser_remove_ami = subparsers.add_parser('remove_ami', help='Delete older AMIs by age, keep minimum of last two.')
    subparser_remove_ami.add_argument('--profile', type=str, required=True, help='AWS account profile.')
    subparser_remove_ami.add_argument('--region', type=str, default='us-east-1', nargs='?', help='AWS account region.')
    subparser_remove_ami.add_argument('--product_name_pattern', type=str, required=True, help='i.e. couchbase_serverless-*7.2.0*, couchbase_cloud-*7.2.0*, direct-nebula-*0.1.*, couchbase-data-api-*0.1*')
    subparser_remove_ami.add_argument('--age', type=int, default=7, nargs='?', help='Days to keep.')

    args = parser.parse_args()

    if args.cmd == 'tag_ami':
        couchbasecloud.tag_ami(args.profile, args.region, args.ami_name, args.tag_name, args.tag_value)
    if args.cmd == 'copy_ami':
        couchbasecloud.copy_ami(args.source_profile, args.source_region, args.dest_profile, args.dest_region, args.ami_name)
    if args.cmd == 'remove_ami':
        couchbasecloud.remove_ami(args.profile, args.region, args.product_name_pattern, args.age)

    if args.download_agents:
        couchbasecloud.download_agents()
