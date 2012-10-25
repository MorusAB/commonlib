#!/bin/bash

# Installs a development environment for testing and developing
# FixaMinGata without touching or interfering with the beta branch.

# Configuration:

#  Who is running the servers?
FMS_USER=fms

#  Where is the repository for our beta server?
FMS_GIT_URL=https://github.com/MorusAB/fixmystreet.git

#  Web root, under which everything will be installed.
#  This is also the same level as where the beta is assumed
#+ to be installed.
WEB_ROOT=/var/www

#  Where is the beta server installed?
#  We will copy some static files etc from there
#+ until we know where to store them (GIT?)
BETA_INSTALL_DIR=${WEB_ROOT}/beta.fixamingata.se

#  The "gems" directory in beta. For now, we'll just
#+ copy the gems from beta to our dev area.
#  TODO: Find out where it actually comes from, and
#+ how we should handle this correctly in the future.

#  Where are the config files for our version of fms stored?
#  They need to be outside the git repository, so for now,
#+ we keep them in root's home.
CONFIG_FILES_DIR=/root/development/config-scripts/fixmystreet

#  The htpassword for "admin" (will be copied)
ADMIN_HTPASSWORD=${BETA_INSTALL_DIR}/admin-htpasswd

DEBUG=true

function debug(){
	$DEBUG && echo $1
	return 0
}

#  Set up the directories where we'll install this development
#+ area. Call this function with the full hostname for the
#+ development area.
function make_web_dirs(){
	site=$1
	declare -i status;
	status=0

	if [ -x ${WEB_ROOT}/${site} ]
	then
		debug "Fatal error in make_web_dirs,  ${WEB_ROOT}/${site} already exists."
		return 50
	fi
	# Directory for Document ROOT etc
	mkdir  ${WEB_ROOT}/${site} || status=1
	# A cache dir is needed for the fms server
	mkdir  ${WEB_ROOT}/${site}/cache || status=2
	# We'll log the nginx here
	mkdir  ${WEB_ROOT}/${site}/log || status=3
	chown -R ${FMS_USER}:  ${WEB_ROOT}/${site} || status=4
	if [ $status -ne 0 ]
	then
		debug "make_web_dirs failed with status $status"
	fi
	return $status
}

function copy_admin_htpasswd(){
	if [ ! -e $ADMIN_HTPASSWORD ]
	then
		debug "Warning, couldn't find htpassword file in $ADMIN_HTPASSWORD"
		return 1
	fi
	cp -a $ADMIN_HTPASSWORD $WEB_ROOT/$1
	return $?
}

function clone_fixmystreet(){
	cd ${WEB_ROOT}/$1
	su ${FMS_USER} -c "git clone --recursive ${FMS_GIT_URL}"
	if [ ! $? -eq 0 ]
	then
		debug "Fatal error: could not clone ${FMS_GIT_URL} in ${FMS_USER}"
		return 1
	fi
	return 0
}

# Exit script with an error message
function die(){
	echo $1
	exit 1
}
### Begin work ###

[ $# -eq 1 ] || die "Usage: $0 <sitename>"

HOST_NAME=$1

# First, create necessary directories in the web root
make_web_dirs $HOST_NAME
# This is fatal. Abort if failure.
if [ $? -eq 50 ]
then
	echo "Problem making web dirs. Aborting."
	exit 1
fi

# Use DEBUG=true if you want warnings on htpasswd copy.
# Not fatal (atm the file is empty anyway).
copy_admin_htpasswd $HOST_NAME

# Now, clone the fixmystreet (from our fork in our repo)
clone_fixmystreet $HOST_NAME || die "Could not clone git. Aborting."


