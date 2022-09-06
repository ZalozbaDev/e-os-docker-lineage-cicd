#!/bin/bash

# restore state before container build
git checkout -- Dockerfile
git checkout -- Dockerfile.community

git checkout -- build-community.sh
git checkout -- src/build.sh

# fetch repository updates
git pull
git status

# prepare for container build
cp Dockerfile.community Dockerfile
cp build-community.sh src/build.sh

# build the container
docker build -t docker-lineage-cicd-custom .

# restore state after container build
git checkout -- Dockerfile
git checkout -- Dockerfile.community

git checkout -- build-community.sh
git checkout -- src/build.sh
