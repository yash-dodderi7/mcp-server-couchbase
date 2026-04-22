#!/usr/bin/env python3

'''
Cloud Image Cleanup Tool

A Python script for automatically remove unused cloud images
* images listed in exclude_images.json are excluded
* images tagged with "released=true" are excluded
* images newer than 45 days are retained by default

USAGE:
    python3 remove_images.py
    --dryrun                Preview images to be deleted without actually deleting
    --retention-days INT    How many days back to keep images (default: 45)
    --cloud-providers SET   Which clouds to clean up: aws, gcp, azure (default: all)
    --environments CHOICE   Which environment to clean up: sandbox, stage (default: sandbox)
    --debug                 Enable debug logging
'''

import argparse
import json
import logging
import os
import sys
from cleanup_summary import initialize_summary
from image_services import (
    process_aws_images,
    process_gcp_images,
    process_azure_images,
)

PROVIDERS = {
    'aws': process_aws_images,
    'gcp': process_gcp_images,
    'azure': process_azure_images,
}

# Set up logging
logger = logging.getLogger(__name__)
console_handler = logging.StreamHandler(stream=sys.stdout)
logger.addHandler(console_handler)


def parse_args():
    '''
    Parse command line arguments
    '''
    parser = argparse.ArgumentParser(
        description='Clean up unused cloud images')
    parser.add_argument('--environment',
                        choices=['sandbox', 'stage'],
                        default='sandbox',
                        help='Environment to cleanup, sandbox or stage')
    parser.add_argument('--cloud-providers',
                        nargs='+',
                        choices=['aws', 'gcp', 'azure'],
                        default=['aws', 'gcp', 'azure'],
                        help='Clouds to cleanup (default: all)')
    parser.add_argument(
        '--retention-days',
        type=int,
        default=45,
        help='How far back to keep the images (default: 45 days)')
    parser.add_argument('--dryrun',
                        action='store_true',
                        help='Perform a dry run without deleting images')
    parser.add_argument('--debug',
                        action='store_true',
                        help='Enable debug logging')
    args = parser.parse_args()
    return args

def load_excluded_images(exclude_file_path='exclude_images.json'):
    '''
    Load excluded images from JSON file
    '''
    excluded_images = {
        'aws': [],
        'gcp': [],
        'azure': []
    }

    if os.path.exists(exclude_file_path):
        try:
            with open(exclude_file_path, 'r') as f:
                excluded_images = json.load(f)
            logger.info(f"Loaded excluded images from {exclude_file_path}")
        except Exception as e:
            logger.warning(
                f"Failed to load excluded images from {exclude_file_path}: {e}")

    return excluded_images


if __name__ == '__main__':
    args = parse_args()
    enabled_providers = frozenset(args.cloud_providers)

    retention_days = args.retention_days
    environment = args.environment
    if args.debug:
        logger.setLevel(logging.DEBUG)
    else:
        logger.setLevel(logging.INFO)

    summary = initialize_summary(args.cloud_providers)

    # Exclude specific images from deletion
    excluded_images = load_excluded_images('exclude_images.json')

    for provider in args.cloud_providers:
        logger.info(f"Finding {provider.upper()} images to cleanup")
        PROVIDERS[provider](
            retention_days,
            excluded_images,
            environment,
            args.dryrun,
            summary)

    logger.info('Cleanup summary:')
    for provider in args.cloud_providers:
        logger.info(
            f"{provider.upper()}: candidates={summary[provider]['candidates']} "
            f"deleted={summary[provider]['deleted']} skipped={summary[provider]['skipped']} "
            f"failed={summary[provider]['failed']} "
            f"dryrun={args.dryrun}")
