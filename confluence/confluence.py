#!/usr/bin/env python3
from atlassian import Confluence
import requests
import json
import sys
import argparse
import logging


logging.basicConfig(format='%(asctime)s:%(levelname)s:%(message)s', stream=sys.stderr, level=logging.INFO)

# Create a https session
def create_session(url, uid, passwd):
    session = Confluence(
        url=url,
        username=uid,
        password=passwd)
    return session

# Main
# Simple script to update elixir ami info confluence page
# https://hub.internal.couchbase.com/confluence/pages/viewpage.action?spaceKey=CR&title=Elixir+AMI+Information
# page_id=108216078 is confluence internal page id

parser=argparse.ArgumentParser()
parser.add_argument('--userid', required=True, help='Confluence User Name.')
parser.add_argument('--password', required=True, help='Confluence User Password.')
args=parser.parse_args()

confluence_url="https://hub.internal.couchbase.com/confluence"
builddb_api_base="http://dbapi.build.couchbase.com:8000/v1/products"
page_id=108216078
products=json.load(open("products.json"))
data='<p><br/></p><table><colgroup><col/><col/></colgroup><tbody><tr><th style=\"text-align: center;\">Service</th><th style=\"text-align: center;\">Latest AMI</th></tr>'

for product in products.keys():
    url=f'{builddb_api_base}/{product}/releases/{products[product]["release"]}/versions/{products[product]["version"]}/builds?filter=last_cloud_ami'
    response=requests.get(url)
    response.raise_for_status()
    bld_num=response.json()["build_num"]
    if product == "couchbase-server":
        products[product]["amis"]=f'couchbase-serverless_server-{products[product]["version"]}-{bld_num}, couchbase-serverless_backup-{products[product]["version"]}-{bld_num}'
    else:
        products[product]["amis"]=f'{product}-{products[product]["version"]}-{bld_num}'
    data=f'{data}<tr><td>{product}</td><td>{products[product]["amis"]}</td></tr>'

data=f'{data}</tbody></table><p><br /></p><p><br /></p><pre class=\"language-none\"><code class=\"language-none\" style=\"text-align: left;\"><br /><br /><br /></code></pre>'

# Create confluence session
confluence=create_session(confluence_url, args.userid, args.password)

# Get current page content
# python module will automatically increase the version, no need to extract and pass version info
content=confluence.get_page_by_id(page_id, expand="title")

# Update page
confluence.update_page(page_id, content["title"], data, parent_id=None, type="page", representation="storage", minor_edit=False)
