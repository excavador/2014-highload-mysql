function init ()
{
  VERSION=${1}
  KIND=${2}
  BASE_DIR=/opt/mysql${VERSION}
  DATA_DIR=/var/${KIND}${VERSION}
  CONFIG_SOURCE=/mnt/nfs/${KIND}.${VERSION}.cnf
  CONFIG=${DATA_DIR}/my.cnf
  USER=mysql
  PASSWORD_FILE=${DATA_DIR}/password
  PASSWORD='bighuyata'
  MYSQLD=${BASE_DIR}/bin/mysqld
  MYSQL=${BASE_DIR}/bin/mysql
  LOG_DIR=${DATA_DIR}logs
  DUMP=/mnt/nfs/dump
  case ${VERSION} in
      5.5)
	  INSTALL_DB=${BASE_DIR}/scripts/mysql_install_db
	  ;;
      5.7)
	  INSTALL_DB=${BASE_DIR}/bin/mysql_install_db
	  ;;
  esac
}

function recreate_users ()
{
    userdel ${USER}                  || true
    groupdel ${USER}                 || true
    groupadd ${USER}                 || true
    useradd -r -m -g ${USER} ${USER} || true
    chmod goa+rx ${BASE_DIR}
    chmod goa+rx ${BASE_DIR}/bin
    export PATH=${BASE_DIR}/bin:${PATH}
    local p
    for p in ${DATA_DIR} ${LOG_DIR}; do
	rm -rf ${p}
	mkdir -p ${p}
	chown ${USER}:${USER} ${p}
	chmod goa+rwx ${p}
    done
}

function query ()
{
    case ${1} in
        "root")
            ${MYSQL} --defaults-file=${CONFIG} --user=root --password="${PASSWORD}"
            ;;
        *)
            ${MYSQL} --defaults-file=${CONFIG} --user=${1}
            ;;
    esac
}

function mysql_instance_init ()
{
    echo "Creating instance ${DATA_DIR}..."

    pushd ${DATA_DIR}
    ${INSTALL_DB} --basedir=${BASE_DIR} --datadir=${DATA_DIR} --user=${USER}
    popd
    cp ${CONFIG_SOURCE} ${CONFIG}
    chown ${USER}:${USER} ${CONFIG}


    case ${VERSION} in
	5.5)
	    ;;
	5.7)
	    echo "Export password to ${DATA_DIR}/password"
	    head -n 2 /root/.mysql_secret | tail -n 1 >  ${PASSWORD_FILE}
	    rm -f /root/.mysql_secret
	    ;;
    esac
}


function mysql_change_password ()
{
    case ${VERSION} in
	5.5)
	    until ${MYSQL} --defaults-file=${CONFIG} --user=root -e "SET PASSWORD=PASSWORD('${PASSWORD}')" ; do
		sleep 5;
	    done	    
	    ;;
	5.7)
	    until ${MYSQL} --defaults-file=${CONFIG} --connect-expired-password --user=root --password="$(cat ${PASSWORD_FILE})" -e "SET PASSWORD=PASSWORD('${PASSWORD}')" ; do
		sleep 5;
	    done
	    ;;
    esac
}


function sysbench_run ()
{
    local ACTION=${1}
    /usr/bin/sysbench --num-threads=16 --max-requests=1000000 --max-time=300 --test=oltp --db-driver=mysql --mysql-host=10.40.0.200 --mysql-user=sysbench --mysql-db=sbtest --mysql-user=sysbench --oltp-test-mode=complex --oltp-table-size=1000000 ${ACTION}
}

function server_run ()
{
    su mysql -c "export PATH=${BASE_DIR}/bin:${PATH}; nohup ${BASE_DIR}/bin/mysqld --defaults-file=${CONFIG}" &
}

function mysql_create_user_sysbench ()
{
echo "CREATE USER 'sysbench'@'%';
GRANT ALL ON *.* TO 'sysbench'@'%';
FLUSH PRIVILEGES;" | query root
}

function mysql_create_user_repl ()
{
echo "Create replication user on master"
echo "CREATE USER 'repl'@'%';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%';
FLUSH PRIVILEGES;" | query root
}

function mysql_create_db_sysbench ()
{
echo "Creating sysbenct test database"
echo "CREATE DATABASE sbtest;" | query root
}

function mysql_dump_create ()
{
  echo "Creating dump"
  echo "FLUSH TABLES WITH READ LOCK;" | query root
  ${BASE_DIR}/bin/mysqldump --socket=/tmp/master.${VERSION}.socket --user=root --password=${PASSWORD} --all-databases --master-data > ${DUMP}
  MASTER_INFO=$(echo "SHOW MASTER STATUS;" | query root | tail -n 1 | awk '{print $1"\t"$2 }')
  MASTER_LOG=$(echo $MASTER_INFO | awk '{ print $1 }')
  MASTER_POS=$(echo $MASTER_INFO | awk '{ print $2 }')
  echo "MASTER_LOG=${MASTER_LOG}
MASTER_POS=${MASTER_POS}" > /mnt/nfs/master.coords
  echo "UNLOCK TABLES;" | query root
}

function mysql_dump_apply ()
{
  echo "Applying dump"
  source /mnt/nfs/master.coords
  echo "STOP SLAVE;" | query root
  cat ${DUMP} | query root
  case ${VERSION} in 
      5.5)
	  CHANGE_MASTER_TO="CHANGE MASTER TO MASTER_HOST='10.40.0.200', MASTER_PORT=3306, MASTER_USER='repl', MASTER_LOG_FILE='${MASTER_LOG}', MASTER_LOG_POS=${MASTER_POS};"	
	  ;;
      5.7)
	  CHANGE_MASTER_TO="CHANGE MASTER TO MASTER_HOST='10.40.0.200', MASTER_PORT=3306, MASTER_USER='repl', MASTER_LOG_FILE='${MASTER_LOG}', MASTER_LOG_POS=${MASTER_POS}, MASTER_BIND='';"
	  ;;
  esac
  echo ${CHANGE_MASTER_TO} | query root
  echo "START SLAVE;" | query root
}
