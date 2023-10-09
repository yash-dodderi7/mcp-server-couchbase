data "aws_caller_identity" "current" {}

# aws accounts:
#   264138468394: Capella sbx env (dbaas5)
#   516524556673: cb-qe
#   955582452726: cb-perf
#   239609595263: AWS dev


locals {
  repositories = ["capella-analytics", "goldfish-nebula"]
  aws_region             = "us-east-2"
  ecr_image_scan         = true
  couchbase_ips          = [
    "12.145.26.240/29",
    "12.235.169.89/30",
    "32.142.206.162/30",
    "64.124.71.194/29",
    "67.212.150.204/27"
  ]
  repo_pull_access_arns  = [
    "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root",
    "arn:aws:iam::264138468394:root",
    "arn:aws:iam::516524556673:root",
    "arn:aws:iam::239609595263:root",
    "arn:aws:iam::955582452726:root"
  ]
  repo_push_access_arns  = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
  repo_push_access_roles = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/cbd-4108_server_jenkins_worker"]
}
