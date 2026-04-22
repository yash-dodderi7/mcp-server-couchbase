#!/usr/bin/env python3

SUMMARY_FIELDS = ('candidates', 'deleted', 'skipped', 'failed')


def initialize_summary(cloud_providers):
    '''
    Initialize summary counters for selected cloud providers.
    '''
    return {
        provider: {
            'candidates': 0,
            'deleted': 0,
            'failed': 0,
            'skipped': 0
        }
        for provider in cloud_providers
    }


def update_summary_counts(summary, provider, result):
    '''
    Update summary counters for one deletion result.
    '''
    summary[provider][result] += 1


def merge_summary_counts(summary, provider, delta_counts):
    '''
    Merge delta counts into the summary for a provider.
    '''
    for field in SUMMARY_FIELDS:
        summary[provider][field] += delta_counts.get(field, 0)
