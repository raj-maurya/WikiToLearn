#!/bin/bash
cd "$(dirname "$(readlink "$0" || printf %s "$0")")"

if [[ ! -f instance_config.conf ]] ; then
 {
  [[ -z "$W2L_INSTANCE_NAME" ]] && W2L_INSTANCE_NAME=w2l-dev
  echo "export W2L_INSTANCE_NAME=$W2L_INSTANCE_NAME"
  [[ -z "$W2L_BACKUP_ENABLED" ]] && W2L_BACKUP_ENABLED=0
  echo "export W2L_BACKUP_ENABLED=$W2L_BACKUP_ENABLED"
  [[ -z "$W2L_BACKUP_PATH" ]] && W2L_BACKUP_PATH=""
  echo "export W2L_BACKUP_PATH=$W2L_BACKUP_PATH"
  [[ -z "$W2L_DOCKER_MYSQL_DATA_PATH" ]] && W2L_DOCKER_MYSQL_DATA_PATH=$(pwd)"/mysql-data/"
  echo "export W2L_DOCKER_MYSQL_DATA_PATH=$W2L_DOCKER_MYSQL_DATA_PATH"
  [[ -z "$W2L_DOCKER_WEBSRV_LOG_PATH" ]] && W2L_DOCKER_WEBSRV_LOG_PATH=$(pwd)"/websrv-log/"
  echo "export W2L_DOCKER_WEBSRV_LOG_PATH=$W2L_DOCKER_WEBSRV_LOG_PATH"
  [[ -z "$W2L_DOCKER_MOUNT_DIRS" ]] && W2L_DOCKER_MOUNT_DIRS=0
  echo "export W2L_DOCKER_MOUNT_DIRS=$W2L_DOCKER_MOUNT_DIRS"

  echo "export W2L_DOCKER_MYSQL=mysql:5.6"
  echo "export W2L_DOCKER_MEMCACHED=memcached:1.4.24"
  echo "export W2L_DOCKER_MAILSRV=wikitolearn/mailsrv:0.3"
  echo "export W2L_DOCKER_OCG=wikitolearn/ocg:0.3.1"
  echo "export W2L_DOCKER_WEBSRV=wikitolearn/websrv:0.5"
  echo "export W2L_DOCKER_HAPROXY=wikitolearn/haproxy:0.1"
 } > instance_config.conf
 echo "Created default instance_config.conf file"
 exit 1
fi

chmod +x instance_config.conf
. ./instance_config.conf

[[ -z "$W2L_INIT_DB" ]] && export W2L_INIT_DB=0
[[ -z "$W2L_PRODUCTION" ]] && W2L_PRODUCTION=1

if [ "$W2L_BACKUP_ENABLED" == "1" ] ; then
 if [ ! -d "$W2L_BACKUP_PATH" ] ; then
  echo "Missing $W2L_BACKUP_PATH"
  exit 1
 fi
fi

which mysql &> /dev/null
if [[ $? -ne 0 ]] ; then
 echo "'mysql' command not found"
 exit 1
fi

test -d configs/ || mkdir -p configs/
test -d configs/secrets/ || mkdir -p configs/secrets/

export MORE_ARGS=" -e W2L_PRODUCTION="$W2L_PRODUCTION" "
if [[ "$W2L_PRODUCTION=" == "1" ]] ; then
        export MORE_ARGS=" --restart=always "$MORE_ARGS
fi

# run mamecached
docker ps | grep ${W2L_INSTANCE_NAME}-memcached &> /dev/null
if [[ $? -ne 0 ]] ; then
 docker ps -a | grep ${W2L_INSTANCE_NAME}-memcached &> /dev/null
 if [[ $? -eq 0 ]] ; then
  docker start ${W2L_INSTANCE_NAME}-memcached
 else
  docker run -ti $MORE_ARGS --hostname memcached.wikitolearn.org --name ${W2L_INSTANCE_NAME}-memcached -d $W2L_DOCKER_MEMCACHED
 fi
fi

# start mail server
docker ps | grep ${W2L_INSTANCE_NAME}-mailsrv &> /dev/null
if [[ $? -ne 0 ]] ; then
 docker ps -a | grep ${W2L_INSTANCE_NAME}-mailsrv &> /dev/null
 if [[ $? -eq 0 ]] ; then
  docker start ${W2L_INSTANCE_NAME}-mailsrv
 else
  docker run -ti $MORE_ARGS --hostname mail.wikitolearn.org --name ${W2L_INSTANCE_NAME}-mailsrv -d $W2L_DOCKER_MAILSRV
 fi
fi
MAIL_PASSWORD=$(date +%s | sha256sum | base64 | head -c 32 ; echo)
echo sysadmin:$MAIL_PASSWORD | docker exec -i ${W2L_INSTANCE_NAME}-mailsrv chpasswd

{
echo "Email Username: sysadmin"
echo "Email Password: "$MAIL_PASSWORD
} > configs/email.txt

# run mysql and init
docker ps | grep ${W2L_INSTANCE_NAME}-mysql &> /dev/null
if [[ $? -ne 0 ]] ; then
 docker ps -a | grep ${W2L_INSTANCE_NAME}-mysql &> /dev/null
 if [[ $? -eq 0 ]] ; then
  docker start ${W2L_INSTANCE_NAME}-mysql
 else
  test -d configs/secrets/ || mkdir -p configs/secrets/
  ROOT_PWD=$(echo $RANDOM$RANDOM$(date +%s) | sha256sum | base64 | head -c 32 )
  if [[ "$W2L_DOCKER_MOUNT_DIRS" == "1" ]] ; then
   MOUNT_DIR="-v '$W2L_DOCKER_MYSQL_DATA_PATH':/var/lib/mysql"
  else
   MOUNT_DIR=""
  fi
  docker run -ti $MORE_ARGS $MOUNT_DIR --hostname mysql.wikitolearn.org --name ${W2L_INSTANCE_NAME}-mysql -e MYSQL_ROOT_PASSWORD=$ROOT_PWD -d $W2L_DOCKER_MYSQL
  IP=$(docker inspect -f "{{ .NetworkSettings.IPAddress }}" ${W2L_INSTANCE_NAME}-mysql)
  echo "[client]" > configs/my.cnf
  echo "user=root" >> configs/my.cnf
  echo "password=$ROOT_PWD" >> configs/my.cnf

  echo "Attesa mysql onlnie..."
  {
  while ! mysql --defaults-file=configs/my.cnf -h $IP -e "SHOW DATABASES" ; do
   sleep 1
  done
  } &> /dev/null

  {
   echo "CREATE DATABASE IF NOT EXISTS dewikitolearn;"
   echo "CREATE DATABASE IF NOT EXISTS enwikitolearn;"
   echo "CREATE DATABASE IF NOT EXISTS eswikitolearn;"
   echo "CREATE DATABASE IF NOT EXISTS frwikitolearn;"
   echo "CREATE DATABASE IF NOT EXISTS itwikitolearn;"
   echo "CREATE DATABASE IF NOT EXISTS ptwikitolearn;"
   echo "CREATE DATABASE IF NOT EXISTS svwikitolearn;"
   echo "CREATE DATABASE IF NOT EXISTS metawikitolearn;"
   echo "CREATE DATABASE IF NOT EXISTS poolwikitolearn;"
   echo "CREATE DATABASE IF NOT EXISTS sharedwikitolearn;"
  } | mysql --defaults-file=configs/my.cnf -h $IP

  mysql --defaults-file=configs/my.cnf -h $IP -e "show databases like '%wiki%';" | grep wikitolearn | while read db; do
   pass=$(echo $RANDOM$RANDOM$(date +%s) | sha256sum | base64 | head -c 32)
   user=${db::-11}
   {
    echo "GRANT ALL PRIVILEGES ON * . * TO '"$user"'@'172.17.%' IDENTIFIED BY '"$pass"';"
   } | mysql --defaults-file=configs/my.cnf -h $IP

   {
    echo "<?php"
    echo "\$wgDBuser='"$user"';"
    echo "\$wgDBpassword='"$pass"';"
    echo "\$wgDBname='"$db"';"
    echo "?>"
   } > configs/secrets/$db.php

  done
 fi
fi

# run ocg docker
docker ps | grep ${W2L_INSTANCE_NAME}-ocg &> /dev/null
if [[ $? -ne 0 ]] ; then
 docker ps -a | grep ${W2L_INSTANCE_NAME}-ocg &> /dev/null
 if [[ $? -eq 0 ]] ; then
  docker start ${W2L_INSTANCE_NAME}-ocg
 else
  docker run -ti $MORE_ARGS --hostname ocg.wikitolearn.org --name ${W2L_INSTANCE_NAME}-ocg -d $W2L_DOCKER_OCG
 fi
fi

# run websrv docker linked to other
docker ps | grep ${W2L_INSTANCE_NAME}-websrv &> /dev/null
if [[ $? -ne 0 ]] ; then
 docker ps -a | grep ${W2L_INSTANCE_NAME}-websrv &> /dev/null
 if [[ $? -eq 0 ]] ; then
  docker start ${W2L_INSTANCE_NAME}-websrv
 else
  if [ ! -f configs/secrets/secrets.php ] ; then
   WG_SECRET_KEY=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 64 | head -n 1)
cat > configs/secrets/secrets.php << EOL
<?php

\$wgSecretKey = "$WG_SECRET_KEY";

\$virtualFactoryUser = "test";
\$virtualFactoryPass = "test";

?>
EOL
  fi

  if [[ "$W2L_DOCKER_MOUNT_DIRS" == "1" ]] ; then
   MOUNT_DIR="-v '$W2L_DOCKER_WEBSRV_LOG_PATH':/var/log/apache2"
  else
   MOUNT_DIR=""
  fi

  docker run -ti $MORE_ARGS $MOUNT_DIR --hostname websrv.wikitolearn.org \
   -v $(readlink -f $(dirname $(readlink -f $0))"/.."):/srv/WikiToLearn --name ${W2L_INSTANCE_NAME}-websrv \
   -e UID=$(id -u) \
   -e GID=$(id -g) \
   --privileged=true \
   --link ${W2L_INSTANCE_NAME}-mysql:mysql \
   --link ${W2L_INSTANCE_NAME}-memcached:memcached \
   --link ${W2L_INSTANCE_NAME}-ocg:ocg \
   --link ${W2L_INSTANCE_NAME}-mailsrv:mail \
   -d $W2L_DOCKER_WEBSRV
 fi
fi

rsync -a configs/secrets/ ../secrets/
