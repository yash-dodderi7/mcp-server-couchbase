#!/usr/bin/env python3

import requests
import base64
import json
import sys
import logging

logging.basicConfig(format='%(asctime)s:%(levelname)s:%(message)s',
                    stream=sys.stderr, level=logging.INFO)


class CouchbaseCloudInternalApi:
    def __init__(self, username, password, env, internal_support_token):
        self.env = env
        self.internal_support_token = internal_support_token

        if env == 'dev':
            self.base_url = 'https://api.dev.nonprod-project-avengers.com'
        elif env == 'stage':
            self.base_url = 'https://api.stage.nonprod-project-avengers.com'
            return
        elif env == 'prod':
            self.base_url = 'https://api.cloud.couchbase.com'
            return
        else:
            logging.error(f'{env} is not a supported environment.')
            exit(1)

        url = f'{self.base_url}/sessions'
        auth_str = f'{username}:{password}'
        auth_b64 = base64.b64encode(auth_str.encode())
        headers = {
            'Authorization': 'Basic {}'.format(auth_b64.decode()),
            'Content-Type': 'application/json'
        }

        try:
            response = requests.post(
                url, headers=headers,
            )
        except requests.exceptions.RequestException as e:
            raise SystemExit(e)

        if 'jwt' in response.json().keys():
            self.jwt_token = response.json()['jwt']
        else:
            logging.error('Unable to obtain JWT session token.')
            exit(1)

    def default_images_info(self):
        if self.env == 'dev':
            headers = {
                'Authorization': f'Bearer {self.jwt_token}'
            }
        else:
            headers = {
                'Authorization': f'Bearer {self.internal_support_token}'
            }

        url = f'{self.base_url}//internal/support/serverless-dataplanes/current-release'

        try:
            response = requests.post(
                url, headers=headers,
            )

        except requests.exceptions.RequestException as e:
            raise SystemExit(e)
        images = response.json()
        return images
