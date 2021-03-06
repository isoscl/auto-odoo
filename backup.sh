#!/bin/bash

set -feuxo pipefail
IFS=

cd $(dirname $0)
. variables

date_string=$(date '+%F-%T' | sed s/:/-/g)

/usr/local/bin/docker-compose pull

if [[ -d backup ]]; then
    mv backup backup-leftover-$date_string
fi

mkdir backup
exec >  >(tee backup/backup.sh.output) 2>&1
echo $date_string

# Add /usr/local/bin to path since it doesn't seem to be present by default when running as a cron job
export PATH=/usr/local/bin:$PATH

# docker-compose calculates the project name by taking the name of the directory and doing some munging like
# removing hyphens.  Then the global volume names are the project name + underscore + the volume name as
# specified in docker-compose.yml.  Since I didn't test exactly how the munging works, to be safe the
# directory name should just be lowercase letters and hyphens.
volume_prefix=$(basename $(pwd) | sed s/-//g)

# systemd will restart the auto-odoo service if it dies because we do a manual docker-compose down, so
# we have to treat differently the case of a systemd managed environment and one that is not, and we do
# that with a convention about the directory name.  Possibly it would be better to just let docker-compose
# handle any restarting we want to do and not have systemd do any restarting.
if [[ $volume_prefix = odoodocker ]]; then
    systemctl stop auto-odoo
else
    docker-compose down
fi

docker ps

docker run --rm -v ${volume_prefix}_odoo-db-data:/source:ro  -v $(pwd)/backup:/target ubuntu cp -a /source /target/odoo-db-data
docker run --rm -v ${volume_prefix}_odoo-web-data:/source:ro -v $(pwd)/backup:/target ubuntu cp -a /source /target/odoo-web-data
docker run --rm -v ${volume_prefix}_nginx-logs:/source       -v $(pwd)/backup:/target ubuntu /bin/sh -c 'cp -a /source /target/nginx-logs && rm -f /source/*'
cp -a odoo.conf backup
cp -a .env backup

if [[ $volume_prefix = odoodocker ]]; then
    systemctl start auto-odoo
else
    docker-compose up -d
fi

exec > >(tee -a backup-end-trace) 2>&1

mkdir -p backups
tar cJf backups/${volume_prefix}-$date_string.txz backup
rm -rf backup

set +f
set +e
for f in backup-configs/*; do
    . $f
    scp -i $backup_server_ssh_key -P $backup_server_ssh_port backups/${volume_prefix}-$date_string.txz $backup_server_ssh_user@$backup_server:$backups_path
done
