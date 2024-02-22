#!/usr/bin/env python3
## Couchbase's Google Cloud Platform(GCP) is accessible via Workload Identity Federation(WIF)
## through AWS.  https://cloud.google.com/iam/docs/configuring-workload-identity-federation
## In order to access GCP, the following steps are taken:
## 1. Obtain GCP encoded GetCallerIdentity token from AWS
## 2. Use the Security Token Service(STS) API to exchange the credential against a short-lived token
## 3. Generate an access_token/impersonated access_token from GCP IAM for a service account


import argparse
import logging
from gcp_utils import GCPUtils
import common_utils

logger = logging.getLogger()
if not logger.handlers:
    logger.setLevel(logging.INFO)
    console_handler = logging.StreamHandler(stream=sys.stdout)
    logger.addHandler(console_handler)

def get_access_token(env):
    gcp = GCPUtils(env)
    logger.info(gcp.access_token_impersonated)

def delete_image(env, image_name_pattern):
    couchbasegcp=GCPUtils(env)
    images = couchbasegcp.search_image_by_pattern(image_name_pattern)
    if images is None:
        logger.info(f"{image_name_pattern} does not exist.  It will not be deleted.")
    else:
        for image in images:
            couchbasegcp.delete_image_by_name(image)
if __name__ == '__main__':
    parser = argparse.ArgumentParser('Couchbase GCP Cloud', allow_abbrev=False)
    subparsers = parser.add_subparsers(help='sub-command help', dest='cmd')
    subparser_get_access_token = subparsers.add_parser(
        'get_access_token', help='Get authentication token')
    subparser_get_access_token.add_argument(
        '--env',
        type=str,
        required=True,
        help='Obtain token from which environment')
    subparser_delete_image = subparsers.add_parser(
        'delete_image', help='delete an image from an Azure account')
    subparser_delete_image.add_argument(
        '--image_name', type=str, required=True, help='Image name')
    subparser_delete_image.add_argument(
        '--env', type=str, required=True, help='Which environment will the image be deleted from')

    args = parser.parse_args()

    if args.cmd == 'get_access_token':
        get_access_token(args.env)

    if args.cmd == 'delete_image':
        delete_image(args.env, args.image_name)
