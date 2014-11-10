#!/bin/bash

set -eu

source /mnt/nfs/deploy.sh

init 5.5 slave
recreate_users
mysql_instance_init
sleep 5
server_run
sleep 5
mysql_change_password
mysql_create_user_sysbench
mysql_create_user_repl
mysql_create_db_sysbench
mysql_dump_apply
