#!/bin/bash
# Copyright (c) 2017, 2018 Oracle and/or its affiliates. All rights reserved.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301 USA

set -e

function get_full_filename() {
        FILEPATH=$1
        PACKAGE_STRING=$2
        FILENAME=$(curl -s $FILEPATH/ | grep $PACKAGE_STRING | sed -e 's/.*href=\"//i' -e 's/\".*//')
        if [ -z "$FILENAME" ]; then
            echo &< "Unable to locate package for $PACKAGE_STRING. Aborting"
            exit 1
        fi
	COUNT=$(echo $FILENAME | tr " " "\n" | wc -l)
        if [ $COUNT -gt 1 ]; then
            echo &<2 "Found multiple file names for package $PACKAGE_STRING. Aborting"
            exit 1
        fi
	echo $FILENAME
}

# This script will simply use sed to replace placeholder variables in the
# files in template/ with version-specific variants.

. VERSION

if [ -z "$1" ]; then
  REPO=https://repo.mysql.com
else
  REPO=$1
fi

# 33060 is the default port for the mysqlx plugin, new to 5.7
declare -A PORTS
PORTS["5.5"]="3306"
PORTS["5.6"]="3306"
PORTS["5.7"]="3306 33060"
PORTS["8.0"]="3306 33060"

declare -A PASSWORDSET
PASSWORDSET["5.5"]="SET PASSWORD FOR 'root'@'localhost'=PASSWORD('\${MYSQL_ROOT_PASSWORD}');"
PASSWORDSET["5.6"]=${PASSWORDSET["5.5"]}
PASSWORDSET["5.7"]="ALTER USER 'root'@'localhost' IDENTIFIED BY '\${MYSQL_ROOT_PASSWORD}';"
PASSWORDSET["8.0"]=${PASSWORDSET["5.7"]}

declare -A DATABASE_INIT
DATABASE_INIT["5.5"]="mysql_install_db --user=mysql --datadir=\"\$DATADIR\" --rpm"
DATABASE_INIT["5.6"]="mysql_install_db --user=mysql --datadir=\"\$DATADIR\" --rpm --keep-my-cnf"
DATABASE_INIT["5.7"]="\"\$@\" --initialize-insecure"
DATABASE_INIT["8.0"]="\"\$@\" --initialize-insecure"

# 5.7+ has the --daemonize flag, which makes the process fork and then exit when
# the server is ready, removing the need for a fragile wait loop
declare -A INIT_STARTUP
INIT_STARTUP["5.5"]="\"\$@\" --skip-networking --socket=\"\$SOCKET\" \&"
INIT_STARTUP["5.6"]="\"\$@\" --skip-networking --socket=\"\$SOCKET\" \&"
INIT_STARTUP["5.7"]="\"\$@\" --daemonize --skip-networking --socket=\"\$SOCKET\""
INIT_STARTUP["8.0"]="\"\$@\" --daemonize --skip-networking --socket=\"\$SOCKET\""

declare -A STARTUP_WAIT
STARTUP_WAIT["5.5"]="\"yes\""
STARTUP_WAIT["5.6"]="\"yes\""
STARTUP_WAIT["5.7"]="\"\""
STARTUP_WAIT["8.0"]="\"\""

# The option to set a user as expired, (forcing a password change before
# any other action can be taken) was added in 5.6
declare -A EXPIRE_SUPPORT
EXPIRE_SUPPORT["5.5"]="\"\""
EXPIRE_SUPPORT["5.6"]="\"yes\""
EXPIRE_SUPPORT["5.7"]="\"yes\""
EXPIRE_SUPPORT["8.0"]="\"yes\""

# sed is for https://bugs.mysql.com/bug.php?id=20545
declare -A TZINFO_WORKAROUND
TZINFO_WORKAROUND["5.5"]="sed 's/Local time zone must be set--see zic manual page/FCTY/' | "
TZINFO_WORKAROUND["5.6"]="sed 's/Local time zone must be set--see zic manual page/FCTY/' | "
TZINFO_WORKAROUND["5.7"]=""
TZINFO_WORKAROUND["8.0"]=""

# Logging to console (stderr) makes server log available with the «docker logs command»
declare -A DEFAULT_LOG
DEFAULT_LOG["5.5"]=""
DEFAULT_LOG["5.6"]=""
DEFAULT_LOG["5.7"]=""
DEFAULT_LOG["8.0"]="console"


for VERSION in "${!MYSQL_SHELL_VERSIONS[@]}"
do
  # Dockerfiles
  MYSQL_SERVER_REPOPATH=yum/mysql-$VERSION-community/docker/x86_64
  MYSQL_CLUSTER_PACKAGE_URL=$REPO/$MYSQL_SERVER_REPOPATH/$(get_full_filename $REPO/$MYSQL_SERVER_REPOPATH mysql-community-server-minimal-${MYSQL_SERVER_VERSIONS[${VERSION}]})
  sed 's#%%MYSQL_SERVER_PACKAGE_URL%%#'"$MYSQL_CLUSTER_PACKAGE_URL"'#g' template/Dockerfile > tmpfile

  if [[ ! -z ${MYSQL_SHELL_VERSIONS[${VERSION}]} ]]; then
    MYSQL_SHELL_REPOPATH=yum/mysql-tools-community/el/7/x86_64
    MYSQL_SHELL_PACKAGE_URL=$REPO/$MYSQL_SHELL_REPOPATH/$(get_full_filename $REPO/$MYSQL_SHELL_REPOPATH mysql-shell-${MYSQL_SHELL_VERSIONS[${VERSION}]})
    sed -i 's#%%MYSQL_SHELL_PACKAGE_URL%%#'"$MYSQL_SHELL_PACKAGE_URL"'#g' tmpfile
  else
    sed -i 's#%%MYSQL_SHELL_PACKAGE_URL%%#'""'#g' tmpfile
  fi

  sed -i 's/%%PORTS%%/'"${PORTS[${VERSION}]}"'/g' tmpfile
  mv tmpfile ${VERSION}/Dockerfile

  # Dockerfile_spec.rb
  if [ ! -d "${VERSION}/inspec" ]; then
    mkdir "${VERSION}/inspec"
  fi
  if [ "${VERSION}" == "5.7" ] || [ "${VERSION}" == "8.0" ]; then
    sed 's#%%MYSQL_SERVER_PACKAGE_VERSION%%#'"${MYSQL_SERVER_VERSIONS[${VERSION}]}"'#g' template/control.rb > tmpFile
    sed -i 's#%%MYSQL_SHELL_PACKAGE_VERSION%%#'"${MYSQL_SHELL_VERSIONS[${VERSION}]}"'#g' tmpFile
    mv tmpFile "${VERSION}/inspec/control.rb"
  else
    sed 's#%%MYSQL_SERVER_PACKAGE_VERSION%%#'"${MYSQL_SERVER_VERSIONS[${VERSION}]}"'#g' template/control_pre57.rb > tmpFile
    mv tmpFile "${VERSION}/inspec/control.rb"
  fi

  # Entrypoint
  sed 's#%%PASSWORDSET%%#'"${PASSWORDSET[${VERSION}]}"'#g' template/docker-entrypoint.sh > tmpfile
  sed -i 's#%%DATABASE_INIT%%#'"${DATABASE_INIT[${VERSION}]}"'#g' tmpfile
  sed -i 's#%%EXPIRE_SUPPORT%%#'"${EXPIRE_SUPPORT[${VERSION}]}"'#g' tmpfile
  sed -i 's#%%SED_TZINFO%%#'"${TZINFO_WORKAROUND[${VERSION}]}"'#g' tmpfile
  sed -i 's#%%INIT_STARTUP%%#'"${INIT_STARTUP[${VERSION}]}"'#g' tmpfile
  sed -i 's#%%STARTUP_WAIT%%#'"${STARTUP_WAIT[${VERSION}]}"'#g' tmpfile
  sed -i 's#%%FULL_SERVER_VERSION%%#'"${FULL_SERVER_VERSIONS[${VERSION}]}"'#g' tmpfile
  sed -i 's#%%DEFAULT_LOG%%#'"${DEFAULT_LOG[${VERSION}]}"'#g' tmpfile
  mv tmpfile ${VERSION}/docker-entrypoint.sh
  chmod +x ${VERSION}/docker-entrypoint.sh

  # Healthcheck
  cp template/healthcheck.sh ${VERSION}/
  chmod +x ${VERSION}/healthcheck.sh
done
