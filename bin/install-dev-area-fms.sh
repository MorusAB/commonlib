#!/bin/bash
set -x
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

#  Beta hostname
BETA_HOSTNAME=beta.fixamingata.se

#  Where is the beta server installed?
#  We will copy some static files etc from there
#+ until we know where to store them (GIT?)
BETA_INSTALL_DIR=${WEB_ROOT}/${BETA_HOSTNAME}

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

#############
# Arguments #
#############
HOSTNAME=$1
FAST_CGI_PORT=$2
NGINX_PORT=$3

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

	if [ -e ${WEB_ROOT}/${HOSTNAME} ]
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

#  Get the latest translation from Transifex
function get_translation(){
	/root/development/commonlib/bin/get_latest_translation.sh $HOSTNAME
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
	#  We need to pass the --compass flag to sass
	#+ for unknown reason, to make the css compile.
	#  I've added a version of the make_css file
	#+ to our config-files directory, and we'll
	#+ have to use that (since it has the --compass flag).
	cp $CONFIG_FILES_DIR/make_css ${WEB_ROOT}/${HOSTNAME}/fixmystreet/bin/
	chown ${FMS_USER}:${FMS_USER} ${WEB_ROOT}/${HOSTNAME}/fixmystreet/bin/make_css
	
	export WEB_ROOT="$WEB_ROOT"
	export HOSTNAME="$HOSTNAME"
	export -f debug
	export GEM_HOME="$WEB_ROOT/$HOSTNAME/gems"
	su fms -c "mkdir -p \"$GEM_HOME\""
	export GEM_PATH=
	export PATH="$GEM_HOME/bin:$PATH"
	export SASS_PATH="$GEM_HOME:$GEM_HOME/gems/compass-0.12.2/frameworks/compass/stylesheets:$GEM_HOME/gems/compass-0.12.2/frameworks/blueprint/stylesheets"
	debug "Installing gems (compass)..."
	su fms -c "gem install --no-ri --no-rdoc compass"

	# Use compass to generate the CSS, if it doesn't seem to already
	# exist:

	if [ ! -f $WEB_ROOT/$HOSTNAME/fixmystreet/web/cobrands/default/base.css ]
	then
		debug "Making css from gem..."
		cd $WEB_ROOT/$HOSTNAME/fixmystreet/
		#  I don't know why I have to pass the PATH below
		#+ but it doesn't work without that.
    		su fms -c "PATH=$GEM_HOME/bin::$PATH bin/make_css"
	fi
}

# Install perl libs
function install_perl_libs(){
	cd $WEB_ROOT/$HOSTNAME/fixmystreet
	su fms -c "bin/install_perl_modules"
}

#  Make the start-stop script for init.d/
#+ so that we can start and stop the fixmystreet
#+ server for this development area.
#  Note that Rikard changed the stop function
#+ to use fuse, which therefore is a required
#  command.
function make_start-stop_script(){
	#  fixmystreet-${HOSTNAME%%.*} takes only the cname,
	#+ e.g. dev.fixamingata.se -> dev
	#+ in this case producing the file
	#+ /etc/init.d/fixmystreet-dev
	TARGET="/etc/init.d/fixmystreet-${HOSTNAME%%.*}"
	if [ -e "$TARGET" ]
	then
		debug "WARNING: $TARGET already exists"
		return 1
	fi
cat > /etc/init.d/fixmystreet-${HOSTNAME%%.*} <<EOF
#! /bin/sh
### BEGIN INIT INFO
# Provides:          application-catalyst-fixmystreet
# Required-Start:    \$local_fs \$network
# Required-Stop:     \$local_fs \$network
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Starts the FastCGI app server for the "FixMyStreet" site
# Description:       The FastCGI application server for the "FixMyStreet" site
### END INIT INFO

# This example sysvinit script is based on the helpful example here:
# http://richard.wallman.org.uk/2010/02/howto-deploy-a-catalyst-application-using-fastcgi-and-nginx/

PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
SITE_HOME=${WEB_ROOT}/${HOSTNAME}
NAME=fixmystreet
DESC="FixMyStreet app server"
USER=fms

echo \$DAEMON
test -f \$DAEMON || exit 0

set -e

start_daemon() {
  su -l -c "cd \$SITE_HOME/fixmystreet && bin/cron-wrapper web/fixmystreet_app_fastcgi.cgi -d -l :$FAST_CGI_PORT -n 2" \$USER
}

stop_daemon() {
  #pkill -f perl-fcgi -u \$USER || true
  PID=\`fuser $FAST_CGI_PORT/tcp 2> /dev/null|cut -d ':' -f2|awk '{print \$1;}'\`
  test -z "\$PID" && return 1
  ps \$PID|grep perl-fcgi-pm 2>&1 >/dev/null && kill \$PID
}

case "\$1" in
 start)
 start_daemon
 ;;
 stop)
 stop_daemon
 ;;
 reload|restart|force-reload)
 stop_daemon
 sleep 5
 start_daemon
 ;;
 *)
 N=/etc/init.d/\$NAME
 echo "Usage: \$N {start|stop|reload|restart|force-reload}" >&2
 exit 1
 ;;
esac

exit 0

EOF
	# make it -rwxr-xr-x
	chmod 755 $TARGET 
	#  Make sure we have fuse installed, it is used
	#+ for the stop function.
	which fuser || debug "Warning: No fuse command found!"
	debug "Starting fixmystreet-${HOSTNAME%%.*}"
	/etc/init.d/fixmystreet-${HOSTNAME%%.*} start
	return $?
}

#  Make the site file for nginx so that we can
#+ access this development area via http.
function make_nginx_config(){
	TARGET=/etc/nginx/sites-enabled/$HOSTNAME
	if [ -f "$TARGET" ]
	then
		debug "Warning: $TARGET already exists. Config file not created."
		return 1
	fi
	cat > $TARGET <<EOF
# An example configuration for running FixMyStreet under nginx.  You
# will also need to set up the FixMyStreet Catalyst FastCGI backend.
# An example sysvinit script to help with this is shown given in the file
# sysvinit-catalyst-fastcgi.example in this directory.
#
# See our installation help at http://code.fixmystreet.com/

server {

    access_log /var/www/beta.fixamingata.se/logs/dev1-access.log;
    error_log /var/www/beta.fixamingata.se/logs/dev1-error.log;
    # $HOSTNAME listens to $NGINX_PORT
    listen $NGINX_PORT;
    server_name $HOSTNAME;
    root ${WEB_ROOT}/${HOSTNAME}/fixmystreet/web;
    error_page 503 /down.html;

    # Make sure that Javascript and CSS are compressed.  (HTML is
    # already compressed under the default configuration of the nginx
    # package.)

    gzip on;
    gzip_disable "msie6";
    gzip_types application/javascript application/x-javascript text/css;

    # Set a long expiry time for CSS and Javascript, and prevent
    # the mangling of Javascript by proxies:

    location ~ \.css$ {
        expires 10y;
    }

    location ~ \.js$ {
        add_header Cache-Control no-transform;
        expires 10y;
        try_files \$uri @catalyst;
    }

    # These rewrite rules are ported from the Apache configuration in
    # conf/httpd.conf

    rewrite ^/rss/council/([0-9]+)$  /rss/reports/\$1 permanent;
    rewrite ^/report$                /reports        permanent;
    rewrite '^/{/rss/(.*)}$'         /rss/\$1         permanent;
    rewrite '^/reports/{/rss/(.*)}$' /rss/\$1         permanent;
    rewrite ^/alerts/?$              /alert          permanent;

    location /mapit {
        proxy_pass http://dev.fixamingata.se:8005/;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    location /admin {
        auth_basic "FixMyStreet admin interface";
        auth_basic_user_file /var/www/beta.fixamingata.se/admin-htpasswd;
        try_files \$uri @catalyst;
    }

    location / {
        if (-f $document_root/down.html) {
            return 503;
        }
        try_files \$uri @catalyst;
    }

    location /down.html {
        internal;
    }

    location @catalyst {
        include /etc/nginx/fastcgi_params;
        fastcgi_param PATH_INFO \$fastcgi_script_name;
        fastcgi_param SCRIPT_NAME '';
	# Set dev1's fastcgi to $FAST_CGI_PORT
        fastcgi_pass 127.0.0.1:${FAST_CGI_PORT};
    }
}
EOF
	/etc/init.d/nginx restart
	return $?	
}

# Exit script with an error message
function die(){
	echo -e "$1"
	exit 1
}
###### Begin work ######
debug "Start"

# Sanity checks
[ $# -eq 3 ] || die "Usage: $0 <hostname> <cgi-port> <http-port>\ne.g $0 dev1.fixamingata.se 9001 8001"
if grep $2 /etc/init.d/fixmystreet* &> /dev/null
then
	echo "The following ports are already taken for fast-cgi:"
	bad_ports=$(grep bin/cron-wrapper /etc/init.d/fixmystreet*|awk '{print $12}'|cut -d ':' -f2|sort -n)
	for p in $bad_ports
	do
		echo $p
	done
	die "$2 is already used as a port for fast-cgi. Try $((++p))"
fi 
if grep $3 /etc/nginx/sites-enabled/* &> /dev/null
then
	echo "The following ports are already taken for HTTP:"
	bad_ports=$(grep "listen " /etc/nginx/sites-enabled/*|grep -v \#|awk '{print $3}'|cut -d ';' -f1|sort -n)
	for p in $bad_ports
	do
		echo $p
	done
	die "$3 is already used as a port for nginx. Try $((++p))"
fi
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

# Get the latest translation
get_translation

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

# We need config files:
# init-script
make_start-stop_script

# Site config for nginx:
make_nginx_config
