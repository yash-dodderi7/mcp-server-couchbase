# General utility shell functions, useful for any script/product

# Provide a dummy "usage" command for clients that don't define it
type -t usage || usage() {
    exit 1
}

function chk_set {
    var=$1
    # ${!var} is a little-known bashism that says "expand $var and then
    # use that as a variable name and expand it"
    if [[ -z "${!var}" ]]; then
        echo "\$${var} must be set!"
        usage
    fi
}

function status() {
    echo "-- $@"
}

function warn() {
    echo "${FUNCNAME[1]}: $@" >&2
}

function error {
    echo "${FUNCNAME[1]}: $@" >&2
    exit 1
}

function chk_cmd {
    for cmd in $@; do
        command -v $cmd > /dev/null 2>&1 || {
            echo "ERROR: command '$cmd' not available!"
            exit 5
        }
    done
}

# Trigger remote jenkins job
function trigger_jenkins_job {
    while getopts n:t:u: opt; do
        case ${opt} in
            n) username=${OPTARG}
               ;;
            t) token=${OPTARG}
               ;;
            u) url=${OPTARG}
               ;;
            *) echo "Usage: $0 -n <user name> -t <personal access token or password> -u <jenkins job>"
               exit 1
               ;;
        esac
    done
    
    result=`curl --head -X POST --user $username:$token $url`
    queued_job_url=`echo "$result"|grep Location |awk '{print $2}' |tr -d '\r'`
    echo "Job Queue: $queued_job_url"
    count=0
    while ((count<=10)); do
        is_blocked=`curl --user $username:$token "$queued_job_url/api/json" |jq -r .blocked`
        if [[ "$is_blocked" == "false" ]]; then
            #Jenkins typically has a small delay when a job is moved from queue to start 
            sleep 10
            build_url=`curl --user $username:$token "$queued_job_url/api/json" |jq -r .executable.url`
            echo "build url: $build_url"
            break
        fi
        count=$((count+1))
        sleep 10
    done

    if ((count>10)); then
    	echo "Unable to kick off $url.  It is possible another run is in progress."
    	exit 99
    fi
}

# Check pid array for error
# The function waits for all processes to complete.
# If any process fails, it exits with error.
function check_pids {
    arr=("$@")
    echo "checking pids: ${arr[@]}"
    for pid in "${arr[@]}"; do
        wait ${pid}
        return_code="$?"
        if [[ ${return_code} != "0" ]]; then
            echo "One of the child processes failed.  Terminating..."
            echo "PID = ${pid}; return_code = ${return_code}"
            exit 1
        fi
    done
}

# Set AWS config in a custom location
function init_aws_config {
    OPTIND=1
    while getopts i:k:p:w: opt; do
        case ${opt} in
            i) aws_access_key_id=${OPTARG}
               ;;
            k) aws_secret_access_key=${OPTARG}
               ;;
            p) aws_profile=${OPTARG}
               ;;
            w) aws_custom_config_dir=${OPTARG}
               ;;
            *) echo "Usage: $0 -p <profile name> -i <AWS Access Key ID>"\
               "-k <AWS Secret Access Key> -w <AWS custom config dir>"
               exit 1
               ;;
        esac
    done
    for param in aws_access_key_id aws_secret_access_key aws_profile aws_custom_config_dir; do
        chk_set ${param}
    done
    rm -rf ${aws_custom_config_dir}
    mkdir ${aws_custom_config_dir}
    cat <<EOT >> ${aws_custom_config_dir}/credentials
[${aws_profile}]
aws_access_key_id     = ${aws_access_key_id}
aws_secret_access_key = ${aws_secret_access_key}
EOT

cat <<EOT >> ${aws_custom_config_dir}/config
[profile ${aws_profile}]
region=us-east-1
output=json
EOT

    export AWS_SHARED_CREDENTIALS_FILE=${aws_custom_config_dir}/credentials
    export AWS_CONFIG_FILE=${aws_custom_config_dir}/config
}

# Function to download a specific agent with a given SHA
function download_agent() {
    local agent=${1}  # Agent name (e.g., dp-backup, dp-agent)
    local sha=${2}    # SHA of the agent
    local profile=${3} # AWS Profile
    local bucket=${4} # AWS S3 bucket

    echo "Downloading ${agent}: ${sha}"
    aws s3 cp --quiet \
        s3://${bucket}/releases/${agent}/${cloud}/${sha}/linux-${dp_arch} \
        agents/${arch} \
        --recursive \
        --profile ${profile}
}

# Download dp-agent, dp-backup, and dp-observer
function download_agents {
    arch=${1}
    dp_arch=${2}
    cloud=${3}

    aws_profile="dbaas-prod-0001-temp"  # Defaults aws_profile to production
    s3_bucket="cbc-internal-release"    # Production's s3 bucket
    mkdir -p agents/${arch}

    # Always download observer from s3 bucket in prod account
    aws s3 cp --quiet \
        s3://${s3_bucket}/releases/dp-observer/latest . \
        --profile ${aws_profile}
    DP_OBSERVER_SHA=$(cat latest)
    download_agent "dp-observer" ${DP_OBSERVER_SHA} ${aws_profile} ${s3_bucket}

    # If DP_AGENT_SHA is not set, download the latest dp-agent and dp-backup.
    # Otherwise, download base on the specific SHA
    if [[ -z "${DP_AGENT_SHA}" ]]; then
        for agent in dp-backup dp-agent; do
            aws s3 cp --quiet \
                s3://${s3_bucket}/releases/${agent}/latest . \
                --profile ${aws_profile}
            export DP_AGENT_SHA=$(cat latest)
            download_agent ${agent} ${DP_AGENT_SHA} ${aws_profile} ${s3_bucket}
        done
    else
        for agent in dp-backup dp-agent; do
            download_agent ${agent} ${DP_AGENT_SHA} ${aws_profile} ${s3_bucket}
        done
    fi
}

# Determine the latest available Golang version based on an input version
# Identify Golang release first, then determine the latest stable version
# from https://go.dev/dl
function find_golang_version {
    input_version=${1}
    golang_release="$(cut -d "." -f 1 <<< "$input_version")"."$(cut -d "." -f 2 <<< "$input_version")"
    golang_version=$(curl -s https://go.dev/dl/?mode=json | \
                     jq -r ".[].version" | \
                     grep "${golang_release}" | \
                     sed "s/go//")
    if [[ -z "${golang_version}" ]]; then
        golang_version=$(curl -s "https://go.dev/dl/?mode=json&include=all" | \
                         jq -r ".[].version" | \
                         grep "${golang_release}" | \
                         head -1 | \
                         sed "s/go//")
    fi
    echo "${golang_version}"
}
