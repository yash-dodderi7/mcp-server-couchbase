#!/usr/bin/env python3

# Azure is accessible by client id and secret.

from azure.mgmt.compute import ComputeManagementClient
from azure.mgmt.resource import ResourceManagementClient
from azure.identity import ClientSecretCredential
import sys

class CouchbaseCloudAzure:
    def __init__(self, client_id, client_secret, subscription_id, tenant_id):
        credential = ClientSecretCredential(
            client_id=client_id,
            client_secret=client_secret,
            tenant_id=tenant_id
        )
        self.compute_client = ComputeManagementClient(credential, subscription_id)
        self.resource_client = ResourceManagementClient(credential, subscription_id)

    def get_gallery(self, resource_name, gallery_name):
        return self.compute_client.galleries.get(resource_name, gallery_name)

    def get_image_definitions(self, resource_name, gallery_name):
        return self.compute_client.gallery_images.list_by_gallery(resource_name, gallery_name)

    def get_image_definition(self, resource_name, gallery_name, image_definition_name):
        return self.compute_client.gallery_images.get(resource_name, gallery_name, image_definition_name)

    def get_images_by_resource_group(self, resource_group):
        images=[]
        image_versions=[]
        resource_list = self.resource_client.resources.list_by_resource_group(
            resource_group, expand = 'type, identity, createdTime, changedTime')

        # We are only interested in image and image version
        for resource in list(resource_list):
            if resource.type == 'Microsoft.Compute/galleries/images/versions':
                image_versions.append(resource)
            if resource.type == 'Microsoft.Compute/images':
                images.append(resource)
        return images, image_versions
