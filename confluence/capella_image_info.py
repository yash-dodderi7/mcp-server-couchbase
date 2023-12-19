#!/usr/bin/env python3

# Simple script to publish latest Capella images information on Confluence
# https://hub.internal.couchbase.com/confluence/display/CR/Capella+Images+Information

import argparse
from atlassian import Confluence
import collections
import git
import logging
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


CONFLUENCE_URL = 'https://hub.internal.couchbase.com/confluence'
CONFLUENCE_PAGE_ID = 122421617
CONFLUENCE_PAGE_NAME = 'Capella Images Information'
IMAGE_TYPES = ['server', 'backup']
CLOUDS = ['aws', 'azure', 'gcp']


def confluence_session(url, uid, pat):
    session = Confluence(
        url=url,
        username=uid,
        password=pat)
    return session


def build_confluence_body(images):
    latest_table = []
    for version in images:
        row = [version]
        for cloud in CLOUDS:
            row.append(
                f"{images[version][cloud]['server']['latest']}<br/>"
                f"{images[version][cloud]['backup']['latest']}<br/>"
                f"Agent: {images[version][cloud]['server']['latest_sha']}")
        latest_table.append(row)

    a = Airium(source_minify=True)
    with a.h1():
        a('couchbase-server')
    with a.h3():
        a('Latest Images')
    with a.table():
        with a.thead().tr():
            a.th(_t='Version')
            a.th(_t='AWS')
            a.th(_t='Azure')
            a.th(_t='GCP')
        with a.tbody():
            for row in latest_table:
                with a.tr():
                    for item in row:
                        a.td(_t=f'{item}')
    with a.h3():
        a('Available Images')
    for version in images:
        with a.li():
            a(version)
        with a.table():
            with a.thead().tr():
                a.th(_t='')
                a.th(_t='AWS')
                a.th(_t='Azure')
                a.th(_t='GCP')
            with a.tbody():
                for type in IMAGE_TYPES:
                    with a.tr():
                        a.td(_t=f'couchbase-cloud-{type}')
                        a.td(
                            _t='<br/>'.join(images[version]['aws'][type]['available']))
                        a.td(
                            _t='<br/>'.join(images[version]['azure'][type]['available']))
                        a.td(
                            _t='<br/>'.join(images[version]['gcp'][type]['available']))

    return str(a)


def get_aws_images(aws, version):
    images = {}
    for type in IMAGE_TYPES:
        images[type] = {}
        images[type]['available'] = []
        images[type]['latest_sha'] = ''
        image_pattern = f'couchbase-cloud-{type}-{version}*'
        available_images = aws.search_ami_by_pattern(image_pattern)
        available_images.sort(key=lambda x: (x['Name']), reverse=True)
        for item in available_images:
            images[type]['available'].append(item['Name'])
        images[type]['latest'] = available_images[0]['Name']
        for tag in available_images[0]['Tags']:
            if tag['Key'] == 'agent':
                images[type]['latest_sha'] = tag['Value']
    return images


def get_gcp_images(gcp, version):
    images = {}
    gcp_version = version.replace('.', '-')
    for type in IMAGE_TYPES:
        images[type] = {}
        images[type]['available'] = []
        images[type]['latest_sha'] = ''
        image_pattern = f'couchbase-cloud-{type}-{gcp_version}*'
        available_images = list(gcp.search_image_by_pattern(image_pattern))
        available_images.sort(key=lambda x: (x.name), reverse=True)
        for item in available_images:
            images[type]['available'].append(item.name)
        images[type]['latest'] = available_images[0].name
        if 'agent' in available_images[0].labels:
            images[type]['latest_sha'] = available_images[0].labels['agent']
    return images


def get_azure_images(azure, version):
    images = {}
    for type in IMAGE_TYPES:
        images[type] = {}
        images[type]['available'] = []
        images[type]['latest_sha'] = ''
        image_pattern = f'^couchbase-cloud-{type}-{version}'
        all_images = azure.get_images('image-factory')
        available_images = list(
            filter(
                lambda x: re.search(
                    image_pattern,
                    x.name),
                all_images))
        available_images.sort(key=lambda x: (x.name), reverse=True)
        for item in available_images:
            images[type]['available'].append(item.name)
        images[type]['latest'] = available_images[0].name
        if 'agent' in available_images[0].tags:
            images[type]['latest_sha'] = available_images[0].tags['agent']
    return images


if __name__ == "__main__":
    parser = argparse.ArgumentParser('Capella Images')
    parser.add_argument(
        '--versions',
        type=str,
        help='Comma separated version list')
    parser.add_argument(
        '--user',
        type=str,
        help='Confluence user name')
    parser.add_argument(
        '--pat',
        type=str,
        help='Confluence user PAT')
    args = parser.parse_args()

    versions = list(args.versions.split(','))
    aws = AWSUtils()
    gcp = GCPUtils('sandbox')
    azure_vars = get_env_vars('azure', 'sandbox')
    gcp_vars = get_env_vars('gcp', 'sandbox')
    aws_vars = get_env_vars('aws', 'sandbox')
    azure_vars['CLIENT_SECRET'] = aws.get_secret(
        aws_vars['AZURE_CLIENT_SECRET_NAME'])
    azure = AzureUtils(
        azure_vars['CLIENT_ID'],
        azure_vars['CLIENT_SECRET'],
        azure_vars['TENANT_ID'],
        azure_vars['SUBSCRIPTION_ID'])
    images = collections.defaultdict(dict)

    for version in versions:
        images[version]['aws'] = get_aws_images(aws, version)
        images[version]['azure'] = get_azure_images(azure, version)
        images[version]['gcp'] = get_gcp_images(gcp, version)

    body = build_confluence_body(images)
    confluence_session = confluence_session(
        CONFLUENCE_URL,
        args.user,
        args.pat)
    confluence_session.update_page(
        CONFLUENCE_PAGE_ID,
        CONFLUENCE_PAGE_NAME,
        body,
        parent_id=None,
        type="page",
        representation="storage",
        minor_edit=False)
