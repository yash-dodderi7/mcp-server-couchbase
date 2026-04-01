#!/usr/bin/env python3

"""
Common utility functions
"""

import concurrent.futures
from dotenv import load_dotenv
import json
import logging
import os
import subprocess
import sys

logger = logging.getLogger()
logger.setLevel(logging.INFO)
console_handler = logging.StreamHandler(stream=sys.stdout)
logger.addHandler(console_handler)


def concurrent_executor(func, items, workers=8):
    items = list(items)
    if not items:
        return []

    max_workers = min(len(items), workers)
    with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as executor:
        futures = {executor.submit(func, item): item for item in items}
        results = []
        failures = []
        for future in concurrent.futures.as_completed(futures):
            item = futures[future]
            try:
                results.append(future.result())
            except Exception as err:
                logger.error(f"Failed for {item}: {err}")
                failures.append((item, err))

    if failures:
        func_name = getattr(func, "__name__", str(func))
        failed_details = ", ".join([f"{item}: {err}" for item, err in failures])
        logger.error(
            f"Concurrent jobs for {func_name} finished with errors "
            f"(succeeded={len(results)}, failed={len(failures)}): {failed_details}"
        )

    return results


def run_cmd(cmd):
    with subprocess.Popen(cmd, stdout=subprocess.PIPE) as proc:
        for line in proc.stdout:
            logger.info(f"{line}")
    if proc.returncode != 0:
        sys.exit(f"{cmd} returns {proc.returncode}")


def load_packer_env(env_file, *args):
    dict = {}
    load_dotenv(dotenv_path=env_file, override=True)
    for arg in args:
        dict[arg] = os.getenv(f'PKR_VAR_{arg}')
    return dict


def get_env_vars(cloud, env):
    '''
    load environments.json
    return a dictionary of variables by cloud environment
    '''
    script_dir = os.path.dirname(os.path.realpath(__file__))
    environments = json.loads(open(f'{script_dir}/environments.json').read())
    if env not in environments:
        sys.exit(f"{env} is not defined in environments.json")
    if cloud not in environments[env]:
        sys.exit(f"{cloud} is not defined in environments.json")
    return environments[env][cloud]
