#!/usr/bin/env bash
set -euo pipefail

# Set this variable to 'true' to publish on successful installation
: ${PUBLISH:=false}

LOCAL_PORT=8080
REMOTE_PORT=8080
GALAXY_URL="http://127.0.0.1:${LOCAL_PORT}"

# Set to 'centos:7' and set GALAXY_GIT_* below to use a clone
GALAXY_DOCKER_IMAGE='galaxy/galaxy-k8s:20.05'
# Disable if using a locally built image e.g. for debugging
GALAXY_DOCKER_IMAGE_PULL=true

GALAXY_TEMPLATE_DB_URL='https://raw.githubusercontent.com/davebx/galaxyproject-sqlite/master/20.01.sqlite'
GALAXY_TEMPLATE_DB="${GALAXY_TEMPLATE_DB_URL##*/}"

# Need to run dev until 0.10.4
EPHEMERIS="git+https://github.com/mvdbeek/ephemeris.git"

# Should be set by Jenkins, so the default here is for development
: ${GIT_COMMIT:=$(git rev-parse HEAD)}

# Set to true to perform everything on the Jenkins worker and copy results to the Stratum 0 for publish, instead of
# performing everything directly on the Stratum 0. Requires preinstallation/preconfiguration of CVMFS and for
# fuse-overlayfs to be installed on Jenkins workers.
USE_LOCAL_OVERLAYFS=true

#
# Development/debug options
#

# If $GALAXY_DOCKER_IMAGE is a CloudVE image, you can set this to a patch file in .ci/ that will be applied to Galaxy in
# the image before Galaxy is run
GALAXY_PATCH_FILE=

# If $GALAXY_DOCKER_IMAGE is centos*, you can set these to clone Galaxy at a specific revision and mount it in to the
# container. Not fully tested because I was essentially using this to bisect for the bug, but Martin figured out what
# the bug was before I finished. But everything up to starting Galaxy works.
GALAXY_GIT_REPO= #https://github.com/galaxyproject/galaxy.git/
GALAXY_GIT_HEAD= #963093448eb6d029d44aa627354d2e01761c8a7b
# Branch is only used if the depth is set
GALAXY_GIT_BRANCH= #release_19.09
GALAXY_GIT_DEPTH= #100

#
# Ensure that everything is defined for set -u
#

TOOL_YAMLS=()
REPO_USER=
REPO_STRATUM0=
CONDA_PATH=
INSTALL_DATABASE=
SHED_TOOL_CONFIG=
SHED_TOOL_DATA_TABLE_CONFIG=
SHED_DATA_MANAGER_CONFIG=
SSH_MASTER_SOCKET=
WORKDIR=
USER_UID="$(id -u)"
GALAXY_DATABASE_TMPDIR=
GALAXY_SOURCE_TMPDIR=
OVERLAYFS_MOUNT=

SSH_MASTER_UP=false
CVMFS_TRANSACTION_UP=false
GALAXY_CONTAINER_UP=false
LOCAL_CVMFS_MOUNTED=false

function trap_handler() {
    { set +x; } 2>/dev/null
    $GALAXY_CONTAINER_UP && stop_galaxy
    clean_preconfigured_container
    $LOCAL_CVMFS_MOUNTED && unmount_overlay
    # $LOCAL_OVERLAYFS_MOUNTED does not need to be checked here since if it's true, $LOCAL_CVMFS_MOUNTED must be true
    $CVMFS_TRANSACTION_UP && abort_transaction
    $SSH_MASTER_UP && stop_ssh_control
    return 0
}
trap "trap_handler" SIGTERM SIGINT ERR EXIT


function log() {
    [ -t 0 ] && echo -e '\033[1;32m#' "$@" '\033[0m' || echo '#' "$@"
}


function log_error() {
    [ -t 0 ] && echo -e '\033[0;31mERROR:' "$@" '\033[0m' || echo 'ERROR:' "$@"
}


function log_debug() {
    echo "####" "$@"
}


function log_exec() {
    local rc
    if $USE_LOCAL_OVERLAYFS && ! $SSH_MASTER_UP; then
        set -x
        eval "$@"
    else
        set -x
        "$@"
    fi
    { rc=$?; set +x; } 2>/dev/null
    return $rc
}


function log_exit_error() {
    log_error "$@"
    exit 1
}


function log_exit() {
    echo "$@"
    exit 0
}


function exec_on() {
    if $USE_LOCAL_OVERLAYFS && ! $SSH_MASTER_UP; then
        log_exec "$@"
    else
        log_exec ssh -S "$SSH_MASTER_SOCKET" -l "$REPO_USER" "$REPO_STRATUM0" -- "$@"
    fi
}


function copy_to() {
    local file="$1"
    if $USE_LOCAL_OVERLAYFS && ! $SSH_MASTER_UP; then
        log_exec cp "$file" "${WORKDIR}/${file##*}"
    else
        log_exec scp -o "ControlPath=$SSH_MASTER_SOCKET" "$file" "${REPO_USER}@${REPO_STRATUM0}:${WORKDIR}/${file##*/}"
    fi
}


function check_bot_command() {
    log 'Checking for Github PR Bot commands'
    log_debug "Value of \$ghprbCommentBody is: ${ghprbCommentBody:-UNSET}"
    case "${ghprbCommentBody:-UNSET}" in
        "@galaxybot deploy"*)
            PUBLISH=true
            ;;
    esac
    $PUBLISH && log_debug "Changes will be published" || log_debug "Test installation, changes will be discarded"
}


function load_repo_configs() {
    log 'Loading repository configs'
    . ./.ci/repos.conf
}


function detect_changes() {
    log 'Detecting changes to tool files...'
    log_exec git remote set-branches --add origin master
    log_exec git fetch origin
    COMMIT_RANGE=origin/master...

    log 'Change detection limited to toolset directories:'
    for d in "${!TOOLSET_REPOS[@]}"; do
        echo "${d}/"
    done

    TOOLSET= ;
    while read op path; do
        if [ -n "$TOOLSET" -a "$TOOLSET" != "${path%%/*}" ]; then
            log_exit_error "Changes to tools in multiple toolsets found: ${TOOLSET} != ${path%%/*}"
        elif [ -z "$TOOLSET" ]; then
            TOOLSET="${path%%/*}"
        fi
        case "${path##*.}" in
            lock)
                ;;
            *)
                continue
                ;;
        esac
        case "$op" in
            A|M)
                echo "$op $path"
                TOOL_YAMLS+=("${path}")
                ;;
        esac
    done < <(git diff --color=never --name-status "$COMMIT_RANGE" -- $(for d in "${!TOOLSET_REPOS[@]}"; do echo "${d}/"; done))

    log 'Change detection results:'
    declare -p TOOLSET TOOL_YAMLS

    [ ${#TOOL_YAMLS[@]} -gt 0 ] || log_exit 'No tool changes, terminating'

    log "Getting repo for toolset: ${TOOLSET}"
    # set -u will force exit here if $TOOLSET is invalid
    REPO="${TOOLSET_REPOS[$TOOLSET]}"
    declare -p REPO
}


function setup_ephemeris() {
    log "Setting up Ephemeris"
    log_exec python3 -m venv ephemeris
    # FIXME: temporary until Jenkins nodes are updated, new versions of venv properly default unset vars in activate
    set +u
    . ./ephemeris/bin/activate
    set -u
    log_exec pip install --upgrade pip wheel
    log_exec pip install --index-url https://wheels.galaxyproject.org/simple/ \
        --extra-index-url https://pypi.org/simple/ "${EPHEMERIS:=ephemeris}" #"${PLANEMO:=planemo}"
}


function patch_cloudve_galaxy() {
    [ -n "${GALAXY_PATCH_FILE:-}" ] || return 0
    log "Copying patch to Stratum 0"
    copy_to ".ci/${GALAXY_PATCH_FILE}"
    run_container_for_preconfigure
    log "Installing patch"
    exec_on docker exec --user root "$PRECONFIGURE_CONTAINER_NAME" apt-get -q update
    exec_on docker exec --user root -e DEBIAN_FRONTEND=noninteractive "$PRECONFIGURE_CONTAINER_NAME" apt-get install -y patch
    log "Patching Galaxy"
    exec_on docker exec --workdir /galaxy/server "$PRECONFIGURE_CONTAINER_NAME" patch -p1 -i "/work/$GALAXY_PATCH_FILE"
    commit_preconfigured_container
}


function prep_for_galaxy_run() {
    # Sets globals $GALAXY_DATABASE_TMPDIR $WORKDIR
    log "Copying configs to Stratum 0"
    WORKDIR=$(exec_on mktemp -d -t usegalaxy-tools.work.XXXXXX)
    log_exec curl -o ".ci/${GALAXY_TEMPLATE_DB}" "$GALAXY_TEMPLATE_DB_URL"
    copy_to ".ci/${GALAXY_TEMPLATE_DB}"
    copy_to ".ci/tool_sheds_conf.xml"
    copy_to ".ci/condarc"
    GALAXY_DATABASE_TMPDIR=$(exec_on mktemp -d -t usegalaxy-tools.database.XXXXXX)
    exec_on mv "${WORKDIR}/${GALAXY_TEMPLATE_DB}" "${GALAXY_DATABASE_TMPDIR}"
    if $GALAXY_DOCKER_IMAGE_PULL; then
        log "Fetching latest Galaxy image"
        exec_on docker pull "$GALAXY_DOCKER_IMAGE"
    fi
}


function run_container_for_preconfigure() {
    # Sets globals $PRECONFIGURE_CONTAINER_NAME $PRECONFIGURED_IMAGE_NAME
    # $1 = true if should mount $GALAXY_SOURCE_TMPDIR
    local source_mount_flag=
    ${1:-false} && source_mount_flag="-v ${GALAXY_SOURCE_TMPDIR}:/galaxy/server"
    PRECONFIGURE_CONTAINER_NAME="${CONTAINER_NAME}-preconfigure"
    PRECONFIGURED_IMAGE_NAME="${PRECONFIGURE_CONTAINER_NAME}d"
    ORIGINAL_IMAGE_NAME="$GALAXY_DOCKER_IMAGE"
    log "Starting Galaxy container for preconfiguration on Stratum 0"
    exec_on docker run -d --name="$PRECONFIGURE_CONTAINER_NAME" \
        -v "${WORKDIR}/:/work/" \
        $source_mount_flag \
        -v "${GALAXY_DATABASE_TMPDIR}:/galaxy/server/database" \
        "$GALAXY_DOCKER_IMAGE" sleep infinity
    GALAXY_CONTAINER_UP=true
}


function commit_preconfigured_container() {
    log "Stopping and committing preconfigured container on Stratum 0"
    exec_on docker kill "$PRECONFIGURE_CONTAINER_NAME"
    GALAXY_CONTAINER_UP=false
    exec_on docker commit "$PRECONFIGURE_CONTAINER_NAME" "$PRECONFIGURED_IMAGE_NAME"
    GALAXY_DOCKER_IMAGE="$PRECONFIGURED_IMAGE_NAME"
}


function clean_preconfigured_container() {
    [ -n "${PRECONFIGURED_IMAGE_NAME:-}" ] || return 0
    exec_on docker kill "$PRECONFIGURE_CONTAINER_NAME" || true
    exec_on docker rm -v "$PRECONFIGURE_CONTAINER_NAME" || true
    exec_on docker rmi -f "$PRECONFIGURED_IMAGE_NAME" || true
}


# TODO: update for $USE_LOCAL_OVERLAYFS
function run_mounted_galaxy() {
    log "Cloning Galaxy"
    GALAXY_SOURCE_TMPDIR=$(exec_on mktemp -d -t usegalaxy-tools.source.XXXXXX)
    if [ -n "$GALAXY_GIT_BRANCH" -a -n "$GALAXY_GIT_DEPTH" ]; then
        log "Performing shallow clone of branch ${GALAXY_GIT_BRANCH} to depth ${GALAXY_GIT_DEPTH}"
        exec_on git clone --branch "$GALAXY_GIT_BRANCH" --depth "$GALAXY_GIT_DEPTH" "$GALAXY_GIT_REPO" "$GALAXY_SOURCE_TMPDIR"
    else
        exec_on git clone "$GALAXY_GIT_REPO" "$GALAXY_SOURCE_TMPDIR"
    fi
    log "Checking out Galaxy at ref ${GALAXY_GIT_HEAD}"
    # ancient git in EL7 doesn't have -C
    #exec_on git -C "$GALAXY_SOURCE_TMPDIR" checkout "$GALAXY_GIT_HEAD"
    exec_on "cd '$GALAXY_SOURCE_TMPDIR'; git checkout '$GALAXY_GIT_HEAD'"

    run_container_for_preconfigure true
    log "Installing packages"
    exec_on docker exec --user root "$PRECONFIGURE_CONTAINER_NAME" yum install -y python-virtualenv
    log "Installing dependencies"
    exec_on docker exec --user "$USER_UID" --workdir /galaxy/server "$PRECONFIGURE_CONTAINER_NAME" virtualenv .venv
    # $HOME is set for pip cache (~/.cache), which is needed to build wheels
    exec_on docker exec --user "$USER_UID" --workdir /galaxy/server -e "HOME=/galaxy/server/database" "$PRECONFIGURE_CONTAINER_NAME" ./.venv/bin/pip install --upgrade pip setuptools wheel
    exec_on docker exec --user "$USER_UID" --workdir /galaxy/server -e "HOME=/galaxy/server/database" "$PRECONFIGURE_CONTAINER_NAME" ./.venv/bin/pip install -r requirements.txt
    commit_preconfigured_container

    log "Updating database"
    exec_on docker run --rm --user "$USER_UID" --name="${CONTAINER_NAME}-setup" \
        -e "GALAXY_CONFIG_OVERRIDE_DATABASE_CONNECTION=sqlite:////galaxy/server/database/${GALAXY_TEMPLATE_DB}" \
        -v "${GALAXY_SOURCE_TMPDIR}:/galaxy/server" \
        -v "${GALAXY_DATABASE_TMPDIR}:/galaxy/server/database" \
        --workdir /galaxy/server \
        "$GALAXY_DOCKER_IMAGE" ./.venv/bin/python ./scripts/manage_db.py upgrade
    log "Starting Galaxy on Stratum 0"
    exec_on docker run -d -p 127.0.0.1:${REMOTE_PORT}:8080 --user "$USER_UID" --name="${CONTAINER_NAME}" \
        -e "GALAXY_CONFIG_OVERRIDE_DATABASE_CONNECTION=sqlite:////galaxy/server/database/${GALAXY_TEMPLATE_DB}" \
        -e "GALAXY_CONFIG_OVERRIDE_INTEGRATED_TOOL_PANEL_CONFIG=/tmp/integrated_tool_panel.xml" \
        -e "GALAXY_CONFIG_OVERRIDE_SHED_TOOL_CONFIG_FILE=${SHED_TOOL_CONFIG}" \
        -e "GALAXY_CONFIG_OVERRIDE_TOOL_SHEDS_CONFIG_FILE=/tool_sheds_conf.xml" \
        -e "GALAXY_CONFIG_OVERRIDE_SHED_TOOL_DATA_TABLE_CONFIG=${SHED_TOOL_DATA_TABLE_CONFIG}" \
        -e "GALAXY_CONFIG_OVERRIDE_SHED_DATA_MANAGER_CONFIG_FILE=${SHED_DATA_MANAGER_CONFIG}" \
        -e "GALAXY_CONFIG_TOOL_DATA_PATH=/tmp/tool-data" \
        -e "GALAXY_CONFIG_INSTALL_DATABASE_CONNECTION=sqlite:///${INSTALL_DATABASE}" \
        -e "GALAXY_CONFIG_MASTER_API_KEY=${API_KEY:=deadbeef}" \
        -e "GALAXY_CONFIG_CONDA_PREFIX=${CONDA_PATH}" \
        -v "${OVERLAYFS_MOUNT}:/cvmfs/${REPO}" \
        -v "${WORKDIR}/tool_sheds_conf.xml:/tool_sheds_conf.xml" \
        -v "${WORKDIR}/condarc:${CONDA_PATH}/.condarc" \
        -v "${GALAXY_SOURCE_TMPDIR}:/galaxy/server" \
        -v "${GALAXY_DATABASE_TMPDIR}:/galaxy/server/database" \
        --workdir /galaxy/server \
        "$GALAXY_DOCKER_IMAGE" ./.venv/bin/uwsgi --yaml config/galaxy.yml.sample
    GALAXY_CONTAINER_UP=true
}


function run_cloudve_galaxy() {
    patch_cloudve_galaxy
    log "Updating database"
    exec_on docker run --rm --user "$USER_UID" --name="${CONTAINER_NAME}-setup" \
        -e "GALAXY_CONFIG_OVERRIDE_DATABASE_CONNECTION=sqlite:////galaxy/server/database/${GALAXY_TEMPLATE_DB}" \
        -v "${GALAXY_DATABASE_TMPDIR}:/galaxy/server/database" \
        "$GALAXY_DOCKER_IMAGE" ./.venv/bin/python ./scripts/manage_db.py upgrade
    # we could just start the patch container and run Galaxy in it with `docker exec`, but then logs aren't captured
    log "Starting Galaxy on Stratum 0"
    exec_on docker run -d -p 127.0.0.1:${REMOTE_PORT}:8080 --user "$USER_UID" --name="${CONTAINER_NAME}" \
        -e "GALAXY_CONFIG_OVERRIDE_DATABASE_CONNECTION=sqlite:////galaxy/server/database/${GALAXY_TEMPLATE_DB}" \
        -e "GALAXY_CONFIG_OVERRIDE_INTEGRATED_TOOL_PANEL_CONFIG=/tmp/integrated_tool_panel.xml" \
        -e "GALAXY_CONFIG_OVERRIDE_SHED_TOOL_CONFIG_FILE=${SHED_TOOL_CONFIG}" \
        -e "GALAXY_CONFIG_OVERRIDE_TOOL_SHEDS_CONFIG_FILE=/tool_sheds_conf.xml" \
        -e "GALAXY_CONFIG_OVERRIDE_SHED_TOOL_DATA_TABLE_CONFIG=${SHED_TOOL_DATA_TABLE_CONFIG}" \
        -e "GALAXY_CONFIG_OVERRIDE_SHED_DATA_MANAGER_CONFIG_FILE=${SHED_DATA_MANAGER_CONFIG}" \
        -e "GALAXY_CONFIG_TOOL_DATA_PATH=/tmp/tool-data" \
        -e "GALAXY_CONFIG_INSTALL_DATABASE_CONNECTION=sqlite:///${INSTALL_DATABASE}" \
        -e "GALAXY_CONFIG_MASTER_API_KEY=${API_KEY:=deadbeef}" \
        -e "GALAXY_CONFIG_CONDA_PREFIX=${CONDA_PATH}" \
        -v "${OVERLAYFS_MOUNT}:/cvmfs/${REPO}" \
        -v "${WORKDIR}/tool_sheds_conf.xml:/tool_sheds_conf.xml" \
        -v "${WORKDIR}/condarc:${CONDA_PATH}/.condarc" \
        -v "${GALAXY_DATABASE_TMPDIR}:/galaxy/server/database" \
        "$GALAXY_DOCKER_IMAGE" ./.venv/bin/uwsgi --http :8080 \
            --virtualenv /galaxy/server/.venv --pythonpath /galaxy/server/lib \
            --master --offload-threads 2 --processes 1 --threads 4 --enable-threads \
            --buffer-size 16384 --thunder-lock --die-on-term --py-call-osafterfork \
            --module 'galaxy.webapps.galaxy.buildapp:uwsgi_app\(\)' \
            --hook-master-start '"unix_signal:2 gracefully_kill_them_all"' \
            --hook-master-start '"unix_signal:15 gracefully_kill_them_all"' \
            --static-map '/static/style=/galaxy/server/static/style/blue' \
            --static-map '/static=/galaxy/server/static' \
            --set 'galaxy_config_file=/galaxy/server/config/galaxy.yml' \
            --set 'galaxy_root=/galaxy/server'
        #"$GALAXY_DOCKER_IMAGE" ./.venv/bin/uwsgi --yaml config/galaxy.yml
        # TODO: double quoting above probably breaks non-local mode
    GALAXY_CONTAINER_UP=true
}


# TODO: update for $USE_LOCAL_OVERLAYFS
function run_bgruening_galaxy() {
    log "Copying additional configs to Stratum 0"
    copy_to ".ci/nginx.conf"
    log "Starting Galaxy on Stratum 0"
    exec_on docker run -d -p 127.0.0.1:${REMOTE_PORT}:80 --name="${CONTAINER_NAME}" \
        -e "GALAXY_CONFIG_INSTALL_DATABASE_CONNECTION=sqlite:///${INSTALL_DATABASE}" \
        -e "GALAXY_CONFIG_SHED_TOOL_CONFIG_FILE=${SHED_TOOL_CONFIG}" \
        -e "GALAXY_CONFIG_MASTER_API_KEY=${API_KEY:=deadbeef}" \
        -e "GALAXY_CONFIG_CONDA_PREFIX=${CONDA_PATH}" \
        -e "GALAXY_HANDLER_NUMPROCS=0" \
        -e "CONDARC=${CONDA_PATH}rc" \
        -v "${OVERLAYFS_MOUNT}:/cvmfs/${REPO}" \
        -v "${WORKDIR}/job_conf.xml:/job_conf.xml" \
        -v "${WORKDIR}/nginx.conf:/etc/nginx/nginx.conf" \
        -e "GALAXY_CONFIG_JOB_CONFIG_FILE=/job_conf.xml" \
        "$GALAXY_DOCKER_IMAGE"
    GALAXY_CONTAINER_UP=true
}


function run_galaxy() {
    prep_for_galaxy_run
    case "$GALAXY_DOCKER_IMAGE" in
        galaxy/galaxy*)
            run_cloudve_galaxy
            ;;
        bgruening/galaxy-stable*)
            run_bgruening_galaxy
            ;;
        centos*)
            run_mounted_galaxy
            ;;
        *)
            log_exit_error "Unknown Galaxy Docker image: ${GALAXY_DOCKER_IMAGE}"
            ;;
    esac
}


function stop_galaxy() {
    log "Stopping Galaxy on Stratum 0"
    # NOTE: docker rm -f exits 1 if the container does not exist
    exec_on docker kill "$CONTAINER_NAME" || true  # probably failed to start, don't prevent the rest of cleanup
    exec_on docker rm -v "$CONTAINER_NAME" || true
    [ -n "$GALAXY_DATABASE_TMPDIR" ] && exec_on rm -rf "$GALAXY_DATABASE_TMPDIR"
    [ -n "${GALAXY_SOURCE_TMPDIR:-}" ] && exec_on rm -rf "$GALAXY_SOURCE_TMPDIR"
    GALAXY_CONTAINER_UP=false
}


function wait_for_galaxy() {
    log "Waiting for Galaxy connection"
    log_exec galaxy-wait -v -g "$GALAXY_URL" --timeout 120 || {
        log_error "Timed out waiting for Galaxy"
        log_debug "contents of docker log";
        exec_on docker logs "$CONTAINER_NAME"
        # bgruening log paths
        #for f in /var/log/nginx/error.log /home/galaxy/logs/uwsgi.log; do
        #    log_debug "contents of ${f}";
        #    exec_on docker exec "$CONTAINER_NAME" cat $f;
        #done
        log_debug "response from ${GALAXY_URL}";
        curl "$GALAXY_URL";
        log_exit_error "Terminating build due to previous errors"
    }
}


function show_logs() {
    local lines=
    if [ -n "${1:-}" ]; then
        lines="--tail ${1:-}"
        log_debug "tail ${lines} of server log";
    else
        log_debug "contents of server log";
    fi
    exec_on docker logs $lines "$CONTAINER_NAME"
}


function install_tools() {
    local tool_yaml
    log "Installing tools"
    for tool_yaml in "${TOOL_YAMLS[@]}"; do
        log "Installing tools in ${tool_yaml}"
        log_exec shed-tools install -v -g "$GALAXY_URL" -a "$API_KEY" -t "$tool_yaml" || {
            log_error "Tool installation failed"
            show_logs
            log_exit_error "Terminating build due to previous errors"
        }
    done
}



function do_install_local() {
    run_galaxy
    wait_for_galaxy
    install_tools
    stop_galaxy
    clean_preconfigured_container
    if $PUBLISH; then
       echo TBA
    fi
}


function do_install_remote() {
    run_galaxy
    wait_for_galaxy
    install_tools
    stop_galaxy
    clean_preconfigured_container
}


function main() {
    check_bot_command
    load_repo_configs
    detect_changes
    setup_ephemeris
    if $USE_LOCAL_OVERLAYFS; then
        do_install_local
    else
        do_install_remote
    fi
    return 0
}


main
