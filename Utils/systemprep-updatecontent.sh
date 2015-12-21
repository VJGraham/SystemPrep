#!/bin/sh
#
# Description:
#   This script is intended to help an administrator update the content
#   managed by the SystemPrep capability. It will use the SystemPrep
#   BootStrap script to download new content and configure it to be available
#   on the system.
#
# Usage:
#   See `systemprep-updatecontent.sh -h`.
#
#################################################################
__SCRIPTPATH=$(readlink -f ${0})
__SCRIPTDIR=$(dirname ${__SCRIPTPATH})
__SCRIPTNAME=$(basename ${__SCRIPTPATH})


log()
{
    logger -i -t "${__SCRIPTNAME}" -s -- "$1" 2> /dev/console
    echo "$1"
}  # ----------  end of function log  ----------


die()
{
    [ -n "$1" ] && log "$1" >&2
    log "ERROR: ${__SCRIPTNAME} failed"'!' >&2
    exit 1
}  # ----------  end of function die  ----------


print_usage()
{
    cat << EOT

  This script will update the content managed by the systemprep capability.
  Parameters may be passed as short-form or long-form arguments, or they may
  be exported as environment variables. Command line arguments take precedence
  over environment variables.

  Usage: ${__SCRIPTNAME} [required] [options]

  Required:
  -e|--environment|\$SYSTEMPREP_ENV
      The environment in which the system is operating. This is parameter
      accepts a tri-state value:
        "true":   Attempt to detect the environment automatically. WARNING:
                  Currently this value is non-functional.
        "false":  Do not set an environment. Any content that is dependent on
                  the environment will not be available to this system.
        <string>: Set the environment to the value of "<string>". Note that
                  uppercase values will be converted to lowercase.

  Options:
  -h|--help
      Display this message.
  -u|--bootstrap-url|\$SYSTEMPREP_BOOTSTRAP_URL
      URL of the systemprep bootstrapper.

EOT
}  # ----------  end of function print_usage  ----------


lower()
{
    echo "${1}" | tr '[:upper:]' '[:lower:]'
}  # ----------  end of function lower  ----------


# Define default values
SYSTEMPREP_ENV="${SYSTEMPREP_ENV}"
BOOTSTRAP_URL="${SYSTEMPREP_BOOTSTRAP_URL:-https://systemprep.s3.amazonaws.com/BootStrapScripts/SystemPrep-Bootstrap--Linux.sh}"


# Parse command-line parameters
SHORTOPTS="he:u:"
LONGOPTS="help,environment:,bootstrap-url:"
ARGS=$(getopt \
    --options "${SHORTOPTS}" \
    --longoptions "${LONGOPTS}" \
    --name "${__SCRIPTNAME}" \
    -- "$@")

if [ $? -ne 0 ]
then
    # Bad arguments.
    print_usage
    exit 1
fi

eval set -- "${ARGS}"

while [ true ]
do
    # When adding options to the case statement, be sure to update SHORTOPTS
    # and LONGOPTS
    case "${1}" in
        -h|--help)
            print_usage
            exit 0
            ;;
        -e|--environment)
            shift
            SYSTEMPREP_ENV=$(lower "${1}")
            ;;
        -u|--bootstrap-url)
            shift
            BOOTSTRAP_URL="${1}"
            ;;
        --)
            shift
            break
            ;;
        *)
            print_usage
            die "ERROR: Unhandled option parsing error."
            ;;
    esac
    shift
done


# Validate parameters
if [ -z "${SYSTEMPREP_ENV}" ]
then
    print_usage
    die "ERROR: Mandatory parameter (-e|--environment) was not specified."
fi


# Check dependencies
if [ $(command -v curl > /dev/null 2>&1)$? -ne 0 ]
then
    die "ERROR: Could not find 'curl'."
fi


# Execute
log "Using bootstrapper to update systemprep content..."
curl -L --retry 3 --silent --show-error "${BOOTSTRAP_URL}" | \
    sed "{
        s/^ENTENV=.*/ENTENV=${SYSTEMPREP_ENV}/
        s/NoReboot=.*/NoReboot=True\"/
        s/SaltStates=.*/SaltStates=None\"/
    }" | \
    bash || \
    die "ERROR: systemprep bootstrapper failed."

log "Sucessfully updated systemprep content."
