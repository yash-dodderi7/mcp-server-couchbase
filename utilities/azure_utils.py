#!/usr/bin/env python3

# Azure Helper functions.
import logging
import sys
from azure.mgmt.compute import ComputeManagementClient
from azure.mgmt.resource import ResourceManagementClient
from azure.mgmt.subscription import SubscriptionClient
from azure.identity import ClientSecretCredential
from azure.core.exceptions import ResourceNotFoundError, HttpResponseError

logger = logging.getLogger('azure')
logger.setLevel(logging.ERROR)


class AzureUtils:
    def __init__(self, client_id, client_secret, tenant_id, subscription_id):
        '''
        Initialize Azure connections to Subscription, Compute, and Resource clients
        '''
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
        '''
        Get a list of available regions.
        This is useful for operations such as image replication.
        '''
        locations = self.subscription_client.subscriptions.list_locations(
            self.subscription_id
        )
        # Get the locations where 'images' resource type is allowed
        compute_provider = self.resource_client.providers.get("Microsoft.Compute")
        image_resource_type = next(
            rt for rt in compute_provider.resource_types if rt.resource_type == 'images'
        )
        allowed_locations = set(image_resource_type.locations)

        # Filter only the allowed regions
        regions = [loc.name for loc in locations if loc.display_name in allowed_locations]

        return regions

    def get_gallery(self, resource_group_name, gallery_name):
        '''
        Retrieve details of a specific Azure Compute Gallery.
        '''
        return self.compute_client.galleries.get(
            resource_group_name, gallery_name)

    def get_image_definition(
            self, resource_group_name, gallery_name, image_definition_name):
        '''
        Retrieve details of a specific image definition from a gallery.
        '''
        try:
            return self.compute_client.gallery_images.get(
                resource_group_name, gallery_name, image_definition_name)
        except ResourceNotFoundError as e:
            logger.warning(f"Image definition not found: {e.message}")
            return None  # or handle as appropriate
        except HttpResponseError as e:
            logger.error(f"Azure API error: {e.message}")
            sys.exit(1)

    def create_image_definition(
            self,
            resource_group_name,
            gallery_name,
            image_definition_name,
            image_definition):
        '''
        Create or update an image definition in a gallery.
        '''
        return self.compute_client.gallery_images.begin_create_or_update(
            resource_group_name, gallery_name, image_definition_name, image_definition)

    def get_images_by_resource_group(self, resource_group_name):
        '''
        Retrieve all images and image versions in a resource group.
        '''
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
        '''
        Return single image detail under a resource group
        '''
        try:
            return self.compute_client.images.get(
                resource_group_name=resource_group_name, image_name=image_name)
        except ResourceNotFoundError:
            logger.warning(f"Image '{image_name}' not found in resource group '{resource_group_name}'.")
            return None
        except HttpResponseError as e:
            logger.error(f"Azure API error: {str(e)}")
            sys.exit(1)

    def delete_image_by_name(self, resource_group_name, image_name):
        '''
        Delete an image from a given resource group
        '''
        return self.compute_client.images.begin_delete(
            resource_group_name=resource_group_name,
            image_name=image_name,
        ).result()

    def delete_image_version(
            self, resource_group_name, gallery_name, gallery_image_name,
            gallery_image_version):
        '''
        Delete an image version from gallery
        This should be done after an image is deleted
        '''
        return self.compute_client.gallery_image_versions.begin_delete(
            resource_group_name, gallery_name, gallery_image_name,
            gallery_image_version)

    def get_image_version(self, resource_group_name, gallery_name,
                          gallery_image_name, gallery_image_version):
        '''
        Retrieve details of a specific gallery image version.
        '''
        return self.compute_client.gallery_image_versions.get(
            resource_group_name, gallery_name, gallery_image_name,
            gallery_image_version)

    def update_image_tags(self, resource_group_name, image_name, tags):
        '''
        Update or add tags to a compute image.
        This does not remove existing tags.
        If a tag already exists, it will be updated with the new value.
        '''
        image = self.get_image_by_name(resource_group_name, image_name)
        if not image:
            logger.error(f'Unable to locate {image_name}')
        else:
            image_tags = image.tags or {}
            image_tags.update(tags)
            self.compute_client.images.begin_update(
                resource_group_name=resource_group_name,
                image_name=image_name,
                parameters={
                    'tags': image_tags
                }
            )

    def search_image_by_pattern(
            self, resource_group_name, image_filters, exclude_tags=None):
        '''
        Search for Azure images,  Use filters to idenfity desired images.
        i.e.
            image_filters={'name': image_name}
            exclude_tags={'released': 'true'}
        '''
        # Get all images in the resource group
        images = self.compute_client.images.list_by_resource_group(
            resource_group_name)
        filtered_images = []

        # Process image filters first (required)
        for image in images:
            matches_all = True
            for key, value in image_filters.items():
                values = [value] if isinstance(value, str) else value
                if key == 'name':
                    if not any(val in image.name.lower() for val in values):
                        matches_all = False
                        break
                else:
                    if not image.tags or key not in image.tags or \
                       not any(val in image.tags[key].lower() for val in values):
                        matches_all = False
                        break

            if matches_all:
                filtered_images.append(image)

        # If no exclude_tags defined, return the results
        if not exclude_tags:
            return filtered_images

        # Filter out images containing exclude_tags
        final_images = []
        for image in filtered_images:
            exclude_image = False
            for key, value in exclude_tags.items():
                values = [value] if isinstance(value, str) else value
                if key == 'name':
                    if any(val in image.name.lower() for val in values):
                        exclude_image = True
                        break
                else:
                    if image.tags and key in image.tags and \
                       any(val in image.tags[key].lower() for val in values):
                        exclude_image = True
                        break

            if not exclude_image:
                final_images.append(image)

        return final_images
