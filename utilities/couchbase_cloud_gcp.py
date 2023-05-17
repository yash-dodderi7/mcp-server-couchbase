#!/usr/bin/env python3
## Couchbase's Google Cloud Platform(GCP) is accessible via Workload Identity Federation(WIF)
## through AWS.  https://cloud.google.com/iam/docs/configuring-workload-identity-federation
## In order to access GCP, the following steps are taken:
## 1. Obtain GCP encoded GetCallerIdentity token from AWS
## 2. Use the Security Token Service(STS) API to exchange the credential against a short-lived token
## 3. Generate an access_token/impersonated access_token from GCP IAM for a service account


import json
import urllib
import requests
import boto3
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest
import logging
import sys
import argparse
import shutil
import os
import google.oauth2.credentials
from googleapiclient import discovery
from pprint import pprint

logging.basicConfig(format='%(asctime)s:%(levelname)s:%(message)s',
                    stream=sys.stderr, level=logging.INFO)

class CouchbaseCloudGCP:

    def __init__(self, env):
        print(f'env is {env}')
        environments = json.loads(open('environments.json').read())
        gcp_config = environments[env]['gcp']
        self.rc_project_id = gcp_config['RC_PROJECT_ID']
        self.rc_project_number = gcp_config['RC_PROJECT_NUMBER']
        self.pool_id = gcp_config['POOL_ID']
        self.provider_id = gcp_config['PROVIDER_ID']
        self.idp_user = gcp_config['IDP_USER']
        self.impersonated_user = gcp_config['IMPERSONATED_USER']

    def create_token_aws(self):
        gcp_wip_provider = f'//iam.googleapis.com/projects/{self.rc_project_number}/locations/global/workloadIdentityPools/{self.pool_id}/providers/{self.provider_id}'

        headers = {
            'Host': 'sts.amazonaws.com',
            'x-goog-cloud-target-resource': gcp_wip_provider
        }
        url = 'https://sts.amazonaws.com/?Action=GetCallerIdentity&Version=2011-06-15'
        request = AWSRequest(
            method='POST',
            url=url,
            headers=headers
        )

        # Sign the request.
        # Signed token lets workload identity federation verify the identity without revealing the AWS secret access key.

        session = boto3.Session()
        credentials = session.get_credentials()
        SigV4Auth(credentials, 'sts', 'us-east-1').add_auth(request)

        # Create token from signed request.
        # headers need to be transformed into key value format
        result = {
            'url': request.url,
            'method': request.method,
            'headers': []
        }

        # headers need to be in the form of {"key": "", "value": ""} pairs
        for key, value in request.headers.items():
            result['headers'].append({'key': key, 'value': value})
        result = urllib.parse.quote(json.dumps(result))

        return result


    # Request and retrieve an sts token from google.
    def generate_sts_token(self, token):
        audience = f'//iam.googleapis.com/projects/{self.rc_project_number}/locations/global/workloadIdentityPools/{self.pool_id}/providers/{self.provider_id}'

        data = {
            'audience'           : audience,
            'grantType'          : 'urn:ietf:params:oauth:grant-type:token-exchange',
            'requestedTokenType' : 'urn:ietf:params:oauth:token-type:access_token',
            'scope'              : 'https://www.googleapis.com/auth/cloud-platform',
            'subjectTokenType'   : 'urn:ietf:params:aws:token-type:aws4_request',
            'subjectToken'       : token
        }

        headers = {
            'Content-Type': 'application/json'
        }

        try:
            request = requests.post('https://sts.googleapis.com/v1/token',
                headers=headers, data=json.dumps(data))
            request.raise_for_status()
        except requests.exceptions.HTTPError as err:
            raise SystemExit(err)

        result = request.json()

        if 'access_token' not in result:
            logging.error(f'Key, expires_in and/or access_token, does not exist.  The returned json is invalid.\n\n{result}')
            sys.exit()

        return result['access_token']

    # Uses the sts token from google sts to request an access token from GCP IAM using a service account
    def generate_access_token(self, token, account):
        data = {
            'scope': [ 'https://www.googleapis.com/auth/cloud-platform' ]
        }

        headers = {
            'Content-Type': 'text/json; charset=utf-8',
            'Authorization': 'Bearer {}'.format(token)
        }

        url = f'https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/{account}:generateAccessToken'

        try:
            request = requests.post(url, headers=headers, data=json.dumps(data))
            request.raise_for_status()
        except requests.exceptions.HTTPError as err:
            raise SystemExit(err)

        result = request.json()
        if 'accessToken' not in result:
            logging.error(f'Key, accessToken, does not exist.  The returned json is invalid.\n\n{result}')
            sys.exit()

        return result['accessToken']

if __name__ == '__main__':
    parser = argparse.ArgumentParser('GCP Utilities')
    parser.add_argument('-e', '--environment', required=True,
                    help='environment, i.e. test, dev, prod')
    args = parser.parse_args()

    env=args.environment
    couchbasecloudgcp = CouchbaseCloudGCP(env)
    signed_aws_token = couchbasecloudgcp.create_token_aws()
    sts_token = couchbasecloudgcp.generate_sts_token(signed_aws_token)

    # use the sts token to generate an access token.
    access_token = couchbasecloudgcp.generate_access_token(sts_token, couchbasecloudgcp.idp_user)
    access_token_impersonated = couchbasecloudgcp.generate_access_token(access_token, couchbasecloudgcp.impersonated_user)
    shutil.rmtree('.gcp', ignore_errors=True)
    os.mkdir('.gcp')
    with open(f'.gcp/{env}', 'w') as file:
        file.write(access_token_impersonated)
