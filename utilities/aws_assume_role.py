#!/usr/bin/env python3

# Simple script to obtain config and credentials for desired couchbase cloud account.
##
# Couchbase cloud has an aws auth account(CBC-MAIN) purely for authentication purpose.
# Access to other environmental accounts are done by assuming role from the main auth account.
##
# Before running this script, do the following:
#   1.  update environments.json with proper aws account numbers.
#   2.  make sure auth config and credentials for cbc-main are set properly in ~/.aws
#       or in custom AWS_CONFIG_FILE and AWS_SHARED_CREDENTIALS_FILE.  The config and
#       credentials files should consist at least of the following:
#
#       .aws/config
#         [profile cbc-main]
#         region=us-east-1
#         output=json
##
#       .aws/credentials
#         [cbc-main]
#         aws_access_key_id     =
#         aws_secret_access_key =
##
# Usage:
# python3 aws_assume_role.py -p cbc-main -e sandbox -t <MFA_TOKEN>
##

import argparse
import boto3
import json
import logging
import os
from pathlib import Path
import re
import sys

# Make boto3 less verbose
logging.getLogger("boto3").setLevel(logging.WARN)
logging.getLogger("botocore").setLevel(logging.WARN)

logger = logging.getLogger()
logger.setLevel(logging.INFO)
console_handler = logging.StreamHandler(stream=sys.stdout)
logger.addHandler(console_handler)


class AWSAssumeRole:

    def __init__(self, cbc_profile, env, mfa_token=None):
        environments = json.loads(open('environments.json').read())
        session = boto3.session.Session(profile_name=cbc_profile)

        # https://docs.aws.amazon.com/STS/latest/APIReference/API_AssumeRole.html
        # Role chaining limits has a max of one hour.  Duration larger than 3600
        # sec will fail.

        client = session.client('sts')
        user = client.get_caller_identity()
        mfa_serial = re.sub('user', 'mfa', user['Arn'])
        if environments.get(env):
            account = environments[env]['aws']['ACCOUNT']
            self.role_arn = re.sub(
                '::\\d+:user',
                f'::{account}:role',
                user['Arn'])
            self.role_session_name = environments[env]['aws']['ROLE_SESSION_NAME']
        else:
            sys.exit(f'{env} is not defined in environments.json')

        # only robot accounts w/ EXTERNALID doesn't require mfa token.
        # build-team only has one robot account, cb-robot.
        if 'cb-robot' in self.role_arn:
            response = client.assume_role(
                RoleArn=self.role_arn,
                RoleSessionName=self.role_session_name,
                DurationSeconds=3600,
                ExternalId=environments[env]['aws']['EXTERNALID']
            )
        else:
            response = client.assume_role(
                RoleArn=self.role_arn,
                RoleSessionName=self.role_session_name,
                DurationSeconds=3600,
                SerialNumber=mfa_serial,
                TokenCode=mfa_token
            )
        self.credentials = response['Credentials']

    def write_config(self):
        home = str(Path.home())
        aws_config_file = os.environ.get(
            'AWS_CONFIG_FILE', os.path.join(
                home, '.aws/config'))
        aws_shared_credentials_file = os.environ.get(
            'AWS_SHARED_CREDENTIALS_FILE', os.path.join(
                home, '.aws/credentials'))

        with open(aws_config_file, 'r+') as file:
            for line in file:
                # Skip writing if it already exists.
                if self.role_session_name in line:
                    break
            else:  # not found at the eof
                file.write(
                    f'[profile {self.role_session_name}]\n')
                file.write('region=us-east-1\n')
                file.write('output=json\n')

        with open(aws_shared_credentials_file, 'r+') as file:
            if not any(self.role_session_name in line for line in file):
                file.write(f'[{self.role_session_name}]\n')
                file.write('aws_access_key_id     = %s\n' %
                           (self.credentials['AccessKeyId']))
                file.write('aws_secret_access_key = %s\n' %
                           (self.credentials['SecretAccessKey']))
                file.write('aws_session_token     = %s\n' %
                           (self.credentials['SessionToken']))
                logger.info(
                    f'{self.role_session_name} has been added '
                    f'to {aws_shared_credentials_file}'
                )
            else:
                logger.info(
                    f'{aws_shared_credentials_file} already '
                    f'contains {self.role_session_name}.  Remove '
                    f'{self.role_session_name} first if you wish '
                    f'to recreate it in {aws_shared_credentials_file} '
                )


if __name__ == "__main__":

    parser = argparse.ArgumentParser('AWS Assume Role')
    parser.add_argument(
        '-p',
        '--cbc_profile',
        type=str,
        default='cbc-main',
        help='CBC profile in .aws/config; i.e. cbc-main')
    parser.add_argument(
        '-t',
        '--mfa_token',
        type=str,
        required=True,
        help='MFA token for CBC profile')
    parser.add_argument(
        '-e',
        '--env',
        type=str,
        required=True,
        help='Environment to assume role to. Environments are defined in environments.json, i.e. sandbox, stage, and production')

    args = parser.parse_args()
    awsassumerole = AWSAssumeRole(args.cbc_profile, args.env, args.mfa_token)
    awsassumerole.write_config()
