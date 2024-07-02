#!/usr/bin/env python3

# Azure Helper functions.
import logging
import sys
from azure.mgmt.compute import ComputeManagementClient
from azure.mgmt.resource import ResourceManagementClient
from azure.mgmt.resource import SubscriptionClient
from azure.identity import ClientSecretCredential

logger = logging.getLogger('azure')
logger.setLevel(logging.ERROR)


class AzureUtils:
    def __init__(self, client_id, client_secret, tenant_id, subscription_id):
        credential = ClientSecretCredential(
            client_id=client_id,
            client_secret=client_secret,
            tenant_id=tenant_id
        )
        self.subscription_client = SubscriptionClient(
            credential)
        self.compute_client = ComputeManagementClient(
            credential, subscription_id)
        self.resource_client = ResourceManagementClient(
            credential, subscription_id)
        self.subscription_id = subscription_id

    def get_regions(self):
        locations = self.subscription_client.subscriptions.list_locations(
            subscription_id=self.subscription_id)
        regions = [
            l.name for l in locations if l.availability_zone_mappings is not None]
        return regions

    def get_gallery(self, resource_group_name, gallery_name):
        return self.compute_client.galleries.get(
            resource_group_name, gallery_name)

    def get_image_definition(
            self, resource_group_name, gallery_name, image_definition_name):
        try:
            return self.compute_client.gallery_images.get(
                resource_group_name, gallery_name, image_definition_name)
        except Exception as e:
            if e.status_code == 404:
                # Image definition not found
                logger.warning(e.message)
            else:
                # Something else is wrong, exit
                sys.exit(e.message)

    def create_image_definition(
            self,
            resource_group_name,
            gallery_name,
            image_definition_name,
            image_definition):
        return self.compute_client.gallery_images.begin_create_or_update(
            resource_group_name, gallery_name, image_definition_name, image_definition)

    def get_images_by_resource_group(self, resource_group_name):
        images = []
        image_versions = []
        resource_list = self.resource_client.resources.list_by_resource_group(
            resource_group_name, expand='type, identity, createdTime, changedTime')

        # We are only interested in image and image version
        for resource in list(resource_list):
            if resource.type == 'Microsoft.Compute/galleries/images/versions':
                image_versions.append(resource)
            if resource.type == 'Microsoft.Compute/images':
                images.append(resource)
        return images, image_versions

    def get_image_by_name(self, resource_group_name, image_name):
        try:
            return self.compute_client.images.get(
                resource_group_name=resource_group_name, image_name=image_name)
        except Exception as e:
            if e.status_code == 404:
                # Image not found
                logger.warning(e.message)
            else:
                # Something else is wrong, exit
                sys.exit(e.message)

    def delete_image_by_name(self, resource_group_name, image_name):
        return self.compute_client.images.begin_delete(
            resource_group_name=resource_group_name,
            image_name=image_name,
        ).result()

    def delete_image_version(
            self, resource_group_name, gallery_name, gallery_image_name,
            gallery_image_version):
        return self.compute_client.gallery_image_versions.begin_delete(
            resource_group_name, gallery_name, gallery_image_name,
            gallery_image_version)

    def get_image_version(self, resource_group_name, gallery_name,
                          gallery_image_name, gallery_image_version):
        return self.compute_client.gallery_image_versions.get(
            resource_group_name, gallery_name, gallery_image_name,
            gallery_image_version)

    def get_images(self, resource_group_name):
        return self.compute_client.images.list_by_resource_group(
            resource_group_name)

    def release_image(self, resource_group_name, image_name):
        image = self.get_image_by_name(resource_group_name, image_name)
        if not image:
            logger.error(f'Unable to locate {image_name}')
        else:
            image_tags = image.tags
            image_tags['released'] = 'true'
            self.compute_client.images.begin_update(
                resource_group_name=resource_group_name,
                image_name=image_name,
                parameters={
                    'tags': image_tags
                }
            )
