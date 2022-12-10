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
            exit -1
        fi
    done
}

# Set AWS config in a custom location
function init_aws_config {
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
            *) echo "Usage: $0 -p <profile name> -i <AWS Access Key ID> -k <AWS Secret Access Key> -w <AWS custom config dir>"
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
