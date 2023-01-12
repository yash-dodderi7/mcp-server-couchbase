#!/usr/bin/env python3

# Simple script to update elixir ami info confluence page
# https://hub.internal.couchbase.com/confluence/pages/viewpage.action?spaceKey=CR&title=Elixir+AMI+Information
# page_id=108216078 is confluence internal page id

from atlassian import Confluence
import sys
import argparse
import logging
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


# Reconstruct confluence content with new data.
# Limit the number of table rows to 15 so that confluence page is not too long.

def construct_confluence_content(tables):
    data=''
    for product, rows in tables.items():
        data += f'<h1>{product}</h1>'
        data += tabulate(rows[:15], tablefmt = 'unsafehtml', headers='firstrow')
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
parser.add_argument('--note', required=False,
                    help='Optional notes, i.e. reason of test failures.')
args = parser.parse_args()
ami_entry = {}
tables = {}

confluence_url = "https://hub.internal.couchbase.com/confluence"
changelog_url_base = "http://changelog.build.couchbase.com/"
builddb_api_base = "http://dbapi.build.couchbase.com:8000/v1/products"

ami_entry['name'] = args.ami_name
ami_entry['note'] = args.note
ami_entry['test_result'] = args.test_result
ami_entry['test_link'] = args.test_link
ami_entry['changelog'] = ''

[product, version, bld_num] = list(
    filter(None, re.split(r'-([0-9.]+)', args.ami_name)))
if 'server' in product:
    product = 'couchbase-server'

# default previous_bld_num as bld_num-1
previous_bld_num=str(int(bld_num)-1)

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

for i in range (1, len(tables[product])):
    if tables[product][i][0].strip() != ami_entry['name'].strip():
        previous_ami=tables[product][i][0].strip()
        [prod_name, version, previous_bld_num] = list(
            filter(None, re.split(r'-([0-9.]+)', previous_ami)))
        ami_entry['changelog'] = f'{changelog_url_base}?product={product}&amp;fromVersion={version}&amp;fromBuild={previous_bld_num}&amp;toVersion={version}&amp;toBuild={bld_num}'
        break
tables[product].insert(1, [ami_entry['name'], f'<a href=\"{ami_entry["changelog"]}\">changes from {previous_bld_num}</a>',
                       ami_entry['test_result'], f'<a href=\"{ami_entry["test_link"]}\">qe jenkins link</a>', ami_entry['note']])

confluence_data = construct_confluence_content(tables)

# Update page
confluence.update_page(page_id, content["title"], confluence_data,
                       parent_id=None, type="page", representation="storage", minor_edit=False)
