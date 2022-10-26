#!/usr/bin/env python3

# Simple script to update elixir ami info confluence page
# https://hub.internal.couchbase.com/confluence/pages/viewpage.action?spaceKey=CR&title=Elixir+AMI+Information
# page_id=108216078 is confluence internal page id

from atlassian import Confluence
import sys
import argparse
import logging
from datetime import datetime
from bs4 import BeautifulSoup
import re
from tabulate import tabulate

logging.basicConfig(format='%(asctime)s:%(levelname)s:%(message)s',
                    stream=sys.stderr, level=logging.INFO)

page_id = 108216078

# Create a https session


def create_session(url, uid, passwd):
    session = Confluence(
        url=url,
        username=uid,
        password=passwd)
    return session


def get_table_data(table):
    table_data = []
    for row in table('tr'):
        row_data = []
        for td in row("th") + row('td'):
            td_check = td.find('a')
            if td_check is not None:
                link = td.a
                row_data.append(link)
            else:
                row_data.append(td.text)
        table_data.append(row_data)
    return table_data


def construct_confluence_content(tables):
    data=''
    for product, rows in tables.items():
        data += f'<h1>{product}</h1>'
        data += tabulate(rows, tablefmt = 'unsafehtml', headers='firstrow')
    return data


# Main

parser = argparse.ArgumentParser()
parser.add_argument('--userid', required=True, help='Confluence user name.')
parser.add_argument('--password', required=True,
                    help='Confluence user password.')
parser.add_argument('--ami_name', required=True, help='AMI name.')
parser.add_argument('--test_result', required=True,
                    help='Validation test result.')
parser.add_argument('--test_link', required=True,
                    help='URL to validation job.')
args = parser.parse_args()
ami_entry = {}
tables = {}
now = datetime.now()

confluence_url = "https://hub.internal.couchbase.com/confluence"
changelog_url_base = "http://changelog.build.couchbase.com/"
builddb_api_base = "http://dbapi.build.couchbase.com:8000/v1/products"

ami_entry['date'] = now.strftime("%m/%d/%Y")
ami_entry['name'] = args.ami_name
if args.test_result == 'SUCCESS':
    ami_entry['status'] = 'Available'
else:
    ami_entry['status'] = ''
ami_entry['test_result'] = args.test_result
ami_entry['test_link'] = args.test_link

[product, version, bld_num] = list(
    filter(None, re.split(r'-([0-9.]+)', args.ami_name)))
previous_bld_num = str(int(bld_num) - 1)
if 'server' in product:
    product = 'couchbase-server'
    ami_entry['changelog'] = f'{changelog_url_base}?product=couchbase-server&amp;fromVersion={version}&amp;fromBuild={previous_bld_num}&amp;toVersion={version}&amp;toBuild={bld_num}'
else:
    ami_entry['changelog'] = f'{changelog_url_base}?product={product}&amp;fromVersion={version}&amp;fromBuild={previous_bld_num}&amp;toVersion={version}&amp;toBuild={bld_num}'

# Create confluence session
confluence = create_session(confluence_url, args.userid, args.password)

# Get current page content
# python module will automatically increase the version, no need to extract and pass version info
content = confluence.get_page_by_id(page_id, expand="title,body.storage")

[server_table, dn_table, dapi_table] = BeautifulSoup(
    content["body"]["storage"]["value"], features="lxml")("table")
tables['couchbase-server'] = get_table_data(server_table)
tables['direct-nebula'] = get_table_data(dn_table)
tables['couchbase-data-api'] = get_table_data(dapi_table)
tables[product].insert(1, [ami_entry['name'], f'<a href=\"{ami_entry["changelog"]}\">changes from {previous_bld_num}</a>',
                       ami_entry['test_result'], f'<a href=\"{ami_entry["test_link"]}\">qe jenkins link</a>', ami_entry['status'], ami_entry['date']])

confluence_data = construct_confluence_content(tables)

# Update page
confluence.update_page(page_id, content["title"], confluence_data,
                       parent_id=None, type="page", representation="storage", minor_edit=False)
