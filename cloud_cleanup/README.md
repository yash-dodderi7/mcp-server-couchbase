# Cloud Image Cleanup

This folder contains scripts for cleaning up unused resources in AWS, Azure, and GCP

There are two main entrypoints: `tenant_cleanup.sh` and `remove_images.py`

## tenant_cleanup.sh
`tenant_cleanup.sh` is used by https://server.jenkins.couchbase.com/view/couchbase-cloud-ami/job/tenant_cleanup
This is called by QE pipelines after cloud testing to ensure leftover resources are removed.

## run_image_cleanup.py
`run_image_cleanup.py` deletes images that are no longer within the retention policy period.

#### Prerequisites
- ensure ~/.aws/credentials contains appropriate profile(s)

#### Quick Start
```
export AWS_PROFILE=<sandbox|stage profile name>
cd cloud_cleanup
uv sync --locked
uv run --frozen python run_image_cleanup.py --dryrun --environment sandbox

```

#### CLI Options
```
--environment        sandbox | stage      (default: sandbox)
--cloud-providers    aws gcp azure        (default: aws gcp azure)
--retention-days     INT                  (default: 60)
--dryrun                                  preview only, no delete
--debug                                   verbose logging
```
