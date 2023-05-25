#!/bin/bash

set -e

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
  echo '⚠️  Please install the Leapp CLI: https://docs.leapp.cloud/latest/cli/'
  exit 1
fi

LEAPP_SESSION_NAME=$(leapp session list --output json | jq -c '.[] | select(.status == "active")' | jq -r '.sessionName')
if [[ "$LEAPP_SESSION_NAME" == "" ]];then
  echo "☠️  You don't seem to have an active Leapp session. Start Leapp and start a session"
  exit 1
fi
echo "ℹ️  Your current Leapp session is $LEAPP_SESSION_NAME"
AWS_PROFILE=$(sed -nE 's/\[(.*)\]/\1/p' < ~/.aws/credentials)
if [[ "$AWS_PROFILE" == "" ]]; then
  echo "☠️  Incredibly, you have a Leapp session, but AWS is somehow not configured. This isn't possible"
  exit 1
fi
echo "ℹ️  Your current AWS profile is named $AWS_PROFILE"
echo "ℹ️  The session is for the AWS account $(aws --profile "$AWS_PROFILE" sts get-caller-identity | jq -r '.Account')"
read -r -p "❓ Does this all look correct? Only 'yes' will be accepted as affirmative: " CONFIRMATION
if [[ $(echo "$CONFIRMATION" | tr '[:upper:]' '[:lower:]') != "yes" ]];then
  echo "☠️ Okay, seeya! ☠️"
  exit 1
fi

# Now that we've checked for sanity, we can begin
#
AWS_SESSION=$(leapp session current --profile "$LEAPP_SESSION_NAME" | jq -r '.alias')
if [[ "$AWS_SESSION" == "" ]]; then
  echo '☠️  Something went wrong whilst trying to get your current AWS session. Are you connected to LEAPP? Is this a CI environment?'
  exit 1
fi

if [ -z "$1" ];then
  echo "⚠️  Please provide the project name as the first argument (e.g. 'web'"
  echo "ℹ️  Hint: It's the firs bit of a bucket ending with '-dev-terraform-backends'. Here's a listing of all the buckets in this account:"
  echo ""
  aws --profile "$AWS_PROFILE" s3 ls
  exit 1
fi
PROJECT=$1
BUCKET="$PROJECT-dev-terraform-backends"

if [ -z "$2" ];then
  echo "⚠️  Please provide one of these for the 'workspace' name as the second argument:"
  echo "ℹ️"
  aws --profile "$AWS_PROFILE" s3 ls "s3://$BUCKET/"
  exit 1
fi
S3_WORKSPACE=$2

aws --profile "$AWS_PROFILE" s3 cp "s3://$BUCKET/$S3_WORKSPACE/terraform.tfvars" .
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
