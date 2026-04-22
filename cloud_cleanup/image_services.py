#!/usr/bin/env python3

from datetime import datetime, timezone, timedelta
import json
import logging
import os
import sys
import time
from functools import partial
from google.oauth2.service_account import Credentials
from google.cloud import compute_v1

from cleanup_summary import merge_summary_counts, update_summary_counts
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
UTILITIES_DIR = os.path.join(os.path.dirname(SCRIPT_DIR), 'utilities')
if UTILITIES_DIR not in sys.path:
    sys.path.insert(0, UTILITIES_DIR)
from aws_utils import AWSUtils
from azure_utils import AzureUtils
from common_utils import get_env_vars, concurrent_executor
from gcp_utils import GCPUtils

logger = logging.getLogger(__name__)

GCP_COMPUTE_SCOPE = 'https://www.googleapis.com/auth/compute'

AZURE_RESOURCE_GROUP_NAME = 'image-factory'
AZURE_GALLERY_NAME = 'capella'
DELETE_WAIT_SECONDS = 10
DELETE_MAX_ATTEMPTS = 60
CLEANUP_MAX_WORKERS = 4
CURRENT_UTC_DATE = datetime.now(timezone.utc).date()

DELETE_RESULT_DELETED = 'deleted'
DELETE_RESULT_SKIPPED = 'skipped'
DELETE_RESULT_FAILED = 'failed'




def _deployment_account_client(
        aws_client, aws_vars, cloud_provider, additional_vars=None):
    '''
    Client for azure and gcp deployment account where actual instance runs
    Image should not be deleted if it's still used by an instance.
    '''
    secret_name = f'{cloud_provider.upper()}_DEPLOYMENT_ACCOUNT_SECRET_NAME'

    if secret_name not in aws_vars:
        logger.debug(
            f'{cloud_provider.upper()} deployment account secret name not defined.')
        return None

    secrets = aws_client.get_secret(aws_vars[secret_name])
    if secrets is None:
        logger.debug(
            f'{cloud_provider.upper()} deployment account secret not defined.')
        return None

    logger.debug(f'Set up {cloud_provider.upper()} deployment client')
    if cloud_provider == 'azure':
        sub_id = (additional_vars or {}).get('DEPLOYMENT_ACCOUNT_SUBSCRIPTION_ID')
        return AzureUtils(
            secrets.get('SERVICE_PRINCIPAL'),
            secrets.get('PASSWORD'),
            secrets.get('TENANT_ID'),
            sub_id
        )

    if cloud_provider == 'gcp':
        if isinstance(secrets, str):
            service_account_info = json.loads(secrets)
        elif isinstance(secrets, dict):
            service_account_info = secrets
        else:
            logger.warning('Unexpected GCP deployment secret payload.')
            return None

        credentials = Credentials.from_service_account_info(
            service_account_info,
            scopes=[GCP_COMPUTE_SCOPE]
        )
        return compute_v1.InstancesClient(credentials=credentials)

    return None

def _split_azure_image_name(image_name):
    '''
    Azure image version name is expected to be in format of
    {image_definition_name}-v{image_version_name}
    '''
    split_result = image_name.rsplit('-v', 1)
    if len(split_result) != 2 or not split_result[0] or not split_result[1]:
        return None
    return split_result[0], split_result[1]


def _wait_for_completion(
        get_state,
        is_done,
        wait_seconds,
        max_attempts,
        waiting_message,
        timeout_message):
    '''
    Wait for an operation to complete with a polling mechanism.
    '''
    for attempt in range(1, max_attempts + 1):
        state = get_state()

        if is_done(state):
            return True

        if attempt == 1 or attempt % 6 == 0:
            logger.info(waiting_message)
        else:
            logger.debug(waiting_message)
        time.sleep(wait_seconds)

    logger.warning(timeout_message)
    return False


def _wait_for_gcp_image_delete(operation_result, image_name):
    '''
    Wait for a GCP image delete operation to complete.
    '''
    if operation_result is None:
        logger.warning(f'No response while waiting for deletion of {image_name}')
        return False

    timeout_seconds = DELETE_WAIT_SECONDS * DELETE_MAX_ATTEMPTS
    result = getattr(operation_result, 'result', None)
    if callable(result):
        result(timeout=timeout_seconds)
    else:
        is_done = _wait_for_completion(
            get_state=lambda: operation_result,
            is_done=lambda op: (
                (getattr(op, 'done', None) and op.done())
                or str(getattr(op, 'status', '')).upper() == 'DONE'
            ),
            wait_seconds=DELETE_WAIT_SECONDS,
            max_attempts=DELETE_MAX_ATTEMPTS,
            waiting_message=f'Waiting for GCP image deletion: {image_name}...',
            timeout_message=f'Timeout waiting for GCP image deletion: {image_name}')
        if not is_done:
            return False

    error_code = getattr(operation_result, 'error_code', None)
    if error_code:
        error_message = getattr(operation_result, 'error_message', None)
        logger.warning(f'{image_name} deletion failed: {error_code} {error_message}')
        return False

    return True


def _wait_for_azure_image_delete(azure, image_name):
    '''
    Wait for an Azure image delete operation to complete.
    '''
    return _wait_for_completion(
        get_state=lambda: azure.get_image_by_name(AZURE_RESOURCE_GROUP_NAME, image_name),
        is_done=lambda result: not result,
        wait_seconds=DELETE_WAIT_SECONDS,
        max_attempts=DELETE_MAX_ATTEMPTS,
        waiting_message=f'Waiting for {image_name} to be deleted...',
        timeout_message=(
            f'Timeout waiting for Azure image deletion: {image_name}. '
            f'Skipping image version delete.'))


def _wait_for_azure_image_version_delete(azure, image_definition_name, image_version_name):
    '''
    Wait for an Azure image version delete operation to complete.
    '''
    return _wait_for_completion(
        get_state=lambda: azure.get_image_version(
            AZURE_RESOURCE_GROUP_NAME,
            AZURE_GALLERY_NAME,
            image_definition_name,
            image_version_name),
        is_done=lambda result: not result,
        wait_seconds=DELETE_WAIT_SECONDS,
        max_attempts=DELETE_MAX_ATTEMPTS,
        waiting_message=(
            f'Waiting for {image_version_name} to be deleted from '
            f'{image_definition_name}...'),
        timeout_message=(
            f'Timeout waiting for Azure image version deletion: '
            f'{image_definition_name}:{image_version_name}'))


def is_image_old(created_date, retention_days, image_name):
    '''
    Check if image is older than the age threshold.
    '''
    if created_date > CURRENT_UTC_DATE - timedelta(days=retention_days):
        logger.debug(
            f'{image_name} is created {created_date}, less than {retention_days} days ago.'
            f'It will not be deleted.')
        return False
    return True


def parse_aws_creation_date(creation_date):
    '''
    Parse AWS AMI creation date string to UTC date.
    '''
    return datetime.strptime(
        creation_date,
        '%Y-%m-%dT%H:%M:%S.%fZ').replace(tzinfo=timezone.utc).date()


def parse_gcp_creation_date(creation_timestamp):
    '''
    Parse GCP image creation timestamp to UTC date.
    '''
    return datetime.strptime(
        creation_timestamp.split('.')[0],
        '%Y-%m-%dT%H:%M:%S').replace(tzinfo=timezone.utc).date()


def find_aws_images_to_remove(retention_days, excluded, aws_client):
    '''
    Find AWS images to remove based on retention days and excluded images.
    '''
    images_to_delete = []
    images = aws_client.search_ami_by_pattern(
        ami_filters={
            'name': '*',
            'tag:creator': 'build-team',
        },
        exclude_tags={'released': 'true'})
    for image in images:
        image_name = image.get('Name', '')
        if not image_name:
            logger.warning(f"Unable to determine {image['ImageId']} image name. Skipping.")
            continue

        if image_name in excluded:
            logger.debug(f"Skipping excluded AWS image: {image_name}")
            continue

        created_date = parse_aws_creation_date(image['CreationDate'])
        if is_image_old(created_date, retention_days, image_name):
            images_to_delete.append(image)

    for image in images_to_delete:
        logger.debug(
            f'{image["Name"]} {image["CreationDate"]} should be deleted')

    return images_to_delete


def delete_aws_image(image, aws_utils):
    '''
    Delete an AWS image if it is not being used by any instances.
    '''
    image_id = image['ImageId']
    instances = aws_utils.get_instances_by_ami_id(image_id)
    region = aws_utils.client.meta.region_name
    if instances:
        logger.info(
            f'{image["Name"]} is still being used in {region}.  '
            f'It will not be deleted.')
        return DELETE_RESULT_SKIPPED

    logger.info(
        f'Removing AWS image {image["Name"]} '
        f'created {image["CreationDate"]} in {region}')
    try:
        response = aws_utils.client.deregister_image(
            ImageId=image_id,
            DeleteAssociatedSnapshots=True)
        if not response.get('Return'):
            return DELETE_RESULT_FAILED

        # Warn about snapshot deletion failure so that we can investigate and cleanup afterward
        snapshot_result = (response.get('DeleteSnapshotResults') or [None])[0]
        if snapshot_result and str(snapshot_result.get('ReturnCode', '')).lower() != 'success':
            logger.warning(
                f'AMI {image["Name"]} deregistered in {region}.  '
                f'Snapshot {snapshot_result.get("SnapshotId", "Unknown Id")} deletion failed: '
                f'{snapshot_result}')
        return DELETE_RESULT_DELETED
    except Exception as e:
        logger.warning(f"Failed to deregister {image['Name']}: {e}")
        return DELETE_RESULT_FAILED

def delete_gcp_image(image, gcp_client):
    '''
    Delete a GCP image.
    '''
    result = gcp_client.delete_image_by_name(image.name)
    if not _wait_for_gcp_image_delete(result, image.name):
        return DELETE_RESULT_FAILED
    logger.info(f'GCP image deleted: {image.name}')
    return DELETE_RESULT_DELETED

def delete_azure_image(image, azure_client):
    '''
    Delete an Azure image and its image version
    '''
    split_result = _split_azure_image_name(image.name)
    if split_result is None:
        logger.warning(
            f'Skipping Azure image with unexpected name format: {image.name}')
        return DELETE_RESULT_SKIPPED
    image_definition_name, image_version_name = split_result

    azure_client.delete_image_by_name(AZURE_RESOURCE_GROUP_NAME, image.name)
    if not _wait_for_azure_image_delete(azure_client, image.name):
        return DELETE_RESULT_FAILED
    logger.info(
        f'Deleting image version {image_version_name} from {image_definition_name}...')
    azure_client.delete_image_version(
        AZURE_RESOURCE_GROUP_NAME,
        AZURE_GALLERY_NAME,
        image_definition_name,
        image_version_name)
    if not _wait_for_azure_image_version_delete(
        azure_client, image_definition_name, image_version_name):
        return DELETE_RESULT_FAILED
    logger.info(
        f'{image.name} and {image_version_name} from {image_definition_name} are deleted')
    return DELETE_RESULT_DELETED


def aws_cleanup_region(retention_days, excluded_images, aws_client, region):
    '''
    Find AWS images to remove.
    '''
    statuses = {
        DELETE_RESULT_DELETED: 0,
        DELETE_RESULT_SKIPPED: 0,
        DELETE_RESULT_FAILED: 0,
    }
    aws_region_client = AWSUtils(aws_client.session.profile_name, region)
    images = find_aws_images_to_remove(
        retention_days,
        excluded_images,
        aws_region_client)
    for image in images:
        logger.info(
            f'Removing AWS image {image["Name"]} created {image["CreationDate"]}.')
        result = delete_aws_image(image, aws_utils=aws_region_client)
        result_key = result if result in statuses else DELETE_RESULT_FAILED
        statuses[result_key] += 1
    return {
        'candidates': len(images),
        'deleted': statuses[DELETE_RESULT_DELETED],
        'skipped': statuses[DELETE_RESULT_SKIPPED],
        'failed': statuses[DELETE_RESULT_FAILED],
    }


def find_gcp_images_to_remove(
        retention_days,
        excluded_images,
        gcp_image_client,
        gcp_deployment_account_client=None,
        gcp_deployment_account_name=None):
    '''
    Find GCP images to remove.
    '''
    all_used_images = set()
    images_to_delete = []
    excluded = set(excluded_images)
    images_to_evaluate = gcp_image_client.search_image_by_pattern(
        image_filters={'name': '*'},
        exclude_labels={'released': 'true'}
    )
    if gcp_deployment_account_client is not None:
        all_instances = gcp_deployment_account_client.aggregated_list(
            project=gcp_deployment_account_name)
        for _, response in all_instances:
            if response.instances:
                for instance in response.instances:
                    for item in instance.metadata.items:
                        if item.key == 'image':
                            all_used_images.add(item.value)

    for image in images_to_evaluate:
        if image.name in excluded:
            logger.debug(f"Skipping excluded GCP image: {image.name}")
            continue

        created_date = parse_gcp_creation_date(image.creation_timestamp)
        if is_image_old(created_date, retention_days, image.name):
            if image.name in all_used_images:
                logger.debug(
                    f'{image.name} is still being used. It will not be deleted.')
                continue
            images_to_delete.append(image)
            logger.debug(
                f"{image.name} created {created_date} should be deleted")
    return images_to_delete


def find_azure_images_to_remove(
        retention_days,
        excluded_images,
        azure_image_client,
        azure_deployment_account_client=None):
    '''
    Find Azure images to remove.
    '''
    images_to_delete = []
    excluded = set(excluded_images)
    vmss_images = set()
    if azure_deployment_account_client is not None:
        vmss_list = azure_deployment_account_client.virtual_machine_scale_sets.list_all()
        for vmss in vmss_list:
            vmss_images.add(
                vmss.virtual_machine_profile.storage_profile.image_reference.id.lower())
    for image in azure_image_client.compute_client.images.list_by_resource_group(
            AZURE_RESOURCE_GROUP_NAME):
        if not hasattr(image, 'tags'):
            continue
        if image.tags.get('creator') != 'build-team':
            continue
        if image.tags.get('released') == 'true':
            continue

        if image.name in excluded:
            logger.debug(f"Skipping excluded Azure image: {image.name}")
            continue

        if 'image_version' not in image.tags:
            logger.debug(
                f'{image.name} does not belong to any image definition.')
            image.creation_date = None
            images_to_delete.append(image)
            continue

        split_result = _split_azure_image_name(image.name)
        if split_result is None:
            logger.warning(
                f'Skipping Azure image with unexpected name format: {image.name}')
            continue
        image_definition_name, image_version_name = split_result
        try:
            image_version = azure_image_client.get_image_version(
                AZURE_RESOURCE_GROUP_NAME,
                AZURE_GALLERY_NAME,
                image_definition_name,
                image_version_name)

            created_date = image_version.publishing_profile.published_date.replace(
                tzinfo=timezone.utc).date()

            if is_image_old(created_date, retention_days, image.name):
                if image_version.id.lower() in vmss_images:
                    logger.debug(
                        f'{image.name} is still being used. It will not be deleted.')
                    continue
                image.creation_date = created_date
                images_to_delete.append(image)
        except Exception as e:
            logger.warning(
                f"Skipping Azure image {image.name}: unable to obtain image_version info: {e}")

    for image in images_to_delete:
        logger.debug(f"{image.name} {image.creation_date} should be deleted")

    return images_to_delete


def process_aws_images(retention_days, excluded_images, environment, dryrun, summary):
    '''
    Process AWS images, remove images that do not satisfy retention policies.
    '''
    aws_excluded_images = excluded_images.get('aws', [])
    aws_vars = get_env_vars('aws', environment)
    aws_client = AWSUtils(aws_vars['ROLE_SESSION_NAME'], 'us-east-1')
    all_regions = aws_client.get_regions()
    if not all_regions:
        logger.warn('Unable to determine AWS regions.  Skip AWS cleanup.')
        return

    if dryrun:
        images_to_delete = find_aws_images_to_remove(
            retention_days,
            aws_excluded_images,
            aws_client)
        summary['aws']['candidates'] += len(images_to_delete)
        for image in images_to_delete:
            logger.info(
                f'AWS image {image["Name"]} '
                f'created {image["CreationDate"]} should be removed.')
        return

    # Use concurrent_executor with extra args for efficiency
    call_aws_cleanup_region = partial(
        aws_cleanup_region, retention_days, aws_excluded_images, aws_client)
    results = concurrent_executor(call_aws_cleanup_region, all_regions, workers=CLEANUP_MAX_WORKERS)
    for region_result in results:
        merge_summary_counts(summary, 'aws', region_result)




def process_gcp_images(retention_days, excluded_images, environment, dryrun, summary):
    '''
    Process GCP images, remove images that do not satisfy retention policies.
    '''
    gcp_vars = get_env_vars('gcp', environment)
    gcp_image_client = GCPUtils(environment)

    aws_vars = get_env_vars('aws', environment)
    aws_client = AWSUtils(aws_vars['ROLE_SESSION_NAME'], 'us-east-1')
    gcp_deployment_account_client = None
    gcp_deployment_account_name = None
    if 'GCP_DEPLOYMENT_ACCOUNT_SECRET_NAME' in aws_vars:
        gcp_deployment_account_client = _deployment_account_client(
            aws_client, aws_vars, 'gcp')
        gcp_deployment_account_name = gcp_vars.get('DEPLOYMENT_ACCOUNT')

    images = find_gcp_images_to_remove(
        retention_days,
        excluded_images.get('gcp', []),
        gcp_image_client,
        gcp_deployment_account_client,
        gcp_deployment_account_name)
    summary['gcp']['candidates'] += len(images)
    if dryrun:
        for image in images:
            created_date = parse_gcp_creation_date(image.creation_timestamp)
            logger.info(
                f'GCP image, {image.name} created {created_date}, should be removed.')
        return
    gcp_delete_images=partial(delete_gcp_image, gcp_client=gcp_image_client)
    results = concurrent_executor(gcp_delete_images, images, workers=CLEANUP_MAX_WORKERS)
    # Batch update summary for efficiency
    for result in results:
        update_summary_counts(summary, 'gcp', result)


def process_azure_images(retention_days, excluded_images, environment, dryrun, summary):
    '''
    Process Azure images, remove images that do not satisfy retention policies.
    '''
    azure_vars = get_env_vars('azure', environment)
    aws_vars = get_env_vars('aws', environment)
    aws_client = AWSUtils(aws_vars['ROLE_SESSION_NAME'], 'us-east-1')
    azure_client_secret = aws_client.get_secret(aws_vars['AZURE_CLIENT_SECRET_NAME'])
    if azure_client_secret is None:
        raise RuntimeError('Unable to obtain Azure CLIENT_SECRET')
    azure_image_client = AzureUtils(
        azure_vars['CLIENT_ID'],
        azure_client_secret,
        azure_vars['TENANT_ID'],
        azure_vars['SUBSCRIPTION_ID']
    )
    # Deployment account client (optional)
    azure_deployment_account_client = None
    if 'AZURE_DEPLOYMENT_ACCOUNT_SECRET_NAME' in aws_vars:
        azure_deployment_account_client = _deployment_account_client(
            aws_client, aws_vars, 'azure', azure_vars)

    images = find_azure_images_to_remove(
        retention_days,
        excluded_images.get('azure', []),
        azure_image_client,
        azure_deployment_account_client)
    summary['azure']['candidates'] += len(images)
    if dryrun:
        for image in images:
            logger.info(
                f'Azure image {image.name} '
                f'created {image.creation_date} should be removed.')
        return

    azure_delete_images = partial(delete_azure_image, azure_client=azure_image_client)
    results = concurrent_executor(azure_delete_images, images, workers=CLEANUP_MAX_WORKERS)
    # Batch update summary for efficiency
    for result in results:
        update_summary_counts(summary, 'azure', result)
