#!/usr/bin/env python3

'''
Simple script to publish latest Capella images information on Confluence
https://hub.internal.couchbase.com/confluence/display/CR/Capella+Images+Information

The script pulls image information in the sandbox environment based on
product+version combination specified in product_versions.json
'''

import argparse
from atlassian import Confluence
import collections
import git
import json
import logging
import os
import re
import sys
from airium import Airium

git_repo = git.Repo(__file__, search_parent_directories=True)
git_root = git_repo.git.rev_parse('--show-toplevel')
sys.path.append(f'{git_root}/utilities')

from aws_utils import AWSUtils
from gcp_utils import GCPUtils
from azure_utils import AzureUtils
from common_utils import get_env_vars

logger = logging.getLogger()
logger.setLevel(logging.INFO)
console_handler = logging.StreamHandler(stream=sys.stdout)
logger.addHandler(console_handler)


CONFLUENCE_URL = 'https://couchbasecloud.atlassian.net'
CONFLUENCE_PAGE_ID = 2405410007
CONFLUENCE_PAGE_NAME = 'Capella Images Information'
CLOUDS = ['aws', 'azure', 'gcp']


def makedict():
    return collections.defaultdict(makedict)


def confluence_session():
    '''
    Initiate a confluence session.
    Cloud Jira and Confluence share the same set of users
    '''
    cloud_jira_creds_file = f'{os.environ["HOME"]}/.ssh/cloud-jira-creds.json'
    cloud_jira_creds = json.loads(open(cloud_jira_creds_file).read())
    session = Confluence(
        url=CONFLUENCE_URL,
        username=f"{cloud_jira_creds['username']}",
        password=f"{cloud_jira_creds['apitoken']}",
        cloud=True)
    return session

def build_confluence_body(images):
    '''
    Construct a simple html page for confluence upload.
    '''
    a = Airium(source_minify=True)
    with a.h1():
        a('Latest Images')
    for product in images:
        with a.h3():
            a(product)
        with a.table():
            with a.thead().tr():
                a.th(_t='Version')
                a.th(_t='AWS')
                a.th(_t='Azure')
                a.th(_t='GCP')
            with a.tbody():
                for version in images[product]:
                    with a.tr():
                        a.td(_t=f'{version}')
                        a.td(
                            _t=f"{images[product][version]['aws']['latest']}"
                            f"<br/>Agent: {images[product][version]['aws']['latest_sha']}")
                        a.td(
                            _t=f"{images[product][version]['azure']['latest']}"
                            f"<br/>Agent: {images[product][version]['aws']['latest_sha']}")
                        a.td(
                            _t=f"{images[product][version]['gcp']['latest']}"
                            f"<br/>Agent: {images[product][version]['aws']['latest_sha']}")

    with a.h1():
        a('Available Images')
    for product in images:
        with a.h3():
            a(product)
        with a.table():
            with a.thead().tr():
                a.th(_t='Version')
                a.th(_t='AWS')
                a.th(_t='Azure')
                a.th(_t='GCP')
            with a.tbody():
                for version in images[product]:
                    with a.tr():
                        a.td(_t=f'{version}')
                        a.td(
                            _t='<br/>'.join(images[product][version]['aws']['available']))
                        a.td(
                            _t='<br/>'.join(images[product][version]['azure']['available']))
                        a.td(
                            _t='<br/>'.join(images[product][version]['gcp']['available']))
    return str(a)


def get_aws_images(aws, product, version):
    '''
    Qeury AWS images based on product and version pattern.
    '''
    images = {}
    images['available'] = []
    images['latest_sha'] = ''
    image_pattern = f'{product}-{version}*-v*'
    available_images = aws.search_ami_by_pattern(image_pattern)
    if available_images:
        available_images.sort(key=lambda x: (x['Name']), reverse=True)
        for item in available_images:
            images['available'].append(item['Name'])
        images['latest'] = available_images[0]['Name']
        for tag in available_images[0]['Tags']:
            if tag['Key'] == 'agent':
                images['latest_sha'] = tag['Value']
    else:
        images['latest'] = ''
        images['latest_sha'] = ''
    return images


def get_gcp_images(gcp, product, version):
    '''
    Qeury GCP images based on product and version pattern.
    '''
    images = {}
    gcp_version = version.replace('.', '-')
    images = {}
    images['available'] = []
    images['latest_sha'] = ''
    image_pattern = f'{product}-{gcp_version}-*'
    available_images = list(gcp.search_image_by_pattern(image_pattern))
    if available_images:
        available_images.sort(key=lambda x: (x.name), reverse=True)
        for item in available_images:
            images['available'].append(item.name)
        images['latest'] = available_images[0].name
        if 'agent' in available_images[0].labels:
            images['latest_sha'] = available_images[0].labels['agent']
    else:
        images['latest'] = ''
        images['latest_sha'] = ''
    return images


def get_azure_images(azure, product, version):
    '''
    Qeury Azure images based on product and version pattern.
    '''
    images = {}
    images['available'] = []
    images['latest_sha'] = ''
    image_pattern = f'^{product}-{version}-v(?!0.0.0)'
    all_images = azure.get_images('image-factory')
    available_images = list(
        filter(
            lambda x: re.search(
                image_pattern,
                x.name),
            all_images))
    if available_images:
        available_images.sort(key=lambda x: (x.name), reverse=True)
        for item in available_images:
            images['available'].append(item.name)
        images['latest'] = available_images[0].name
        if 'agent' in available_images[0].tags:
            images['latest_sha'] = available_images[0].tags['agent']
    else:
        images['latest'] = ''
        images['latest_sha'] = ''
    return images


if __name__ == "__main__":
    parser = argparse.ArgumentParser('Capella Images')
    parser.add_argument(
        '--user',
        type=str,
        required=True,
        help='Confluence user name')
    parser.add_argument(
        '--pat',
        type=str,
        required=True,
        help='Confluence user PAT')
    args = parser.parse_args()

    script_dir = os.path.dirname(os.path.realpath(__file__))
    product_versions = json.loads(
        open(f'{script_dir}/product_versions.json').read())

    aws_session = AWSUtils()
    gcp_session = GCPUtils('sandbox')
    azure_vars = get_env_vars('azure', 'sandbox')
    gcp_vars = get_env_vars('gcp', 'sandbox')
    aws_vars = get_env_vars('aws', 'sandbox')
    azure_vars['CLIENT_SECRET'] = aws_session.get_secret(
        aws_vars['AZURE_CLIENT_SECRET_NAME'])
    azure_session = AzureUtils(
        azure_vars['CLIENT_ID'],
        azure_vars['CLIENT_SECRET'],
        azure_vars['TENANT_ID'],
        azure_vars['SUBSCRIPTION_ID'])
    product_images = makedict()

    for product, versions in product_versions.items():
        for version in versions:
            product_images[product][version]['aws'] = get_aws_images(
                aws_session, product, version)
            product_images[product][version]['azure'] = get_azure_images(
                azure_session, product, version)
            product_images[product][version]['gcp'] = get_gcp_images(
                gcp_session, product, version)

    body = build_confluence_body(product_images)
    confluence_session = confluence_session()
    confluence_session.update_page(
        CONFLUENCE_PAGE_ID,
        CONFLUENCE_PAGE_NAME,
        body,
        parent_id=None,
        type="page",
        representation="storage",
        minor_edit=False)
