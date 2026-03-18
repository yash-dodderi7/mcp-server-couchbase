#!/usr/bin/env python3

"""
Check image availability in a single cloud provider.

Inputs:
- cloud_provider: aws | gcp | azure
- environment: sandbox | stage | production
- image names: space separated names
"""


import argparse
import os
import sys
from typing import Any, Dict, List, Tuple

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
UTILITIES_DIR = os.path.join(os.path.dirname(SCRIPT_DIR), 'utilities')
if UTILITIES_DIR not in sys.path:
    sys.path.insert(0, UTILITIES_DIR)

from aws_utils import AWSUtils
from azure_utils import AzureUtils
from common_utils import get_env_vars, concurrent_executor
from couchbase_cloud_azure import excluded_regions
from gcp_utils import GCPUtils

AZURE_RESOURCE_GROUP = 'image-factory'
AZURE_GALLERY_NAME = 'capella'
MAX_WORKERS = 8


def parse_args() -> argparse.Namespace:
    """Arguments parser"""
    parser = argparse.ArgumentParser(
        description='Check images availability in a cloud provider'
    )
    parser.add_argument(
        '--cloud-provider',
        required=True,
        choices=['aws', 'gcp', 'azure'],
        help='Cloud provider to check'
    )
    parser.add_argument(
        '--image-names',
        required=True,
        nargs='+',
        help='List of image names to verify'
    )
    parser.add_argument(
        '--environment',
        required=True,
        choices=['sandbox', 'stage', 'production'],
        help='Environment to check images in'
    )
    parser.add_argument(
        '--debug',
        action='store_true',
        help='Enable debug output'
    )
    return parser.parse_args()


def init_cloud_clients(environment: str, provider: str) -> Dict[str, Any]:
    """Initialize cloud clients for the specified provider."""
    aws_vars = get_env_vars('aws', environment)
    aws_client = AWSUtils(aws_vars['ROLE_SESSION_NAME'], 'us-east-1')

    clients = {
        'aws_client': aws_client,
        'aws_vars': aws_vars,
        'gcp_client': None,
        'azure_client': None,
    }

    if provider == 'gcp':
        clients['gcp_client'] = GCPUtils(environment)
    elif provider == 'azure':
        azure_vars = get_env_vars('azure', environment)
        azure_client_secret = aws_client.get_secret(
            aws_vars['AZURE_CLIENT_SECRET_NAME'])
        if azure_client_secret is None:
            print('Unable to obtain Azure CLIENT_SECRET', file=sys.stderr)
            sys.exit(1)
        clients['azure_client'] = AzureUtils(
            azure_vars['CLIENT_ID'],
            azure_client_secret,
            azure_vars['TENANT_ID'],
            azure_vars['SUBSCRIPTION_ID']
        )

    return clients


def check_aws_images_by_region(
    item: Tuple[str, str, List[str]]) -> Tuple[str, set]:
    """Return image names found in a single AWS region."""
    profile_name, region, image_names = item
    aws_client = AWSUtils(profile_name, region)
    images = aws_client.search_ami_by_pattern({'name': image_names})
    image_name_set = set(image_names)
    found_names = {
        image.get('Name')
        for image in images
        if image.get('Name') in image_name_set
    }
    return region, found_names


def check_aws_images(
    cloud_clients: Dict[str, Any],
    image_names: List[str]
) -> Dict[str, Dict[str, List[str]]]:
    """Check AWS AMI availability for each requested image across all regions."""
    aws_client = cloud_clients['aws_client']
    aws_profile_name = cloud_clients['aws_vars']['ROLE_SESSION_NAME']
    regions = aws_client.get_regions()

    result = {name: [] for name in image_names}

    work_items = [(aws_profile_name, region, image_names)
                  for region in regions]
    region_results = concurrent_executor(
        check_aws_images_by_region, work_items, workers=MAX_WORKERS)
    for region, found_names in region_results:
        for image_name in found_names:
            result[image_name].append(region)

    all_region_set = set(regions)
    return {
        name: {
            'found_regions': sorted(found_regions),
            'not_found_regions': sorted(all_region_set - set(found_regions)),
        }
        for name, found_regions in result.items()
    }


def check_gcp_image(item: Tuple[Any, str]) -> Tuple[str, List[str]]:
    """Return GCP image availability for one image name."""
    gcp_client, image_name = item
    image = gcp_client.get_image_by_name(image_name)
    return image_name, ['global'] if image is not None else []


def check_gcp_images(
    cloud_clients: Dict[str, Any],
    image_names: List[str]
) -> Dict[str, Dict[str, List[str]]]:
    """Check GCP image availability for each requested image."""
    gcp_client = cloud_clients['gcp_client']
    workers = min(MAX_WORKERS, max(1, len(image_names)))
    work_items = [(gcp_client, image_name) for image_name in image_names]
    image_results = concurrent_executor(
        check_gcp_image, work_items, workers=workers)
    return {
        name: {
            'found_regions': regions,
            'not_found_regions': [] if regions else ['global'],
        }
        for name, regions in image_results
    }


def check_azure_image_replication(
    item: Tuple[str, Any, set]
) -> Tuple[str, Dict[str, List[str]]]:
    """Check Azure image presence and replication coverage for one image."""
    image_name, azure_client, all_region_set = item

    split_result = image_name.rsplit('-v', 1)
    if len(split_result) != 2 or not split_result[0] or not split_result[1]:
        return image_name, {
            'found_regions': [],
            'not_found_regions': ['replication-check-unavailable'],
        }

    image_definition_name, image_version_name = split_result

    image_version = azure_client.get_image_version(
        AZURE_RESOURCE_GROUP,
        AZURE_GALLERY_NAME,
        image_definition_name,
        image_version_name,
    )
    target_regions = [
        target_region.name.lower().replace(' ', '')
        for target_region in (image_version.publishing_profile.target_regions or [])
        if getattr(target_region, 'name', None)
    ]
    found_regions = sorted(set(target_regions))
    not_found_regions = sorted(all_region_set - set(found_regions))
    return image_name, {
        'found_regions': found_regions,
        'not_found_regions': not_found_regions,
    }


def check_azure_images(
    cloud_clients: Dict[str, Any],
    image_names: List[str]
) -> Dict[str, Dict[str, List[str]]]:
    """Check Azure image availability and replication for each requested image."""
    azure_client = cloud_clients['azure_client']

    all_region_set = {
        region.lower()
        for region in azure_client.get_regions()
        if region.lower() not in excluded_regions
    }
    work_items = [
        (image_name, azure_client, all_region_set)
        for image_name in image_names
    ]
    image_results = concurrent_executor(
        check_azure_image_replication, work_items, workers=MAX_WORKERS)
    return dict(image_results)


def print_summary_report(
    provider: str,
    summary: Dict[str, Dict[str, List[str]]],
    debug: bool
) -> None:
    """Print a summary table for all checked images."""
    print('\nSUMMARY REPORT')
    print(f'Provider: {provider.upper()}')
    for image_name, data in summary.items():
        found_regions = data['found_regions']
        not_found_regions = data['not_found_regions']
        if found_regions and not not_found_regions:
            status = 'FOUND'
        elif found_regions:
            status = 'PARTIAL'
        else:
            status = 'NOT FOUND'
        missing_text = ', '.join(
            not_found_regions) if not_found_regions else '-'
        if debug:
            found_text = ', '.join(found_regions) if found_regions else '-'
            print(
                f'- {image_name}: status={status}; '
                f'found_regions=[{found_text}]; '
                f'not_found_regions=[{missing_text}]'
            )
        else:
            print(
                f'- {image_name}: status={status}; '
                f'not_found_regions=[{missing_text}]'
            )


def add_summary_entry(
    summary: Dict[str, Dict[str, List[str]]],
    image_name: str,
    found_regions: List[str],
    not_found_regions: List[str]
) -> bool:
    """Store normalized summary data for one image and return whether it is missing."""
    entry = {
        'found_regions': sorted(found_regions),
        'not_found_regions': sorted(not_found_regions),
    }
    summary[image_name] = entry
    return (not entry['found_regions']) or bool(entry['not_found_regions'])


def process_results(
    image_names: List[str],
    availability: Dict[str, Dict[str, List[str]]]
) -> Tuple[
    Dict[str, Dict[str, List[str]]], List[str]
]:
    """Process image results, build summary and missing lists."""
    summary: dict[str, dict[str, list[str]]] = {}
    missing: list[str] = []

    for name in image_names:
        availability_item = availability[name]
        regions = availability_item.get('found_regions', [])
        not_found_regions = availability_item.get('not_found_regions', [])

        if add_summary_entry(summary, name, regions, not_found_regions):
            missing.append(name)

    return summary, missing


def main() -> int:
    """Run the requested provider checks and return process exit code."""
    args = parse_args()
    cloud_clients = init_cloud_clients(args.environment, args.cloud_provider)
    image_names = list(dict.fromkeys(args.image_names))

    checker = {
        'aws': check_aws_images,
        'gcp': check_gcp_images,
        'azure': check_azure_images,
        }
    availability = checker[args.cloud_provider](cloud_clients, image_names)
    summary, missing = process_results(
        image_names,
        availability
    )
    print_summary_report(args.cloud_provider, summary, args.debug)

    if missing:
        print(
            f'RESULT: missing or partially missing images: {", ".join(missing)}')
        return 1

    print('RESULT: all images found')
    return 0


if __name__ == '__main__':
    sys.exit(main())
