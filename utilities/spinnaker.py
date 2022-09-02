#!/usr/bin/env python3
import requests
import json
import sys
import argparse
import logging
import time


logging.basicConfig(format='%(asctime)s:%(levelname)s:%(message)s', stream=sys.stderr, level=logging.INFO)

# Create a https session
def create_session(token, spinnaker_config):
    headers = {'Authorization': f'Bearer {token}'}
    session = requests.post(spinnaker_config['api_base']+spinnaker_config['login_path'], headers=headers, allow_redirects=False)
    session.raise_for_status()
    return session

# Get pipeline job result
def get_pipeline_result(session, url):
    while(True):
        req = requests.get(url, cookies=session.cookies)
        req.raise_for_status()
        if req.json()['status'] == "RUNNING":
            time.sleep(30)
            logging.info(f"Waiting for pipeline to finish.  Status available at {url}")
        else:
            break
    return req.json()

# Run a pipeline job against sandbox env
def trigger_pipeline(session, spinnaker_config, pipeline_url, data):
    logging.info(f"Kicking off {pipeline_url}")
    req = requests.post(pipeline_url, cookies=session.cookies, json=data)
    req.raise_for_status()

    ref_url=spinnaker_config['api_base']+req.json()['ref']
    result=get_pipeline_result(session, ref_url)
    if result['status'] != 'SUCCEEDED':
        sys.exit(f"{pipeline_url} finished unsuccessfully. \
                      See {ref_url} for detail.")
    logging.info(f"{pipeline_url} finished successfully.")

# Spinnaker URLs
spinnaker_config = {
    "api_base"          : "https://preprod.spinnaker-stage.cloud.couchbase.com/api/v1",
    "login_path"            : "/login",
    "find_available_sandbox": "/pipelines/sandboxes/find-available-sandboxes",
    "deploy-control-plane"  : "deploy-control-plane"
}

# Control plane source code:
# Application Branch:
# Infrastructure Branch:
control_plane_data = {
    "branch"    : "main",
    "revision"  : "main"
}


# Main
# Current script only deploys latest CP on specific sandbox env.

parser = argparse.ArgumentParser()
parser.add_argument('--token', required=True, help='Github Personal Access Token.')
parser.add_argument('--sandbox', required=True, help='Spinnaker application, i.e. sbx-30')
args = parser.parse_args()

session=create_session(args.token, spinnaker_config)
pipeline_url = f"{spinnaker_config['api_base']}/pipelines/{args.sandbox}/{spinnaker_config['deploy-control-plane']}"
trigger_pipeline(session, spinnaker_config, pipeline_url, control_plane_data)
