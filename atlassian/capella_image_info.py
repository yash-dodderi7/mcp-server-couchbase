#!/usr/bin/env python3

'''
Simple script to publish latest Capella images information on Confluence
https://confluence.issues.couchbase.com/wiki/spaces/CR/pages/2405410007/Capella+Images+Information

The script pulls image information in the sandbox environment based on
product+version combination specified in product_versions.json
'''

import argparse
import collections
import json
import logging
import os
import re
import sys
import git
from airium import Airium
from atlassian import Confluence

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
ARCHITECTURES = ['amd64', 'x86_64', 'arm64']


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


def get_latest_image(image_names):
    '''
    Select the latest image
    Return a dictionary of latest images by architecture.

    '''
    latest_images = {}
    if not image_names:
        return latest_images

    images_with_arch = collections.defaultdict(list)
    images_without_arch = []

    for img in image_names:
        # Check if image name contains any architecture
        for arch in ARCHITECTURES:
            if f'-{arch}-' in img['Name']:
                images_with_arch[arch].append(img)
                break
        else:
            images_without_arch.append(img)

    if images_without_arch:
        latest_images['no_arch'] = images_without_arch[0]
    else:
        for arch in ARCHITECTURES:
            if images_with_arch[arch]:
                latest_images[arch] = images_with_arch[arch][0]

    return latest_images


def build_confluence_body(images):
    '''
    Construct a simple html page for confluence upload.
    '''
    a = Airium(source_minify=True)
    a('<p><ac:structured-macro ac:name="excerpt-include" ac:schema-version="1" ac:macro-id="68b1d163-a68f-4e63-aa86-936b6da49b73">')
    a('<ac:parameter ac:name=""><ac:link><ri:page ri:content-title="Capella Released Images"/></ac:link></ac:parameter>')
    a('<ac:parameter ac:name="name">references_to_capella_image_code</ac:parameter>')
    a('<ac:parameter ac:name="nopanel">true</ac:parameter></ac:structured-macro></p>')

    with a.h1():
        a('Images of Recent and Active Releases')
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
                        # Format latest images - dictionary of latest images by architecture
                        aws_latest = images[product][version]['aws']['latest']
                        aws_display = '<br/>'.join(sorted([img['Name'] for img in aws_latest.values()])) if aws_latest else ''
                        a.td(_t=aws_display)
                        azure_latest = images[product][version]['azure']['latest']
                        azure_display = '<br/>'.join(sorted([img['Name'] for img in azure_latest.values()])) if azure_latest else ''
                        a.td(_t=azure_display)
                        gcp_latest = images[product][version]['gcp']['latest']
                        gcp_display = '<br/>'.join(sorted([img['Name'] for img in gcp_latest.values()])) if gcp_latest else ''
                        a.td(_t=gcp_display)

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
    image_pattern = f'{product}-{version}*-v*'
    available_images = aws.search_ami_by_pattern(
        ami_filters={'name': image_pattern})
    if available_images:
        available_images.sort(key=lambda x: (x['Name']), reverse=True)
        for item in available_images:
            images['available'].append(item['Name'])
    images['latest'] = get_latest_image(available_images)
    return images


def get_gcp_images(gcp, product, version):
    '''
    Qeury GCP images based on product and version pattern.
    '''
    images = {}
    gcp_version = version.replace('.', '-')
    images['available'] = []
    image_pattern = f'{product}-{gcp_version}-*'
    available_images = gcp.search_image_by_pattern(
        image_filters={'name': image_pattern})
    # Convert to same format as AWS (dict with 'Name' key)
    available_images = [{'Name': img.name}
                        for img in available_images] if available_images else []
    if available_images:
        available_images.sort(key=lambda x: (x['Name']), reverse=True)
        for item in available_images:
            images['available'].append(item['Name'])
    images['latest'] = get_latest_image(available_images)
    return images


def get_azure_images(azure, product, version):
    '''
    Qeury Azure images based on product and version pattern.
    '''
    images = {}
    images['available'] = []
    image_pattern = f'^{product}-{version}-v(?!0.0.0)'
    all_images, image_versions = azure.get_images_by_resource_group(
        'image-factory')
    available_images = list(
        filter(
            lambda x: re.search(
                image_pattern,
                x.name),
            all_images))
    # Convert to same format as AWS (dict with 'Name' key)
    available_images = [{'Name': img.name} for img in available_images]
    if available_images:
        available_images.sort(key=lambda x: (x['Name']), reverse=True)
        for item in available_images:
            images['available'].append(item['Name'])
    images['latest'] = get_latest_image(available_images)
    return images


if __name__ == "__main__":
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

    BODY = build_confluence_body(product_images)
    confluence_session = confluence_session()
    confluence_session.update_page(
        CONFLUENCE_PAGE_ID,
        CONFLUENCE_PAGE_NAME,
        BODY,
        parent_id=None,
        type="page",
        representation="storage",
        minor_edit=False)
