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
CONFIG_FILE_FIXMYSTREET=general.yml

#  The htpassword for "admin" (will be copied)
ADMIN_HTPASSWORD=${BETA_INSTALL_DIR}/admin-htpasswd

DEBUG=true

HOSTNAME=$1

function debug(){
	$DEBUG && echo $1
	return 0
}

#  Set up the directories where we'll install this development
#+ area. Call this function with the full hostname for the
#+ development area.
function make_web_dirs(){
	declare -i status;
	status=0

	if [ -x ${WEB_ROOT}/${HOSTNAME} ]
	then
		debug "Fatal error in make_web_dirs,  ${WEB_ROOT}/${HOSTNAME} already exists."
		return 50
	fi
	# Directory for Document ROOT etc
	mkdir  ${WEB_ROOT}/${HOSTNAME} || status=1
	# A cache dir is needed for the fms server
	mkdir  ${WEB_ROOT}/${HOSTNAME}/cache || status=2
	# We'll log the nginx here
	mkdir  ${WEB_ROOT}/${HOSTNAME}/log || status=3
	chown -R ${FMS_USER}:  ${WEB_ROOT}/${HOSTNAME} || status=4
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
	cp -a $ADMIN_HTPASSWORD $WEB_ROOT/$HOSTNAME
	return $?
}

function clone_fixmystreet(){
	cd ${WEB_ROOT}/${HOSTNAME}
	su ${FMS_USER} -c "git clone --recursive ${FMS_GIT_URL}"
	if [ ! $? -eq 0 ]
	then
		debug "Fatal error: could not clone ${FMS_GIT_URL} in ${FMS_USER}"
		return 1
	fi
	return 0
}

#  We need to copy our config file, since only the template
#+ is in the repo.
#  TODO: generalize /fixmystreet/config into a variable? It will probably not
#+ change (famous last words).
function copy_config_file(){
	if [ ! -e ${CONFIG_FILES_DIR}/${CONFIG_FILE_FIXMYSTREET} ]
	then
		debug "Warning: no config file found in ${CONFIG_FILES_DIR}/${CONFIG_FILE_FIXMYSTREET}"
		return 1
	fi
	cp ${CONFIG_FILES_DIR}/${CONFIG_FILE_FIXMYSTREET} ${WEB_ROOT}/${HOSTNAME}/fixmystreet/conf/
	chown  ${FMS_USER}: ${WEB_ROOT}/${HOSTNAME}/fixmystreet/conf/${CONFIG_FILE_FIXMYSTREET}
	return $?
}

#  Compile the translation.
#  TODO: get the translation from Transifex
function compile_translations(){
	cd ${WEB_ROOT}/${HOSTNAME}/fixmystreet
	su ${FMS_USER} -c "commonlib/bin/gettext-makemo"
	return $?
}

#  Install the Ruby gems
#  Needs to be run as ${FMS_USER}.
function install_ruby_gems(){
	export WEB_ROOT="$WEB_ROOT"
	export HOSTNAME="$HOSTNAME"
	export -f debug
	export GEM_HOME="$WEB_ROOT/$HOSTNAME/gems"
	su fms -c "mkdir -p \"$GEM_HOME\""
	export GEM_PATH=
	export PATH="$GEM_HOME/bin:$PATH"

	debug "Installing gems (compass)..."
	su fms -c "gem install --no-ri --no-rdoc compass"

	# Use compass to generate the CSS, if it doesn't seem to already
	# exist:

	if [ ! -f $WEB_ROOT/$HOSTNAME/fixmystreet/web/cobrands/default/base.css ]
	then
		debug "Making css from gem..."
		cd $WEB_ROOT/$HOSTNAME/fixmystreet/
    		su fms -c "PATH=$GEM_HOME/bin:$PATH bin/make_css"
	fi
}

# Install perl libs
function install_perl_libs(){
	cd $WEB_ROOT/$HOSTNAME/fixmystreet
	su fms -c "bin/install_perl_modules"
}

# Exit script with an error message
function die(){
	echo $1
	exit 1
}
### Begin work ###

[ $# -eq 1 ] || die "Usage: $0 <hostname>"

# First, create necessary directories in the web root
debug "Creating directories in $WEB_ROOT..."
make_web_dirs
# This is fatal, could be someone else's dev area. Abort if failure.
if [ $? -eq 50 ] # Already exists
then
	echo "Problem making web dirs. Aborting."
	exit 1
fi

# Use DEBUG=true if you want warnings on htpasswd copy.
# Not fatal (atm the file is empty anyway).
debug "Copy htpassword file"
copy_admin_htpasswd

# Now, clone the fixmystreet (from our fork in our repo)
debug "Get system files from github"
clone_fixmystreet || die "Could not clone git. Aborting."

# We need a config file from our store
debug "Copy the config file"
copy_config_file || echo "Warning: config file not copied"

# Next, compile our translation .po file
debug "Compile translations"
compile_translations || echo "Warning, could not compile translations"

# Next, install gems and from that, create css
debug "Installing gems and CSS..."
## Can this be done in a nicer way?
#export -f install_ruby_gems
install_ruby_gems

# Next, install perl libs (in local)
debug "Installing perl libs..."
install_perl_libs 
