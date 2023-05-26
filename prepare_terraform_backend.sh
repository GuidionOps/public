#!/bin/bash

set -e

function throw_exception {
  echo "☠️  ${1:-"Unknown Error"}" 1>&2
  exit 1
}

trap throw_exception ERR

# Configure backend and exit early if on CI environment
#
if [[ "$CI" != "" || "$1" == "cicd" ]];then
  echo "terraform {
  cloud {
    organization = \"guidion\"
  }
}" > backend.tf


  echo "🤘 Created backend (CI) configuration as 'backend.tf'"
  exit 0
fi

## Local configuration section (CI sould never be able to get to this point)

# First some sanity checks :)
#
if [[ $(which leapp) == "" ]]; then
  throw_exception 'Please install the Leapp CLI: https://docs.leapp.cloud/latest/cli/'
fi

LEAPP_SESSION_NAME=$(leapp session list --output json | jq -c '.[] | select(.status == "active")' | jq -r '.sessionName')
if [[ "$LEAPP_SESSION_NAME" == "" ]];then
  throw_exception "You don't seem to have an active Leapp session. Start Leapp and start a session"
fi
echo "ℹ️  Your current Leapp session is $LEAPP_SESSION_NAME"

AWS_PROFILE=$(sed -nE 's/\[(.*)\]/\1/p' < ~/.aws/credentials)
if [[ "$AWS_PROFILE" == "" ]]; then
  throw_exception "Incredibly, you have a Leapp session, but AWS is somehow not configured. This isn't possible"
fi
export AWS_PROFILE

echo "ℹ️  Your current AWS profile is named $AWS_PROFILE"
echo "ℹ️  The session is for the AWS account '$(aws --output json sts get-caller-identity | jq -r '.Account')'"

# Now that we've checked for sanity, we can begin
#
AWS_SESSION=$(leapp session current --profile "$AWS_PROFILE" | jq -r '.alias')
if [[ "$AWS_SESSION" == "" ]]; then
  throw_exception 'Something went wrong whilst trying to get your current AWS session. Are you connected to LEAPP? Is this a CI environment?'
fi

if [ -z "$1" ];then
  throw_exception "Please provide the project name as the first argument (e.g. 'web')
ℹ️  Hint: It's the firs bit of a bucket ending with '-dev-terraform-backends'. Here's a listing of all the buckets in this account:

$(aws s3api list-buckets --output json | jq -c '.[] | .[] | try .Name')"
fi
PROJECT=$1
BUCKET="$PROJECT-dev-terraform-backends"

if [ -z "$2" ];then
  throw_exception "Please provide one of these for the 'workspace' name as the second argument:
ℹ️
$(aws s3 ls "s3://$BUCKET/" | sed 's/PRE //' | sed 's/\///')"
fi
S3_WORKSPACE=$2

aws s3 cp "s3://$BUCKET/$S3_WORKSPACE/terraform.tfvars" .
echo "🤘 Copied variables file to terraform.tfvars"

echo "
terraform {
  backend \"s3\" {
    profile        = \"$AWS_PROFILE\"
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
