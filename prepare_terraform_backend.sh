#!/bin/bash

set -e

if [[ "$CI" != "" ]];then
  echo "This script is designed to be run on developer laptops, not CI environments. Exiting"
  exit 1
fi

if [ -z "$1" ];then
  echo "⚠️  Please provde the project name as the first argument (e.g. 'web'"
  echo "ℹ️  Hint: It's the firs bit of a bucket ending with '-dev-terraform-backends'"
  aws s3 ls
  exit 1
fi
PROJECT=$1
BUCKET="$PROJECT-dev-terraform-backends"

if [ -z "$2" ];then
  echo "⚠️  Please provde one of these for the 'workspace' name as the second argument:"
  echo "ℹ️"
  aws s3 ls "s3://$BUCKET/"
  exit 1
fi
S3_WORKSPACE=$2

AWS_SESSION=$(leapp session current | jq -r '.alias')
if [[ "$AWS_SESSION" == "" ]]; then
  echo '⚠️  Something went wrong whilst trying to get your current AWS session. Are you connected to LEAPP?'
  exit 1
fi

aws s3 cp "s3://$BUCKET/$S3_WORKSPACE/terraform.tfvars" .
echo "🤘 Copied variables file to terraform.tfvars"

echo "
terraform {
  backend \"s3\" {
    bucket         = \"$BUCKET\"
    key            = \"$S3_WORKSPACE/afsprk_nl.tfstate\"
    region         = \"eu-central-1\"
    dynamodb_table = \"$PROJECT-dev-terraform-backends-statefile-locks\"
    encrypt        = true
  }
}
" > backend.tf
echo "🤘 Created backend (S3) configuration as 'backend.tf'"

if ! [[ -f ".gitignore" ]]; then
  touch .gitignore
  echo "🤘 Created .gitignore file, because one didn't exist"
fi

IGNORED_FILES=( "node_modules" "dist" "coverage/" ".npmrc" ".DS_Store" "config/local.json" ".terraform" ".terraform.lock.hcl" "terraform.tfstate*" "*.tfvars" "backend.tf")
for this_filename in "${IGNORED_FILES[@]}"
do :
  if ! grep -q "$this_filename" '.gitignore'; then
    echo "$this_filename" >> .gitignore
    echo "🤘 Added $this_filename to .gitignore because it was missing"
  fi
done
