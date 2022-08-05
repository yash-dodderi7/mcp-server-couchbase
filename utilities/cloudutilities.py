#!/usr/bin/env python3

import boto3
import botocore
import os
import json

class CouchbaseCloud:
    def __init__(self,profile):
        config =json.loads(open("config.json").read())
        self.session = boto3.session.Session(profile_name=profile)
        self.s3=config['s3']
        self.roles=config['roles']

    def assume_role (self, env):
        client = self.session.client('sts')
        result = client.assume_role(
            RoleArn=self.roles[env]['ROLE_ARN'],
            RoleSessionName=self.roles[env]['ROLE_SESSION_NAME'],
            DurationSeconds=3600,
            ExternalId=self.roles[env]['EXTERNALID']
        )
        credentials = result['Credentials']
        return credentials

    def write_config (self, env, credentials):

        with open('.aws/config', 'a') as f:
            f.write("[profile %s]\n" %(self.roles[env]['ROLE_SESSION_NAME']))
            f.write("region=us-east-1\n")
            f.write("output=json\n")

        with open('.aws/credentials', 'a') as f:
            f.write("[%s]\n" %(self.roles[env]['ROLE_SESSION_NAME']))
            f.write("aws_access_key_id     = %s\n" %(credentials['AccessKeyId']))
            f.write("aws_secret_access_key = %s\n" %(credentials['SecretAccessKey']))
            f.write("aws_session_token     = %s\n" %(credentials['SessionToken']))

    def download_agents (self, credentials):
        s3_session = boto3.Session(profile_name=self.s3['profile'])
        s3_resource = s3_session.resource('s3')
        for file in self.s3['files']:
            name=os.path.basename(self.s3['files'][file])
            path=self.s3['files'][file]
            try:
                s3_resource.Bucket(self.s3['bucket']).download_file(path, name)
            except botocore.exceptions.ClientError as e:
                if e.response['Error']['Code'] == "404":
                    print("The object does not exist.")
                else:
                    raise

if __name__ == "__main__":
    couchbasecloud=CouchbaseCloud('CBROBOT')
    for env in couchbasecloud.roles.keys():
        credentials=couchbasecloud.assume_role(env)
        couchbasecloud.write_config(env, credentials)

    couchbasecloud.download_agents(credentials)
