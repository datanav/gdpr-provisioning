#!/usr/bin/env bash
# vim: ai ts=2 sw=2 et sts=2 ft=sh

apt install -y jq
REPO_USER="$(jq -r '.docker_username' < /etc/sesam-agent/config.json)"
REPO_PASS="$(jq -r '.docker_password' < /etc/sesam-agent/config.json)"
docker login --username "$REPO_USER" --password "$REPO_PASS"

set -e

if [ -z "$SUBSCRIPTION_ID" ]; then
  SUBSCRIPTION_ID="$(grep -v 'SESAM' < /sesam/node-00/data/license.key | base64 -d | jq -r '.payload' | base64 -d | jq -r '._id')"
  if [ -z "$SUBSCRIPTION_ID" ]; then
    echo No SUBSCRIPTION_ID environment variable was defined, and I failed to get the subscription-id from the license file!
    exit -1
  fi
fi

DATABROWSER_DOCKER_IMAGE_TAG=${DATABROWSER_DOCKER_IMAGE_TAG:-prototype-encrypted-fields}
SOLR_DOCKER_IMAGE_TAG=${SOLR_DOCKER_IMAGE_TAG:-gdpr}
APPLIANCE_ID=$(< /etc/sesam-agent/id)
HOST_IP_ADDRESS="$(ip route get 1 | awk '{print $NF;exit}')"

bs_docker() {
  docker pull sesam/sesam-solr:"$SOLR_DOCKER_IMAGE_TAG"
  docker pull sesam/sesam-redis:latest
  docker pull sesam/databrowser:"$DATABROWSER_DOCKER_IMAGE_TAG"
  docker pull v2tec/watchtower:latest
}

bs_watchtower() {
  docker run -d \
  --name watchtower \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /root/.docker/config.json:/config.json \
  v2tec/watchtower redis solr databrowser
}

bs_solr() {
  mkdir -p /srv/data/solr/{data,conf}
  chown 1000:1000 /srv/data/solr/data

  docker run -d --restart always --name solr \
    --network=sesam \
    -u "1000" \
    -p 8983:8983 \
    -v /srv/data/solr/data:/sesam/data/solr-data \
    index.docker.io/sesam/sesam-solr:"$SOLR_DOCKER_IMAGE_TAG"

  docker network connect microservices solr
}

bs_redis() {
  mkdir -p /srv/data/redis/{data,conf,logs,temp}
  chown -R 200:200 /srv/data/redis

  envsubst < redis.conf > /srv/data/redis/conf/redis.conf

  docker run -d --restart always --name redis \
  --network=sesam \
  -p 6379:6379 \
  -v /srv/data/redis/data:/sesam/data:rw \
  -v /srv/data/redis/conf:/sesam/conf:rw \
  -v /srv/data/redis/logs:/sesam/logs:rw \
  -v /srv/data/redis/temp:/sesam/temp:rw \
  index.docker.io/sesam/sesam-redis:latest

  docker network connect microservices redis
}

bs_databrowser() {
  mkdir -p /srv/data/databrowser/{data,conf,logs}
  chown -R 200:200 /srv/data/databrowser
  envsubst < production.ini > /srv/data/databrowser/conf/production.ini

  envsubst < databrowser.ini > /srv/data/databrowser/conf/databrowser.ini
  cp resultitemrenderers.yaml /srv/data/databrowser/conf/resultitemrenderers.yaml

  docker run -d --restart always --name databrowser \
    --network=sesam \
    -p 6543:6543 \
    -v /srv/data/databrowser/conf:/sesam/conf \
    -v /srv/data/databrowser/logs:/sesam/logs \
    -v /srv/data/databrowser/data:/sesam/data \
    -e SESAM_CONF=/sesam/conf \
    -e SESAM_LOGS=/sesam/logs \
    -e SESAM_DATA=/sesam/data \
    index.docker.io/sesam/databrowser:"$DATABROWSER_DOCKER_IMAGE_TAG" pserve --reload /sesam/conf/production.ini

  docker network connect microservices databrowser
}

bs_consul_service() {
if [ -d "/srv/data/consul/conf/" ]; then
cat > /srv/data/consul/conf/databrowser.json << SCRPT_EOF
{
  "services": [
    {
      "name": "sesam-databrowser:$SUBSCRIPTION_ID",
      "tags": [
        "traefik.tags=sesam",
        "traefik.frontend.rule=Host:gdpr-${SUBSCRIPTION_ID:0:8}.sesam.cloud",
        "traefik.frontend.entryPoints=https,http",
        "appliance_id: $APPLIANCE_ID",
        "subscription_id: $SUBSCRIPTION_ID"
      ],
      "address": "$HOST_IP_ADDRESS",
      "port": 6543
    }  
  ]
}
SCRPT_EOF
fi  
}

echo I will use the following settings:
echo SUBSCRIPTION_ID: \""$SUBSCRIPTION_ID"\".
echo DATABROWSER_DOCKER_IMAGE_TAG: \""$DATABROWSER_DOCKER_IMAGE_TAG"\".
echo SOLR_DOCKER_IMAGE_TAG: \""$SOLR_DOCKER_IMAGE_TAG"\".

read -p "Do these settings look ok? (y/n)" -n 1 -r
echo    # (optional) move to a new line
if [[ $REPLY =~ ^[Yy]$ ]]; then
  echo "Starting to create/update the various docker containers..."
  set -x

  if [ "$SKIP_PULL" != "1" ]; then
    bs_docker
  fi

  set +e
  docker stop solr redis databrowser watchtower | xargs -r docker rm
  set -e

  bs_solr
  bs_redis
  bs_databrowser
  bs_watchtower
  bs_consul_service

  echo Provisioning finished successfully.
else
  echo "Ok, exiting without doing any changes."
fi
