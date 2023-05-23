#!/bin/bash

set -e

if [[ "$CI" != "" ]];then
  echo "This script is designed to be run on developer laptops, not CI environments. Exiting"
  exit 1
fi

if [ -z "$1" ];then
  echo "Please provde the project name as the first argument (e.g. 'web'"
  echo "Hint:"
  aws s3 ls
  exit 1
fi
BUCKET="$1-dev-terraform-backends"

if [ -z "$2" ];then
  echo "Please provde one of these for the 'workspace' name as the second argument:"
  aws s3 ls "s3://$BUCKET/"
  exit 1
fi
S3_WORKSPACE=$2

AWS_SESSION=$(leapp session current | jq -r '.alias')
if [[ "$AWS_SESSION" == "" ]]; then
  echo 'Something went wrong whilst trying to get your current AWS session. Are you connected to LEAPP?'
  exit 1
fi

aws s3 cp "s3://$BUCKET/$S3_WORKSPACE/terraform.tfvars" .
echo "Copied variables file to terraform.tfvars"
cp terraform-local-configuration backend.tf
echo "Copied backend (S3) configuration to backend.tf"
