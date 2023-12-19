#!/usr/bin/env python3

"""
Common utility functions
"""

from concurrent import futures
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


def concurrent_executor(func, workers, *args, **kwargs):
    with futures.ProcessPoolExecutor(max_workers=workers) as executor:
        futures = [
            executor.submit(
                func,
                *args,
                value) for value in kwargs['items']]
        for f in futures.as_completed(futures):
            if f.exception() is not None:
                sys.exit(f"{f.exception()}")


def concurrent_executor_two_lists(func, workers, *args, **kwargs):
    with futures.ProcessPoolExecutor(max_workers=workers) as executor:
        for i in kwargs['items1']:
            futures = [
                executor.submit(
                    func,
                    i,
                    *args,
                    j) for j in kwargs['items2']]
        for f in futures.as_completed(futures):
            if f.exception() is not None:
                sys.exit(f"{f.exception()}")


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
