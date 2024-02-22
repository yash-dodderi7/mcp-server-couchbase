#!/usr/bin/env python3

# This script is used by cb-robot in data center to manage images on Azure.
# It is unlikely an individual can run this script since she/he may not have
# proper permissions.

import argparse
import logging
import sys
from aws_utils import AWSUtils
from azure_utils import AzureUtils
import common_utils

logger = logging.getLogger()
if not logger.handlers:
    logger.setLevel(logging.INFO)
    console_handler = logging.StreamHandler(stream=sys.stdout)
    logger.addHandler(console_handler)


def delete_image(env_name, image_name):
    azure_vars = common_utils.get_env_vars(
        'azure',
        env_name)
    aws_vars = common_utils.get_env_vars(
        'aws',
        env_name)
    aws = AWSUtils(aws_vars['ROLE_SESSION_NAME'], 'us-east-1')
    client_secret = aws.get_secret(aws_vars['AZURE_CLIENT_SECRET_NAME'])
    if client_secret is None:
        sys.exit(f'Unable to obtain CLIENT_SECRET to delete images')
    couchbaseazure = AzureUtils(
        azure_vars['CLIENT_ID'],
        client_secret,
        azure_vars['TENANT_ID'],
        azure_vars['SUBSCRIPTION_ID'])
    resource_group = 'image-factory'
    image_gallery = 'capella'
    gallery_image_info = image_name.split('-v', 1)
    gallery_image_name = gallery_image_info[0]
    gallery_image_version = gallery_image_info[1]
    response = couchbaseazure.get_image_by_name(resource_group, image_name)
    if True:
        couchbaseazure.delete_image_by_name(resource_group, image_name)
        couchbaseazure.delete_image_version(
            resource_group, image_gallery, gallery_image_name, gallery_image_version)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        'Couchbase AZure Cloud', allow_abbrev=False)
    subparsers = parser.add_subparsers(help='sub-command help', dest='cmd')

    subparser_delete_image = subparsers.add_parser(
        'delete_image', help='delete an image from an Azure account')
    subparser_delete_image.add_argument(
        '--image_name', type=str, required=True, help='Azure image name')
    subparser_delete_image.add_argument(
        '--env', type=str, required=True, help='Which environment will the image be deleted from')

    args = parser.parse_args()

    if args.cmd == 'delete_image':
        delete_image(args.env, args.image_name)
