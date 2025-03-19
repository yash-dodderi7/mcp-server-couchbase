#!/usr/bin/env python3

# This script is used by cb-robot in data center to manage images on Azure.
# It is unlikely an individual can run this script since she/he may not have
# proper permissions.

import argparse
import json
import logging
import re
import sys
from aws_utils import AWSUtils
from azure_utils import AzureUtils
import common_utils

logger = logging.getLogger()
if not logger.handlers:
    logger.setLevel(logging.INFO)
    console_handler = logging.StreamHandler(stream=sys.stdout)
    logger.addHandler(console_handler)

excluded_regions = {"eastus2euap", "indonesiacentral"}

def couchbase_azure_session(env):
    azure_vars = common_utils.get_env_vars('azure', env)
    aws_vars = common_utils.get_env_vars('aws', env)
    aws = AWSUtils(aws_vars['ROLE_SESSION_NAME'], 'us-east-1')
    client_secret = aws.get_secret(aws_vars['AZURE_CLIENT_SECRET_NAME'])
    if client_secret is None:
        sys.exit(f'Unable to obtain Azure CLIENT_SECRET for {env}')
    couchbaseazure = AzureUtils(
        azure_vars['CLIENT_ID'],
        client_secret,
        azure_vars['TENANT_ID'],
        azure_vars['SUBSCRIPTION_ID'])
    return couchbaseazure


def get_regions(env):
    couchbaseazure = couchbase_azure_session(env)
    regions = couchbaseazure.get_regions()
    # Exclude regions that Capella doesn't support
    # These regions might be available, but not configured to allow image replication.
    filtered_regions = [region for region in regions if region not in excluded_regions]
    logger.info(json.dumps(filtered_regions))


def get_image(env, image_name):
    couchbaseazure = couchbase_azure_session(env)
    resource_group_name = 'image-factory'
    result = couchbaseazure.get_image_by_name(resource_group_name, image_name)
    logger.info(f'{result}')
    return result


def delete_image(env, image_name):
    result=get_image(env, image_name)
    if result:
        couchbaseazure = couchbase_azure_session(env)
        resource_group_name = 'image-factory'
        image_gallery = 'capella'
        gallery_image_info = image_name.split('-v', 1)
        gallery_image_name = gallery_image_info[0]
        gallery_image_version = gallery_image_info[1]
        couchbaseazure.delete_image_by_name(resource_group_name, image_name)
        couchbaseazure.delete_image_version(
            resource_group_name, image_gallery, gallery_image_name, gallery_image_version)


def create_image_definition(env, image_definition_name):
    couchbaseazure = couchbase_azure_session(env)
    resource_group_name = 'image-factory'
    gallery_name = 'capella'
    result = couchbaseazure.get_image_definition(
        resource_group_name, gallery_name, image_definition_name)
    if result:
        logger.info(
            f'Image definition, {image_definition_name}, already exist.  It will not be created again.')
    else:
        logger.info(f'Creating image definition, {image_definition_name}.')
        offer = re.sub('-\\d+.\\d+.\\d+', '', image_definition_name)
        image_definition = {}
        image_definition['identifier'] = {}
        image_definition['architecture'] = 'x64'
        image_definition['hyper_v_generation'] = "V2"
        image_definition['location'] = 'eastus'
        image_definition['os_state'] = 'Generalized'
        image_definition['os_type'] = 'Linux'
        image_definition['identifier']['publisher'] = 'couchbase-capella'
        image_definition['identifier']['offer'] = offer
        image_definition['identifier']['sku'] = image_definition_name
        couchbaseazure.create_image_definition(
            resource_group_name,
            gallery_name,
            image_definition_name,
            image_definition)


def release_image(env, image_name):
    couchbaseazure = couchbase_azure_session(env)
    resource_group_name = 'image-factory'
    image_gallery = 'capella'
    gallery_image_info = image_name.split('-v', 1)
    gallery_image_name = gallery_image_info[0]
    gallery_image_version = gallery_image_info[1]
    couchbaseazure.release_image(resource_group_name, image_name)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        'Couchbase AZure Cloud', allow_abbrev=False)
    subparsers = parser.add_subparsers(help='sub-command help', dest='cmd')

    subparser_get_image = subparsers.add_parser(
        'get_image', help='Check if an image exist')
    subparser_get_image.add_argument(
        '--image_name', type=str, required=True, help='Azure image name')
    subparser_get_image.add_argument(
        '--env', type=str, required=True, help='Which environment does the image belongs to')
    subparser_delete_image = subparsers.add_parser(
        'delete_image', help='delete an image from an Azure account')
    subparser_delete_image.add_argument(
        '--image_name', type=str, required=True, help='Azure image name')
    subparser_delete_image.add_argument(
        '--env', type=str, required=True, help='Which environment will the image be deleted from')
    subparser_get_regions = subparsers.add_parser(
        'get_regions', help='Get available regions of an Azure account')
    subparser_get_regions.add_argument(
        '--env', type=str, required=True, help='sandbox, stage, or production')
    subparser_create_image_definition = subparsers.add_parser(
        'create_image_definition', help='Create image definition if it does not exist')
    subparser_create_image_definition.add_argument(
        '--env', type=str, required=True, help='Which environment to create image definition in')
    subparser_create_image_definition.add_argument(
        '--image_definition_name', type=str, required=True, help='The name of image definition')

    subparser_release_image = subparsers.add_parser(
        'release_image', help='Add released tag after an image is released to production')
    subparser_release_image.add_argument(
        '--image_name', type=str, required=True, help='Azure image name')
    subparser_release_image.add_argument(
        '--env', type=str, required=True, help='Sandbox or stage environment')

    if len(sys.argv) == 1:
        parser.print_help(sys.stderr)
        sys.exit(1)

    args = parser.parse_args()

    if args.cmd == 'get_image':
        get_image(args.env, args.image_name)

    if args.cmd == 'delete_image':
        delete_image(args.env, args.image_name)

    if args.cmd == 'get_regions':
        get_regions(args.env)

    if args.cmd == 'create_image_definition':
        create_image_definition(args.env, args.image_definition_name)

    if args.cmd == 'release_image':
        release_image(args.env, args.image_name)
