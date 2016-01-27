#!/bin/bash

# This file will be run exactly one time after the docker containers
# are up and running.

CWD="$( 
  cd "$(dirname "$(readlink "$0" || printf %s "$0")")"
  pwd -P 
)"

if [[ "$1" == "--init-db" ]] ; then
    W2L_INIT_DB=1
fi


cd $CWD;

if [[ ! -e secrets/itwikitolearn.php ]]; then
    echo "I can't find secrets!!! (at least, secrets/itwikifm.php)"
    echo "Please copy the secrets in $CWD/secrets and try again."
    exit 1;
fi;

# if [[ -e init.lockfile ]]; then
#     echo "You have already called this script."
#     echo "If you really want to init again, please remove $CWD/init.lockfile"
#     exit 1;
# else
#     touch $CWD/init.lockfile
# fi;

$CWD/init-symlinks.sh
test -d $CWD/mediawiki/images/tmp || mkdir -p $CWD/mediawiki/images/tmp

cd $CWD/mediawiki/extensions/Math/texvccheck/; make; cd -

cd $CWD/mediawiki; composer install --no-dev; composer update --prefer-source; cd -;

cd $CWD/extensions/SyntaxHighlight_GeSHi/ ; composer install; cd -;

if [[ "$W2L_INIT_DB" == "1" ]] ; then
    $CWD/lang-foreach.sh sql.php --debug --conf $CWD/mediawiki/LocalSettings.php $CWD/empty-wikifm.sql
    WIKI=it.wikitolearn.org php $CWD/mediawiki/maintenance/sql.php --debug --conf SharedLocalSettings.php $CWD/sharedwikifm.sql
fi

# For every language, update the database
$CWD/lang-foreach.sh update.php --conf=$CWD/mediawiki/LocalSettings.php --quick --doShared


if [[ "$W2L_INIT_DB" == "1" ]] ; then
    $CWD/lang-foreach.sh importDump.php $CWD/developer-dump.xml 
fi

