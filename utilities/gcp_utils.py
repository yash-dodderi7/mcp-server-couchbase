#!/usr/bin/env python3

'''
GCP helper functions
'''

import boto3
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest
import google.oauth2.credentials
from google.cloud import compute_v1
import json
import logging
import os
import requests
import sys
import urllib
import common_utils

logger = logging.getLogger("googleapiclient")
logger.setLevel(logging.WARNING)

# Make boto3 less verbose
logging.getLogger("boto3").setLevel(logging.WARN)
logging.getLogger("botocore").setLevel(logging.WARN)


class GCPUtils:

    def __init__(self, env):
        '''
        In Capella, GCP is authenticated via AWS Workload Identity
        Federation(WIF). In order to access GCP, the following steps
        are taken:
        1. Obtain GCP encoded GetCallerIdentity token from AWS
        2. Use the Security Token Service(STS) API to exchange the
           credential against a short-lived token
        3. Generate an access_token/impersonated access_token from
           GCP IAM for a service account
        https://cloud.google.com/iam/docs/configuring-workload-identity-federation
        '''

        vars = common_utils.get_env_vars('gcp', env)
        self.image_factory_project_id = vars['IMAGE_FACTORY_PROJECT_ID']
        self.rc_project_number = vars['RC_PROJECT_NUMBER']
        self.pool_id = vars['POOL_ID']
        self.provider_id = vars['PROVIDER_ID']
        self.idp_user = vars['IDP_USER']
        self.impersonated_user = vars['IMPERSONATED_USER']

        signed_aws_token = self.create_aws_token()
        sts_token = self.generate_sts_token(signed_aws_token)
        access_token = self.generate_access_token(sts_token, self.idp_user)
        self.access_token_impersonated = self.generate_access_token(
            access_token, self.impersonated_user)
        self.credentials = google.oauth2.credentials.Credentials(
            self.access_token_impersonated)
        os.makedirs('.gcp', exist_ok=True)
        with open(f'.gcp/{env}', 'w') as file:
            file.write(self.access_token_impersonated)

    def create_aws_token(self):
        gcp_wip_provider = (
            f'//iam.googleapis.com/projects/{self.rc_project_number}/locations'
            f'/global/workloadIdentityPools/{self.pool_id}/providers'
            f'/{self.provider_id}'
        )

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
        # Signed token lets workload identity federation verify the identity
        # without revealing the AWS secret access key.
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

    def generate_sts_token(self, token):
        '''
        Request and retrieve an sts token from google.
        '''
        audience = (
            f'//iam.googleapis.com/projects/{self.rc_project_number}'
            f'/locations/global/workloadIdentityPools/{self.pool_id}'
            f'/providers/{self.provider_id}'
        )
        data = {
            'audience': audience,
            'grantType': 'urn:ietf:params:oauth:grant-type:token-exchange',
            'requestedTokenType': 'urn:ietf:params:oauth:token-type:access_token',
            'scope': 'https://www.googleapis.com/auth/cloud-platform',
            'subjectTokenType': 'urn:ietf:params:aws:token-type:aws4_request',
            'subjectToken': token}
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
            logging.error(
                f'Key, expires_in and/or access_token, does not exist.'
                f'The returned json is invalid.\n\n{result}'
            )
            sys.exit()
        return result['access_token']

    # Uses the sts token from google sts to request an access token from GCP
    # IAM using a service account
    def generate_access_token(self, token, account):
        data = {
            'scope': ['https://www.googleapis.com/auth/cloud-platform']
        }
        headers = {
            'Content-Type': 'text/json; charset=utf-8',
            'Authorization': 'Bearer {}'.format(token)
        }
        url = (
            f'https://iamcredentials.googleapis.com/v1/projects/'
            f'-/serviceAccounts/{account}:generateAccessToken'
        )
        try:
            request = requests.post(
                url, headers=headers, data=json.dumps(data))
            request.raise_for_status()
        except requests.exceptions.HTTPError as err:
            raise SystemExit(err)
        result = request.json()
        if 'accessToken' not in result:
            logging.error(
                f'Key, accessToken, does not exist.'
                f'The returned json is invalid.\n\n{result}'
            )
            sys.exit()
        return result['accessToken']

    def get_image_by_name(self, image_name):
        client = compute_v1.ImagesClient(credentials=self.credentials)

        request = compute_v1.GetImageRequest(
            image=image_name,
            project=self.image_factory_project_id,
        )
        try:
            response = client.get(request=request)
            return response
        except Exception as e:
            if e.code == 404:
                logger.warning(e.errors)
            else:
                sys.exit(e.errors)

    def delete_image_by_name(self, image_name):
        client = compute_v1.ImagesClient(credentials=self.credentials)
        request = compute_v1.DeleteImageRequest(
            image=image_name,
            project=self.image_factory_project_id,
        )
        client.delete(request=request)

    def search_image_by_pattern(self, image_name_pattern):
        client = compute_v1.ImagesClient(credentials=self.credentials)

        images_list_request = compute_v1.ListImagesRequest(
            project=self.image_factory_project_id,
            filter=f"name:{image_name_pattern}"
        )
        return client.list(request=images_list_request)
