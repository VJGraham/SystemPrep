#!/usr/bin/env bash
set -ex

exec > >(logger -i -t "stage_pip_packages" -s 2> /dev/console) 2>&1

BUCKETNAME=${1:-systemprep-repo}

GET_PIP="https://bootstrap.pypa.io/get-pip.py"

PYPI_DEPS=( 
    "awscli"
    "boto"
    "pip2pi"
    "s3cmd"
)

# Temporarily suppress rsyslog rate limiting
if [[ -e /etc/rsyslog.conf ]]; then
    echo "Temporarily disabling rsyslog rate limiting"
    RSYSLOGFLAG=1
    # Replace or append the $SystemLogRateLimitInterval parameter
    grep -q '^$SystemLogRateLimitInterval' /etc/rsyslog.conf && \
        sed -i.bak -e \
        "s/^$SystemLogRateLimitInterval.*/$SystemLogRateLimitInterval 0/" \
        /etc/rsyslog.conf || \
        sed -i.bak "$ a\$SystemLogRateLimitInterval 0" /etc/rsyslog.conf
    echo "Restarting rsyslog..."
    service rsyslog restart
fi
# Temporarily suppress journald rate limiting
if [[ -e /etc/systemd/journald.conf ]]; then
    echo "Temporarily disabling journald rate limiting"
    JOURNALDFLAG=1
    # Replace or append the RateLimitInterval parameter
    grep -q '^RateLimitInterval' /etc/systemd/journald.conf && \
        sed -i.bak -e \
        "s/^RateLimitInterval.*/RateLimitInterval=0/" \
        /etc/rsyslog.conf || \
        sed -i.bak "$ a\RateLimitInterval=0" /etc/systemd/journald.conf
    echo "Restarting systemd-journald..."
    systemctl restart systemd-journald.service
fi

# Make sure the certificates have been updated
yum -y upgrade ca-certificates

# Establish variables
PYPI_REPO=$(echo ~/repo/pypi)
PYPI_PACKAGES="${PYPI_REPO}/packages"
PYPI_INSTALLER="${PYPI_REPO}/get-pip.py"
PYPI_BUCKET="${BUCKETNAME}/pypi"

# Make directories
mkdir -p "${PYPI_PACKAGES}"

# Install pip
curl $GET_PIP -o ${PYPI_INSTALLER}
python "${PYPI_INSTALLER}"
hash pip 2> /dev/null || PATH="${PATH}:/usr/local/bin"  # Make sure pip is in path

# Install pip2pi
pip install pip2pi

# Use pip2pi to download pip packages and create the index
for pkg in "${PYPI_DEPS[@]}"; do
    pip2pi $PYPI_PACKAGES $pkg
done

# Install s3cmd
pip install --upgrade s3cmd
hash s3cmd 2> /dev/null || PATH="${PATH}:/usr/local/bin"  # Make sure s3cmd is in path

# Sync the pip installer to S3
s3cmd sync "${PYPI_INSTALLER}" s3://${PYPI_BUCKET}/
# Sync the packages and index to S3
s3cmd sync "${PYPI_PACKAGES}/simple/" "s3://${PYPI_BUCKET}/packages/" --follow-symlinks

# Restore prior rsyslog config
if [[ -n "${RSYSLOGFLAG}" ]]; then
    # Sleep to let the logger catch up with the output of the python script...
    sleep 5
    echo "Re-storing previous rsyslog configuration"
    mv -f /etc/rsyslog.conf.bak /etc/rsyslog.conf
    echo "Restarting rsyslog..."
    service rsyslog restart
fi
# Restore prior journald config
if [[ -n "${JOURNALDFLAG}" ]]; then
    # Sleep to let the logger catch up with the output of the python script...
    sleep 5
    echo "Re-storing previous journald configuration"
    mv -f /etc/systemd/journald.conf.bak /etc/systemd/journald.conf
    echo "Restarting systemd-journald..."
    systemctl restart systemd-journald.service
fi

echo "Finished staging the packages!"
